import Foundation
import Network
import os

/// What the browser delivered to `/callback` after the user consented.
struct LoopbackCallback: Sendable, Hashable {
    var code: String
    var state: String
}

/// A one-shot HTTP/1.1 server on the loopback interface that receives the OAuth authorization redirect.
///
/// It binds 127.0.0.1 on an ephemeral port and, best effort, ::1 on the same port: Google is told to redirect
/// to `127.0.0.1`, Microsoft to `localhost`, and `localhost` resolves to either family depending on the browser.
/// Only the first `/callback` request settles the result; everything else gets a short page and is dropped.
final class LoopbackRedirectListener: @unchecked Sendable {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "auth")
    /// Browsers attach every cookie set for localhost or 127.0.0.1 to the redirect, whatever the port, so a
    /// developer's jar for other local servers rides along. Chrome allows about 720 KiB per host; this stays
    /// clear of that where the 8-16 KiB most servers accept would turn a valid redirect into a 400.
    static let defaultMaximumRequestBytes = 1024 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let lineTerminator = Data("\r\n".utf8)

    private let expectedState: String
    /// The path the redirect URI names; every other path is a stray request (favicon, probes).
    private let callbackPath: String
    private let maximumRequestBytes: Int
    private let queue = DispatchQueue(label: "app.paperinbox.mac.oauth-loopback")
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var outcome: Result<LoopbackCallback, Error>?
    private var waiter: CheckedContinuation<LoopbackCallback, Error>?
    private var stopped = false

    init(expectedState: String, callbackPath: String = "/callback", maximumRequestBytes: Int = LoopbackRedirectListener.defaultMaximumRequestBytes) {
        self.expectedState = expectedState
        self.callbackPath = callbackPath
        self.maximumRequestBytes = maximumRequestBytes
    }

    deinit {
        stop()
    }

    /// Binds and returns the port the browser must be sent to.
    func start() async throws -> UInt16 {
        let port = try await bind(host: .ipv4(.loopback), port: .any)
        // Some browsers resolve "localhost" to ::1 first; losing this bind only costs them a fallback attempt.
        if let samePort = NWEndpoint.Port(rawValue: port) {
            do {
                _ = try await bind(host: .ipv6(.loopback), port: samePort)
            } catch {
                Self.logger.debug("IPv6 loopback bind on port \(port, privacy: .public) failed; continuing with IPv4 only")
            }
        }
        return port
    }

    /// Waits for the redirect. Task cancellation and `stop()` both resolve it with `AuthError.userCancelled`.
    func callback() async throws -> LoopbackCallback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LoopbackCallback, Error>) in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(with: outcome)
                    return
                }
                if stopped {
                    lock.unlock()
                    continuation.resume(throwing: AuthError.userCancelled)
                    return
                }
                guard waiter == nil else {
                    lock.unlock()
                    continuation.resume(throwing: AuthError.invalidResponse("The redirect listener already has a waiter"))
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            settle(.failure(AuthError.userCancelled))
        }
    }

    /// Closes the sockets. Safe to call more than once and from any thread.
    func stop() {
        lock.lock()
        stopped = true
        let listeners = self.listeners
        let connections = Array(self.connections.values)
        self.listeners = []
        self.connections = [:]
        lock.unlock()
        listeners.forEach { $0.cancel() }
        connections.forEach { $0.cancel() }
        settle(.failure(AuthError.userCancelled))
    }

    // MARK: Binding

    private func bind(host: NWEndpoint.Host, port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw AuthError.invalidResponse("Could not create the loopback listener: \(error.localizedDescription)")
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        guard register(listener) else { throw AuthError.userCancelled }

        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            // The state handler keeps firing after ready (cancelled on stop), so resume exactly once.
            let resumeOnce: @Sendable (Result<UInt16, Error>) -> Void = { result in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(with: result) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        resumeOnce(.success(port))
                    } else {
                        resumeOnce(.failure(AuthError.invalidResponse("The loopback listener reported no port")))
                    }
                case let .failed(error):
                    self?.forget(listener)
                    listener.cancel()
                    resumeOnce(.failure(AuthError.invalidResponse("The loopback listener failed: \(error.localizedDescription)")))
                case .cancelled:
                    self?.forget(listener)
                    resumeOnce(.failure(AuthError.userCancelled))
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// False once `stop()` has run, in which case the listener must not be started.
    private func register(_ listener: NWListener) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        listeners.append(listener)
        return true
    }

    private func forget(_ listener: NWListener) {
        lock.lock()
        listeners.removeAll { $0 === listener }
        lock.unlock()
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        lock.lock()
        if stopped || outcome != nil {
            lock.unlock()
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func forget(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = nil
        lock.unlock()
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumRequestBytes) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffered
            if let content { buffer.append(content) }
            if error != nil {
                connection.cancel()
                return
            }
            if let terminator = buffer.range(of: Self.headerTerminator) {
                self.handle(requestHead: buffer[..<terminator.lowerBound], on: connection)
            } else if buffer.count >= self.maximumRequestBytes {
                self.rejectOversized(requestHead: buffer, on: connection)
            } else if isComplete {
                self.respond(on: connection, status: 400, reason: "Bad Request", html: Self.failurePage("The request was not understood."), then: nil)
            } else {
                self.receive(on: connection, buffered: buffer)
            }
        }
    }

    /// Method and target from the first line of `head`, which may be a complete head or the start of one.
    private static func requestLine(of head: Data) -> (method: Substring, target: Substring)? {
        let lineEnd = head.range(of: lineTerminator)?.lowerBound ?? head.endIndex
        let parts = String(decoding: head[..<lineEnd], as: UTF8.self).split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// A head past the cap is almost certainly the redirect buried under a cookie jar, which no retry will fix.
    /// When it is the callback, settling with the reason spares the user the full timeout; the page itself is
    /// best effort because the unread remainder may reset the connection before the browser renders it.
    private func rejectOversized(requestHead: Data, on connection: NWConnection) {
        let reason = "The browser's request was too large to read. Clear this browser's cookies for localhost and 127.0.0.1, then try again."
        let isCallback = Self.requestLine(of: requestHead).flatMap { URLComponents(string: String($0.target)) }.map(isCallback) ?? false
        respond(on: connection, status: 431, reason: "Request Header Fields Too Large", html: Self.failurePage(reason),
                then: isCallback ? .failure(AuthError.invalidResponse(reason)) : nil)
    }

    /// A redirect URI without a path makes the browser ask for "/".
    private func isCallback(_ target: URLComponents) -> Bool {
        let path = target.path.isEmpty ? "/" : target.path
        return path == callbackPath
    }

    private func handle(requestHead: Data, on connection: NWConnection) {
        guard let (method, rawTarget) = Self.requestLine(of: requestHead) else {
            respond(on: connection, status: 400, reason: "Bad Request", html: Self.failurePage("The request was not understood."), then: nil)
            return
        }
        guard let target = URLComponents(string: String(rawTarget)), isCallback(target) else {
            // Browsers also ask for /favicon.ico; answering keeps them from retrying while we wait.
            respond(on: connection, status: 404, reason: "Not Found", html: Self.failurePage("Nothing to see here."), then: nil)
            return
        }
        guard method == "GET" else {
            respond(on: connection, status: 405, reason: "Method Not Allowed", html: Self.failurePage("Nothing to see here."), then: nil)
            return
        }
        var query: [String: String] = [:]
        for item in target.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }

        if let providerError = query["error"] {
            let description = query["error_description"] ?? providerError
            let failure: AuthError = providerError == "access_denied"
                ? .userCancelled
                : .invalidResponse("The provider declined the sign-in: \(providerError): \(description)")
            respond(on: connection, status: 200, reason: "OK", html: Self.failurePage("Sign-in was not completed (\(description))."), then: .failure(failure))
            return
        }
        // Comparing state defeats a forged redirect from another local process or a stale browser tab
        // (RFC 6749 §10.12); PKCE already protects the code itself.
        guard let state = query["state"], state == expectedState else {
            respond(on: connection, status: 400, reason: "Bad Request", html: Self.failurePage("The sign-in response did not match this request. Please try again from Paper."),
                    then: .failure(AuthError.invalidResponse("Authorization response state did not match the request")))
            return
        }
        guard let code = query["code"], !code.isEmpty else {
            respond(on: connection, status: 400, reason: "Bad Request", html: Self.failurePage("The sign-in response did not include an authorization code."),
                    then: .failure(AuthError.invalidResponse("Authorization response did not include a code")))
            return
        }
        respond(on: connection, status: 200, reason: "OK", html: Self.successPage, then: .success(LoopbackCallback(code: code, state: state)))
    }

    /// Writes a complete response, half-closes, and only then settles the flow so the browser always gets its
    /// page before the app tears the socket down.
    private func respond(on connection: NWConnection, status: Int, reason: String, html: String, then result: Result<LoopbackCallback, Error>?) {
        let body = Data(html.utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            if let result { self?.settle(result) }
        })
    }

    private func settle(_ result: Result<LoopbackCallback, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(with: result)
    }

    // MARK: Pages

    static let successPage = page(
        title: "Signed in",
        heading: "You can return to Paper",
        body: "Sign-in is complete. You can close this window."
    )

    static func failurePage(_ reason: String) -> String {
        page(title: "Sign-in failed", heading: "Sign-in failed", body: escape(reason))
    }

    private static func page(title: String, heading: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title) - Paper</title>
        <style>
        body{font:16px/1.5 -apple-system,system-ui,sans-serif;color:#1d1d1f;background:#f5f5f7;margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center}
        main{background:#fff;border-radius:14px;padding:32px 40px;box-shadow:0 1px 3px rgba(0,0,0,.08);max-width:28rem;text-align:center}
        h1{font-size:20px;margin:0 0 8px}p{margin:0;color:#6e6e73}
        @media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}main{background:#2c2c2e}p{color:#aeaeb2}}
        </style></head>
        <body><main><h1>\(heading)</h1><p>\(body)</p></main></body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
