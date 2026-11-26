import Foundation
import PaperCore
import XCTest
@testable import PaperAI

/// The API providers as the app runs them: built by `AIProviderFactory`, driven by `AIWriter`. The writer's Stop and
/// deadline must reach the URLSession task, and a refusal must reach the card as `AIError.refused`.
final class HTTPWriterIntegrationTests: HTTPProviderTestCase {
    private let keys = InMemoryAIKeyStore([.claudeAPI: "sk-ant-api03-TESTKEY", .openAIAPI: "sk-proj-TESTKEY"])
    private let field = AIFieldID(name: "integration")

    @MainActor
    private func makeWriter() -> AIWriter {
        let factory = AIProviderFactory(keys: keys, session: session)
        return AIWriter(resolve: { factory.provider(for: $0) }, hasConsent: { _, _ in true })
    }

    @MainActor
    func testBothAPIsWriteThroughTheWriter() async throws {
        let cases: [(AIProviderKind, String)] = [(.claudeAPI, "anthropic"), (.openAIAPI, "openai")]
        for (kind, folder) in cases {
            HTTPStubURLProtocol.reset()
            HTTPStubURLProtocol.serve([.sse(try fixture("\(folder)/stream-text-synthetic.sse"))])
            let outcome = await collect(makeWriter().write(writeRequest, using: AIProviderConfiguration(kind: kind), in: field, action: pressedWrite))
            XCTAssertNil(outcome.error, folder)
            XCTAssertEqual(outcome.text, "Hi Dana,\n\nThanks, Thursday at 10 works for me. I'll bring the draft — see you then.", folder)
            XCTAssertEqual(outcome.finished, [.done], folder)
            XCTAssertEqual(requests.count, 1, folder)
        }
    }

    @MainActor
    func testARefusalReachesTheCardAsRefused() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-refusal-synthetic.sse"))])
        let outcome = await collect(makeWriter().write(writeRequest, using: AIProviderConfiguration(kind: .claudeAPI, model: "claude-haiku-5-5"),
                                                       in: field, action: pressedWrite))
        XCTAssertEqual(outcome.error, .refused)
        XCTAssertEqual(outcome.error?.message(for: .claudeAPI), "Claude declined to write this.")

        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.serve([.sse(try fixture("openai/stream-refusal-synthetic.sse"))])
        let openAI = await collect(makeWriter().write(writeRequest, using: AIProviderConfiguration(kind: .openAIAPI), in: field, action: pressedWrite))
        XCTAssertEqual(openAI.error, .refused)
    }

    @MainActor
    func testAReplyCutBeforeAnyTextIsAnEmptyReply() async throws {
        let cut = #"""
        event: response.incomplete
        data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":10,"output_tokens":4000}}}


        """#
        HTTPStubURLProtocol.serve([.sse(cut)])
        let outcome = await collect(makeWriter().write(writeRequest, using: AIProviderConfiguration(kind: .openAIAPI), in: field, action: pressedWrite))
        XCTAssertEqual(outcome.error, .emptyReply, "reasoning used the whole cap")
    }

    @MainActor
    func testStopCancelsTheRequest() async throws {
        let text = try FixtureFiles.string("anthropic/stream-text-synthetic.sse")
        let open = String(text[..<text.range(of: "event: ping\ndata: {\"type\":\"ping\"}\n\nevent: content_block_delta")!.lowerBound])
        HTTPStubURLProtocol.serve([.streamThenHang(body: Data(open.utf8))])
        let writer = makeWriter()
        let stream = writer.write(writeRequest, using: AIProviderConfiguration(kind: .claudeAPI), in: field, action: pressedWrite)
        var events: [AIWriteEvent] = []
        for try await event in stream {
            events.append(event)
            if case .text = event { writer.stop(field) }
        }
        XCTAssertEqual(events, [.text("Hi Dana,\n\nThanks, Thursday"), .finished(.cancelled)])
        let stopped = await waitUntil { HTTPStubURLProtocol.stops == 1 }
        XCTAssertTrue(stopped, "Stop reached the URLSession task")
        XCTAssertFalse(writer.isWriting(in: field))
    }

    @MainActor
    func testTheDeadlineCancelsTheRequest() async throws {
        let text = try FixtureFiles.string("openai/stream-text-synthetic.sse")
        let open = String(text[..<text.range(of: "event: response.output_text.delta")!.lowerBound])
        HTTPStubURLProtocol.serve([.streamThenHang(body: Data(open.utf8))])
        var request = writeRequest
        request.deadline = .milliseconds(300)
        let outcome = await collect(makeWriter().write(request, using: AIProviderConfiguration(kind: .openAIAPI), in: field, action: pressedWrite))
        XCTAssertEqual(outcome.error, .timedOut)
        let stopped = await waitUntil { HTTPStubURLProtocol.stops == 1 }
        XCTAssertTrue(stopped, "the deadline reached the URLSession task")
    }

    @MainActor
    func testHealthAndCheckThroughTheWriter() async throws {
        let writer = makeWriter()
        var contacts: [String] = []
        let lock = NSLock()
        AIEgress.observe { contact, action in lock.withLock { contacts.append("\(action.kind.rawValue): \(contact)") } }
        defer { AIEgress.observe(nil) }
        let health = writer.localHealth(of: AIProviderConfiguration(kind: .openAIAPI, model: "gpt-6.2-sol"))
        XCTAssertEqual(health, .ready(detail: "Ready · GPT-6.2 Sol"))
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(lock.withLock { contacts }, [], "local health makes no contact")

        HTTPStubURLProtocol.serve([.json(try fixture("anthropic/models-synthetic.json"), status: 200)])
        let checked = await writer.check(AIProviderConfiguration(kind: .claudeAPI), action: pressedCheck)
        XCTAssertEqual(checked, .ready(detail: "Ready · Claude Opus 5.5"))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(lock.withLock { contacts }, ["check: GET api.anthropic.com/v1/models"], "recorded against the Check")

        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-text-synthetic.sse"))])
        _ = await collect(writer.write(writeRequest, using: AIProviderConfiguration(kind: .claudeAPI), in: field, action: pressedWrite))
        XCTAssertEqual(lock.withLock { contacts }.last, "write: POST api.anthropic.com/v1/messages")
        XCTAssertEqual(requests.count, 2)
    }
}
