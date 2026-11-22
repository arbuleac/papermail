import Foundation

/// The writer's side of the stream the UI reads. Text arrives from the provider's task while Stop, the deadline and the
/// consumer's own cancellation close the stream from elsewhere; the lock makes the first close win and drops anything
/// after it, so the UI never sees text after `.finished` or after an error.
final class AIStreamGate: @unchecked Sendable {
    enum Ending: Sendable, Equatable {
        case finished(AIStop)
        case failed(AIError)
        /// The consumer stopped reading.
        case abandoned
    }

    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<AIWriteEvent, Error>.Continuation
    private var ending: Ending?

    init(_ continuation: AsyncThrowingStream<AIWriteEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return ending != nil
    }

    func yield(_ event: AIWriteEvent) {
        lock.lock(); defer { lock.unlock() }
        guard ending == nil else { return }
        continuation.yield(event)
    }

    /// Closes the stream with `ending`; false when it was already closed.
    @discardableResult
    func close(_ ending: Ending) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.ending == nil else { return false }
        self.ending = ending
        switch ending {
        case .finished(let stop):
            continuation.yield(.finished(stop))
            continuation.finish()
        case .failed(let error):
            continuation.finish(throwing: error)
        case .abandoned:
            continuation.finish()
        }
        return true
    }
}
