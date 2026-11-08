import Foundation
import os
import SSCore
import XCTest
@testable import SSGmail

/// What a stubbed endpoint answers. `error` simulates a transport failure instead of an HTTP reply.
struct StubResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
    var error: Error?
    /// When set, the body is sent in this many pieces a few milliseconds apart, as a slow network delivers it, so a
    /// streaming download sees several chunks. URLSession holds back the first 512 bytes to sniff a type unless the
    /// reply names one, so chunked replies always carry a Content-Type.
    var chunks: Int?

    /// `body` delivered in `count` pieces.
    func chunked(_ count: Int) -> StubResponse {
        var copy = self
        copy.chunks = count
        return copy
    }

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        var merged = headers
        merged["Content-Type"] = merged["Content-Type"] ?? "application/json; charset=UTF-8"
        return StubResponse(status: status, headers: merged, body: Data(text.utf8))
    }

    static func empty(status: Int = 204) -> StubResponse {
        StubResponse(status: status)
    }

    static func failure(_ error: Error) -> StubResponse {
        StubResponse(status: 0, error: error)
    }

    /// A Gmail batch reply: one embedded HTTP response per (index, status, json) triple.
    static func batch(boundary: String = "batch_reply_boundary", parts: [(index: Int, status: Int, json: String)]) -> StubResponse {
        batch(boundary: boundary, stubParts: parts.map { StubBatchPart(index: $0.index, status: $0.status, json: $0.json) })
    }

    /// A Gmail batch reply whose embedded responses may carry their own headers (a part's Retry-After).
    static func batch(boundary: String = "batch_reply_boundary", stubParts parts: [StubBatchPart]) -> StubResponse {
        var body = ""
        for part in parts {
            body += "--\(boundary)\r\n"
            body += "Content-Type: application/http\r\n"
            body += "Content-ID: <response-item-\(part.index)>\r\n\r\n"
            body += "HTTP/1.1 \(part.status) \(part.status == 200 ? "OK" : "Error")\r\n"
            body += "Content-Type: application/json; charset=UTF-8\r\n"
            for (name, value) in part.headers.sorted(by: { $0.key < $1.key }) {
                body += "\(name): \(value)\r\n"
            }
            body += "Content-Length: \(part.json.utf8.count)\r\n\r\n"
            body += part.json + "\r\n"
        }
        body += "--\(boundary)--\r\n"
        return StubResponse(status: 200, headers: ["Content-Type": "multipart/mixed; boundary=\(boundary)"], body: Data(body.utf8))
    }
}

/// One embedded response of a stubbed batch reply.
struct StubBatchPart {
    var index: Int
    var status: Int
    var json: String
    var headers: [String: String] = [:]
}

struct RecordedRequest {
    var method: String
    var url: URL
    var path: String
    var query: [String: [String]]
    var headers: [String: String]
    var body: Data

    init(_ request: URLRequest) {
        method = request.httpMethod ?? "GET"
        url = request.url ?? URL(fileURLWithPath: "/")
        path = url.path
        var query: [String: [String]] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name, default: []].append(item.value ?? "")
        }
        self.query = query
        headers = request.allHTTPHeaderFields ?? [:]
        body = request.httpBody ?? Self.read(request.httpBodyStream)
    }

    var bodyText: String { String(decoding: body, as: UTF8.self) }

    /// The query exactly as it goes on the wire; `query` has already undone the percent-encoding.
    var rawQuery: String { URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "" }

    var jsonBody: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// URLSession hands protocols the body as a stream, never as `httpBody`.
    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// In-process fake of Google's API: routes match by method and path suffix, every request is recorded.
final class StubServer: @unchecked Sendable {
    static let shared = StubServer()

    private struct Route {
        var method: String
        var path: String
        var respond: (RecordedRequest) -> StubResponse
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var recorded: [RecordedRequest] = []

    func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = []
        recorded = []
    }

    func on(_ method: String = "GET", _ path: String, _ respond: @escaping (RecordedRequest) -> StubResponse) {
        lock.lock(); defer { lock.unlock() }
        routes.append(Route(method: method, path: path, respond: respond))
    }

    func on(_ method: String = "GET", _ path: String, _ response: StubResponse) {
        on(method, path) { _ in response }
    }

    /// Answers in order, repeating the last response once the list is exhausted.
    func sequence(_ method: String = "GET", _ path: String, _ responses: [StubResponse]) {
        var remaining = responses
        let sequenceLock = NSLock()
        on(method, path) { _ in
            sequenceLock.lock(); defer { sequenceLock.unlock() }
            if remaining.count > 1 { return remaining.removeFirst() }
            return remaining.first ?? StubResponse(status: 500)
        }
    }

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func requests(to path: String) -> [RecordedRequest] {
        requests.filter { $0.path == path || $0.path.hasSuffix(path) }
    }

    func respond(to request: RecordedRequest) -> StubResponse {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        // Later registrations win so a test can override a default route.
        for route in routes.reversed() where route.method == request.method {
            if request.path == route.path || request.path.hasSuffix(route.path) {
                return route.respond(request)
            }
        }
        let message = "{\"error\":{\"code\":404,\"message\":\"No stub for \(request.method) \(request.path)\"}}"
        return StubResponse.json(message, status: 404)
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(request)
        let response = StubServer.shared.respond(to: recorded)
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        guard let pieces = response.chunks, pieces > 1, response.body.count > 1 else {
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body = response.body
        let size = (body.count + pieces - 1) / pieces
        let queue = DispatchQueue(label: "StubURLProtocol.chunks")
        var offset = 0
        var step = 1
        while offset < body.count {
            let piece = body.subdata(in: offset..<min(body.count, offset + size))
            queue.asyncAfter(deadline: .now() + .milliseconds(15 * step)) { [weak self] in
                guard let self, !self.stopped.withLock({ $0 }) else { return }
                self.client?.urlProtocol(self, didLoad: piece)
            }
            offset += size
            step += 1
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(15 * step)) { [weak self] in
            guard let self, !self.stopped.withLock({ $0 }) else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    private let stopped = OSAllocatedUnfairLock(initialState: false)

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}

/// Hands out tokens in order, advancing only when the provider invalidates one.
final class FakeTokenProvider: AccessTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let tokens: [String]
    private var index = 0
    private(set) var invalidations = 0
    /// The scopes the token endpoint listed for the account; nil when unknown.
    private let scopes: String?

    init(tokens: [String] = ["token-1", "token-2", "token-3"], scopes: String? = nil) {
        self.tokens = tokens
        self.scopes = scopes
    }

    func grantedScopes(for accountID: AccountID) async -> String? {
        scopes
    }

    func accessToken(for accountID: AccountID) async throws -> String {
        lock.withLock { tokens[min(index, tokens.count - 1)] }
    }

    func invalidateAccessToken(for accountID: AccountID) async {
        lock.withLock {
            invalidations += 1
            index += 1
        }
    }
}

/// Stands in for the provider's throttle waits: records each one instead of sleeping.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var delays: [TimeInterval] { lock.withLock { recorded } }

    func record(_ seconds: TimeInterval) {
        lock.withLock { recorded.append(seconds) }
    }

    /// The provider's real schedule and ceilings, with the waits recorded rather than slept.
    func retry(delays: [TimeInterval] = GmailThrottleRetry.standard.delays,
               maxInlineWait: TimeInterval = GmailThrottleRetry.standard.maxInlineWait,
               maxWaitWithNothingFetched: TimeInterval = GmailThrottleRetry.standard.maxWaitWithNothingFetched) -> GmailThrottleRetry {
        GmailThrottleRetry(delays: delays, maxInlineWait: maxInlineWait, maxWaitWithNothingFetched: maxWaitWithNothingFetched,
                           sleep: { [self] in record($0) })
    }
}

enum TestSupport {
    static let accountID = AccountID("acct-test")

    /// Throttled batch parts go out again at once: tests never wait on the real schedule.
    static let instantRetry = GmailThrottleRetry(delays: [0, 0, 0], maxInlineWait: GmailThrottleRetry.standard.maxInlineWait,
                                                 maxWaitWithNothingFetched: GmailThrottleRetry.standard.maxWaitWithNothingFetched,
                                                 sleep: { _ in })

    static func makeProvider(tokens: FakeTokenProvider = FakeTokenProvider(), throttleRetry: GmailThrottleRetry = instantRetry) -> GmailProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return GmailProvider(accountID: accountID, tokens: tokens, session: URLSession(configuration: configuration),
                             throttleRetry: throttleRetry)
    }

    /// Registers the batch endpoint to answer each embedded get through `answer`, given which batch send
    /// this is (0 for the first), the part's index in that send, and the id it asks for.
    static func stubBatchRounds(_ answer: @escaping (_ round: Int, _ index: Int, _ id: String) -> StubBatchPart) {
        let lock = NSLock()
        var round = 0
        StubServer.shared.on("POST", "/batch/gmail/v1") { request in
            let current: Int = lock.withLock {
                defer { round += 1 }
                return round
            }
            let ids = batchRequestIDs(in: request.bodyText)
            return .batch(stubParts: ids.enumerated().map { answer(current, $0.offset, $0.element) })
        }
    }

    /// Registers the batch endpoint to answer each embedded metadata get from `messages`, 404 otherwise.
    static func stubBatch(messages: [String: String]) {
        StubServer.shared.on("POST", "/batch/gmail/v1") { request in
            let ids = batchRequestIDs(in: request.bodyText)
            let parts = ids.enumerated().map { index, id -> (index: Int, status: Int, json: String) in
                if let json = messages[id] { return (index, 200, json) }
                return (index, 404, GmailFixtures.notFoundError)
            }
            return .batch(parts: parts)
        }
    }

    static func batchRequestIDs(in body: String) -> [String] {
        body.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("GET /gmail/v1/users/me/messages/") else { return nil }
            let afterPrefix = line.dropFirst("GET /gmail/v1/users/me/messages/".count)
            return afterPrefix.split(whereSeparator: { $0 == "?" || $0 == " " }).first.map(String.init)
        }
    }

    /// The (headers, bytes) parts of a multipart upload body, split on the boundary its Content-Type declares.
    static func uploadParts(of request: RecordedRequest) -> [(headers: String, body: Data)] {
        guard let boundary = GmailBatch.boundary(from: request.header("Content-Type")) else { return [] }
        let body = request.body
        let delimiter = Data("--\(boundary)".utf8)
        var pieces: [Data] = []
        var cursor = body.startIndex
        while let range = body.range(of: delimiter, in: cursor..<body.endIndex) {
            pieces.append(body[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        pieces.append(body[cursor...])
        var parts: [(headers: String, body: Data)] = []
        for piece in pieces.dropFirst() {
            if piece.starts(with: Data("--".utf8)) { break }
            var inner = piece
            if inner.starts(with: Data("\r\n".utf8)) { inner = inner.dropFirst(2) }
            if inner.suffix(2) == Data("\r\n".utf8) { inner = inner.dropLast(2) }
            guard let split = inner.range(of: Data("\r\n\r\n".utf8)) else {
                parts.append((String(decoding: inner, as: UTF8.self), Data()))
                continue
            }
            parts.append((String(decoding: inner[inner.startIndex..<split.lowerBound], as: UTF8.self), Data(inner[split.upperBound...])))
        }
        return parts
    }

    static func providerError(_ body: () async throws -> Void) async -> ProviderError? {
        do {
            try await body()
            XCTFail("Expected a ProviderError")
            return nil
        } catch let error as ProviderError {
            return error
        } catch {
            XCTFail("Unexpected error \(error)")
            return nil
        }
    }
}
