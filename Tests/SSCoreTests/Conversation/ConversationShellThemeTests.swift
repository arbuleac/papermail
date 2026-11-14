import WebKit
import XCTest
@testable import SSCore

/// The reader in a theme (spec §4.16) and the Dark Mode default (§5.14, §5.16). The headless half holds the shell's
/// document, CSS and payload to the design; the rest drives the real shell in a `WKWebView` and is gated behind
/// `SS_UI_TESTS=1`, as `ConversationShellWebViewTests` is.
@MainActor
final class ConversationShellThemeTests: XCTestCase {
    typealias F = ConversationFixtures

    // MARK: Themes from tokens.json

    /// `themes` of tokens.json, the source of the flags the app reads from `QuireTheme`.
    private static let tokenThemes: [[String: Any]] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Conversation
            .deletingLastPathComponent() // SSCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
            .appendingPathComponent("docs/design/tokens.json")
        guard let data = try? Data(contentsOf: url),
              let tokens = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return tokens["themes"] as? [[String: Any]] ?? []
    }()

    private func entry(_ id: String) throws -> [String: Any] {
        try XCTUnwrap(Self.tokenThemes.first { $0["id"] as? String == id }, "no theme \(id) in tokens.json")
    }

    /// The shell's view of theme `id`, flags and all, as the app makes it from `QuireTheme`.
    private func shellTheme(_ id: String) throws -> ShellTheme {
        let theme = try entry(id)
        return ShellTheme(id: id, links: try XCTUnwrap(theme["linkUnderlineAtRest"] as? [String: Bool]),
                          quoteLinks: try XCTUnwrap(theme["quoteLinkUnderlineAtRest"] as? [String: Bool]))
    }

    /// Theme `id`'s value of `token` in `mode`, as tokens.json has it.
    private func value(_ token: String, _ id: String, _ mode: String = "light") throws -> String {
        let colours = try XCTUnwrap(try entry(id)["color"] as? [String: [String: Any]])
        return try XCTUnwrap(colours[token]?[mode] as? String, "\(id).\(token).\(mode)")
    }

    // MARK: Document, CSS and payload

    /// A shell starts in the theme it was built in: its sheet after the head from the first paint, its id stamped on the
    /// root, and the body sheet and flags in `SS_THEME` for the bodies it builds. Study's sheet is empty.
    func testTheShellDocumentStartsInItsTheme() throws {
        let study = ConversationShellAssets.document()
        XCTAssertTrue(study.contains("<html data-ss-theme=\"study\">"))
        XCTAssertTrue(study.contains("<style id=\"ss-theme\"></style>"), "Study draws the head alone")
        XCTAssertEqual(study, ConversationShellAssets.html)

        let rain = try shellTheme("rain")
        let document = ConversationShellAssets.document(symbolCSS: ":root{--sym-star:url(data:x)}", theme: rain)
        XCTAssertTrue(document.contains("<html data-ss-theme=\"rain\">"))
        let sheet = try XCTUnwrap(document.range(of: "<style id=\"ss-theme\">" + rain.shell + "</style>"))
        let head = try XCTUnwrap(document.range(of: QuireCSS.head))
        let symbols = try XCTUnwrap(document.range(of: ":root{--sym-star:url(data:x)}"))
        XCTAssertLessThan(head.upperBound, sheet.lowerBound, "after the head, so it wins by order alone")
        XCTAssertLessThan(symbols.upperBound, sheet.lowerBound)
        XCTAssertTrue(document.contains(ConversationShellAssets.js))

        let line = try XCTUnwrap(document.components(separatedBy: "\n").first { $0.hasPrefix("var SS_THEME = ") })
        let state = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.dropFirst("var SS_THEME = ".count).dropLast().utf8))
                                  as? [String: Any])
        XCTAssertEqual(state["id"] as? String, "rain")
        XCTAssertEqual(state["body"] as? String, rain.body)
        XCTAssertNil(state["shell"], "the document carries the shell sheet once, in its style element")
        XCTAssertEqual(state["quoteLinks"] as? [String: Bool], ["light": true, "dark": true, "lightHC": true, "darkHC": true])
    }

    /// `ss.setTheme` gets both sheets and the two flags for every mode, in a script that stays inert inside `<script>`.
    func testTheThemeScriptCarriesBothSheetsAndTheFlags() throws {
        let gallery = try shellTheme("gallery")
        let script = gallery.script
        XCTAssertTrue(script.hasPrefix("window.ss && window.ss.setTheme("))
        XCTAssertFalse(script.contains("</"), "inert inside a <script> element")
        let json = String(script.dropFirst("window.ss && window.ss.setTheme(".count).dropLast())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "gallery")
        XCTAssertEqual(object["shell"] as? String, QuireCSS.themeSheet("gallery"))
        XCTAssertEqual(object["body"] as? String, ConversationShellAssets.bodyCut(QuireCSS.themeSheet("gallery")))
        XCTAssertEqual(object["links"] as? [String: Bool], ["light": true, "dark": true, "lightHC": true, "darkHC": true])
        XCTAssertEqual(object["quoteLinks"] as? [String: Bool], ["light": false, "dark": true, "lightHC": true, "darkHC": true])
        XCTAssertTrue(ConversationShellAssets.js.contains("setTheme: setTheme"))
    }

    /// Links underline at rest by `ss-links` and `ss-qlinks`, which Graphite and the theme's flags set, never by Graphite's
    /// class alone; an uncoloured link on the sender's page is `--q-linkOnPage`; the white page's ring is
    /// `--q-focusOnPage`, never a hand-written Iron Gall; and the inset is the permanent page's class, not `.ss-original`.
    func testLinksThePageAndItsRingDrawFromTheThemeVariables() {
        let shell = ConversationShellAssets.shellCSS
        XCTAssertTrue(shell.contains("html.ss-links .ss-link {"))
        XCTAssertTrue(shell.contains("html.ss-links .ss-idet .ss-ilink {"))
        XCTAssertFalse(shell.contains("html.ss-graphite .ss-link"), "Graphite underlines through ss-links")
        XCTAssertFalse(shell.contains("html.ss-graphite .ss-idet"), "Graphite underlines through ss-links")
        XCTAssertTrue(shell.contains(".ss-page.ss-inset-on {"))
        XCTAssertFalse(shell.contains(".ss-original"), "the shell's page is .ss-page; .ss-original names the frame document")

        let body = ConversationShellAssets.bodyCSS
        XCTAssertTrue(body.contains(":where(a:link) { color: var(--q-linkOnPage); }"))
        XCTAssertFalse(body.contains(":where(a:link) { color: var(--q-accent)"))
        XCTAssertTrue(body.contains(".ss-original a:focus-visible { --q-focus: var(--q-focusOnPage);"))
        for hex in ["#1E5468", "#123E4D"] {
            XCTAssertFalse(body.replacingOccurrences(of: ConversationShellAssets.bodyVariables, with: "").contains(hex),
                           "the page's ring is generated, not written by hand: \(hex)")
        }
        for selector in ["html.ss-links.ss-adapt a[href]", "html.ss-links body.ss-set a[href]",
                         "html.ss-qlinks body.ss-set blockquote a[href]", "html.ss-qlinks body.ss-set .ss-quote a[href]"] {
            XCTAssertTrue(body.contains(selector), selector)
        }
        XCTAssertTrue(ConversationShellAssets.bodyVariables.contains("--q-focusOnPage:"))
        XCTAssertTrue(ConversationShellAssets.bodyVariables.contains("--q-linkOnPage:"))
    }

    /// The Dark Mode default travels in the payload when the app gives it, and the shell reads it; a payload without it
    /// encodes as before.
    func testThePayloadCarriesTheDarkModeDefaultWhenGiven() throws {
        let message = F.message("m1")
        let bodies = [message.id: F.body(html: "<p>Hi</p>")]
        let off = F.builder.build(messages: [message], bodies: bodies, accounts: F.accounts, adaptsColours: false)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try off.jsonString().utf8)) as? [String: Any])
        XCTAssertEqual(object["adaptsColours"] as? Bool, false)
        let unsaid = F.builder.build(messages: [message], bodies: bodies, accounts: F.accounts)
        XCTAssertFalse(try unsaid.jsonString().contains("adaptsColours"))
        XCTAssertEqual(try JSONDecoder().decode(RenderPayload.self, from: Data(try off.jsonString().utf8)), off)
        XCTAssertTrue(ConversationShellAssets.js.contains(".adaptsColours"))
    }

    /// Print is paper (spec §5.48): Study's light values whatever the theme, so the print document has the head alone.
    func testPrintingLeavesTheThemeOut() throws {
        let message = F.message("m1")
        let payload = F.builder.build(messages: [message], bodies: [message.id: F.body(html: "<p>Hi</p>")], accounts: F.accounts)
        let document = PrintDocumentBuilder().document(for: payload)
        XCTAssertTrue(document.contains(QuireCSS.head))
        XCTAssertFalse(document.contains("ss-theme"))
        for id in QuireCSS.themeIDs.dropFirst() {
            let first = try XCTUnwrap(QuireCSS.themeSheet(id).components(separatedBy: "\n").first)
            XCTAssertFalse(document.contains(first), id)
        }
    }

    // MARK: In WebKit

    /// `ss.setTheme` replaces the sheet in the shell and in every body document in place: the same frames, the same
    /// heights, every document resolved in the new theme, and `themed` posted.
    func testSetThemeRestylesTheShellAndEveryBodyWithoutAReload() async throws {
        let (webView, handler) = try await loadedShell()
        _ = try await evaluate("window.ss.render(\(try twoMessagePayload().jsonString())); window.ss.expandAll()", in: webView)
        try await waitForFrames(count: 2, in: webView)
        _ = try await evaluate("document.querySelectorAll('.ss-card iframe').forEach(function (f, i) { f.ssMark = i + 1; })", in: webView)
        let sizes = "window.ss.iframeHeights().concat([document.documentElement.scrollHeight])"
        let before = numbers(try await evaluate(sizes, in: webView))
        let rain = try shellTheme("rain")
        let id = try await evaluate(rain.script, in: webView) as? String
        XCTAssertEqual(id, "rain")
        XCTAssertTrue(handler.received.contains { $0["kind"] as? String == "themed" && $0["id"] as? String == "rain" })
        let marks = numbers(try await evaluate(
            "Array.prototype.map.call(document.querySelectorAll('.ss-card iframe'), function (f) { return f.ssMark || 0; })", in: webView))
        XCTAssertEqual(marks, [1, 2], "the same frames: nothing reloaded")
        let after = numbers(try await evaluate(sizes, in: webView))
        XCTAssertEqual(after, before, "colour changes no height")
        try await expect("getComputedStyle(document.documentElement).getPropertyValue('--q-paper')", try value("paper", "rain"), in: webView)
        try await expect("document.documentElement.getAttribute('data-ss-theme')", "rain", in: webView)
        for index in 0..<2 {
            let doc = "document.querySelectorAll('.ss-card iframe')[\(index)].contentDocument"
            try await expect("\(doc).getElementById('ss-theme').textContent", rain.body, in: webView)
            try await expect("\(doc).documentElement.getAttribute('data-ss-theme')", "rain", in: webView)
            try await expect("getComputedStyle(\(doc).documentElement).getPropertyValue('--q-ink')", try value("ink", "rain"), in: webView)
        }
        // And back: Study's sheet is empty, so the head alone draws.
        _ = try await evaluate(ShellTheme.study.script, in: webView)
        try await expect("getComputedStyle(document.documentElement).getPropertyValue('--q-paper')", try value("paper", "study"), in: webView)
        try await expect("document.querySelector('.ss-card iframe').contentDocument.getElementById('ss-theme').textContent", "", in: webView)
    }

    /// A frame still loading when the theme changes loads the srcdoc it was built with; the shell finds the old sheet's
    /// stamp once it lands and puts the new sheet in.
    func testAFrameLoadingDuringASwitchEndsWithTheNewSheet() async throws {
        let (webView, _) = try await loadedShell()
        let grove = try shellTheme("grove")
        _ = try await evaluate("window.ss.render(\(try twoMessagePayload().jsonString())); window.ss.expandAll(); \(grove.script)", in: webView)
        try await waitForFrames(count: 2, in: webView)
        for index in 0..<2 {
            let doc = "document.querySelectorAll('.ss-card iframe')[\(index)].contentDocument"
            try await expect("\(doc).documentElement.getAttribute('data-ss-theme')", "grove", in: webView)
            try await expect("\(doc).getElementById('ss-theme').textContent", grove.body, in: webView)
            try await expect("getComputedStyle(\(doc).documentElement).getPropertyValue('--q-ink')", try value("ink", "grove"), in: webView)
        }
    }

    /// `ss-links` and `ss-qlinks` follow the theme's flag for the mode, and Graphite sets both, on the shell and on every
    /// body document; a link in a Quire-set body then draws its underline at rest, even one whose markup took it off.
    func testLinkClassesFollowTheThemeTheModeAndGraphite() async throws {
        let shellClasses = "['ss-links', 'ss-qlinks'].filter(function (c) { return document.documentElement.classList.contains(c); }).join(' ')"
        let bodyClasses = "(function () { var d = document.querySelector('.ss-card iframe').contentDocument.documentElement;"
            + " return ['ss-links', 'ss-qlinks'].filter(function (c) { return d.classList.contains(c); }).join(' '); })()"
        func expectClasses(_ expected: String, in webView: WKWebView, _ message: String, line: UInt = #line) async throws {
            try await expect(shellClasses, expected, in: webView, message, line: line)
            try await expect(bodyClasses, expected, in: webView, "every body document copies the shell's", line: line)
        }
        let underline = "getComputedStyle(document.querySelector('.ss-card iframe').contentDocument.querySelector('p > a')).textDecorationLine"
        let quoted = "getComputedStyle(document.querySelector('.ss-card iframe').contentDocument.querySelector('blockquote a')).textDecorationLine"

        let (light, _) = try await loadedShell()
        _ = try await evaluate("window.ss.render(\(try linkPayload().jsonString()))", in: light)
        try await waitForFrames(count: 1, in: light)
        try await expectClasses("", in: light, "Study draws no link underline at rest outside Graphite")
        try await expect(underline, "none", in: light)
        _ = try await evaluate(try shellTheme("gallery").script, in: light)
        try await expectClasses("ss-links", in: light, "Gallery's ink is its text ink: every link, in Light")
        try await expect(underline, "underline", in: light)
        _ = try await evaluate(try shellTheme("rain").script, in: light)
        try await expectClasses("ss-qlinks", in: light, "Rain's ink sits near its ink2: links in quotes")
        try await expect(underline, "none", in: light)
        try await expect(quoted, "underline", in: light)
        _ = try await evaluate(ShellTheme.study.script + "; window.ss.setModes({graphite: true})", in: light)
        try await expectClasses("ss-links ss-qlinks", in: light, "Graphite underlines every link in every theme")
        try await expect(underline, "underline", in: light)

        let (dark, _) = try await loadedShell(dark: true, theme: try shellTheme("gallery"))
        _ = try await evaluate("window.ss.render(\(try linkPayload().jsonString()))", in: dark)
        try await waitForFrames(count: 1, in: dark)
        try await expectClasses("ss-links ss-qlinks", in: dark, "a shell built in Gallery starts with its Dark flags")
        _ = try await evaluate(try shellTheme("dusk").script, in: dark)
        try await expectClasses("", in: dark, "Dusk's night ink is far from both its inks")
    }

    /// A styled newsletter's link that its sender left uncoloured, and undecorated, sits beside the sender's text: it takes
    /// `--q-linkOnPage`, Study's accent, even in Gallery, whose ink is its text ink; the sender's `none` stays.
    func testAnUncolouredLinkInAStyledNewsletterTakesTheLinkOnPage() async throws {
        let (webView, _) = try await loadedShell(theme: try shellTheme("gallery"))
        let message = F.message("m1")
        var body = F.body(html: "<table><tr><td style=\"color:#222222\">News "
            + "<a href=\"https://example.com/read\" style=\"text-decoration:none\">Read more</a></td></tr></table>")
        body.typesetting = .styled
        body.declaresColors = false
        let payload = F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts)
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFrames(count: 1, in: webView)
        let link = "document.querySelector('.ss-card iframe').contentDocument.querySelector('a')"
        try await expect("getComputedStyle(\(link)).color", rgb(try value("accent", "study")), in: webView)
        XCTAssertNotEqual(rgb(try value("accent", "gallery")), rgb(try value("accent", "study")))
        try await expect("getComputedStyle(\(link)).textDecorationLine", "none", in: webView)
    }

    /// The frame's page is permanent: ⇧⌘O, a change of the Dark Mode default and an appearance change toggle the inset's
    /// class and refit, and the frame is never built again. On the inset the body is light, as the page is.
    func testThePageWrapperIsPermanent() async throws {
        let (webView, _) = try await loadedShell(dark: true)
        _ = try await evaluate("window.ss.render(\(try declaringPayload().jsonString()))", in: webView)
        try await waitForFrames(count: 1, in: webView)
        _ = try await evaluate("document.querySelector('.ss-card iframe').ssMark = 7", in: webView)
        let state = """
            (function () { var f = document.querySelector('.ss-card iframe'); var p = document.querySelector('.ss-card .ss-page');
              return [document.querySelectorAll('.ss-card iframe').length, f.ssMark || 0, p.contains(f),
                      p.classList.contains('ss-inset-on'), f.contentDocument.documentElement.className].join(' '); })()
            """
        let dark = "document.querySelector('.ss-card iframe').contentWindow.matchMedia('(prefers-color-scheme: dark)').matches"
        // The page around the frame, the frame, and the card against its content: refitted, never left at the old height.
        let heights = """
            (function () { var c = document.querySelector('.ss-card'); var inner = c.querySelector('.ss-inner');
              return [c.querySelector('.ss-page').getBoundingClientRect().height, c.querySelector('iframe').getBoundingClientRect().height,
                      c.getBoundingClientRect().height - Math.ceil(inner.getBoundingClientRect().height)]; })()
            """
        try await expect(state, "1 7 true false ss-adapt", in: webView)
        let adapted = numbers(try await evaluate(heights, in: webView))
        XCTAssertEqual(adapted.count, 3)
        XCTAssertEqual(adapted.first, adapted.dropFirst().first, "no inset: the page is the frame")

        _ = try await evaluate("window.ss.preferences({readingSans: false, colorsNoticeDismissed: false, adaptsColours: false})", in: webView)
        try await expect(state, "1 7 true true ss-original", in: webView, "the default: a class, not a frame")
        try await expectTrue("!(\(dark))", in: webView, "the white page is light inside too")
        let inset = numbers(try await evaluate(heights, in: webView))
        XCTAssertEqual(inset.count, 3)
        if inset.count == 3 {
            XCTAssertEqual(inset[0], inset[1] + 24, accuracy: 0.5, "the inset's padding")
            XCTAssertEqual(inset[2], 0, accuracy: 0.5, "the card refitted to it")
        }

        let switched = try await evaluate("window.ss.toggleOriginal()", in: webView) as? Bool
        XCTAssertEqual(switched, false)
        try await expect(state, "1 7 true false ss-adapt", in: webView, "⇧⌘O: a class, not a frame")
        try await expectTrue(dark, in: webView, "adapted, the body is dark again")

        webView.appearance = NSAppearance(named: .aqua)
        try await waitFor("document.querySelector('.ss-card iframe').contentDocument.documentElement.className === ''", in: webView)
        try await expect(state, "1 7 true false", in: webView, "Light offers no original colours")
        webView.appearance = NSAppearance(named: .darkAqua)
        try await waitFor("document.querySelector('.ss-card iframe').contentDocument.documentElement.className !== ''", in: webView)
        try await expect(state, "1 7 true false ss-adapt", in: webView, "switched by hand: adapted, as it was left")
    }

    /// With the Dark Mode default off, a styled message that declares colours opens as sent, View › Original Colors
    /// checked and no notice; ⇧⌘O adapts it, with the adapted notice, and a second puts it back; a later change of the
    /// default leaves it as the user set it, which is then not the default's choice, so it says so.
    func testWithTheDefaultOffAStyledMessageOpensAsSentAndSwitchesByHand() async throws {
        let (webView, handler) = try await loadedShell(dark: true)
        var payload = try declaringPayload()
        payload.adaptsColours = false
        let key = payload.messages[0].id
        _ = try await evaluate("window.ss.render(\(try payload.jsonString()))", in: webView)
        try await waitForFrames(count: 1, in: webView)
        let root = "document.querySelector('.ss-card iframe').contentDocument.documentElement.className"
        let notice = "(function () { var n = document.querySelector('.ss-banner.ss-warn .ss-btxt'); return n ? n.textContent : ''; })()"
        let original = "window.ss.targetState().original"
        func shown() -> [String]? { handler.received.last { $0["kind"] as? String == "originalColors" }?["shown"] as? [String] }

        try await expect(root, "ss-original", in: webView)
        try await expectTrue(original, in: webView)
        XCTAssertEqual(shown(), [key], "the menu's checkmark: shown as sent")
        try await expect(notice, "", in: webView, "Settings chose it, so nothing says so")
        try await expectTrue("document.querySelectorAll('.ss-hact.ss-qon').length === 1", in: webView, "the header action shows it on")

        let first = try await evaluate("window.ss.toggleOriginal()", in: webView) as? Bool
        XCTAssertEqual(first, false, "⇧⌘O adapts it")
        try await expect(root, "ss-adapt", in: webView)
        XCTAssertEqual(shown(), [])
        XCTAssertEqual(handler.received.last { $0["kind"] as? String == "originalColors" }?["on"] as? Bool, false)
        try await expect(notice, "This message uses its own colours.", in: webView)

        let second = try await evaluate("window.ss.toggleOriginal()", in: webView) as? Bool
        XCTAssertEqual(second, true, "a second puts it back")
        try await expect(root, "ss-original", in: webView)
        XCTAssertEqual(shown(), [key])
        try await expect(notice, "", in: webView)

        _ = try await evaluate("window.ss.preferences({readingSans: false, colorsNoticeDismissed: false, adaptsColours: true})", in: webView)
        try await expect(root, "ss-original", in: webView, "a message switched by hand keeps its colours")
        try await expectTrue(original, in: webView)
        try await expect(notice, "Showing the sender\u{2019}s colours.", in: webView, "no longer the default's choice")

        // A message never switched follows the default both ways.
        let other = try declaringPayload(id: "m2")
        _ = try await evaluate("window.ss.render(\(try other.jsonString()))", in: webView)
        try await waitForFrames(count: 1, in: webView)
        try await expect(root, "ss-adapt", in: webView)
        _ = try await evaluate("window.ss.preferences({readingSans: false, colorsNoticeDismissed: false, adaptsColours: false})", in: webView)
        try await expect(root, "ss-original", in: webView)
        XCTAssertEqual(shown(), [other.messages[0].id])
    }

    // MARK: Fixtures

    private func twoMessagePayload() throws -> RenderPayload {
        let first = F.message("m1", date: F.utc(2025, 1, 3, 14, 5))
        let second = F.message("m2", from: F.bob, date: F.utc(2025, 3, 7, 14, 5), isRead: false)
        var styled = F.body(html: "<table><tr><td>Newsletter</td></tr></table><p>More</p>")
        styled.typesetting = .styled
        styled.declaresColors = false
        let bodies: [MessageID: StoredBody] = [first.id: F.body(html: "<p>Hello <b>world</b></p>"), second.id: styled]
        return F.builder.build(messages: [first, second], bodies: bodies, accounts: F.accounts, now: F.utc(2025, 3, 7, 15, 0))
    }

    /// A Quire-set body with a link in its text and one in a quote, both with their underline taken off.
    private func linkPayload() throws -> RenderPayload {
        let message = F.message("m1")
        var body = F.body(html: "<p>See <a href=\"https://example.com/a\" style=\"text-decoration:none\">the plan</a></p>"
            + "<blockquote><p>Earlier <a href=\"https://example.com/b\" style=\"text-decoration:none\">notes</a></p></blockquote>")
        body.typesetting = .unstyled
        body.declaresColors = false
        return F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts)
    }

    /// Styled mail that declares its own colours: adapted in Dark by default, or shown as sent.
    private func declaringPayload(id: String = "m1") throws -> RenderPayload {
        let message = F.message(id)
        var body = F.body(html: "<table bgcolor=\"#B91C1C\"><tr><td style=\"color:#ffffff\">Northwind</td></tr></table>")
        body.typesetting = .styled
        body.declaresColors = true
        return F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts)
    }

    private func rgb(_ hex: String) -> String {
        let digits = Array(hex.dropFirst())
        let channels = stride(from: 0, to: 6, by: 2).map { Int(String(digits[$0..<$0 + 2]), radix: 16) ?? 0 }
        return "rgb(\(channels[0]), \(channels[1]), \(channels[2]))"
    }

    // MARK: Harness

    /// Collects what the shell posts.
    @MainActor
    private final class ShellMessages: NSObject, WKScriptMessageHandler {
        private(set) var isReady = false
        private(set) var received: [[String: Any]] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { received.append(body) }
            if message.name == ConversationShellAssets.readyHandlerName { isReady = true }
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

    private var handlers: [ShellMessages] = []

    /// The shell built in `theme`, in a web view, once it has signalled ready. Skips unless `SS_UI_TESTS=1`.
    private func loadedShell(dark: Bool = false, theme: ShellTheme = .study) async throws -> (WKWebView, ShellMessages) {
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else {
            throw XCTSkip("Set SS_UI_TESTS=1 to drive WebKit")
        }
        let handler = ShellMessages()
        handlers.append(handler)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ShellSchemeStub(), forURLScheme: ConversationShellAssets.scheme)
        configuration.userContentController.add(handler, name: ConversationShellAssets.readyHandlerName)
        configuration.userContentController.add(handler, name: ConversationShellAssets.messageHandlerName)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        webView.loadHTMLString(ConversationShellAssets.document(theme: theme), baseURL: ConversationShellAssets.baseURL)
        for _ in 0..<200 where !handler.isReady {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard handler.isReady else {
            XCTFail("shell never signalled ready")
            throw XCTSkip("no shell")
        }
        return (webView, handler)
    }

    private func waitForFrames(count: Int, in webView: WKWebView) async throws {
        var heights: [Double] = []
        for _ in 0..<100 {
            heights = numbers(try await evaluate("window.ss.measureAll(); window.ss.iframeHeights()", in: webView)).filter { $0 >= 0 }
            if heights.count == count, heights.allSatisfy({ $0 > 0 }) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("frames never measured: \(heights)")
    }

    private func waitFor(_ condition: String, in webView: WKWebView) async throws {
        for _ in 0..<100 {
            if try await evaluate("!!(\(condition))", in: webView) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("never: \(condition)")
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

    private func string(_ script: String, in webView: WKWebView) async throws -> String {
        ((try await evaluate(script, in: webView) as? String) ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func expect(_ script: String, _ expected: String, in webView: WKWebView, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await string(script, in: webView)
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    private func expectTrue(_ script: String, in webView: WKWebView, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await evaluate("!!(\(script))", in: webView) as? Bool
        XCTAssertEqual(actual, true, message, file: file, line: line)
    }

    private func numbers(_ value: Any?) -> [Double] {
        (value as? [NSNumber])?.map(\.doubleValue) ?? []
    }
}
