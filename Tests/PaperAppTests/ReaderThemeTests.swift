import AppKit
import PaperCore
import PaperDesign
import WebKit
import XCTest
@testable import PaperApp

/// The reader in a theme (spec §4.16) and the Dark Mode default (§5.14, §5.16), in the app: a switch restyles every
/// ready shell in place and the colour under each page; a reader made in a theme loads its shell in it; and with Adapt
/// off, View › Original Colors, the More menu, ⇧⌘O and the page agree on what a message shows. Every window is off
/// screen over a throwaway store, and the theme is given back to Study.
@MainActor
final class ReaderThemeTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated { QuireEnvironment.shared.setTheme(.study) }
        super.tearDown()
    }

    private func evaluate(_ script: String, in webView: WKWebView) -> Any? {
        var value: Any??
        webView.evaluateJavaScript(script) { result, _ in value = .some(result) }
        ListTestSupport.spin(until: { value != nil }, timeout: 5)
        return value ?? nil
    }

    private func hex(_ colour: NSColor?) -> String {
        guard let rgb = colour?.usingColorSpace(.sRGB) else { return "none" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }

    /// `token` of `theme` as `appearance` draws it.
    private func hex(_ token: QuireColorToken, _ theme: QuireTheme, under appearance: NSAppearance) -> String {
        var value = ""
        appearance.performAsCurrentDrawingAppearance { value = hex(NSColor.quire(token, theme: theme)) }
        return value
    }

    private func settled(_ harness: MainWindowHarness) throws {
        var landed: WKWebView??
        harness.controller.whenReaderSettles(timeout: 10) { landed = .some($0) }
        harness.spin(until: { landed != nil })
        XCTAssertNotNil(landed ?? nil, "the reader rendered the conversation")
        ListTestSupport.spin(until: { harness.reader.pool.slots.allSatisfy { $0.isReady && !$0.renderInFlight } }, timeout: 10)
    }

    /// A theme switch replaces the sheet of every ready shell, the pre-rendered ones too, without reloading a frame, and
    /// sets the colour under each page again, which WebKit keeps fixed; an appearance change sets it again as well.
    func testASwitchRestylesEveryShellInPlaceAndTheColourUnderItsPage() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        window.appearance = NSAppearance(named: .aqua)
        harness.selectFirst(1)
        try settled(harness)
        let pool = harness.reader.pool
        for slot in pool.slots {
            _ = evaluate("document.querySelectorAll('iframe').forEach(function (f) { f.ssMark = 1; })", in: slot.webView)
            XCTAssertEqual(hex(slot.webView.underPageBackgroundColor), hex(.canvas, .study, under: slot.webView.effectiveAppearance))
        }
        var themed: [QuireTheme] = []
        pool.onThemed = { themed.append($0) }
        harness.settings.theme = .rain
        ListTestSupport.spin(until: { themed == [.rain] }, timeout: 5)
        XCTAssertEqual(themed, [.rain], "every ready shell restyled, once")
        for slot in pool.slots {
            let webView = slot.webView
            XCTAssertEqual(evaluate("document.documentElement.getAttribute('data-ss-theme')", in: webView) as? String, "rain")
            let canvas = (evaluate("getComputedStyle(document.documentElement).getPropertyValue('--q-canvas').trim()", in: webView) as? String)
            XCTAssertEqual(canvas, hex(.canvas, .rain, under: webView.effectiveAppearance), "the shell draws Rain's desk")
            let unmarked = evaluate("Array.prototype.filter.call(document.querySelectorAll('iframe'), function (f) { return !f.ssMark; }).length",
                                    in: webView) as? NSNumber
            XCTAssertEqual(unmarked?.intValue, 0, "no frame was built again")
            XCTAssertEqual(hex(webView.underPageBackgroundColor), hex(.canvas, .rain, under: webView.effectiveAppearance),
                           "the colour under the page follows the theme")
            XCTAssertNotEqual(hex(.canvas, .rain, under: webView.effectiveAppearance), hex(.canvas, .study, under: webView.effectiveAppearance))
        }
        let current = try XCTUnwrap(pool.current?.webView)
        window.appearance = NSAppearance(named: .darkAqua)
        ListTestSupport.spin(until: { self.hex(current.underPageBackgroundColor) == self.hex(.canvas, .rain, under: current.effectiveAppearance) },
                             timeout: 5)
        XCTAssertEqual(hex(current.underPageBackgroundColor), hex(.canvas, .rain, under: NSAppearance(named: .darkAqua)!),
                       "and the appearance")
        pool.onThemed = nil
    }

    /// A reader made while a theme is chosen (a reader window's, on ⌘O) loads a shell already in it, so its first frame
    /// is never Study's.
    func testAReaderMadeInAThemeLoadsItsShellInIt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.settings.theme = .dusk
        let reader = ConversationViewController(client: harness.environment.engine, poolSize: 1, settings: harness.settings)
        _ = reader.view
        XCTAssertTrue(reader.pool.document.contains("<html data-ss-theme=\"dusk\">"))
        XCTAssertTrue(reader.pool.document.contains("<style id=\"ss-theme\">" + QuireCSS.themeSheet("dusk") + "</style>"))
        let id = try XCTUnwrap(harness.list.conversations.first?.id)
        reader.show(id)
        let slot = try XCTUnwrap(reader.pool.current)
        ListTestSupport.spin(until: { slot.isReady && !slot.renderInFlight && slot.renderedID == id }, timeout: 10)
        XCTAssertEqual(evaluate("document.documentElement.getAttribute('data-ss-theme')", in: slot.webView) as? String, "dusk")
    }

    /// With Adapt off, in Dark, a styled message that declares its own colours opens as sent and View › Original Colors is
    /// checked; ⇧⌘O adapts it and unchecks it, a second ⇧⌘O puts both back, and the More menu names the switch the same
    /// way. Turning Adapt on leaves the message as it was switched.
    func testWithAdaptOffTheMenuTheMoreMenuAndThePageAgree() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        window.appearance = NSAppearance(named: .darkAqua)
        harness.settings.adaptsMailColours = false
        let conversation = try XCTUnwrap(harness.list.conversations.first?.id)
        let messages = try harness.environment.store.messages(in: conversation)
        for message in messages {
            var body = StoredBody(body: MessageBody(html: "<table bgcolor=\"#B91C1C\"><tr><td style=\"color:#ffffff\">Sale</td></tr></table>",
                                                    text: "Sale", attachments: []),
                                  renderedHTML: "<table bgcolor=\"#B91C1C\"><tr><td style=\"color:#ffffff\">Sale</td></tr></table>",
                                  plainText: "Sale")
            body.typesetting = .styled
            body.declaresColors = true
            try harness.environment.store.saveBody(body, for: message.id)
        }
        harness.selectFirst(1)
        try settled(harness)
        let reader = harness.reader
        let slot = try XCTUnwrap(reader.pool.current)
        let target = try XCTUnwrap(reader.currentMessages.last?.id)
        let item = NSMenuItem(title: "Original Colors", action: #selector(ConversationViewController.toggleOriginalColors(_:)), keyEquivalent: "o")
        func checked() -> Bool {
            _ = reader.validateMenuItem(item)
            return item.state == .on
        }
        func moreSays() -> String? {
            let state = evaluate("window.ss.targetState()", in: slot.webView) as? [String: Any] ?? [:]
            return reader.makeMoreMenu(for: target, shellState: state).items.first { $0.title.hasSuffix("Colors") }?.title
        }
        func frameClass() -> String? {
            evaluate("(function () { var f = document.querySelector('.ss-card.ss-sheet iframe');"
                     + " return f ? f.contentDocument.documentElement.className : null; })()", in: slot.webView) as? String
        }
        ListTestSupport.spin(until: { checked() }, timeout: 5)
        XCTAssertTrue(checked(), "opened as sent: checked")
        XCTAssertTrue(slot.originalColorsShown.contains(target))
        XCTAssertEqual(moreSays(), "Adaptive Colors")
        XCTAssertEqual(frameClass(), "ss-original")

        reader.toggleOriginalColors(nil)
        ListTestSupport.spin(until: { !checked() }, timeout: 5)
        XCTAssertFalse(checked(), "⇧⌘O adapts it")
        XCTAssertEqual(moreSays(), "Original Colors")
        XCTAssertEqual(frameClass(), "ss-adapt")

        reader.toggleOriginalColors(nil)
        ListTestSupport.spin(until: { checked() }, timeout: 5)
        XCTAssertTrue(checked(), "a second ⇧⌘O puts it back")

        reader.toggleOriginalColors(nil)
        ListTestSupport.spin(until: { !checked() }, timeout: 5)
        harness.settings.adaptsMailColours = true
        ListTestSupport.spin(for: 0.2)
        XCTAssertFalse(checked(), "switched by hand, it stays adapted whatever the default")
        XCTAssertEqual(frameClass(), "ss-adapt")
    }
}
