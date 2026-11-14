import AppKit
import SSCore
import SSDesign
import WebKit
import XCTest
@testable import SuperSparrowApp

/// Renders the app in every theme (spec §4.16), Light and Dark, for looking at: the main window at 1280 × 800 with the
/// demo's styled newsletter open (`theme-<id>-<light|dark>-main.png`), an 840 × 900 reader window on it
/// (`…-reader.png`), Settings on its Appearance tab (`…-settings.png`), and in Dark the newsletter with the Dark Mode
/// default off, on its white page (`theme-<id>-dark-original.png`). Written to `SS_RENDER_DIR` (the temporary folder when
/// unset). Opt-in, because it writes files:
///
///     SS_UI_TESTS=1 SS_RENDER_DIR=<dir> swift test --filter ThemeRenderTests
///
/// The demo runs over a throwaway store in a temporary folder with throwaway settings; nothing reaches the network, the
/// Keychain or the user's mail. Each theme is forced through the environment's overrides, as the design gallery's popup
/// does, and every window switches in place, as the app does.
@MainActor
final class ThemeRenderTests: XCTestCase {
    /// The demo's newsletters (`DemoCatalog`): styled mail that sets its own colours.
    private static let newsletters = ["The Overnight Brief", "Frontend Weekly", "Trailhead Outfitters", "Northwind Weekly", "SaaS Metrics Digest"]

    private var folder: URL!
    private var environment: AppEnvironment?
    private var overridesBefore = QuireEnvironment.Overrides()

    override func setUpWithError() throws {
        // Taken before the skip, so a skipped run's tearDown gives back exactly what it found.
        overridesBefore = QuireEnvironment.shared.overrides
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else {
            throw XCTSkip("set SS_UI_TESTS=1 to render the themes")
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ThemeRender-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        // Settings' tiles were set too, which sets the app's theme beneath the overrides.
        QuireEnvironment.shared.setTheme(.study)
        QuireEnvironment.shared.setOverrides(overridesBefore)
        if let environment {
            var finished = false
            Task { @MainActor in
                await environment.shutdown()
                finished = true
            }
            ListTestSupport.spin(until: { finished }, timeout: 5)
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testRenderEveryThemeInLightAndDark() throws {
        let output = ProcessInfo.processInfo.environment["SS_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // The tokens' own tables, whatever the Mac running this has chosen for its accent and contrast.
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, theme: .study))
        let environment = try AppEnvironment.makeScratch(in: folder, mode: .demo)
        self.environment = environment
        environment.start()
        let settings = ListTestSupport.settings()

        let controller = MainWindowController(environment: environment, settings: settings, remembersScope: false)
        defer {
            controller.tearDown()
            controller.close()
        }
        // Reader windows and this one stay where they are put, far off screen.
        controller.bringForward = { _ in }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 1_280, height: 800))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()

        let list = controller.list
        // The demo seeds its mailboxes in batches: choose once the Inbox has stopped growing, so no later refresh or the
        // welcome screen giving way to the window moves the selection away from the newsletter.
        var count = -1
        var steadySince = Date()
        XCTAssertTrue(ListTestSupport.spin(until: {
            if list.conversations.count != count {
                count = list.conversations.count
                steadySince = Date()
            }
            return count > 0 && Date().timeIntervalSince(steadySince) > 2
        }, timeout: 60), "the demo Inbox is in")
        let newsletter = list.conversations.first { summary in Self.newsletters.contains { summary.subject.hasPrefix($0 + " #") } }
        let id = try XCTUnwrap(newsletter?.id, "a demo newsletter is in the Inbox")
        list.selectedConversationID = id
        list.onSelectionChange?(id)
        let reader = controller.conversation
        XCTAssertTrue(ListTestSupport.spin(until: { reader.currentConversationID == id }, timeout: 5), "the reader shows the newsletter")
        try settle(reader, on: id)
        let message = try XCTUnwrap(reader.currentMessages.last?.id)
        let body = try XCTUnwrap(environment.store.body(for: message), "the newsletter's body is stored")
        XCTAssertEqual(body.typesetting, .styled)
        XCTAssertEqual(body.declaresColors, true, "the newsletter sets its own colours")

        let readerWindow = try XCTUnwrap(controller.openInNewWindow(id))
        let readerFrame = try XCTUnwrap(readerWindow.window)
        readerFrame.setContentSize(NSSize(width: 840, height: 900))
        readerFrame.setFrameOrigin(NSPoint(x: -21_000, y: -20_000))
        readerFrame.orderFrontRegardless()
        try settle(readerWindow.conversation, on: id)

        let settingsController = SettingsWindowController(environment: environment, settings: settings,
                                                          mailtoHandler: FakeMailtoHandler(), loginItem: FakeLoginItem())
        defer { settingsController.tearDown() }
        let settingsWindow = try XCTUnwrap(settingsController.window)
        settingsWindow.setFrameAutosaveName("")
        settingsWindow.setFrameOrigin(NSPoint(x: -22_000, y: -20_000))
        settingsController.show(tab: .appearance)

        var written: [String] = []
        for (name, look, mode) in [("light", NSAppearance.Name.aqua, QuireMode.light), ("dark", .darkAqua, .dark)] {
            for frame in [window, readerFrame, settingsWindow] { frame.appearance = NSAppearance(named: look) }
            for theme in QuireTheme.allCases {
                // Settings' tiles show the forced theme as the chosen one.
                settings.theme = theme
                QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, theme: theme))
                let label = "\(theme), \(name)"
                for shell in [reader, readerWindow.conversation] {
                    try settled(shell, in: theme, mode: mode, label)
                }
                let prefix = "theme-\(theme.rawValue)-\(name)"
                try write(window, reader: reader, to: output.appendingPathComponent(prefix + "-main.png"))
                try write(readerFrame, reader: readerWindow.conversation, to: output.appendingPathComponent(prefix + "-reader.png"))
                ListTestSupport.spin(for: 0.2)
                try write(settingsWindow, reader: nil, to: output.appendingPathComponent(prefix + "-settings.png"))
                written += [prefix + "-main.png", prefix + "-reader.png", prefix + "-settings.png"]

                if mode == .dark {
                    settings.adaptsMailColours = false
                    let slot = try XCTUnwrap(reader.pool.current)
                    XCTAssertTrue(ListTestSupport.spin(until: { slot.originalColorsShown.contains(message) }, timeout: 5),
                                  label + ": with Adapt off the newsletter opens as sent")
                    XCTAssertEqual(evaluate("(function () { var f = document.querySelector('.ss-card.ss-sheet iframe');"
                                            + " return !!f && f.contentDocument.documentElement.classList.contains('ss-original'); })()",
                                            in: slot.webView) as? Bool, true, label + ": the white page")
                    ListTestSupport.spin(for: 0.5)
                    try write(window, reader: reader, to: output.appendingPathComponent(prefix + "-original.png"))
                    written.append(prefix + "-original.png")
                    settings.adaptsMailColours = true
                    XCTAssertTrue(ListTestSupport.spin(until: { !slot.originalColorsShown.contains(message) }, timeout: 5), label)
                }
            }
        }
        XCTAssertEqual(written.count, 35, "20 windows, 10 Settings tabs and 5 dark originals")
        for file in written {
            let size = (try? FileManager.default.attributesOfItem(atPath: output.appendingPathComponent(file).path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(size, 10_000, "\(file) was written")
        }
        print("ThemeRenderTests wrote \(written.count) files to \(output.path)")
    }

    // MARK: Helpers

    /// The reader shows `id`, rendered, every body measured, and its fonts loaded.
    private func settle(_ reader: ConversationViewController, on id: ConversationID) throws {
        var landed: WKWebView??
        // The first render of a run waits for WebKit's content process and the fonts to start.
        reader.whenShownRenderLands(timeout: 30) { landed = .some($0) }
        XCTAssertTrue(ListTestSupport.spin(until: { landed != nil }, timeout: 30))
        let webView = try XCTUnwrap(landed ?? nil, "the reader rendered the newsletter")
        XCTAssertTrue(ListTestSupport.spin(until: {
            guard let slot = reader.pool.current, slot.isReady, slot.renderedID == id, !slot.renderInFlight else { return false }
            return self.evaluate("document.fonts.status === 'loaded' && window.ss.measureAll().every(function (h) { return h > 0; })",
                                 in: webView) as? Bool == true
        }, timeout: 15), "measured, with its fonts")
    }

    /// Every ready shell of `reader` and its open body draw `theme`'s `mode`, then wait a moment for glyphs and the sheet's
    /// fit to settle.
    private func settled(_ reader: ConversationViewController, in theme: QuireTheme, mode: QuireMode, _ label: String) throws {
        let webView = try XCTUnwrap(reader.pool.current?.webView)
        let tokens: [QuireColorToken] = [.paper, .ink, .accent]
        XCTAssertTrue(ListTestSupport.spin(until: {
            self.evaluate("document.documentElement.getAttribute('data-ss-theme')", in: webView) as? String == theme.rawValue
                && self.computed("--q-paper", in: webView, body: false) == self.hex(QuireColorToken.paper.values(theme: theme)[mode])
        }, timeout: 5), label + ": the shell restyled")
        for token in tokens {
            XCTAssertEqual(computed("--q-\(token.rawValue)", in: webView, body: false), hex(token.values(theme: theme)[mode]),
                           label + ": the shell's \(token)")
        }
        // A body document carries the keep-list: the ink, the accent and its sheet, not the list's paper.
        for token in [QuireColorToken.ink, .accent, .sheet] {
            XCTAssertEqual(computed("--q-\(token.rawValue)", in: webView, body: true), hex(token.values(theme: theme)[mode]),
                           label + ": the body's \(token)")
        }
        // The tokens alone would pass a shell that restyled but never heard of the appearance: in Dark with Adapt on, the
        // newsletter is adapted and says so, or the image is not the one §5.14 describes.
        if mode == .dark {
            let adapted = "(function () { var f = document.querySelector('.ss-card.ss-sheet iframe');"
                + " return !!f && f.contentDocument.documentElement.classList.contains('ss-adapt')"
                + " && !!document.querySelector('.ss-card.ss-sheet .ss-notice-toggle'); })()"
            XCTAssertTrue(ListTestSupport.spin(until: { self.evaluate(adapted, in: webView) as? Bool == true }, timeout: 5),
                          label + ": the newsletter is adapted, with its notice")
        }
        ListTestSupport.spin(for: 1)
    }

    private func evaluate(_ script: String, in webView: WKWebView) -> Any? {
        var value: Any??
        webView.evaluateJavaScript(script) { result, _ in value = .some(result) }
        ListTestSupport.spin(until: { value != nil }, timeout: 5)
        return value ?? nil
    }

    /// A custom property as the shell's root, or the open sheet's body document, resolves it.
    private func computed(_ property: String, in webView: WKWebView, body: Bool) -> String? {
        let root = body
            ? "(function () { var f = document.querySelector('.ss-card.ss-sheet iframe'); return f ? f.contentDocument.documentElement : null; })()"
            : "document.documentElement"
        let script = "(function () { var r = \(root); return r ? getComputedStyle(r).getPropertyValue('\(property)').trim() : ''; })()"
        return (evaluate(script, in: webView) as? String)?.uppercased()
    }

    private func hex(_ value: UInt32) -> String {
        String(format: "#%02X%02X%02X", Int(value >> 24 & 0xFF), Int(value >> 16 & 0xFF), Int(value >> 8 & 0xFF))
    }

    /// The window as the app's `--snapshot` draws it: `cacheDisplay` cannot draw WKWebView content, so the reader's own
    /// image goes over its frame, and what the reader draws above the web view goes back on top.
    private func write(_ window: NSWindow, reader: ConversationViewController?, to url: URL) throws {
        window.displayIfNeeded()
        let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
        let bitmap = try XCTUnwrap(SnapshotRenderer.render(view))
        if let reader {
            let webView = try XCTUnwrap(reader.pool.current?.webView)
            var image: NSImage?
            webView.takeSnapshot(with: nil) { snapshot, _ in image = snapshot ?? NSImage() }
            XCTAssertTrue(ListTestSupport.spin(until: { image != nil }, timeout: 10), "the web view's snapshot")
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            var frame = webView.convert(webView.bounds, to: view)
            if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image?.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            ReaderSnapshotOverlay.draw(over: webView, in: view)
            NSGraphicsContext.restoreGraphicsState()
        }
        XCTAssertTrue(SnapshotRenderer.writePNG(bitmap, to: url.path), url.lastPathComponent)
    }
}
