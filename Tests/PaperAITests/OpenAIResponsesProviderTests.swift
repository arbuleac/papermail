import Foundation
import PaperCore
import XCTest
@testable import PaperAI

/// The OpenAI Responses API adapter over a stub URLProtocol: `store: false` on every request, effort never `none`
/// on the GPT-6.2 models, the stream's events, and the 429 that is money versus the 429 that is a rate limit.
final class OpenAIResponsesProviderTests: HTTPProviderTestCase {
    private let keys = InMemoryAIKeyStore([.openAIAPI: "sk-proj-TESTKEY"])

    private func provider(model: String? = nil, keys: (any AIKeyStoring)? = nil) -> OpenAIResponsesProvider {
        var provider = OpenAIResponsesProvider(model: model, keys: keys ?? self.keys, session: session)
        provider.pause = pauses.pause
        return provider
    }

    private func write(model: String? = nil, _ request: AIWriteRequest? = nil) async -> Outcome {
        await collect(provider(model: model).write(request ?? writeRequest, action: pressedWrite))
    }

    private func errorReply(_ name: String, status: Int, headers: [String: String] = [:]) throws -> HTTPStubURLProtocol.Reply {
        .json(try fixture("openai/\(name).json"), status: status, headers: headers)
    }

    private static let text = "Hi Dana,\n\nThanks, Thursday at 10 works for me. I'll bring the draft — see you then."

    // MARK: What is sent

    func testTheRequestIsExactlyTheSpecs() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("openai/stream-text-synthetic.sse"))])
        _ = await write()

        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(sent.header("Authorization"), "Bearer sk-proj-TESTKEY")
        XCTAssertEqual(sent.header("Content-Type"), "application/json")

        let body = sent.json()
        XCTAssertEqual(Set(body.keys), ["model", "instructions", "input", "max_output_tokens", "store", "reasoning", "text",
                                        "stream", "stream_options"],
                       "nothing else: no temperature, top_p, user, previous_response_id, tools")
        XCTAssertEqual(body["model"] as? String, "gpt-6.1-terra")
        XCTAssertEqual(body["instructions"] as? String, Self.instructions)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input.first?["role"] as? String, "user")
        let content = try XCTUnwrap(input.first?["content"] as? [[String: String]])
        XCTAssertEqual(content, [["type": "input_text", "text": writeRequest.userTurn]])
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4_000)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": "low"])
        XCTAssertEqual(body["text"] as? [String: String], ["verbosity": "low"])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["stream_options"] as? [String: Bool], ["include_obfuscation": false])
    }

    func testStoreIsFalseOnEveryRequestAndEffortIsNeverNoneOnGPT62() async throws {
        let models = [nil] + AIProviderKind.openAIAPI.modelChoices.map(\.model)
        for model in models {
            for cap in [nil, 1, 8_000] {
                HTTPStubURLProtocol.reset()
                HTTPStubURLProtocol.serve([.sse(try fixture("openai/stream-text-synthetic.sse"))])
                var request = writeRequest
                request.maxOutputTokens = cap
                _ = await write(model: model, request)
                let body = try XCTUnwrap(requests.first).json()
                let name = model ?? "default"
                XCTAssertEqual(body["store"] as? Bool, false, name)
                let effort = try XCTUnwrap((body["reasoning"] as? [String: String])?["effort"], name)
                XCTAssertFalse(["none", "minimal"].contains(effort), name)
                if name.hasPrefix("gpt-6.2-") { XCTAssertEqual(effort, "low", name) }
                XCTAssertNil(body["temperature"], name)
                XCTAssertNil(body["top_p"], name)
                XCTAssertGreaterThanOrEqual(body["max_output_tokens"] as? Int ?? 0, 16, "\(name): the API's floor")
            }
        }
    }

    func testTheEffortRuleCoversEveryModelThisBuildOffers() throws {
        for choice in AIProviderKind.openAIAPI.modelChoices {
            let model = try XCTUnwrap(choice.model)
            XCTAssertEqual(OpenAIResponsesProvider.reasoningEffort(for: model), "low", model)
        }
        XCTAssertEqual(OpenAIResponsesProvider.reasoningEffort(for: "gpt-6.2-astra"), "low")
    }

    func testTheChosenModelAndCapAreSent() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("openai/stream-text-synthetic.sse"))])
        var request = writeRequest
        request.maxOutputTokens = 1_500
        _ = await write(model: "gpt-6.2-sol", request)
        let body = try XCTUnwrap(requests.first).json()
        XCTAssertEqual(body["model"] as? String, "gpt-6.2-sol")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 1_500)
    }

    func testOnlyTheInstructionsAndTheUserTurnLeave() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("openai/stream-text-synthetic.sse"))])
        _ = await write()
        let text = try XCTUnwrap(requests.first).bodyText
        XCTAssertTrue(text.contains("TRANSCRIPT-MARK") && text.contains("TASK-MARK"))
        XCTAssertFalse(text.contains(WritePrompt.version))
        XCTAssertFalse(text.contains("ignored-by-api-providers"))
    }

    // MARK: Reading the stream

    func testTextStreamsThenUsageThenDone() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("openai/stream-text-synthetic.sse"), pieces: 9)])
        let outcome = await write()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.events, [
            .text("Hi Dana,\n\nThanks, Thursday"),
            .text(" at 10 works for me."),
            .text(" I'll bring the draft — see you then."),
            .usage(AIUsage(inputTokens: 397, outputTokens: 52)),
            .finished(.done),
        ], "the reasoning item, the comment and the repeated final text add nothing")
        XCTAssertEqual(outcome.text, Self.text)
    }

    func testAFinalTextThatDiffersReplacesWhatStreamed() async throws {
        let original = try FixtureFiles.string("openai/stream-text-synthetic.sse")
        let edited = original.replacingOccurrences(
            of: #""text":"Hi Dana,\n\nThanks, Thursday at 10 works for me. I'll bring the draft — see you then.","sequence_number":9"#,
            with: #""text":"Hi Dana,\n\nThursday at 10 works.","sequence_number":9"#)
        XCTAssertNotEqual(original, edited)
        HTTPStubURLProtocol.serve([.sse(edited)])
        let outcome = await write()
        XCTAssertEqual(outcome.text, "Hi Dana,\n\nThursday at 10 works.")
        XCTAssertTrue(outcome.events.contains(.replaceAll("Hi Dana,\n\nThursday at 10 works.")))
        XCTAssertEqual(outcome.finished, [.done])
    }

    func testARefusalFinishesAsRefusedAndItsWordsNeverArrive() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("openai/stream-refusal-synthetic.sse"))])
        let outcome = await write(model: "gpt-6.2-sol")
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.events, [.finished(.refused)])
    }

    func testIncompleteForTheCapIsMaxTokensAndForAFilterIsRefused() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("openai/stream-incomplete-synthetic.sse"))])
        let cut = await write(model: "gpt-6-luna")
        XCTAssertEqual(cut.text, "Hi Dana, thanks for")
        XCTAssertEqual(cut.finished, [.maxTokens])

        HTTPStubURLProtocol.reset()
        let filtered = try FixtureFiles.string("openai/stream-incomplete-synthetic.sse")
            .replacingOccurrences(of: "\"reason\":\"max_output_tokens\"", with: "\"reason\":\"content_filter\"")
        HTTPStubURLProtocol.serve([.sse(filtered)])
        let outcome = await write(model: "gpt-6-luna")
        XCTAssertEqual(outcome.finished, [.refused])
    }

    func testADoneSentinelIsTolerated() async throws {
        let stream = try FixtureFiles.string("openai/stream-text-synthetic.sse") + "data: [DONE]\n\n"
        HTTPStubURLProtocol.serve([.sse(stream)])
        let outcome = await write()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.finished, [.done])
    }

    // MARK: Failures and the one retry

    func testTheRecorded401IsReadAsAnErrorNotAsAStream() async throws {
        // Recorded live: a streamed request with a bad key answers `text/plain` JSON, not SSE.
        HTTPStubURLProtocol.serve([.http(status: 401, headers: ["Content-Type": "text/plain"],
                                         body: try fixture("openai/401-invalid-key-stream.txt"))])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .keyRefused)
        XCTAssertEqual(outcome.error?.message(for: .openAIAPI), "The OpenAI API key was refused")
        XCTAssertEqual(requests.count, 1)
    }

    func testAMissingBearerIsAKeyRefusal() async throws {
        HTTPStubURLProtocol.serve([try errorReply("401-missing-key", status: 401)])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .keyRefused)
    }

    func testNoCreditIsNeverRetriedWhateverTheRetryAfter() async throws {
        HTTPStubURLProtocol.serve([try errorReply("error-429-insufficient-quota-synthetic", status: 429, headers: ["retry-after": "1"])])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .noCredit)
        XCTAssertEqual(outcome.error?.message(for: .openAIAPI), "OpenAI says the key has no credit")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(pauses.delays, [])
    }

    func testASpendLimitIsTheUsageLimit() async throws {
        HTTPStubURLProtocol.serve([try errorReply("error-429-spend-limit-synthetic", status: 429)])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .planLimit)
        XCTAssertEqual(outcome.error?.message(for: .openAIAPI), "Your OpenAI usage limit is reached")
        XCTAssertEqual(requests.count, 1)
    }

    func testARateLimitWithAShortWaitIsRetriedOnce() async throws {
        HTTPStubURLProtocol.serve([try errorReply("error-429-rate-limit-synthetic", status: 429, headers: ["retry-after": "2"]),
                                   .sse(try fixture("openai/stream-text-synthetic.sse"))])
        let outcome = await write()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.text, Self.text)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(pauses.delays, [2])
    }

    func testRetryAfterInMillisecondsWins() async throws {
        HTTPStubURLProtocol.serve([try errorReply("error-429-rate-limit-synthetic", status: 429,
                                                  headers: ["retry-after-ms": "250", "retry-after": "1"]),
                                   .sse(try fixture("openai/stream-text-synthetic.sse"))])
        _ = await write()
        XCTAssertEqual(pauses.delays, [0.25])
    }

    func testARateLimitWithALongWaitIsReportedAtOnce() async throws {
        HTTPStubURLProtocol.serve([try errorReply("error-429-rate-limit-synthetic", status: 429, headers: ["retry-after": "20"])])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .rateLimited(retryAfter: 20))
        XCTAssertEqual(requests.count, 1)
    }

    func testAnOverloadedServerIsRetriedOnce() async throws {
        HTTPStubURLProtocol.serve([try errorReply("error-503-overloaded-synthetic", status: 503)])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .overloaded)
        XCTAssertEqual(outcome.error?.message(for: .openAIAPI), "OpenAI is busy. Try again in a moment.")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(pauses.delays, [1])
    }

    func testServerErrorsKeepTheirStatus() async throws {
        HTTPStubURLProtocol.serve([try errorReply("error-500-synthetic", status: 500)])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .badResponse(code: 500))
        XCTAssertEqual(requests.count, 2)
    }

    func testAnUnknownModelIsUnavailable() async throws {
        HTTPStubURLProtocol.serve([try errorReply("error-400-model-not-found-synthetic", status: 400)])
        let byCode = await write(model: "gpt-6.2-astra")
        XCTAssertEqual(byCode.error, .modelUnavailable)
        XCTAssertEqual(byCode.error?.needsSettings, true)

        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.serve([.json(Data(#"{"error":{"message":"Not found","type":"invalid_request_error","param":null,"code":null}}"#.utf8), status: 404)])
        let byStatus = await write(model: "gpt-6.2-astra")
        XCTAssertEqual(byStatus.error, .modelUnavailable)
        XCTAssertEqual(requests.count, 1)
    }

    func testOtherBadRequestsAreBadResponses() async throws {
        HTTPStubURLProtocol.serve([try errorReply("error-400-invalid-request-synthetic", status: 400)])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .badResponse(code: 400))
        XCTAssertEqual(requests.count, 1)
    }

    func testAFailedResponseBeforeTextIsRetried() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("openai/stream-failed-synthetic.sse")),
                                   .sse(try fixture("openai/stream-text-synthetic.sse"))])
        let outcome = await write()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.text, Self.text)
        XCTAssertEqual(requests.count, 2)
    }

    func testAFailedResponseTwiceIsABadResponse() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("openai/stream-failed-synthetic.sse"))])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .badResponse(code: 500))
        XCTAssertEqual(requests.count, 2)
    }

    func testAnErrorEventAfterTextIsNeverRetried() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("openai/stream-error-after-text-synthetic.sse")),
                                   .sse(try fixture("openai/stream-text-synthetic.sse"))])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .badResponse(code: 500))
        XCTAssertEqual(outcome.text, "Hi Dana,")
        XCTAssertEqual(requests.count, 1)
    }

    func testAStreamWithoutATerminalEventIsAFailure() async throws {
        let text = try FixtureFiles.string("openai/stream-text-synthetic.sse")
        let cut = String(text[..<text.range(of: "event: response.completed")!.lowerBound])
        HTTPStubURLProtocol.serve([.sse(cut)])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .badResponse(code: 0))
        XCTAssertEqual(requests.count, 1, "text had been shown: no retry")
    }

    // MARK: Keys, laziness, cancellation

    func testNoKeyFailsBeforeAnythingIsSent() async {
        let outcome = await collect(provider(keys: InMemoryAIKeyStore([.claudeAPI: "sk-ant-other"])).write(writeRequest, action: pressedWrite))
        XCTAssertEqual(outcome.error, .missingKey)
        XCTAssertEqual(outcome.error?.message(for: .openAIAPI), "Add your OpenAI API key in Settings › AI")
        XCTAssertTrue(requests.isEmpty)
    }

    func testNothingIsSentOrReadUntilTheStreamIsRead() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("openai/stream-text-synthetic.sse"))])
        let stream = provider().write(writeRequest, action: pressedWrite)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(keys.reads(of: .openAIAPI), 0)
        _ = await collect(stream)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(keys.reads(of: .openAIAPI), 1)
    }

    func testCancellingTheReaderCancelsTheRequest() async throws {
        let text = try FixtureFiles.string("openai/stream-text-synthetic.sse")
        let open = String(text[..<text.range(of: ": Intermediate response events omitted.")!.lowerBound])
        HTTPStubURLProtocol.serve([.streamThenHang(body: Data(open.utf8))])
        let stream = provider().write(writeRequest, action: pressedWrite)
        let firstText = expectation(description: "first text")
        let reader = Task {
            for try await event in stream {
                if case .text = event { firstText.fulfill() }
            }
        }
        await fulfillment(of: [firstText], timeout: 3)
        reader.cancel()
        let stopped = await waitUntil { HTTPStubURLProtocol.stops == 1 }
        XCTAssertTrue(stopped, "the URLSession task was cancelled")
    }

    // MARK: Health and Check

    func testHealthReadsNoKeyAndSendsNothing() async {
        let ready = provider().localHealth()
        XCTAssertEqual(ready, .ready(detail: "Ready · GPT-6.1 Terra"))
        let sol = provider(model: "gpt-6.2-sol").localHealth()
        XCTAssertEqual(sol, .ready(detail: "Ready · GPT-6.2 Sol"))
        let noKey = provider(keys: InMemoryAIKeyStore()).localHealth()
        XCTAssertEqual(noKey, .needsSetup(reason: "Add your API key"))
        let keychain = provider(keys: HTTPThrowingKeyStore()).localHealth()
        XCTAssertEqual(keychain, .unavailable(reason: "The Keychain couldn't be read"))
        XCTAssertEqual(keys.reads(of: .openAIAPI), 0)
        XCTAssertTrue(requests.isEmpty)
    }

    func testCheckSendsOnlyTheKeyToTheModelsList() async throws {
        HTTPStubURLProtocol.serve([.json(try fixture("openai/models-synthetic.json"), status: 200)])
        let health = await provider().check(pressedCheck)
        XCTAssertEqual(health, .ready(detail: "Ready · GPT-6.1 Terra"))
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.url.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(sent.header("Authorization"), "Bearer sk-proj-TESTKEY")
        XCTAssertTrue(sent.body?.isEmpty ?? true)
    }

    func testCheckSaysWhenTheModelIsNotAvailableToTheKey() async throws {
        HTTPStubURLProtocol.serve([.json(try fixture("openai/models-synthetic.json"), status: 200)])
        let health = await provider(model: "gpt-6.2-astra").check(pressedCheck)
        XCTAssertEqual(health, .needsSetup(reason: "GPT-6.2 Astra isn't available with this key. Choose another model."))
    }

    func testCheckWithTheRecordedRefusals() async throws {
        for path in ["401-invalid-key", "401-missing-key"] {
            HTTPStubURLProtocol.reset()
            HTTPStubURLProtocol.serve([try errorReply(path, status: 401)])
            let health = await provider().check(pressedCheck)
            XCTAssertEqual(health, .needsSetup(reason: "The OpenAI API key was refused"), path)
        }
    }

    // MARK: Privacy

    func testErrorsNeverCarryTheBodyTheRequestOrTheKey() async throws {
        let replies: [HTTPStubURLProtocol.Reply] = [
            .http(status: 401, headers: ["Content-Type": "text/plain"], body: try fixture("openai/401-invalid-key-stream.txt")),
            try errorReply("error-429-insufficient-quota-synthetic", status: 429),
            try errorReply("error-429-rate-limit-synthetic", status: 429, headers: ["retry-after": "60"]),
            try errorReply("error-400-invalid-request-synthetic", status: 400),
            try errorReply("error-400-model-not-found-synthetic", status: 400),
            try errorReply("error-503-overloaded-synthetic", status: 503),
            .sse(try fixture("openai/stream-error-after-text-synthetic.sse")),
            .sse(try fixture("openai/stream-refusal-synthetic.sse")),
        ]
        var errors: [AIError] = []
        for reply in replies {
            HTTPStubURLProtocol.reset()
            HTTPStubURLProtocol.serve([reply])
            let outcome = await write()
            if let error = outcome.error { errors.append(error) }
            XCTAssertFalse(outcome.text.contains("SENTINEL"), "refusal or error words never reach the field")
        }
        XCTAssertEqual(errors.count, replies.count - 1, "all but the refusal, which finishes as refused")
        let secrets = ["SENTINEL", "REQUEST-ECHO", "TRANSCRIPT-MARK", "TASK-MARK", "FIXED-INSTRUCTIONS", "TESTKEY", "sk-",
                       "Incorrect API key", "quota", "gpt-6.2-astra", "Hi Dana"]
        for error in errors {
            for rendering in renderings(of: error, kind: .openAIAPI) {
                for secret in secrets {
                    XCTAssertFalse(rendering.contains(secret), "\(rendering) contains \(secret)")
                }
            }
        }
    }
}
