import Foundation
import PaperCore
import XCTest
@testable import PaperAI

/// The pieces both API providers share: the retry wait, error replies read without their words, the lazy stream, and
/// both decoders fed the fixtures in every chunk size a network might use.
final class HTTPStreamingTests: XCTestCase {
    private func response(_ headers: [String: String], status: Int = 429) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.example.invalid/v1")!, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: headers)!
    }

    // MARK: Retry policy

    func testRetryAfterReadsSecondsMillisecondsAndDates() {
        XCTAssertEqual(HTTPRetryPolicy.retryAfter(in: response(["retry-after": "7"])), 7)
        XCTAssertEqual(HTTPRetryPolicy.retryAfter(in: response(["Retry-After": " 1.5 "])), 1.5)
        XCTAssertEqual(HTTPRetryPolicy.retryAfter(in: response(["retry-after-ms": "250", "retry-after": "9"])), 0.25)
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = formatter.string(from: now.addingTimeInterval(5))
        XCTAssertEqual(HTTPRetryPolicy.retryAfter(in: response(["retry-after": date]), now: now) ?? -1, 5, accuracy: 0.5)
        XCTAssertNil(HTTPRetryPolicy.retryAfter(in: response([:])))
        XCTAssertNil(HTTPRetryPolicy.retryAfter(in: response(["retry-after": "soon"])))
        XCTAssertNil(HTTPRetryPolicy.retryAfter(in: response(["retry-after": "-3"])))
    }

    func testTheWaitIsTheServersOrASecondAndNeverLongerThanTen() {
        XCTAssertEqual(HTTPRetryPolicy.delay(after: nil), 1)
        XCTAssertEqual(HTTPRetryPolicy.delay(after: 0), 0)
        XCTAssertEqual(HTTPRetryPolicy.delay(after: 10), 10)
        XCTAssertNil(HTTPRetryPolicy.delay(after: 10.5))
        XCTAssertEqual(HTTPRetryPolicy.attempts, 2, "one try and one retry")
    }

    // MARK: Error replies

    func testAnErrorReplyKeepsTypeCodeAndHintsButNeverTheMessage() {
        let body = Data(#"{"type":"error","error":{"type":"rate_limit_error","code":"slow_down","message":"SECRET words"}}"#.utf8)
        let reply = HTTPErrorReply(response: response(["retry-after": "4", "x-should-retry": "false"]), body: body)
        XCTAssertEqual(reply, HTTPErrorReply(status: 429, type: "rate_limit_error", code: "slow_down", retryAfter: 4, shouldRetry: false))
        XCTAssertFalse(String(reflecting: reply).contains("SECRET"))
    }

    func testAnErrorReplyThatIsNotJSONHasOnlyItsStatus() {
        let reply = HTTPErrorReply(response: response([:], status: 502), body: Data("<html>Bad gateway</html>".utf8))
        XCTAssertEqual(reply, HTTPErrorReply(status: 502))
    }

    func testANumericCodeIsReadAsText() {
        let reply = HTTPErrorReply(response: response([:], status: 400), body: Data(#"{"error":{"code":42}}"#.utf8))
        XCTAssertEqual(reply.code, "42")
    }

    // MARK: The lazy stream

    func testTheWorkStartsOnTheFirstReadOnly() async throws {
        let started = HTTPCounter()
        let stream = HTTPEventStream.make { continuation in
            started.increment()
            continuation.yield(.text("a"))
            continuation.yield(.finished(.done))
            continuation.finish()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(started.value, 0)
        var events: [AIWriteEvent] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(events, [.text("a"), .finished(.done)])
        XCTAssertEqual(started.value, 1)
    }

    func testAStreamLetGoUnreadNeverStarts() async throws {
        let started = HTTPCounter()
        do {
            _ = HTTPEventStream.make { continuation in
                started.increment()
                continuation.finish()
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(started.value, 0)
    }

    func testCancellingTheReaderCancelsTheWork() async throws {
        let cancelled = expectation(description: "work cancelled")
        let stream = HTTPEventStream.make { continuation in
            continuation.yield(.text("first"))
            await withTaskCancellationHandler {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            } onCancel: {
                cancelled.fulfill()
            }
            continuation.finish()
        }
        let reader = Task {
            for try await _ in stream {}
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        reader.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
    }

    func testAnErrorEndsTheStream() async {
        let stream = HTTPEventStream.make { continuation in
            continuation.yield(.text("partial"))
            continuation.finish(throwing: AIError.overloaded)
        }
        var events: [AIWriteEvent] = []
        do {
            for try await event in stream { events.append(event) }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AIError, .overloaded)
        }
        XCTAssertEqual(events, [.text("partial")])
    }

    // MARK: Decoders over every chunking

    private func decode<Decoder: HTTPStreamDecoding>(_ data: Data, chunk: Int, as: Decoder.Type) -> [HTTPStreamStep] {
        var parser = SSEParser()
        var decoder = Decoder()
        var steps: [HTTPStreamStep] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: chunk, limitedBy: data.endIndex) ?? data.endIndex
            for event in parser.feed(data[index..<end]) {
                steps += decoder.decode(event)
            }
            index = end
        }
        if let event = parser.finish() { steps += decoder.decode(event) }
        return steps
    }

    func testEverySSEFixtureDecodesTheSameWhateverTheChunks() throws {
        for path in FixtureFiles.all() where path.hasSuffix(".sse") {
            let data = try FixtureFiles.data(path)
            let decode: (Int) -> [HTTPStreamStep] = path.hasPrefix("anthropic/")
                ? { self.decode(data, chunk: $0, as: AnthropicStreamDecoder.self) }
                : { self.decode(data, chunk: $0, as: OpenAIStreamDecoder.self) }
            let whole = decode(Int.max / 2)
            XCTAssertFalse(whole.isEmpty, path)
            for chunk in [1, 2, 3, 7, 64, 511] {
                XCTAssertEqual(decode(chunk), whole, "\(path) in \(chunk)-byte chunks")
            }
            let crlf = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n").utf8)
            XCTAssertEqual(decode(Int.max / 2), self.decodeSame(crlf, like: path), "\(path) with CRLF")
        }
    }

    private func decodeSame(_ data: Data, like path: String) -> [HTTPStreamStep] {
        path.hasPrefix("anthropic/") ? decode(data, chunk: 5, as: AnthropicStreamDecoder.self)
            : decode(data, chunk: 5, as: OpenAIStreamDecoder.self)
    }

    func testEverySSEFixtureReachesAnEnd() throws {
        for path in FixtureFiles.all() where path.hasSuffix(".sse") {
            let data = try FixtureFiles.data(path)
            let steps = path.hasPrefix("anthropic/") ? decode(data, chunk: 100, as: AnthropicStreamDecoder.self)
                : decode(data, chunk: 100, as: OpenAIStreamDecoder.self)
            let ends = steps.filter { if case .emit = $0 { return false } else { return true } }
            // The writer stops at the first end; OpenAI's refusal fixture goes on (refusal.done, completed) after it.
            XCTAssertFalse(ends.isEmpty, path)
            if path.hasPrefix("anthropic/") { XCTAssertEqual(ends.count, 1, path) }
        }
    }

    func testAnthropicIgnoresTextDeltasOfOtherBlocksAndUnknownEvents() {
        var decoder = AnthropicStreamDecoder()
        XCTAssertEqual(decoder.decode(SSEEvent(event: "content_block_start",
                                               data: #"{"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"a"},"to":{"model":"b"}}}"#)), [])
        XCTAssertEqual(decoder.decode(SSEEvent(event: "content_block_delta",
                                               data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"not reply"}}"#)), [])
        XCTAssertEqual(decoder.decode(SSEEvent(event: "future_event", data: #"{"type":"future_event","x":1}"#)), [])
        XCTAssertEqual(decoder.decode(SSEEvent(event: "content_block_start",
                                               data: #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"Hi"}}"#)),
                       [.emit(.text("Hi"))], "text a block starts with is text too")
        XCTAssertEqual(decoder.decode(SSEEvent(event: "content_block_delta", data: "{not json")),
                       [.fail(.badResponse(code: 0), retryable: false)])
    }

    func testAnthropicStopReasons() {
        XCTAssertEqual(AnthropicStreamDecoder.stop(for: "end_turn"), .done)
        XCTAssertEqual(AnthropicStreamDecoder.stop(for: "stop_sequence"), .done)
        XCTAssertEqual(AnthropicStreamDecoder.stop(for: "max_tokens"), .maxTokens)
        XCTAssertEqual(AnthropicStreamDecoder.stop(for: "model_context_window_exceeded"), .maxTokens)
        XCTAssertEqual(AnthropicStreamDecoder.stop(for: "refusal"), .refused)
        XCTAssertEqual(AnthropicStreamDecoder.stop(for: nil), .done)
    }

    func testAnthropicStreamErrorTypes() {
        func map(_ type: String?) -> AIError { AnthropicErrorMapping.mapStreamError(type: type).error }
        XCTAssertEqual(map("overloaded_error"), .overloaded)
        XCTAssertEqual(map("rate_limit_error"), .rateLimited(retryAfter: nil))
        XCTAssertEqual(map("api_error"), .badResponse(code: 500))
        XCTAssertEqual(map("authentication_error"), .keyRefused)
        XCTAssertEqual(map("billing_error"), .noCredit)
        XCTAssertEqual(map("not_found_error"), .modelUnavailable)
        XCTAssertEqual(map(nil), .badResponse(code: 0))
        XCTAssertTrue(AnthropicErrorMapping.mapStreamError(type: "overloaded_error").retryable)
        XCTAssertFalse(AnthropicErrorMapping.mapStreamError(type: "authentication_error").retryable)
    }

    func testOpenAIStreamErrorCodes() {
        func map(_ code: String?, _ type: String? = nil) -> (error: AIError, retryable: Bool) {
            OpenAIErrorMapping.mapStreamError(code: code, type: type)
        }
        XCTAssertEqual(map("server_error").error, .badResponse(code: 500))
        XCTAssertTrue(map("server_error").retryable)
        XCTAssertEqual(map("rate_limit_exceeded").error, .rateLimited(retryAfter: nil))
        XCTAssertEqual(map("server_is_overloaded").error, .overloaded)
        XCTAssertEqual(map("invalid_prompt").error, .refused)
        XCTAssertEqual(map("bio_policy").error, .refused)
        XCTAssertEqual(map("insufficient_quota").error, .noCredit)
        XCTAssertFalse(map("insufficient_quota").retryable)
        XCTAssertEqual(map(nil, "insufficient_quota").error, .noCredit)
        XCTAssertEqual(map("data_residency_mismatch").error, .badResponse(code: 0))
        XCTAssertFalse(map("data_residency_mismatch").retryable)
    }

    func testOpenAIErrorEventsNestedOrFlat() {
        var decoder = OpenAIStreamDecoder()
        XCTAssertEqual(decoder.decode(SSEEvent(event: "error", data: #"{"type":"error","code":"rate_limit_exceeded","message":"x","param":null}"#)),
                       [.fail(.rateLimited(retryAfter: nil), retryable: true)])
        XCTAssertEqual(decoder.decode(SSEEvent(event: "error", data: #"{"type":"error","error":{"type":"insufficient_quota","code":null,"message":"x"}}"#)),
                       [.fail(.noCredit, retryable: false)])
    }
}

/// A thread-safe count for work that runs off the test's task.
final class HTTPCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
