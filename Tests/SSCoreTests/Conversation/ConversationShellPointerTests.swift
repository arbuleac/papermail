import WebKit
import XCTest
@testable import SSCore

/// The pointer in the reader (spec §4.17): the pointing hand over every control the shell makes and every link in a body,
/// the arrow over a disabled control, the I-beam left to text. The headless half holds the shell's and the body
/// documents' rules; the rest reads the computed cursor in a real shell and is gated behind `SS_UI_TESTS=1`, as
/// `ConversationShellWebViewTests` is.
@MainActor
final class ConversationShellPointerTests: XCTestCase {
    typealias F = ConversationFixtures

    // MARK: Rules

    /// One rule gives every button and button-role element the hand and a disabled one the arrow, and they are the only
    /// cursor declarations in the shell, so no later rule can take the hand away (the shell once set `cursor: default` on
    /// every button).
    func testTheShellGivesEveryButtonTheHandAndADisabledOneTheArrow() {
        let css = ConversationShellAssets.css
        XCTAssertTrue(css.contains(#"button, [role="button"] { cursor: pointer; }"#))
        XCTAssertTrue(css.contains(#"button:disabled, [aria-disabled="true"] { cursor: default; }"#))
        XCTAssertEqual(declarations(of: "cursor", in: css), 2, "no other cursor rule in the shell")
        let base = css.components(separatedBy: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("button {") }
        XCTAssertNotNil(base)
        XCTAssertFalse(base?.contains("cursor") ?? true, "the base button rule leaves the cursor to the pointer rule")
    }

    /// Every element the script makes a control is a `<button>` or takes the button role, which the rule covers: the only
    /// other role it gives is the invitation card's group, which is not clicked.
    func testEveryRoleTheScriptGivesIsCoveredByTheRule() throws {
        let script = ConversationShellAssets.script
        let pattern = try NSRegularExpression(pattern: #"setAttribute\('role', '([a-z]+)'\)"#)
        let roles = Set(pattern.matches(in: script, range: NSRange(script.startIndex..., in: script)).compactMap {
            Range($0.range(at: 1), in: script).map { String(script[$0]) }
        })
        XCTAssertEqual(roles, ["button", "group"])
        XCTAssertTrue(script.contains("function button(cls, label, title) {"))
        XCTAssertTrue(script.contains("var node = el('button', cls, label);"), "button() makes <button> elements")
    }

    /// Every link in a body document shows the hand, whatever a sender's sheet says: the rule is `!important` under
    /// `:root body`, and it covers the words and pictures inside a link and image-map areas.
    func testBodyDocumentsGiveEveryLinkTheHand() {
        let css = ConversationShellAssets.bodyCSS
        XCTAssertTrue(css.contains(":root body a[href], :root body a[href] *, :root body area[href] { cursor: pointer !important; }"))
        XCTAssertEqual(declarations(of: "cursor", in: css), 1, "no other cursor rule in a body document")
    }

    /// A URL or address in a plain-text body becomes an `a[href]`, the element the body rule matches, and keeps its
    /// address through the sanitizer.
    func testLinksFoundInPlainTextAreTheLinksTheRuleMatches() {
        XCTAssertEqual(PlainTextRenderer.linkify("See https://example.com/notes or ada@example.com"),
                       #"See <a href="https://example.com/notes">https://example.com/notes</a> or <a href="mailto:ada@example.com">ada@example.com</a>"#)
        let body = plainBody("Notes: https://example.com/notes")
        XCTAssertEqual(body.typesetting, .plain)
        XCTAssertTrue(body.renderedHTML.contains(#"<a href="https://example.com/notes">"#), body.renderedHTML)
    }

    // MARK: In WebKit

    /// Every control of a long conversation's stack and open sheet computes the hand, and so does everything inside it
    /// (glyphs, labels, avatar, snippet), which before 1.8.1 showed the arrow or the I-beam; the sender's name and the
    /// keycaps, which are not controls, keep `auto`. A Download whose file is downloading takes the arrow, and the hand
    /// comes back when it ends.
    func testEveryControlOfAConversationShowsTheHand() async throws {
        let (webView, _) = try await loadedShell()
        var messages = (1...8).map { F.message("m\($0)", date: F.utc(2025, 3, $0, 9, 0)) }
        var newest = F.message("m9", cc: [F.carol], date: F.utc(2025, 3, 9, 9, 0), hasAttachments: true)
        newest.listUnsubscribe = "<https://news.example.com/u/1>"
        messages.append(newest)
        let files = [AttachmentInfo(id: "att-1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 240_000, isInline: false),
                     AttachmentInfo(id: "att-2", filename: "notes.txt", mimeType: "text/plain", sizeBytes: 2_000, isInline: false)]
        let html = #"<p>Plan attached</p><img data-ss-src="https://example.com/a.png" alt=""><div class="ss-quote"><p>Earlier</p></div>"#
        let payload = F.builder.build(messages: messages, bodies: [newest.id: F.body(html: html, attachments: files)],
                                      accounts: F.accounts, now: F.utc(2025, 3, 20, 9, 0))
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)

        var report = try await cursors(in: webView)
        XCTAssertEqual(report.wrong, [], "every control and what is inside it")
        for control in ["ss-card", "ss-fold", "ss-hact", "ss-unsub", "ss-rc", "ss-load-images", "ss-toggle-quote", "ss-chip",
                        "ss-chip-dl", "ss-dlall", "ss-gb"] {
            XCTAssertTrue(report.classes.contains(control), "the conversation shows a \(control): \(report.classes.sorted())")
        }
        XCTAssertGreaterThan(report.checked, 100, "the controls' insides are checked too")
        let text = try await evaluate("""
            [getComputedStyle(document.querySelector('.ss-sheet .ss-name')).cursor,
             getComputedStyle(document.querySelector('.ss-sheet .ss-kbd')).cursor,
             getComputedStyle(document.querySelector('.ss-collapsed .ss-rsnip')).cursor].join(',')
            """, in: webView) as? String
        XCTAssertEqual(text, "auto,auto,pointer", "the open sheet's words are text; a collapsed row's are a control's")

        // The open recipients are a control too: a click anywhere in them folds them.
        _ = try await evaluate("document.querySelector('.ss-sheet .ss-rc').click()", in: webView)
        report = try await cursors(in: webView)
        XCTAssertTrue(report.classes.contains("ss-rcx"))
        XCTAssertEqual(report.wrong, [])

        let key = ConversationShellAssets.jsStringLiteral(payload.messages[8].id)
        let download = """
            (function () {
              var save = document.querySelector('.ss-chip[data-attachment-id="att-1"]').parentNode.querySelector('.ss-chip-dl');
              return [getComputedStyle(save).cursor, getComputedStyle(save.firstElementChild || save).cursor].join(',');
            })()
            """
        _ = try await evaluate("window.ss.attachmentProgress(\(key), 'att-1', null)", in: webView)
        let busy = try await evaluate(download, in: webView) as? String
        XCTAssertEqual(busy, "default,default", "a disabled Download and its glyph take the arrow")
        report = try await cursors(in: webView)
        XCTAssertEqual(report.wrong, [], "the chip itself stays a control while its file downloads")
        _ = try await evaluate("window.ss.attachmentProgress(\(key), 'att-1', -1)", in: webView)
        let done = try await evaluate(download, in: webView) as? String
        XCTAssertEqual(done, "pointer,pointer")
    }

    /// The invitation card's controls show the hand: its answers (the chosen one too, which is pressed, not disabled), its
    /// links, which are buttons, Open in Calendar and the elision mark over the message under it.
    func testTheInvitationCardsControlsShowTheHand() async throws {
        let (webView, _) = try await loadedShell()
        var message = F.message("m1", date: F.utc(2025, 3, 7, 14, 5))
        message.invitationReply = .accepted
        var body = F.body(html: "<p>Ben has invited you.</p>")
        body.invitation = CalendarInvitation(
            method: .request, uid: "uid-1", title: "Design review", start: F.utc(2025, 3, 11, 15), end: F.utc(2025, 3, 11, 16),
            location: "https://meet.example.com/abc", conferenceURL: "https://teams.example.com/l/meetup-join/abc",
            organizer: CalendarInvitation.Person(name: "Ben Carter", address: "ben@example.com"),
            attendees: [CalendarInvitation.Person(address: "me@example.com", response: .accepted)], repeats: nil,
            userAddress: "me@example.com", userResponse: .accepted, calendarText: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
        let payload = F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts, now: F.utc(2025, 3, 7, 15))
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        let report = try await cursors(in: webView)
        XCTAssertEqual(report.wrong, [])
        for control in ["ss-ans", "ss-chosen", "ss-ilink", "ss-iopen", "ss-toggle-message"] {
            XCTAssertTrue(report.classes.contains(control), "the card shows a \(control): \(report.classes.sorted())")
        }
    }

    /// Links in bodies compute the hand: the ones the reader found in a plain-text body (before 1.8.1 they computed only
    /// `auto`), and a sender's own, whose sheet asks for the arrow with `!important`, the words inside them included.
    /// The body's words keep `auto`, which WebKit shows as the I-beam.
    func testLinksInBodiesShowTheHand() async throws {
        let (webView, _) = try await loadedShell()
        let plain = F.message("m1", date: F.utc(2025, 3, 1, 9, 0))
        let styled = F.message("m2", date: F.utc(2025, 3, 2, 9, 0))
        var styledBody = F.body(html: """
            <style>a { cursor: default !important; } a b { cursor: text !important; }</style>
            <p>Read <a href="https://example.com/a">the notes</a> or <a href="https://example.com/b"><b>the plan</b></a>.</p>
            """)
        styledBody.typesetting = .styled
        let payload = F.builder.build(messages: [plain, styled],
                                      bodies: [plain.id: plainBody("Notes: https://example.com/notes\nWrite to ada@example.com"),
                                               styled.id: styledBody],
                                      accounts: F.accounts, now: F.utc(2025, 3, 20, 9, 0))
        _ = try await evaluate("window.ss.render(\(try payload.jsonString())); window.ss.expandAll()", in: webView)
        try await waitForFrames(count: 2, in: webView)
        let probe = """
            Array.from(document.querySelectorAll('.ss-card iframe')).map(function (f) {
              var d = f.contentDocument;
              var links = Array.from(d.querySelectorAll('a[href], a[href] *')).map(function (a) { return getComputedStyle(a).cursor; });
              var words = d.querySelector('p, .ss-plain');
              return links.join(' ') + '|' + (words ? getComputedStyle(words).cursor : '');
            }).join('\\n')
            """
        let frames = (try await evaluate(probe, in: webView) as? String)?.components(separatedBy: "\n")
        XCTAssertEqual(frames, ["pointer pointer|auto", "pointer pointer pointer|auto"],
                       "plain: the address and the mailto; styled: two links and the bold words in one")
    }

    // MARK: Helpers

    /// How many declarations of `property` a stylesheet makes, its comments left out.
    private func declarations(of property: String, in css: String) -> Int {
        let code = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return code.components(separatedBy: property + ":").count - 1
    }

    private func plainBody(_ text: String) -> StoredBody {
        let id = MessageID(accountID: F.accountID, providerID: "plain")
        let sanitized = HTMLSanitizer().sanitize(MessageBody(html: nil, text: text), messageID: id)
        return StoredBody(body: MessageBody(html: nil, text: text), renderedHTML: sanitized.html, plainText: sanitized.plainText,
                          hasQuotedContent: sanitized.hasQuotedContent, blockedRemoteImageCount: sanitized.blockedRemoteImageCount,
                          typesetting: sanitized.typesetting, declaresColors: sanitized.declaresColors,
                          coveredByNewYork: sanitized.coveredByNewYork)
    }

    /// What the shell's controls compute: every element that is a button or has the button role, and everything inside
    /// one, against what its nearest control asks for (the arrow when that control is disabled, the hand otherwise).
    private struct CursorReport {
        var wrong: [String]
        var classes: Set<String>
        var checked: Int
    }

    private func cursors(in webView: WKWebView) async throws -> CursorReport {
        let script = """
            (function () {
              var controls = 'button, [role="button"]';
              var wrong = [], classes = {}, checked = 0;
              document.querySelectorAll(controls).forEach(function (c) {
                (c.getAttribute('class') || '').split(' ').forEach(function (k) { if (k) { classes[k] = true; } });
              });
              document.querySelectorAll('button, [role="button"], button *, [role="button"] *').forEach(function (n) {
                var control = n.closest(controls);
                var disabled = control.disabled || control.getAttribute('aria-disabled') === 'true';
                var cursor = getComputedStyle(n).cursor;
                checked += 1;
                if (cursor !== (disabled ? 'default' : 'pointer')) {
                  wrong.push(control.className + ' > ' + n.tagName.toLowerCase() + '.' + (n.getAttribute('class') || '') + ': ' + cursor);
                }
              });
              return JSON.stringify({ wrong: wrong, classes: Object.keys(classes), checked: checked });
            })()
            """
        let result = try await evaluate(script, in: webView)
        let json = try XCTUnwrap(result as? String)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return CursorReport(wrong: object["wrong"] as? [String] ?? ["unreadable"], classes: Set(object["classes"] as? [String] ?? []),
                            checked: object["checked"] as? Int ?? 0)
    }

    private final class ShellMessages: NSObject, WKScriptMessageHandler {
        private(set) var isReady = false

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == ConversationShellAssets.readyHandlerName { isReady = true }
        }
    }

    /// WebKit stalls a `loadHTMLString` whose base scheme has no handler, so the test registers one as the app does.
    private final class SchemeStub: NSObject, WKURLSchemeHandler {
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
    private let schemes = SchemeStub()

    override func tearDown() {
        configuration?.userContentController.removeAllScriptMessageHandlers()
        configuration = nil
        super.tearDown()
    }

    /// The shell in a web view, once it has signalled ready. Skips unless `SS_UI_TESTS=1`.
    private func loadedShell() async throws -> (WKWebView, ShellMessages) {
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else {
            throw XCTSkip("Set SS_UI_TESTS=1 to drive WebKit")
        }
        let handler = ShellMessages()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemes, forURLScheme: ConversationShellAssets.scheme)
        configuration.userContentController.add(handler, name: ConversationShellAssets.readyHandlerName)
        configuration.userContentController.add(handler, name: ConversationShellAssets.messageHandlerName)
        self.configuration = configuration
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.loadHTMLString(ConversationShellAssets.html, baseURL: ConversationShellAssets.baseURL)
        var attempts = 0
        while !handler.isReady, attempts < 200 {
            try await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
        guard handler.isReady else { throw XCTSkip("no shell") }
        return (webView, handler)
    }

    /// Frames size themselves after their documents load.
    private func waitForFrames(count: Int, in webView: WKWebView) async throws {
        var heights: [Double] = []
        for _ in 0..<100 {
            heights = (try await evaluate("window.ss.measureAll()", in: webView) as? [NSNumber])?.map(\.doubleValue) ?? []
            if heights.count == count, heights.allSatisfy({ $0 > 0 }) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("frames never measured: \(heights)")
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
}
