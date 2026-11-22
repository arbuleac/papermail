import AppKit
import PaperCore
import WebKit
import XCTest
@testable import PaperApp

/// A click on a link to a named place in its own message moves the reader there: the pointing hand it shows promises a
/// click that does something (spec §4.17). Drives the real reader, its web view and its navigation policy over a
/// throwaway store, with a click WebKit asks the policy about as a link activated; gated behind `PAPER_UI_TESTS=1`.
@MainActor
final class ReaderAnchorTests: XCTestCase {
    func testAClickOnAnInMessageAnchorScrollsTheReaderToIt() throws {
        guard ProcessInfo.processInfo.environment["PAPER_UI_TESTS"] == "1" else {
            throw XCTSkip("set PAPER_UI_TESTS=1 to click in WebKit")
        }
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let account = ListTestSupport.accountA
        let message = MessageID(accountID: account.id, providerID: "msg-0-0")
        let source = ##"<p><a href="#list">Jump to the list</a></p><div style="height:2400px">Long news</div><h2 id="list">The list</h2><p>End</p>"##
        let sanitized = HTMLSanitizer().sanitize(MessageBody(html: source, text: nil), messageID: message)
        XCTAssertTrue(sanitized.html.contains(##"href="#ss-list""##), sanitized.html)
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: source, text: nil), renderedHTML: sanitized.html,
                                                          plainText: sanitized.plainText, typesetting: sanitized.typesetting),
                                               for: message)

        let reader = ConversationViewController(client: harness.environment.engine)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = reader
        window.setContentSize(NSSize(width: 900, height: 700))
        let conversation = ConversationID(accountID: account.id, providerID: "thread-0")
        reader.show(conversation)
        XCTAssertTrue(ListTestSupport.spin(until: {
            guard let slot = reader.pool.current else { return false }
            return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == conversation
        }, timeout: 10), "the conversation rendered")
        let webView = try XCTUnwrap(reader.pool.current?.webView)
        // Where the list starts on the page, once the body has laid out at its full height.
        let top = """
            (function () {
              var f = document.querySelector('.ss-card iframe'); var d = f && f.contentDocument;
              var h = d && d.getElementById('ss-list');
              if (!h || f.getBoundingClientRect().height < 2000) { return ''; }
              return f.getBoundingClientRect().top + h.getBoundingClientRect().top;
            })()
            """
        var answer = ""
        XCTAssertTrue(ListTestSupport.spin(until: { answer = self.evaluate(top, in: webView); return !answer.isEmpty }, timeout: 10),
                      "the body laid out at its full height")
        let before = try XCTUnwrap(Double(answer))
        XCTAssertGreaterThan(before, webView.bounds.height, "the list starts out of view")

        // A click on the link, which WebKit asks the policy about as a link activated.
        _ = evaluate("document.querySelector('.ss-card iframe').contentDocument.querySelector('a[href=\"#ss-list\"]').click()", in: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { (Double(self.evaluate(top, in: webView)) ?? before) < webView.bounds.height }, timeout: 5),
                      "the list scrolled into view: \(evaluate(top, in: webView)) from \(before)")
        reader.show(nil)
    }

    private func evaluate(_ script: String, in webView: WKWebView) -> String {
        var answer: String?
        webView.evaluateJavaScript("(function () { var v = (\(script)); return v === null || v === undefined ? '' : String(v); })()") { value, _ in
            answer = value as? String ?? ""
        }
        ListTestSupport.spin(until: { answer != nil }, timeout: 5)
        return answer ?? ""
    }
}
