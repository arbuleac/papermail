import WebKit
import XCTest
@testable import SSCore

/// Drives the real shell inside a `WKWebView`. Gated behind `SS_UI_TESTS=1` because WebKit needs a
/// window-server session; everything else in the suite stays headless.
@MainActor
final class ConversationShellWebViewTests: XCTestCase {
    /// Collects what the shell posts and anything WebKit reports, so a readiness miss names its cause.
    @MainActor
    private final class ShellMessages: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private(set) var isReady = false
        private(set) var received: [[String: Any]] = []
        private(set) var failures: [String] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { received.append(body) }
            if message.name == ConversationShellAssets.readyHandlerName { isReady = true }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failures.append("didFail: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failures.append("didFailProvisionalNavigation: \(error)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            failures.append("web content process terminated")
        }
    }

    /// WebKit stalls a `loadHTMLString` whose base scheme has no handler, so the test registers one as the app does.
    @MainActor
    private final class ShellSchemeStub: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])
            else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }

    private var configuration: WKWebViewConfiguration?

    override func tearDown() {
        configuration?.userContentController.removeAllScriptMessageHandlers()
        configuration = nil
        super.tearDown()
    }

    func testShellRendersTwoCardsWithMeasuredFrames() async throws {
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else {
            throw XCTSkip("Set SS_UI_TESTS=1 to drive WebKit")
        }
        let handler = ShellMessages()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ShellSchemeStub(), forURLScheme: ConversationShellAssets.scheme)
        configuration.userContentController.add(handler, name: ConversationShellAssets.readyHandlerName)
        configuration.userContentController.add(handler, name: ConversationShellAssets.messageHandlerName)
        self.configuration = configuration

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.navigationDelegate = handler
        webView.loadHTMLString(ConversationShellAssets.html, baseURL: ConversationShellAssets.baseURL)
        // Sleeping on the main actor keeps the run loop turning, which is what delivers WebKit's callbacks.
        var attempts = 0
        while !handler.isReady, attempts < 200 {
            try await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
        guard handler.isReady else {
            return XCTFail("shell never signalled ready; WebKit reported: \(handler.failures)")
        }

        let payload = twoMessagePayload()
        let rendered = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        XCTAssertEqual((rendered as? NSNumber)?.intValue, 2)
        let cards = try await evaluate("document.querySelectorAll('.ss-card').length", in: webView)
        XCTAssertEqual((cards as? NSNumber)?.intValue, 2)
        let collapsed = try await evaluate("document.querySelectorAll('.ss-card.ss-collapsed').length", in: webView)
        XCTAssertEqual((collapsed as? NSNumber)?.intValue, 1, "only the last message starts expanded")

        _ = try await evaluate("window.ss.expandAll(); window.ss.cardCount()", in: webView)
        var heights: [Double] = []
        for _ in 0..<100 {
            heights = numbers(try await evaluate("window.ss.measureAll()", in: webView))
            if heights.count == 2, heights.allSatisfy({ $0 > 0 }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(heights.count, 2)
        XCTAssertTrue(heights.allSatisfy { $0 > 0 }, "measured iframe heights: \(heights)")
        let styled = numbers(try await evaluate("window.ss.iframeHeights()", in: webView))
        XCTAssertEqual(styled.count, 2)
        XCTAssertTrue(styled.allSatisfy { $0 > 0 }, "styled iframe heights: \(styled)")

        let quoteButtons = try await evaluate("document.querySelectorAll('.ss-toggle-quote').length", in: webView)
        XCTAssertEqual((quoteButtons as? NSNumber)?.intValue, 1)
        let imageButtons = try await evaluate("document.querySelectorAll('.ss-load-images').length", in: webView)
        XCTAssertEqual((imageButtons as? NSNumber)?.intValue, 1)
        XCTAssertTrue(handler.received.contains { ($0["kind"] as? String) == "ready" }, "ready is also posted on the ss handler")
    }

    // MARK: Helpers

    private func twoMessagePayload() -> RenderPayload {
        typealias F = ConversationFixtures
        let first = F.message("m1", date: F.utc(2025, 1, 3, 14, 5))
        let second = F.message("m2", from: F.bob, date: F.utc(2025, 3, 7, 14, 5), isRead: false)
        let bodies: [MessageID: StoredBody] = [
            first.id: F.body(html: "<p>Hello <b>world</b></p><div class=\"ss-quote\"><p>Earlier</p></div>"),
            second.id: F.body(html: "<p>Reply</p><img data-ss-src=\"https://example.com/a.png\" alt=\"\">"),
        ]
        return F.builder.build(messages: [first, second], bodies: bodies, accounts: F.accounts, now: F.utc(2025, 3, 7, 15, 0))
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func numbers(_ value: Any?) -> [Double] {
        (value as? [NSNumber])?.map(\.doubleValue) ?? []
    }
}
