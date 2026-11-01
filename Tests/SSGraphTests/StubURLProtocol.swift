import Foundation

/// Serves canned replies to every request of a test `URLSession` and records what was sent, so provider tests
/// never touch the network.
final class StubURLProtocol: URLProtocol {
    struct Request: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?

        var path: String { url.path }

        var query: [String: String] {
            var map: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                map[item.name] = item.value ?? ""
            }
            return map
        }

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        func json() -> [String: Any] {
            guard let body, let object = try? JSONSerialization.jsonObject(with: body) else { return [:] }
            return object as? [String: Any] ?? [:]
        }
    }

    enum Reply {
        case http(status: Int, headers: [String: String], body: Data)
        case failure(URLError.Code)

        static func json(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            var headers = headers
            headers["Content-Type"] = "application/json"
            return .http(status: status, headers: headers, body: Data(string.utf8))
        }

        static func status(_ code: Int, headers: [String: String] = [:], body: String = "") -> Reply {
            .http(status: code, headers: headers, body: Data(body.utf8))
        }

        static func bytes(_ data: Data, status: Int = 200) -> Reply {
            .http(status: status, headers: ["Content-Type": "application/octet-stream"], body: data)
        }
    }

    typealias Handler = (Request) -> Reply

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: Handler?
        var requests: [Request] = []
    }

    private static let state = State()

    static func install(_ handler: @escaping Handler) {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.handler = handler
    }

    static func reset() {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.handler = nil
        state.requests = []
    }

    static func clearRequests() {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.requests = []
    }

    static var requests: [Request] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.requests
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Request(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(of: request)
        )
        Self.state.lock.lock()
        Self.state.requests.append(recorded)
        let handler = Self.state.handler
        Self.state.lock.unlock()

        let reply = handler?(recorded) ?? .json(#"{"error":{"code":"NoStub","message":"no handler installed"}}"#, status: 599)
        switch reply {
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(url: recorded.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    /// URLSession hands protocols the body as a stream, never as `httpBody`.
    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
