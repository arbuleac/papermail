import AppKit
import WebKit
import XCTest
@testable import PaperApp

/// The reader's web view tells its shell when the page may have focus again, since the shell stops watching which
/// body holds focus while the page has none (Q1.7d): on becoming first responder, and when its window becomes key.
@MainActor
final class ReaderWebViewTests: XCTestCase {
    func testTheShellHearsWhenFocusMayBeBack() throws {
        let webView = ReaderWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: WKWebViewConfiguration())
        // A stand-in shell that counts the calls.
        webView.loadHTMLString("<script>window.calls = 0; window.ss = { focusChanged: function () { window.calls++; } };</script>",
                               baseURL: nil)
        XCTAssertTrue(ListTestSupport.spin(until: { self.calls(in: webView) == 0 }, timeout: 10), "the page loaded")
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(webView)
        XCTAssertEqual(calls(in: webView), 0, "joining a window is not focus")

        XCTAssertTrue(window.makeFirstResponder(webView))
        XCTAssertTrue(ListTestSupport.spin(until: { self.calls(in: webView) == 1 }, timeout: 5), "first responder")

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(ListTestSupport.spin(until: { self.calls(in: webView) == 2 }, timeout: 5), "the window became key")

        let other = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 10, height: 10), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        webView.removeFromSuperview()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(calls(in: webView), 2, "another window, or one the view has left, says nothing")
    }

    /// `window.calls`, or -1 before the page has run its script.
    private func calls(in webView: WKWebView) -> Int {
        var value: Int?
        webView.evaluateJavaScript("typeof window.calls === 'number' ? window.calls : -1") { result, _ in
            value = (result as? NSNumber)?.intValue ?? -1
        }
        ListTestSupport.spin(until: { value != nil }, timeout: 5)
        return value ?? -1
    }
}
