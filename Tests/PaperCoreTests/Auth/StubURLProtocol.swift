import Foundation
import os

/// Answers every request on a session built by `makeSession()` with a canned reply and records what was sent,
/// so token endpoint traffic never leaves the process.
final class StubURLProtocol: URLProtocol {
    struct Reply: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]

        init(status: Int = 200, json: String, headers: [String: String] = ["Content-Type": "application/json"]) {
            self.status = status
            self.body = Data(json.utf8)
            self.headers = headers
        }
    }

    struct RecordedRequest: Sendable {
        var url: URL?
        var method: String?
        var body: Data?

        /// The request body decoded as application/x-www-form-urlencoded.
        var form: [String: String] {
            guard let body, let text = String(data: body, encoding: .utf8) else { return [:] }
            var result: [String: String] = [:]
            for pair in text.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let name = parts.first?.removingPercentEncoding else { continue }
                result[name] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
            }
            return result
        }
    }

    typealias Handler = @Sendable (RecordedRequest) throws -> Reply

    private struct State {
        var handler: Handler?
        var requests: [RecordedRequest] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func install(_ handler: @escaping Handler) {
        state.withLock {
            $0.handler = handler
            $0.requests = []
        }
    }

    static func reset() {
        state.withLock {
            $0.handler = nil
            $0.requests = []
        }
    }

    static var requests: [RecordedRequest] {
        state.withLock { $0.requests }
    }

    static var requestCount: Int {
        state.withLock { $0.requests.count }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(url: request.url, method: request.httpMethod, body: Self.body(of: request))
        let handler = Self.state.withLock { state -> Handler? in
            state.requests.append(recorded)
            return state.handler
        }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let reply = try handler(recorded)
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession hands protocols the body as a stream, never as `httpBody`.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
