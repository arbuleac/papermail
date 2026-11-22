import Foundation
import PaperCore
import XCTest
@testable import PaperAI

/// The Anthropic Messages API adapter over a stub URLProtocol: what it sends (SPEC §4: version 2026-10-21, effort low,
/// fallbacks only for Opus and Sonnet 5.5, no sampling parameters, nothing but the instructions and the user turn),
/// how it reads the stream, and how it fails and retries.
final class AnthropicMessagesProviderTests: HTTPProviderTestCase {
    private let keys = InMemoryAIKeyStore([.claudeAPI: "sk-ant-api03-TESTKEY"])

    private func provider(model: String? = nil, keys: (any AIKeyStoring)? = nil) -> AnthropicMessagesProvider {
        var provider = AnthropicMessagesProvider(model: model, keys: keys ?? self.keys, session: session)
        provider.pause = pauses.pause
        return provider
    }

    private func write(model: String? = nil, _ request: AIWriteRequest? = nil) async -> Outcome {
        await collect(provider(model: model).write(request ?? writeRequest, action: pressedWrite))
    }

    private func errorReply(_ status: Int, headers: [String: String] = [:]) throws -> HTTPStubURLProtocol.Reply {
        .json(try fixture("anthropic/error-\(status)-synthetic.json"), status: status, headers: headers)
    }

    // MARK: What is sent

    func testTheRequestIsExactlyTheSpecs() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-text-synthetic.sse"))])
        _ = await write(model: "claude-opus-5-5")

        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent.header("x-api-key"), "sk-ant-api03-TESTKEY")
        XCTAssertEqual(sent.header("anthropic-version"), "2026-10-21")
        XCTAssertEqual(sent.header("content-type"), "application/json")
        XCTAssertNil(sent.header("Authorization"), "the key goes in x-api-key only")

        let body = sent.json()
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "stream", "system", "messages", "output_config", "fallbacks"],
                       "nothing else: no temperature, top_p, top_k, thinking, metadata")
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 16_000)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, Self.instructions)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "one user turn, no assistant prefill")
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, writeRequest.userTurn)
        XCTAssertEqual(body["output_config"] as? [String: String], ["effort": "low"])
    }

    func testNoSamplingOrThinkingParametersForAnyModel() async throws {
        for model in [nil, "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"] {
            HTTPStubURLProtocol.reset()
            HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-text-synthetic.sse"))])
            _ = await write(model: model)
            let body = try XCTUnwrap(requests.first).json()
            for forbidden in ["temperature", "top_p", "top_k", "thinking", "stop_sequences", "metadata", "tools"] {
                XCTAssertNil(body[forbidden], "\(model ?? "default"): \(forbidden)")
            }
            XCTAssertEqual(body["output_config"] as? [String: String], ["effort": "low"], model ?? "default")
            XCTAssertEqual(try XCTUnwrap(requests.first).header("anthropic-version"), "2026-10-21")
        }
    }

    func testFallbacksOnlyForOpusAndSonnet() async throws {
        let expectations: [(String?, String, Bool)] = [
            (nil, "claude-opus-5-5", true),
            ("claude-opus-5-5", "claude-opus-5-5", true),
            ("claude-sonnet-5-5", "claude-sonnet-5-5", true),
            ("claude-haiku-5-5", "claude-haiku-5-5", false),
        ]
        for (model, sentModel, fallback) in expectations {
            HTTPStubURLProtocol.reset()
            HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-text-synthetic.sse"))])
            _ = await write(model: model)
            let sent = try XCTUnwrap(requests.first)
            let body = sent.json()
            XCTAssertEqual(body["model"] as? String, sentModel)
            if fallback {
                XCTAssertEqual(sent.header("anthropic-beta"), "server-side-fallback-2026-07-01", sentModel)
                XCTAssertEqual(body["fallbacks"] as? String, "default", sentModel)
            } else {
                XCTAssertNil(sent.header("anthropic-beta"), sentModel)
                XCTAssertNil(body["fallbacks"], "\(sentModel): no fallbacks key at all")
            }
        }
    }

    func testTheOutputCapCanBeChosen() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-text-synthetic.sse"))])
        var request = writeRequest
        request.maxOutputTokens = 2_000
        _ = await write(request)
        XCTAssertEqual(try XCTUnwrap(requests.first).json()["max_tokens"] as? Int, 2_000)
    }

    func testOnlyTheInstructionsAndTheUserTurnLeave() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-text-synthetic.sse"))])
        _ = await write()
        let text = try XCTUnwrap(requests.first).bodyText
        XCTAssertTrue(text.contains("TRANSCRIPT-MARK") && text.contains("TASK-MARK"))
        XCTAssertFalse(text.contains(WritePrompt.version), "the prompt version is for the log, not the provider")
        XCTAssertFalse(text.contains("ignored-by-api-providers"), "the request's model field is the CLIs'; the API sends its own")
    }

    // MARK: Reading the stream

    func testTextStreamsInOrderThenUsageThenDone() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-text-synthetic.sse"), pieces: 7)])
        let outcome = await write()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.events, [
            .text("Hi Dana,\n\nThanks, Thursday"),
            .text(" at 10 works for me."),
            .text(" I'll bring the draft — see you then."),
            .usage(AIUsage(inputTokens: 412, outputTokens: 38)),
            .finished(.done),
        ], "the thinking block, its signature and the pings never reach the field")
    }

    func testAFallbackContinuesTheTextAlreadyStreamed() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-fallback-synthetic.sse"))])
        let outcome = await write()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.text, "Hi Dana,\n\nThanks for the update. Thursday works.")
        XCTAssertEqual(outcome.finished, [.done])
        XCTAssertFalse(outcome.events.contains { if case .replaceAll = $0 { return true } else { return false } })
    }

    func testARefusalFinishesAsRefused() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-refusal-synthetic.sse"))])
        let outcome = await write(model: "claude-haiku-5-5")
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.finished, [.refused])
        XCTAssertEqual(outcome.events.last, .finished(.refused))
    }

    func testMaxTokensFinishesCutShort() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-max-tokens-synthetic.sse"))])
        let outcome = await write(model: "claude-sonnet-5-5")
        XCTAssertEqual(outcome.text, "Hi Dana, thanks for")
        XCTAssertEqual(outcome.finished, [.maxTokens])
    }

    func testCRLFLineEndsReadTheSame() async throws {
        let lf = try FixtureFiles.string("anthropic/stream-text-synthetic.sse")
        // The JSON's own line breaks are escaped (`\n` as two characters), so only the wire's line ends change.
        HTTPStubURLProtocol.serve([.sse(lf.replacingOccurrences(of: "\n", with: "\r\n"), pieces: 13)])
        let outcome = await write()
        XCTAssertEqual(outcome.text, "Hi Dana,\n\nThanks, Thursday at 10 works for me. I'll bring the draft — see you then.")
        XCTAssertEqual(outcome.finished, [.done])
    }

    // MARK: Failures and the one retry

    func testAnOverloadBeforeAnyTextIsRetriedOnce() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-overloaded-synthetic.sse")),
                                   .sse(try fixture("anthropic/stream-text-synthetic.sse"))])
        let outcome = await write()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.finished, [.done])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(pauses.delays, [1], "no retry-after in a stream: a second")
        XCTAssertEqual(requests[0].body, requests[1].body, "the retry is the same request")
    }

    func testAnErrorAfterTextIsNeverRetried() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-error-after-text-synthetic.sse")),
                                   .sse(try fixture("anthropic/stream-text-synthetic.sse"))])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .overloaded)
        XCTAssertEqual(outcome.text, "Hi Dana,")
        XCTAssertTrue(outcome.finished.isEmpty)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(pauses.delays, [])
    }

    func testRateLimitWithAShortRetryAfterIsRetriedAfterIt() async throws {
        HTTPStubURLProtocol.serve([try errorReply(429, headers: ["retry-after": "3"]),
                                   .sse(try fixture("anthropic/stream-text-synthetic.sse"))])
        let outcome = await write()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(pauses.delays, [3])
    }

    func testRateLimitTwiceIsRateLimitedWithTheServersWait() async throws {
        HTTPStubURLProtocol.serve([try errorReply(429, headers: ["retry-after": "2"])])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .rateLimited(retryAfter: 2))
        XCTAssertEqual(requests.count, 2, "one retry, no more")
        XCTAssertEqual(pauses.delays, [2])
    }

    func testRateLimitWithALongWaitIsNotRetried() async throws {
        HTTPStubURLProtocol.serve([try errorReply(429, headers: ["retry-after": "30"])])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .rateLimited(retryAfter: 30))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(pauses.delays, [])
        XCTAssertEqual(outcome.error?.message(for: .claudeAPI), "Anthropic is limiting requests. Try again in 30 seconds.")
    }

    func test529IsOverloadedAfterOneRetry() async throws {
        HTTPStubURLProtocol.serve([try errorReply(529)])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .overloaded)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(pauses.delays, [1])
        XCTAssertEqual(outcome.error?.message(for: .claudeAPI), "Anthropic is busy. Try again in a moment.")
    }

    func test529ThenSuccessWrites() async throws {
        HTTPStubURLProtocol.serve([try errorReply(529), .sse(try fixture("anthropic/stream-text-synthetic.sse"))])
        let outcome = await write()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.finished, [.done])
    }

    func testServerErrorsAreRetriedOnceThenReportedWithTheirStatus() async throws {
        HTTPStubURLProtocol.serve([try errorReply(500)])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .badResponse(code: 500))
        XCTAssertEqual(requests.count, 2)
    }

    func testTheServerCanForbidTheRetry() async throws {
        HTTPStubURLProtocol.serve([try errorReply(529, headers: ["x-should-retry": "false"])])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .overloaded)
        XCTAssertEqual(requests.count, 1)
    }

    func testClientErrorsAreNeverRetried() async throws {
        let expected: [(Int, AIError)] = [
            (400, .badResponse(code: 400)),
            (401, .keyRefused),
            (402, .noCredit),
            (403, .keyRefused),
            (404, .modelUnavailable),
            (413, .badResponse(code: 413)),
        ]
        for (status, error) in expected {
            HTTPStubURLProtocol.reset()
            HTTPStubURLProtocol.serve([try errorReply(status)])
            let outcome = await write()
            XCTAssertEqual(outcome.error, error, "HTTP \(status)")
            XCTAssertEqual(requests.count, 1, "HTTP \(status): no retry")
            XCTAssertTrue(outcome.events.isEmpty, "HTTP \(status)")
        }
    }

    func testTheCardsWordsForTheCommonFailures() async throws {
        HTTPStubURLProtocol.serve([try errorReply(401)])
        let refused = await write()
        XCTAssertEqual(refused.error?.message(for: .claudeAPI), "The Anthropic API key was refused")
        XCTAssertEqual(refused.error?.needsSettings, true)

        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.serve([try errorReply(402)])
        let noCredit = await write()
        XCTAssertEqual(noCredit.error?.message(for: .claudeAPI), "Anthropic says the key has no credit")
    }

    func testAnErrorBodyWithoutJSONFallsBackToTheStatus() async {
        HTTPStubURLProtocol.serve([.http(status: 401, headers: ["Content-Type": "text/html"], body: Data("<html>nope</html>".utf8))])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .keyRefused)
    }

    func testAConnectionLostBeforeTheReplyIsRetried() async throws {
        HTTPStubURLProtocol.serve([.failure(.networkConnectionLost), .sse(try fixture("anthropic/stream-text-synthetic.sse"))])
        let outcome = await write()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(requests.count, 2)
    }

    func testNoNetworkIsOfflineAtOnce() async {
        HTTPStubURLProtocol.serve([.failure(.notConnectedToInternet)])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .offline)
        XCTAssertEqual(outcome.error?.message(for: .claudeAPI), "No connection")
        XCTAssertEqual(requests.count, 1)
    }

    func testAConnectionLostAfterTextIsNotRetried() async throws {
        let text = try FixtureFiles.string("anthropic/stream-text-synthetic.sse")
        let partial = String(text[..<text.range(of: "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}")!.lowerBound])
        HTTPStubURLProtocol.serve([.streamThenFail(body: Data(partial.utf8), .networkConnectionLost)])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .offline)
        XCTAssertFalse(outcome.text.isEmpty)
        XCTAssertEqual(requests.count, 1)
    }

    func testAStreamThatEndsWithoutStoppingIsAFailure() async throws {
        let text = try FixtureFiles.string("anthropic/stream-text-synthetic.sse")
        let cut = String(text[..<text.range(of: "event: message_delta")!.lowerBound])
        HTTPStubURLProtocol.serve([.sse(cut)])
        let outcome = await write()
        XCTAssertEqual(outcome.error, .badResponse(code: 0), "a reply that never said it was over is not complete")
        XCTAssertEqual(requests.count, 1, "text had been shown: no retry")
    }

    func testAStreamThatLosesOnlyItsLastEventIsComplete() async throws {
        let text = try FixtureFiles.string("anthropic/stream-text-synthetic.sse")
        let cut = String(text[..<text.range(of: "event: message_stop")!.lowerBound])
        HTTPStubURLProtocol.serve([.sse(cut)])
        let outcome = await write()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.finished, [.done])
    }

    // MARK: Keys, laziness, cancellation

    func testNoKeyFailsBeforeAnythingIsSent() async {
        let outcome = await collect(provider(keys: InMemoryAIKeyStore()).write(writeRequest, action: pressedWrite))
        XCTAssertEqual(outcome.error, .missingKey)
        XCTAssertTrue(requests.isEmpty)
    }

    func testAnUnreadableKeychainFailsBeforeAnythingIsSent() async {
        let outcome = await collect(provider(keys: HTTPThrowingKeyStore()).write(writeRequest, action: pressedWrite))
        XCTAssertEqual(outcome.error, .missingKey)
        XCTAssertTrue(requests.isEmpty)
    }

    func testNothingIsSentOrReadUntilTheStreamIsRead() async throws {
        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-text-synthetic.sse"))])
        let stream = provider().write(writeRequest, action: pressedWrite)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(keys.reads(of: .claudeAPI), 0)

        let outcome = await collect(stream)
        XCTAssertEqual(outcome.finished, [.done])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(keys.reads(of: .claudeAPI), 1, "the key is read once per write, right before sending")
    }

    func testCancellingTheReaderCancelsTheRequest() async throws {
        let text = try FixtureFiles.string("anthropic/stream-text-synthetic.sse")
        let open = String(text[..<text.range(of: "event: ping\ndata: {\"type\":\"ping\"}\n\nevent: content_block_delta")!.lowerBound])
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
        XCTAssertEqual(requests.count, 1)
    }

    // MARK: Health and Check

    func testHealthReadsNoKeyAndSendsNothing() async {
        let ready = provider(model: "claude-haiku-5-5").localHealth()
        XCTAssertEqual(ready, .ready(detail: "Ready · Claude Haiku 5.5"))
        let byDefault = provider().localHealth()
        XCTAssertEqual(byDefault, .ready(detail: "Ready · Claude Opus 5.5"))
        let noKey = provider(keys: InMemoryAIKeyStore()).localHealth()
        XCTAssertEqual(noKey, .needsSetup(reason: "Add your API key"))
        XCTAssertEqual(keys.reads(of: .claudeAPI), 0, "health asks only whether a key is stored: no Keychain prompt")
        XCTAssertTrue(requests.isEmpty)
    }

    func testCheckSendsOnlyTheKeyToTheModelsList() async throws {
        HTTPStubURLProtocol.serve([.json(try fixture("anthropic/models-synthetic.json"), status: 200)])
        let health = await provider(model: "claude-sonnet-5-5").check(pressedCheck)
        XCTAssertEqual(health, .ready(detail: "Ready · Claude Sonnet 5.5"))
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.url.path, "/v1/models")
        XCTAssertEqual(sent.url.host, "api.anthropic.com")
        XCTAssertEqual(sent.header("x-api-key"), "sk-ant-api03-TESTKEY")
        XCTAssertEqual(sent.header("anthropic-version"), "2026-10-21")
        XCTAssertTrue(sent.body?.isEmpty ?? true)
    }

    func testCheckSaysWhenTheKeyIsRefused() async throws {
        HTTPStubURLProtocol.serve([try errorReply(401)])
        let health = await provider().check(pressedCheck)
        XCTAssertEqual(health, .needsSetup(reason: "The Anthropic API key was refused"))
    }

    func testCheckSaysWhenTheModelIsNotListed() async throws {
        let list = #"{"data":[{"type":"model","id":"claude-haiku-5-5"}],"has_more":false}"#
        HTTPStubURLProtocol.serve([.json(Data(list.utf8), status: 200)])
        let health = await provider(model: "claude-opus-5-5").check(pressedCheck)
        XCTAssertEqual(health, .needsSetup(reason: "Claude Opus 5.5 isn't available with this key. Choose another model."))
    }

    func testCheckTrustsAListWithMorePages() async throws {
        let list = #"{"data":[{"type":"model","id":"claude-haiku-5-5"}],"has_more":true}"#
        HTTPStubURLProtocol.serve([.json(Data(list.utf8), status: 200)])
        let health = await provider(model: "claude-opus-5-5").check(pressedCheck)
        XCTAssertEqual(health, .ready(detail: "Ready · Claude Opus 5.5"))
    }

    func testCheckWithoutAKeyOrNetwork() async {
        let noKey = await provider(keys: InMemoryAIKeyStore()).check(pressedCheck)
        XCTAssertEqual(noKey, .needsSetup(reason: "Add your API key"))
        XCTAssertTrue(requests.isEmpty)

        HTTPStubURLProtocol.serve([.failure(.notConnectedToInternet)])
        let offline = await provider().check(pressedCheck)
        XCTAssertEqual(offline, .unavailable(reason: "No connection"))
    }

    // MARK: Privacy

    func testErrorsNeverCarryTheBodyTheRequestOrTheKey() async throws {
        var outcomes: [Outcome] = []
        for status in [400, 401, 402, 403, 404, 413, 429, 500, 529] {
            HTTPStubURLProtocol.reset()
            HTTPStubURLProtocol.serve([try errorReply(status)])
            outcomes.append(await write())
        }
        HTTPStubURLProtocol.reset()
        HTTPStubURLProtocol.serve([.sse(try fixture("anthropic/stream-error-after-text-synthetic.sse"))])
        outcomes.append(await write())

        let secrets = ["SENTINEL", "REQUEST-ECHO", "TRANSCRIPT-MARK", "TASK-MARK", "FIXED-INSTRUCTIONS", "TESTKEY", "sk-ant",
                       "credit balance", "x-api-key", "Hi Dana", "req_fixture"]
        for outcome in outcomes {
            let error = try XCTUnwrap(outcome.error)
            for rendering in renderings(of: error, kind: .claudeAPI) {
                for secret in secrets {
                    XCTAssertFalse(rendering.contains(secret), "\(rendering) contains \(secret)")
                }
            }
        }
    }
}

/// A key store whose Keychain cannot be read.
final class HTTPThrowingKeyStore: AIKeyStoring, @unchecked Sendable {
    struct Unreadable: Error {}
    func key(for kind: AIProviderKind) throws -> String? { throw Unreadable() }
    func hasKey(for kind: AIProviderKind) throws -> Bool { throw Unreadable() }
    func setKey(_ key: String?, for kind: AIProviderKind) throws { throw Unreadable() }
}
