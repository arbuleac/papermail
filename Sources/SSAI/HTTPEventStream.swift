import Foundation
import SSCore

/// The stream an API provider's `write` returns. Its work (reading the key, then sending) starts on the stream's first
/// `next()`, not when the stream is made, so a stream nobody reads sends nothing and reads no key (the port's promise).
/// When the reader stops (its task is cancelled, or it lets the stream go) the work is cancelled, which cancels the
/// URLSession task: `AIWriter`'s Stop and deadline reach the network that way.
enum HTTPEventStream {
    typealias Continuation = LazyEventStream.Continuation

    static func make(_ work: @escaping LazyEventStream.Work) -> AsyncThrowingStream<AIWriteEvent, Error> {
        LazyEventStream.make(work)
    }
}

/// A provider's stream whose work starts on the stream's first `next()`, never when the stream is made: a stream
/// nobody reads sends nothing, reads no key and starts no process (the port's promise). `HTTPEventStream` for the APIs,
/// `CLIReplyStream` for the CLIs.
enum LazyEventStream {
    typealias Continuation = AsyncThrowingStream<AIWriteEvent, Error>.Continuation
    typealias Work = @Sendable (Continuation) async -> Void

    /// - Parameter cancelsWork: when the stream ends, whether started work is cancelled with it. Always, by default; a
    ///   CLI's work goes on after its answer so the CLI can tidy up and exit by itself.
    static func make(cancelsWork: @escaping @Sendable (Continuation.Termination) -> Bool = { _ in true },
                     _ work: @escaping Work) -> AsyncThrowingStream<AIWriteEvent, Error> {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: AIWriteEvent.self, throwing: Error.self)
        let starter = Starter(work: work, continuation: continuation)
        continuation.onTermination = { termination in starter.end(cancellingWork: cancelsWork(termination)) }
        let reader = Reader(events.makeAsyncIterator())
        // `unfolding` runs in the reader's own task, so its cancellation reaches the inner iterator, which ends the
        // inner stream and, through `onTermination`, the work.
        return AsyncThrowingStream {
            starter.startOnce()
            return try await reader.next()
        }
    }

    /// Starts the work once, on the first read, unless the stream already ended.
    private final class Starter: @unchecked Sendable {
        private let lock = NSLock()
        private var work: Work?
        private var continuation: Continuation?
        private var task: Task<Void, Never>?

        init(work: @escaping Work, continuation: Continuation) {
            self.work = work
            self.continuation = continuation
        }

        func startOnce() {
            lock.lock()
            defer { lock.unlock() }
            guard let work, let continuation else { return }
            self.work = nil
            self.continuation = nil
            task = Task { await work(continuation) }
        }

        /// The stream ended: work not started never starts; started work is cancelled when `cancellingWork`.
        func end(cancellingWork: Bool) {
            lock.lock()
            let task = self.task
            work = nil
            continuation = nil
            lock.unlock()
            if cancellingWork { task?.cancel() }
        }
    }

    /// The inner stream's iterator, kept between reads. The reader reads one element at a time, so the box is never
    /// used from two tasks at once.
    private final class Reader: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<AIWriteEvent, Error>.AsyncIterator

        init(_ iterator: AsyncThrowingStream<AIWriteEvent, Error>.AsyncIterator) {
            self.iterator = iterator
        }

        func next() async throws -> AIWriteEvent? {
            // The iterator is a handle on shared storage: advancing a copy advances the stream.
            var iterator = self.iterator
            defer { self.iterator = iterator }
            return try await iterator.next()
        }
    }
}
