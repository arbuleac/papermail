import Foundation
import PaperCore
import XCTest
@testable import PaperAI

/// Shared ground for the Anthropic and OpenAI provider tests: the stub session, a request whose every part is
/// recognisable, the waits the one retry asked for, and reading a stream to its end.
class HTTPProviderTestCase: XCTestCase {
    let session = HTTPStubURLProtocol.makeSession()
    let pauses = HTTPPauseRecorder()

    static let instructions = "FIXED-INSTRUCTIONS: write the reply body only."
    static let transcript = "<<<CONVERSATION 0a1b2c3d>>>\nDana: Does Thursday at 10 work? TRANSCRIPT-MARK\n<<<END CONVERSATION 0a1b2c3d>>>"
    static let task = "Instruction: say yes and that I'll bring the draft. TASK-MARK"

    var writeRequest: AIWriteRequest {
        AIWriteRequest(instructions: Self.instructions, transcript: Self.transcript, task: Self.task, model: "ignored-by-api-providers")
    }

    override func setUp() {
        super.setUp()
        HTTPStubURLProtocol.reset()
    }

    override func tearDown() {
        HTTPStubURLProtocol.reset()
        super.tearDown()
    }

    var requests: [HTTPStubURLProtocol.Request] { HTTPStubURLProtocol.requests }

    struct Outcome {
        var events: [AIWriteEvent]
        var error: AIError?

        var text: String {
            var text = ""
            for event in events {
                switch event {
                case .text(let more): text += more
                case .replaceAll(let all): text = all
                case .usage, .finished: break
                }
            }
            return text
        }

        var finished: [AIStop] {
            events.compactMap { if case .finished(let stop) = $0 { return stop } else { return nil } }
        }

        var usage: AIUsage? {
            events.compactMap { if case .usage(let usage) = $0 { return usage } else { return nil } }.last
        }
    }

    /// Reads `stream` to its end; fails the test if it throws anything but an `AIError`.
    func collect(_ stream: AsyncThrowingStream<AIWriteEvent, Error>, file: StaticString = #filePath, line: UInt = #line) async -> Outcome {
        var events: [AIWriteEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return Outcome(events: events, error: nil)
        } catch let error as AIError {
            return Outcome(events: events, error: error)
        } catch {
            XCTFail("threw something other than an AIError", file: file, line: line)
            return Outcome(events: events, error: .badResponse(code: -1))
        }
    }

    /// Waits until `condition` holds, up to `timeout`.
    func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    func fixture(_ path: String) throws -> Data {
        try FixtureFiles.data(path)
    }

    /// Every way an error can be printed, for the “no request text, body or key in errors” checks.
    func renderings(of error: AIError, kind: AIProviderKind) -> [String] {
        [error.description, error.debugDescription, error.localizedDescription, error.message(for: kind),
         error.message(for: nil), String(describing: error), String(reflecting: error)]
    }
}

/// Records the waits before a retry instead of sleeping.
final class HTTPPauseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var delays: [TimeInterval] { lock.withLock { recorded } }

    var pause: HTTPRetryPolicy.Pause {
        { [self] seconds in lock.withLock { recorded.append(seconds) } }
    }
}
