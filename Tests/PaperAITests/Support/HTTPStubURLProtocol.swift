import Foundation

/// Serves scripted replies to every request of a test `URLSession` and records what was sent, so the API providers'
/// tests never reach the network. Streamed replies arrive in pieces a moment apart, as a network delivers them, so
/// the providers' byte-by-byte SSE path sees events split across chunks. Tests run one at a time in this bundle, so
/// the state is static; `reset()` in `setUp`.
final class HTTPStubURLProtocol: URLProtocol {
    struct Request: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        func json() -> [String: Any] {
            guard let body, let object = try? JSONSerialization.jsonObject(with: body) else { return [:] }
            return object as? [String: Any] ?? [:]
        }

        var bodyText: String { body.map { String(decoding: $0, as: UTF8.self) } ?? "" }
    }

    enum Reply {
        /// A whole reply at once.
        case http(status: Int, headers: [String: String], body: Data)
        /// A reply in `pieces` parts a moment apart, then the end.
        case stream(status: Int, headers: [String: String], body: Data, pieces: Int)
        /// A reply in parts that then stays open until the client cancels.
        case streamThenHang(body: Data)
        /// A reply in parts, then the connection fails.
        case streamThenFail(body: Data, URLError.Code)
        /// No reply: the connection fails.
        case failure(URLError.Code)

        static func sse(_ body: Data, pieces: Int = 4) -> Reply {
            .stream(status: 200, headers: ["Content-Type": "text/event-stream; charset=utf-8"], body: body, pieces: pieces)
        }

        static func sse(_ text: String, pieces: Int = 4) -> Reply {
            sse(Data(text.utf8), pieces: pieces)
        }

        static func json(_ body: Data, status: Int, headers: [String: String] = [:]) -> Reply {
            var headers = headers
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
            return .http(status: status, headers: headers, body: body)
        }
    }

    /// The reply for the `attempt`-th request (0-based) of the test.
    typealias Handler = @Sendable (Request, Int) -> Reply

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: Handler?
        var requests: [Request] = []
        var stops = 0
    }

    private static let state = State()

    static func install(_ handler: @escaping Handler) {
        state.lock.withLock { state.handler = handler }
    }

    /// Serves `replies` in order, repeating the last.
    static func serve(_ replies: [Reply]) {
        let replies = HTTPStubBox(replies)
        install { _, attempt in replies.value[min(attempt, replies.value.count - 1)] }
    }

    static func reset() {
        state.lock.withLock {
            state.handler = nil
            state.requests = []
            state.stops = 0
        }
    }

    static var requests: [Request] { state.lock.withLock { state.requests } }

    /// How many loads URLSession stopped: a cancelled task stops its load.
    static var stops: Int { state.lock.withLock { state.stops } }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubURLProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let queue = DispatchQueue(label: "HTTPStubURLProtocol.delivery")
    private let stopLock = NSLock()
    private var stopped = false
    private var isStopped: Bool { stopLock.withLock { stopped } }

    override func startLoading() {
        let recorded = Request(method: request.httpMethod ?? "GET", url: request.url!,
                               headers: request.allHTTPHeaderFields ?? [:], body: Self.readBody(of: request))
        let (handler, attempt): (Handler?, Int) = Self.state.lock.withLock {
            Self.state.requests.append(recorded)
            return (Self.state.handler, Self.state.requests.count - 1)
        }
        let reply = handler?(recorded, attempt) ?? .http(status: 599, headers: [:], body: Data("no stub installed".utf8))
        switch reply {
        case .http(let status, let headers, let body):
            respond(status: status, headers: headers)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .stream(let status, let headers, let body, let pieces):
            respond(status: status, headers: headers)
            deliver(body, pieces: pieces) { $0.client?.urlProtocolDidFinishLoading($0) }
        case .streamThenHang(let body):
            respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            deliver(body, pieces: 2) { _ in }
        case .streamThenFail(let body, let code):
            respond(status: 200, headers: ["Content-Type": "text/event-stream"])
            deliver(body, pieces: 2) { $0.client?.urlProtocol($0, didFailWithError: URLError(code)) }
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {
        let first = stopLock.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        if first { Self.state.lock.withLock { Self.state.stops += 1 } }
    }

    private func respond(status: Int, headers: [String: String]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    private func deliver(_ body: Data, pieces: Int, then end: @escaping @Sendable (HTTPStubURLProtocol) -> Void) {
        let size = max(1, (body.count + max(1, pieces) - 1) / max(1, pieces))
        var offset = 0
        var step = 1
        while offset < body.count {
            let piece = body.subdata(in: offset..<min(body.count, offset + size))
            queue.asyncAfter(deadline: .now() + .milliseconds(2 * step)) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.client?.urlProtocol(self, didLoad: piece)
            }
            offset += size
            step += 1
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(2 * step)) { [weak self] in
            guard let self, !self.isStopped else { return }
            end(self)
        }
    }

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

/// Holds a non-Sendable value a `@Sendable` closure only reads.
final class HTTPStubBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
