import AppKit
import SSCore
@testable import SSDesign
import SwiftUI
import XCTest
@testable import SuperSparrowApp

/// Settings › Appearance (spec §5.40, §4.16): the fourth tab, its five rows, General after Font and Text size left it,
/// the tiles to the keyboard and to VoiceOver, the Dark Mode default's dependence on Appearance, and the three values
/// stored and applied as launch applies them. Settings live in throwaway defaults suites; the theme, the app's
/// appearance and the environment's overrides are given back after every test, so nothing reads or writes the
/// developer's own choices.
@MainActor
final class AppearanceSettingsTests: XCTestCase {
    private var suites: [String] = []
    private var appearanceBefore: NSAppearance?
    private var overridesBefore = QuireEnvironment.Overrides()

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            appearanceBefore = NSApplication.shared.appearance
            overridesBefore = QuireEnvironment.shared.overrides
            // The Mac running the tests may have Graphite or Increase Contrast on; the colours asserted here are the tokens'.
            QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false))
            QuireEnvironment.shared.setTheme(.study)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            QuireEnvironment.shared.setTheme(.study)
            QuireEnvironment.shared.setTextSize(.default)
            QuireEnvironment.shared.setOverrides(overridesBefore)
            NSApplication.shared.appearance = appearanceBefore
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        }
        super.tearDown()
    }

    // MARK: The tab

    /// A fourth tab, appended so no tab a user knows moves, holding Theme, Appearance and Dark Mode, then Font and Text
    /// size; it never scrolls, stays far shorter than Accounts, and Settings stays at Default whatever the Text size.
    func testTheFourthTabHoldsFiveControlsAndNeverScrolls() throws {
        let settings = try throwawaySettings()
        let (controller, window, tab) = try settingsWindow(settings)
        defer { controller.tearDown() }
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["Accounts", "OAuth", "General", "Appearance"])
        XCTAssertNotNil(tabs.tabViewItems[3].image, "the tab's symbol draws")
        XCTAssertEqual(Quire.Icon.appearanceTab, "paintpalette", "circle.lefthalf.filled is Original colours'")
        XCTAssertEqual(tabs.selectedTabViewItemIndex, 3)

        let height = tab.fittingSize.height
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height, height, accuracy: 0.5, "the window shows the whole tab")
        XCTAssertLessThanOrEqual(height, 400, "about 380 pt, far below Accounts' 760: \(height)")

        let s = Quire.Layout.Settings.self
        let controls = focusables(in: tab)
        XCTAssertEqual(controls.count, 5, "Theme, Appearance, Dark Mode, Font and Text size")
        XCTAssertEqual(controls.first?.frame, NSRect(x: fieldX, y: s.padTop, width: s.fieldWidth, height: s.themeRow),
                       "the tiles fill the field column in their 76 pt row, first")

        var heights: Set<CGFloat> = []
        for size in QuireFont.TextSize.allCases {
            QuireEnvironment.shared.setTextSize(size)
            let (view, window) = hostTab(settings)
            heights.insert(view.fittingSize.height)
            close(window)
        }
        XCTAssertEqual(heights, [height], "Settings stays at Default")

        controller.model.tab = .general
        XCTAssertEqual(tabs.selectedTabViewItemIndex, 2)
        tabs.selectedTabViewItemIndex = 3
        XCTAssertEqual(controller.model.tab, .appearance, "choosing the tab in the toolbar is the model's choice")
    }

    /// General loses Font and Text size: nine controls with every optional one showing, under its cap of twelve, and it
    /// still never scrolls.
    func testGeneralHoldsNineControlsAndNeverScrolls() throws {
        let settings = try throwawaySettings()
        settings.accountWasAdded(totalAccounts: 7)
        let mail = DefaultMailAppModel(handler: FakeMailtoHandler())
        mail.showForSnapshot(.notDefault)
        let login = LaunchAtLoginModel(handler: FakeLoginItem())
        login.showForSnapshot(.off)
        let view = NSHostingView(rootView: QuireThemeRoot(GeneralSettingsView(settings: settings, defaultMailApp: mail,
                                                                              mailboxSize: MailboxSizeModel(measure: { 292_000_000 }),
                                                                              launchAtLogin: login)))
        let window = host(view)
        defer { close(window) }
        XCTAssertEqual(focusables(in: view).count, 9,
                       "List density, Rows, Undo send, Remote images, Notifications and its checkbox, Keep mail, At login, Mail links")
        XCTAssertLessThanOrEqual(view.fittingSize.height, 760, "General never scrolls: \(view.fittingSize.height) pt")
    }

    // MARK: VoiceOver

    /// The tiles are a radio group named Theme, one radio per theme in Settings' order, the chosen one selected; the
    /// caption is the group's help. Automatic says what it follows.
    func testTheTilesReadAsARadioGroupToVoiceOver() {
        for (i, theme) in QuireTheme.allCases.enumerated() {
            let radios = QuireThemePicker.radios(selection: theme)
            XCTAssertEqual(radios.map(\.name), ["Study", "Gallery", "Rain", "Grove", "Dusk"])
            XCTAssertEqual(radios.filter(\.isSelected).map(\.spoken), ["\(theme.name), \(i + 1) of 5, selected"])
        }
        XCTAssertEqual(QuireThemePicker.radios(selection: .study).first?.spoken, "Study, 1 of 5, selected")
        XCTAssertEqual(QuireThemePicker.radios(selection: .rain)[2].spoken, "Rain, 3 of 5, selected")
        XCTAssertEqual(AppAppearance.allCases.map(AppearanceSettingsView.spokenTitle(for:)), ["Automatic, follows macOS", "Light", "Dark"])
        XCTAssertEqual(AppAppearance.allCases.map(AppearanceSettingsView.title(for:)), ["Automatic", "Light", "Dark"])
    }

    // MARK: Keyboard

    /// Arrow keys move and apply the choice through all five tiles and back: every step re-themes the app and Settings in
    /// place, and keyboard focus never leaves the tiles, so the next arrow still moves the choice. The window's desk, the
    /// tab's on-fills and a primary button in another Settings root all take each theme's values.
    func testArrowKeysApplyEveryThemeWithFocusKeptOnTheTiles() throws {
        let settings = try throwawaySettings()
        let (controller, window, tab) = try settingsWindow(settings)
        defer { controller.tearDown() }
        let tiles = try XCTUnwrap(focusables(in: tab).first)
        XCTAssertTrue(window.makeFirstResponder(tiles))
        ListTestSupport.spin(for: 0.05)
        // Drawn as in a key window: a primary button in a window that is not key draws as a secondary one (§3.4).
        let button = NSHostingView(rootView: QuireThemeRoot(Button("Save") {}.buttonStyle(.quire(.primary)).padding(8)
            .environment(\.controlActiveState, .key)))
        let buttonWindow = host(button)
        defer { close(buttonWindow) }
        let radios = try XCTUnwrap(focusables(in: tab).dropFirst().first, "Appearance's radio group")

        let themes = QuireTheme.allCases
        let path = Array(themes.dropFirst()) + themes.dropLast().reversed()
        for (step, theme) in path.enumerated() {
            sendArrow(step < themes.count - 1 ? .right : .left, to: window)
            let label = "step \(step + 1), \(theme)"
            XCTAssertEqual(settings.theme, theme, label)
            XCTAssertEqual(QuireEnvironment.theme, theme, label + ": applied at once")
            XCTAssertTrue(window.firstResponder === tiles, label + ": focus stays on the tiles")

            let canvas = rgba(.canvas, theme)
            XCTAssertEqual(resolved(window.backgroundColor), canvas, label + ": the window's desk")
            let rep = render(tab)
            XCTAssertColor(pixel(rep, at: NSPoint(x: 4, y: tab.bounds.height - 4)), canvas, label + ": the tab's desk")
            // The chosen name's bar, in the new theme: the tiles redrew in place.
            let s = Quire.Layout.Settings.self
            let index = CGFloat(try XCTUnwrap(themes.firstIndex(of: theme)))
            let bar = NSPoint(x: fieldX + index * (s.themeTile[0] + s.themeTileGap) + s.themeTile[0] / 2,
                              y: s.padTop + s.themeTile[1] + s.themeNameGap + QuireFont.Role.label.lineHeight + s.themeUnderlineGap + s.themeUnderline / 2)
            XCTAssertColor(pixel(rep, at: bar), rgba(window.isKeyWindow ? .selRule : .selRuleIdle, theme), label + ": the chosen name's bar")
            // Automatic's radio, 2.5 pt inside its edge and clear of its dot, is drawn in the ink.
            XCTAssertColor(pixel(rep, at: NSPoint(x: radios.frame.minX + 2.5, y: radios.frame.midY)), rgba(.accentFill, theme),
                           label + ": the chosen radio")
            XCTAssertColor(pixel(render(button), at: NSPoint(x: 12, y: button.bounds.midY)), rgba(.accentFill, theme),
                           label + ": a primary button")
        }
        XCTAssertEqual(settings.theme, .study)
    }

    // MARK: Dark Mode

    /// Under Light the default would change nothing, so the checkbox is disabled, its caption kept; Automatic keeps it,
    /// since night will come.
    func testDarkModeIsDisabledWhileAppearanceIsLight() throws {
        let settings = try throwawaySettings()
        let (view, window) = hostTab(settings)
        defer { close(window) }
        let checkbox = try XCTUnwrap(focusables(in: view).dropFirst(2).first, "the Dark Mode checkbox")
        let box = NSPoint(x: checkbox.frame.minX + Quire.Layout.Checkbox.size / 2, y: checkbox.frame.midY)
        let height = view.fittingSize.height

        settings.appearance = .light
        fit(view)
        click(box, in: view)
        XCTAssertTrue(settings.adaptsMailColours, "disabled under Light")
        XCTAssertEqual(view.fittingSize.height, height, "the caption stays")
        let face = pixel(render(view), at: NSPoint(x: checkbox.frame.minX + 2, y: checkbox.frame.midY))
        XCTAssertNotEqual(face, rgba(.accentFill, .study), "drawn disabled")

        settings.appearance = .automatic
        fit(view)
        click(box, in: view)
        XCTAssertFalse(settings.adaptsMailColours, "enabled under Automatic")
        settings.appearance = .dark
        fit(view)
        click(box, in: view)
        XCTAssertTrue(settings.adaptsMailColours, "and under Dark")
    }

    // MARK: Persistence

    /// Chosen with the tab's own controls, the three values are saved, read back by the next launch's settings and
    /// applied as launch applies them: the theme into the environment before the first window, the appearance to the app.
    func testTheThreeValuesPersistAndApplyAtLaunch() throws {
        let defaults = try throwawayDefaults()
        let settings = AppSettings(defaults: defaults)
        let (view, window) = hostTab(settings)
        defer { close(window) }
        let s = Quire.Layout.Settings.self
        let grove = try XCTUnwrap(QuireTheme.allCases.firstIndex(of: .grove))
        click(NSPoint(x: fieldX + CGFloat(grove) * (s.themeTile[0] + s.themeTileGap) + s.themeTile[0] / 2, y: s.padTop + s.themeTile[1] / 2),
              in: view)
        XCTAssertEqual(settings.theme, .grove, "a click on a tile chooses it")
        XCTAssertEqual(QuireEnvironment.theme, .grove)

        let radios = try XCTUnwrap(focusables(in: view).dropFirst().first)
        XCTAssertTrue(window.makeFirstResponder(radios))
        ListTestSupport.spin(for: 0.05)
        sendArrow(.right, to: window)
        sendArrow(.right, to: window)
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua, "applied at once")

        let checkbox = try XCTUnwrap(focusables(in: view).dropFirst(2).first)
        click(NSPoint(x: checkbox.frame.minX + Quire.Layout.Checkbox.size / 2, y: checkbox.frame.midY), in: view)
        XCTAssertFalse(settings.adaptsMailColours)

        // The next launch: a fresh process starts in Study and follows macOS until the settings are applied.
        QuireEnvironment.shared.setTheme(.study)
        NSApplication.shared.appearance = nil
        let next = AppSettings(defaults: defaults)
        XCTAssertEqual(next.theme, .grove)
        XCTAssertEqual(next.appearance, .dark)
        XCTAssertFalse(next.adaptsMailColours)
        XCTAssertEqual(QuireEnvironment.theme, .study, "reading applies nothing")
        let options = LaunchOptions(arguments: ["SuperSparrow"])
        QuireEnvironment.shared.setTheme(options.theme ?? next.theme)
        next.applyAppearance()
        XCTAssertEqual(QuireEnvironment.theme, .grove)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
    }

    // MARK: Support

    private func throwawayDefaults() throws -> UserDefaults {
        let suite = "SuperSparrowAppTests.Appearance.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func throwawaySettings() throws -> AppSettings {
        AppSettings(defaults: try throwawayDefaults())
    }

    /// The field column's leading edge.
    private var fieldX: CGFloat {
        let s = Quire.Layout.Settings.self
        return s.padX + s.labelColumn + s.labelGap
    }

    /// The Settings window on Appearance, far off screen and in Light, over a throwaway store.
    private func settingsWindow(_ settings: AppSettings) throws -> (SettingsWindowController, NSWindow, NSView) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppearanceSettingsTests-\(UUID().uuidString)")
        let environment = try AppEnvironment.makeScratch(in: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let controller = SettingsWindowController(environment: environment, settings: settings, mailtoHandler: FakeMailtoHandler(),
                                                  loginItem: FakeLoginItem())
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        controller.show(tab: .appearance)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        let tab = try XCTUnwrap(tabs.tabViewItems[3].viewController?.view)
        XCTAssertTrue(ListTestSupport.spin(until: { !self.focusables(in: tab).isEmpty }, timeout: 3), "the tab is laid out")
        // The window opens with nothing focused, on the next turn of the run loop.
        ListTestSupport.spin(for: 0.1)
        return (controller, window, tab)
    }

    /// The Appearance tab as Settings hosts it, in Light, in an ordered window far off screen sized to its content.
    private func hostTab(_ settings: AppSettings) -> (view: NSView, window: NSWindow) {
        let view = NSHostingView(rootView: QuireThemeRoot(AppearanceSettingsView(settings: settings)))
        return (view, host(view))
    }

    private func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        fit(view)
        return window
    }

    /// Lets SwiftUI update, then sizes the window to the content, as Settings does on every change.
    private func fit(_ view: NSView) {
        ListTestSupport.spin(for: 0.05)
        view.window?.setContentSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        ListTestSupport.spin(for: 0.05)
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    /// The tab's keyboard controls, top to bottom: SwiftUI gives each focusable control a key-view proxy under its
    /// hosting view, framed as the control, and that is what the window's first responder is while one has focus.
    private func focusables(in view: NSView) -> [NSView] {
        view.subviews
            .filter { String(describing: type(of: $0)).hasSuffix("KeyViewProxy") }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private enum Arrow {
        case left, right

        var keyCode: UInt16 { self == .left ? 123 : 124 }
        var characters: String { String(UnicodeScalar(self == .left ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey)!) }
    }

    private func sendArrow(_ arrow: Arrow, to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: arrow.characters,
                                               charactersIgnoringModifiers: arrow.characters, isARepeat: false, keyCode: arrow.keyCode)
            else { return XCTFail("no event") }
            window.sendEvent(event)
        }
        ListTestSupport.spin(for: 0.1)
    }

    /// A click as the user makes one (SwiftUI's buttons answer real mouse events, not accessibility presses, here).
    private func click(_ point: NSPoint, in view: NSView) {
        guard let window = view.window else { return XCTFail("no window") }
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return XCTFail("no event") }
            window.sendEvent(event)
        }
        ListTestSupport.spin(for: 0.1)
    }

    // MARK: Colour

    private struct RGB: Equatable, CustomStringConvertible {
        var r: Int, g: Int, b: Int
        var description: String { String(format: "#%02X%02X%02X", r, g, b) }
    }

    /// `token` in `theme` under Light, as tokens.json writes it.
    private func rgba(_ token: QuireColorToken, _ theme: QuireTheme) -> RGB {
        let v = token.values(theme: theme)[.light]
        return RGB(r: Int(v >> 24 & 0xFF), g: Int(v >> 16 & 0xFF), b: Int(v >> 8 & 0xFF))
    }

    private func resolved(_ color: NSColor) -> RGB? {
        var out: NSColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) }
        guard let out else { return nil }
        return RGB(r: Int((out.redComponent * 255).rounded()), g: Int((out.greenComponent * 255).rounded()), b: Int((out.blueComponent * 255).rounded()))
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

    /// The pixel under `point`, in the view's flipped (top-left) points.
    private func pixel(_ rep: NSBitmapImageRep, at point: NSPoint) -> RGB {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var samples = [Int](repeating: 0, count: 4)
        rep.getPixel(&samples, atX: Int(point.x * scale), y: Int(point.y * scale))
        return RGB(r: samples[0], g: samples[1], b: samples[2])
    }

    private func XCTAssertColor(_ actual: RGB, _ expected: RGB, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let d = max(abs(actual.r - expected.r), abs(actual.g - expected.g), abs(actual.b - expected.b))
        XCTAssertLessThanOrEqual(d, 3, "\(actual) is not \(expected): \(message)", file: file, line: line)
    }
}
