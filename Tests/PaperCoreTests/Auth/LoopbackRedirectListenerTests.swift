import XCTest
@testable import PaperCore

final class LoopbackRedirectListenerTests: XCTestCase {
    private let state = "state-1"

    private func makeListener(maximumRequestBytes: Int) -> LoopbackRedirectListener {
        LoopbackRedirectListener(expectedState: state, maximumRequestBytes: maximumRequestBytes)
    }

    /// Plays a browser with a cookie jar bigger than the listener accepts. The reply is optional: closing a
    /// socket with unread bytes can reset the connection before the client reads the page.
    private func send(path: String, cookieBytes: Int, to port: UInt16) async -> Int? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.setValue(String(repeating: "x", count: cookieBytes), forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 5
        guard let (_, response) = try? await URLSession(configuration: .ephemeral).data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// Past the cap there is nothing to retry, so the flow must fail with the reason at once instead of
    /// leaving the sign-in to run out its timeout.
    func testOversizedCallbackSettlesWithTheReasonInsteadOfWaiting() async throws {
        let listener = makeListener(maximumRequestBytes: 4096)
        defer { listener.stop() }
        let port = try await listener.start()
        let waiting = Task { try await listener.callback() }
        // Turns a regression (no settle) into a wrong-error failure rather than a hung test.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            listener.stop()
        }
        defer { watchdog.cancel() }

        let status = await send(path: "/callback?code=c&state=\(state)", cookieBytes: 8192, to: port)
        if let status { XCTAssertEqual(status, 431) }

        let outcome = await waiting.result
        guard case let .failure(error) = outcome, case let AuthError.invalidResponse(reason) = error else {
            return XCTFail("expected the flow to settle with the reason, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("cookies"), reason)
    }

    /// Oversized traffic that is not the callback is turned away like any other stray request: the flow stays
    /// open for the real redirect.
    func testOversizedUnrelatedRequestLeavesTheFlowWaiting() async throws {
        let listener = makeListener(maximumRequestBytes: 4096)
        defer { listener.stop() }
        let port = try await listener.start()
        let waiting = Task { try await listener.callback() }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            listener.stop()
        }
        defer { watchdog.cancel() }

        let status = await send(path: "/favicon.ico", cookieBytes: 8192, to: port)
        if let status { XCTAssertEqual(status, 431) }
        let callbackStatus = await send(path: "/callback?code=c&state=\(state)", cookieBytes: 0, to: port)
        XCTAssertEqual(callbackStatus, 200)

        let callback = try await waiting.value
        XCTAssertEqual(callback, LoopbackCallback(code: "c", state: state))
    }
}
