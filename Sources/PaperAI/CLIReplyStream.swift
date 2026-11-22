import Foundation
import PaperCore

/// Turns a CLI's JSON lines into a provider's events. Pure: the stream below feeds it lines and the exit.
protocol CLIReplyParser: Sendable {
    mutating func consume(_ line: Data) -> [CLIReplyStep]
    /// The process ended; returns at least one ending step if no line ended the reply.
    mutating func finish(_ exit: CLIExit, version: CLIVersion) -> [CLIReplyStep]
}

enum CLIReplyStep: Sendable, Equatable {
    case event(AIWriteEvent)
    case finished(AIStop)
    case failed(AIError)
    /// Fail, and end the process now rather than letting it finish: a tool appeared although every tool is off.
    case abort(AIError)
}

/// A CLI provider's `write`: prepares (finds the CLI, checks its version and sign-in), runs it, and relays what the
/// parser makes of its output, ending with exactly one `.finished` or one thrown `AIError`. Nothing runs before the
/// stream's first `next()` (`LazyEventStream`): a stream let go unread starts no CLI.
///
/// Once the reply is decided (the `result` or `turn.completed` line) the stream ends at once, but the process is left
/// to exit by itself, so the CLI tidies up its own session files; the runner's timeouts still bound it. Before that, the
/// consumer leaving (Stop, the deadline) ends the process.
enum CLIReplyStream {
    typealias Prepare = @Sendable () async throws -> (runner: CLIProcessRunner, command: CLICommand, version: CLIVersion)

    static func make<Parser: CLIReplyParser>(_ parser: Parser, prepare: @escaping Prepare) -> AsyncThrowingStream<AIWriteEvent, Error> {
        let answered = CLILatch()
        return LazyEventStream.make(cancelsWork: { termination in
            guard case .cancelled = termination else { return false }
            return !answered.isClosed
        }) { continuation in
            await relay(parser, prepare: prepare, answered: answered, into: continuation)
        }
    }

    private static func relay<Parser: CLIReplyParser>(_ parser: Parser, prepare: Prepare, answered: CLILatch,
                                                      into continuation: AsyncThrowingStream<AIWriteEvent, Error>.Continuation) async {
        var parser = parser
        do {
            let (runner, command, version) = try await prepare()
            try Task.checkCancellation()
            reading: for try await output in runner.run(command) {
                // After the answer, the rest is drained unread until the process exits by itself.
                guard !answered.isClosed else { continue }
                let steps: [CLIReplyStep]
                switch output {
                case .line(let line): steps = parser.consume(line)
                case .exit(let exit): steps = parser.finish(exit, version: version)
                }
                for step in steps {
                    switch step {
                    case .event(let event):
                        continuation.yield(event)
                    case .finished(let stop):
                        if answered.close() {
                            continuation.yield(.finished(stop))
                            continuation.finish()
                        }
                    case .failed(let error):
                        if answered.close() { continuation.finish(throwing: error) }
                    case .abort(let error):
                        if answered.close() { continuation.finish(throwing: error) }
                        // Leaving the loop drops the runner's stream, which ends the process.
                        break reading
                    }
                }
            }
            // Reached only when the consumer left (the stream is already over) or the run ended without an exit.
            if answered.close() {
                continuation.finish(throwing: Task.isCancelled ? AIError.cancelled : AIError.badResponse(code: 0))
            }
        } catch {
            if answered.close() { continuation.finish(throwing: AIError.from(error)) }
        }
    }
}

/// Closes once: the first answer wins.
final class CLILatch: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    var isClosed: Bool {
        lock.withLock { closed }
    }

    /// True for the caller that closed it.
    func close() -> Bool {
        lock.withLock {
            if closed { return false }
            closed = true
            return true
        }
    }
}

/// JSON helpers shared by the two parsers.
enum CLIJSON {
    static func object(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}
