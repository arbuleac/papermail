import AppKit
import SSCore
import SSDesign
import WebKit
import XCTest
@testable import SuperSparrowApp

/// Settings › Appearance › Theme and Appearance as the whole app sees them (spec §4.16, §5.40): one choice restyles the
/// list, the open conversation, an open composer, a reader window and Settings in place, without a relaunch, moving no
/// row, selection or scroll offset; the colour under every page follows; the app's appearance follows Appearance and the
/// reader with it; and a reader window opened in a theme paints its first frame in it. Every window is far off screen
/// over a throwaway store, settings live in throwaway defaults, and the theme, the overrides and the app's appearance are
/// given back after every test.
@MainActor
final class ThemeSettingTests: XCTestCase {
    private var folder: URL!
    private var appearanceBefore: NSAppearance?
    private var overridesBefore = QuireEnvironment.Overrides()

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowThemeSetting-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            ComposeDraftStore.shared.useDirectory(folder)
            appearanceBefore = NSApplication.shared.appearance
            overridesBefore = QuireEnvironment.shared.overrides
            // The Mac running the tests may have Graphite or Increase Contrast on; the colours asserted are the tokens'.
            QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false))
            QuireEnvironment.shared.setTheme(.study)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
            QuireEnvironment.shared.setTheme(.study)
            QuireEnvironment.shared.setOverrides(overridesBefore)
            NSApplication.shared.appearance = appearanceBefore
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: The list

    /// Every theme in Light and Dark: the rows draw the theme's paper and the selected row its selection wash, while the
    /// rows keep their heights, the selection stays and the list does not scroll. Colour never changes a height, so a
    /// switch re-measures nothing, and no sender's face is drawn again: the faces' key is theme-free (spec §4.16, the
    /// theme budget in docs/ARCHITECTURE.md).
    func testASwitchRestylesTheListWithoutMovingARow() throws {
        let settings = ListTestSupport.settings()
        let (list, window) = ListTestSupport.host(store: try ListTestSupport.store(threads: 150), settings: settings)
        defer { window.close() }
        let clip = list.scrollView.contentView
        let top = try XCTUnwrap(list.layout.row(ofConversation: 60))
        clip.scroll(to: NSPoint(x: 0, y: list.tableView.rect(ofRow: top).minY + 17 - list.scrollView.contentInsets.top))
        list.scrollView.reflectScrolledClipView(clip)
        let selected = list.conversations[62].id
        list.selectedConversationID = selected
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let selectedRow = try XCTUnwrap(list.layout.row(ofConversation: 62))
        let plainRow = try XCTUnwrap(list.layout.row(ofConversation: 61))
        let heights = (0..<list.tableView.numberOfRows).map { list.tableView.rect(ofRow: $0).height }
        let offset = clip.bounds.origin

        for (name, look) in [("Light", NSAppearance.Name.aqua), ("Dark", .darkAqua)] {
            window.appearance = NSAppearance(named: look)
            // An appearance is a new key for the faces: let them render once in it before counting.
            window.displayIfNeeded()
            ListTestSupport.spin(for: 0.3)
            _ = render(list.tableView)
            ListTestSupport.spin(for: 0.3)
            let misses = ConversationCellView.faceMisses
            for theme in QuireTheme.allCases + [.study] {
                settings.theme = theme
                window.layoutIfNeeded()
                window.displayIfNeeded()
                let label = "\(theme) in \(name)"
                XCTAssertEqual(QuireEnvironment.theme, theme, label)
                XCTAssertEqual((0..<list.tableView.numberOfRows).map { list.tableView.rect(ofRow: $0).height }, heights,
                               label + ": no row changed height")
                XCTAssertEqual(list.selectedConversationID, selected, label + ": the selection stays")
                XCTAssertEqual(clip.bounds.origin, offset, label + ": the list did not scroll")

                let rep = render(list.tableView)
                let appearance = list.tableView.effectiveAppearance
                XCTAssertColor(dominant(rep, in: list.tableView.rect(ofRow: plainRow)), expected(.paper, theme, under: appearance),
                               label + ": a row on the theme's paper")
                let wash: QuireColorToken = window.isKeyWindow ? .selWash : .selWashIdle
                XCTAssertColor(dominant(rep, in: list.tableView.rect(ofRow: selectedRow)), expected(wash, theme, under: appearance),
                               label + ": the selected row on the theme's wash")
            }
            XCTAssertEqual(ConversationCellView.faceMisses, misses, "\(name): five switches drew no sender's face again")
        }
    }

    // MARK: Every window

    /// One choice in Settings reaches every window at once: the main window's reader shells and the colour under their
    /// pages, an open composer's paper and sheet, a reader window's shell, and Settings' own desk on a tab other than
    /// Appearance. Nothing is relaunched and no body frame is built again.
    func testASwitchRestylesEveryWindowWithoutARelaunch() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let main = try XCTUnwrap(harness.controller.window)
        main.appearance = NSAppearance(named: .aqua)
        harness.selectFirst(1)
        try settled(harness.reader)
        let conversation = try XCTUnwrap(harness.list.selectedConversationID)
        for slot in harness.reader.pool.slots {
            _ = evaluate("document.querySelectorAll('iframe').forEach(function (f) { f.ssMark = 1; })", in: slot.webView)
        }

        let composer = ComposeWindowController(client: harness.environment.engine, account: ListTestSupport.accountA,
                                               accounts: [ListTestSupport.accountA], mode: .new)
        defer { composer.closeWithoutSaving() }
        let composerWindow = try XCTUnwrap(composer.window)
        composerWindow.appearance = NSAppearance(named: .aqua)
        composerWindow.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        composerWindow.orderFrontRegardless()
        let composerView = try XCTUnwrap(composerWindow.contentView as? ComposeContentView)
        composerView.layoutSubtreeIfNeeded()

        let readerWindow = try XCTUnwrap(harness.controller.openInNewWindow(conversation))
        let readerWindowView = try XCTUnwrap(readerWindow.window)
        readerWindowView.appearance = NSAppearance(named: .aqua)
        try settled(readerWindow.conversation)

        let settingsController = SettingsWindowController(environment: harness.environment, settings: harness.settings,
                                                          mailtoHandler: FakeMailtoHandler(), loginItem: FakeLoginItem())
        defer { settingsController.tearDown() }
        let settingsWindow = try XCTUnwrap(settingsController.window)
        settingsWindow.setFrameAutosaveName("")
        settingsWindow.appearance = NSAppearance(named: .aqua)
        settingsWindow.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        settingsController.show(tab: .general)
        let tabs = try XCTUnwrap(settingsWindow.contentViewController as? NSTabViewController)
        let general = try XCTUnwrap(tabs.tabViewItems[2].viewController?.view)
        ListTestSupport.spin(for: 0.2)

        var themed: [QuireTheme] = []
        harness.reader.pool.onThemed = { themed.append($0) }
        defer { harness.reader.pool.onThemed = nil }
        var windowThemed: [QuireTheme] = []
        readerWindow.conversation.pool.onThemed = { windowThemed.append($0) }
        defer { readerWindow.conversation.pool.onThemed = nil }

        for theme in QuireTheme.allCases.dropFirst() + [.study] {
            harness.settings.theme = theme
            let label = "\(theme)"
            XCTAssertTrue(ListTestSupport.spin(until: { themed.last == theme && windowThemed.last == theme }, timeout: 5),
                          label + ": every ready shell of both readers restyled")
            for slot in harness.reader.pool.slots + readerWindow.conversation.pool.slots where slot.isReady {
                let webView = slot.webView
                XCTAssertEqual(evaluate("document.documentElement.getAttribute('data-ss-theme')", in: webView) as? String, theme.rawValue, label)
                XCTAssertEqual(computed("--q-paper", in: webView), hex(expected(.paper, theme, under: webView.effectiveAppearance)),
                               label + ": the shell's paper")
                XCTAssertEqual(hex(webView.underPageBackgroundColor), hex(expected(.canvas, theme, under: webView.effectiveAppearance)),
                               label + ": the colour under the page")
            }
            for slot in harness.reader.pool.slots where slot.isReady {
                let unmarked = evaluate("Array.prototype.filter.call(document.querySelectorAll('iframe'), function (f) { return !f.ssMark; }).length",
                                        in: slot.webView) as? NSNumber
                XCTAssertEqual(unmarked?.intValue, 0, label + ": no frame was built again")
            }

            // The composer's views paint in draw(_:), which the sweep reaches: its title band is paper, its body sheet.
            composerWindow.displayIfNeeded()
            let composerRep = render(composerView)
            let band = NSPoint(x: composerView.bounds.width - 24, y: composerView.titlebarHeight / 2)
            XCTAssertColor(pixel(composerRep, at: band), expected(.paper, theme, under: composerView.effectiveAppearance),
                           label + ": the composer's paper")
            let body = NSPoint(x: composerView.bounds.width - 24, y: composerView.bodyRect.midY)
            XCTAssertColor(pixel(composerRep, at: body), expected(.sheet, theme, under: composerView.effectiveAppearance),
                           label + ": the composer's sheet")

            // Settings, on General: the window's desk is assigned again and the tab redraws in place.
            ListTestSupport.spin(for: 0.05)
            XCTAssertColor(rgb(settingsWindow.backgroundColor, under: settingsWindow.effectiveAppearance),
                           expected(.canvas, theme, under: settingsWindow.effectiveAppearance), label + ": the Settings window's desk")
            XCTAssertColor(pixel(render(general), at: NSPoint(x: 4, y: 4)), expected(.canvas, theme, under: general.effectiveAppearance),
                           label + ": the General tab's desk")
        }
        XCTAssertEqual(themed, QuireTheme.allCases.dropFirst() + [.study], "one restyle per choice, in order")
        XCTAssertEqual(harness.list.selectedConversationID, conversation, "the selection outlived five switches")
        XCTAssertTrue(harness.controller.readerWindows.contains { $0 === readerWindow }, "the reader window stayed open")
    }

    /// A reader window opened while Rain is chosen loads a shell already in Rain, with Rain's desk under the page before
    /// the shell has loaded at all: its first frame is never Study's.
    func testANewReaderWindowOpenedInRainPaintsItsFirstFrameInRain() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.settings.theme = .rain
        let id = harness.list.conversations[0].id
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        let reader = try XCTUnwrap(harness.controller.openInNewWindow(id))
        let window = try XCTUnwrap(reader.window)
        window.appearance = NSAppearance(named: .aqua)
        let pool = reader.conversation.pool
        XCTAssertTrue(pool.document.contains("<html data-ss-theme=\"rain\">"), "the document is built in Rain")
        XCTAssertTrue(pool.document.contains("<style id=\"ss-theme\">" + QuireCSS.themeSheet("rain") + "</style>"))
        for slot in pool.slots {
            XCTAssertEqual(hex(slot.webView.underPageBackgroundColor), hex(expected(.canvas, .rain, under: slot.webView.effectiveAppearance)),
                           "Rain's desk shows while the shell loads")
        }
        let slot = try XCTUnwrap(pool.current)
        XCTAssertTrue(ListTestSupport.spin(until: { slot.isReady }, timeout: 10), "the shell loaded")
        XCTAssertEqual(evaluate("document.documentElement.getAttribute('data-ss-theme')", in: slot.webView) as? String, "rain")
        XCTAssertEqual(computed("--q-canvas", in: slot.webView), hex(expected(.canvas, .rain, under: slot.webView.effectiveAppearance)),
                       "the shell's first style is Rain's")
        try settled(reader.conversation)
        XCTAssertEqual(computed("--q-sheet", in: slot.webView), hex(expected(.sheet, .rain, under: slot.webView.effectiveAppearance)))
    }

    // MARK: Appearance

    /// Appearance picks the half of the theme the app shows: Dark sets the app's appearance to Dark Aqua, which every
    /// window without its own appearance takes, the reader's shells through `prefers-color-scheme` and the colour under
    /// their pages included; Light sets Aqua; Automatic gives the choice back to macOS.
    func testAppearanceSetsTheAppsAppearanceAndTheReaderFollows() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        window.appearance = nil
        harness.settings.theme = .dusk
        harness.selectFirst(1)
        try settled(harness.reader)
        let webView = try XCTUnwrap(harness.reader.pool.current?.webView)

        for (appearance, name, dark) in [(AppAppearance.dark, NSAppearance.Name.darkAqua, true), (.light, .aqua, false), (.dark, .darkAqua, true)] {
            harness.settings.appearance = appearance
            let label = "\(appearance)"
            XCTAssertEqual(NSApplication.shared.appearance?.name, name, label)
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name, label + ": the main window follows")
            XCTAssertTrue(ListTestSupport.spin(until: {
                self.evaluate("matchMedia('(prefers-color-scheme: dark)').matches", in: webView) as? Bool == dark
            }, timeout: 5), label + ": the reader's shell follows")
            let mode: QuireMode = dark ? .dark : .light
            XCTAssertEqual(computed("--q-sheet", in: webView), hex(QuireColorToken.sheet.values(theme: .dusk)[mode]),
                           label + ": Dusk's \(mode) sheet")
            XCTAssertTrue(ListTestSupport.spin(until: {
                self.hex(webView.underPageBackgroundColor) == self.hex(QuireColorToken.canvas.values(theme: .dusk)[mode])
            }, timeout: 5), label + ": the colour under the page")
        }
        harness.settings.appearance = .automatic
        XCTAssertNil(NSApplication.shared.appearance, "Automatic follows macOS")
    }

    // MARK: Helpers

    private func settled(_ reader: ConversationViewController) throws {
        var landed: WKWebView??
        reader.whenShownRenderLands(timeout: 10) { landed = .some($0) }
        ListTestSupport.spin(until: { landed != nil }, timeout: 10)
        XCTAssertNotNil(landed ?? nil, "the reader rendered the conversation")
        ListTestSupport.spin(until: { reader.pool.slots.allSatisfy { $0.isReady && !$0.renderInFlight } }, timeout: 10)
    }

    private func evaluate(_ script: String, in webView: WKWebView) -> Any? {
        var value: Any??
        webView.evaluateJavaScript(script) { result, _ in value = .some(result) }
        ListTestSupport.spin(until: { value != nil }, timeout: 5)
        return value ?? nil
    }

    /// A custom property as the shell's root resolves it, upper-cased like the tokens.
    private func computed(_ property: String, in webView: WKWebView) -> String? {
        (evaluate("getComputedStyle(document.documentElement).getPropertyValue('\(property)').trim()", in: webView) as? String)?.uppercased()
    }

    private struct RGB: Equatable, CustomStringConvertible {
        var r: Int, g: Int, b: Int
        var description: String { String(format: "#%02X%02X%02X", r, g, b) }
    }

    private func hex(_ rgb: RGB) -> String { rgb.description }

    private func hex(_ colour: NSColor?) -> String {
        guard let colour else { return "none" }
        return rgb(colour, under: nil).description
    }

    private func hex(_ value: UInt32) -> String {
        String(format: "#%02X%02X%02X", Int(value >> 24 & 0xFF), Int(value >> 16 & 0xFF), Int(value >> 8 & 0xFF))
    }

    private func rgb(_ colour: NSColor, under appearance: NSAppearance?) -> RGB {
        var out: NSColor?
        if let appearance {
            appearance.performAsCurrentDrawingAppearance { out = colour.usingColorSpace(.sRGB) }
        } else {
            out = colour.usingColorSpace(.sRGB)
        }
        guard let out else { return RGB(r: -1, g: -1, b: -1) }
        return RGB(r: Int((out.redComponent * 255).rounded()), g: Int((out.greenComponent * 255).rounded()),
                   b: Int((out.blueComponent * 255).rounded()))
    }

    /// `token` of `theme` as `appearance` draws it.
    private func expected(_ token: QuireColorToken, _ theme: QuireTheme, under appearance: NSAppearance) -> RGB {
        rgb(NSColor.quire(token, theme: theme), under: appearance)
    }

    /// The view drawn at 2×, tagged sRGB, the space the tokens are tuned in, so samples are the tokens' own values.
    private func render(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0,
                                   bitsPerPixel: 0)!.retagging(with: .sRGB)!
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// The pixel under `point`, in the view's top-left points.
    private func pixel(_ rep: NSBitmapImageRep, at point: NSPoint) -> RGB {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var samples = [Int](repeating: 0, count: 4)
        rep.getPixel(&samples, atX: Int(point.x * scale), y: Int(point.y * scale))
        return RGB(r: samples[0], g: samples[1], b: samples[2])
    }

    /// The colour most of `rect` is drawn in: a row's ground, whatever its text, avatar and marks.
    private func dominant(_ rep: NSBitmapImageRep, in rect: NSRect) -> RGB {
        var counts: [Int: Int] = [:]
        var samples = [Int](repeating: 0, count: 4)
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        for y in stride(from: Int(rect.minY * scale) + 1, to: Int(rect.maxY * scale) - 1, by: 2) {
            for x in stride(from: Int(rect.minX * scale) + 1, to: Int(rect.maxX * scale) - 1, by: 2) {
                rep.getPixel(&samples, atX: x, y: y)
                counts[samples[0] << 16 | samples[1] << 8 | samples[2], default: 0] += 1
            }
        }
        let key = counts.max { $0.value < $1.value }?.key ?? 0
        return RGB(r: key >> 16 & 0xFF, g: key >> 8 & 0xFF, b: key & 0xFF)
    }

    private func XCTAssertColor(_ actual: RGB, _ expected: RGB, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let d = max(abs(actual.r - expected.r), abs(actual.g - expected.g), abs(actual.b - expected.b))
        XCTAssertLessThanOrEqual(d, 3, "\(actual) is not \(expected): \(message)", file: file, line: line)
    }
}
