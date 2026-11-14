import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The three Appearance settings (spec §4.16, §5.40) as stored and applied: Theme, Appearance and the Dark Mode default.
/// Every test works on throwaway defaults and gives the theme and the app's appearance back afterwards, so nothing
/// depends on, or writes to, the developer's saved choices; the draft store points at a temporary folder.
@MainActor
final class ThemePreferencesTests: XCTestCase {
    private var suites: [String] = []
    private var folder: URL!
    private var appearanceBefore: NSAppearance?

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowTheme-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            ComposeDraftStore.shared.useDirectory(folder)
            appearanceBefore = NSApplication.shared.appearance
            QuireEnvironment.shared.setTheme(.study)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
            QuireEnvironment.shared.setTheme(.study)
            NSApplication.shared.appearance = appearanceBefore
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func throwawayDefaults() throws -> UserDefaults {
        let suite = "SuperSparrowAppTests.Theme.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testAFreshInstallOpensInStudyAutomaticAndAdapted() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        XCTAssertEqual(settings.theme, .study)
        XCTAssertEqual(settings.appearance, .automatic)
        XCTAssertTrue(settings.adaptsMailColours)
        XCTAssertEqual(QuireEnvironment.theme, .study, "reading the settings applies nothing")
    }

    func testAValueThisVersionDoesNotKnowReadsAsTheDefault() throws {
        let defaults = try throwawayDefaults()
        defaults.set("sepia", forKey: "theme")
        defaults.set("dim", forKey: "appearance")
        defaults.set("maybe", forKey: "adaptsMailColours")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.theme, .study)
        XCTAssertEqual(settings.appearance, .automatic)
        XCTAssertTrue(settings.adaptsMailColours)
    }

    func testTheThreeValuesPersistAndApplyAtOnce() throws {
        let defaults = try throwawayDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.theme = .dusk
        XCTAssertEqual(QuireEnvironment.theme, .dusk, "a choice re-themes every window at once")
        settings.appearance = .dark
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
        settings.adaptsMailColours = false
        let again = AppSettings(defaults: defaults)
        XCTAssertEqual(again.theme, .dusk)
        XCTAssertEqual(again.appearance, .dark)
        XCTAssertFalse(again.adaptsMailColours)
        settings.appearance = .light
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua)
        settings.appearance = .automatic
        XCTAssertNil(NSApplication.shared.appearance, "Automatic follows macOS")
    }

    func testAppearanceNamesOnlyTheLightOrDarkHalf() {
        XCTAssertNil(AppAppearance.automatic.nsAppearance)
        XCTAssertEqual(AppAppearance.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppAppearance.dark.nsAppearance?.name, .darkAqua)
    }

    /// `--theme` forces a theme for one process; it is a launch option, not a setting, so nothing is saved.
    func testTheThemeLaunchOptionNamesATheme() {
        XCTAssertNil(LaunchOptions(arguments: ["SuperSparrow"]).theme)
        #if DEBUG
        XCTAssertEqual(LaunchOptions(arguments: ["SuperSparrow", "--theme=rain"]).theme, .rain)
        XCTAssertEqual(LaunchOptions(arguments: ["SuperSparrow", "--demo", "--theme=Grove"]).theme, .grove)
        XCTAssertNil(LaunchOptions(arguments: ["SuperSparrow", "--theme=sepia"]).theme)
        XCTAssertNil(LaunchOptions(arguments: ["SuperSparrow", "--theme="]).theme)
        #endif
        XCTAssertEqual(QuireEnvironment.theme, .study, "parsing applies nothing")
    }

    /// Launched with `--theme=rain`, the app draws Rain while Settings shows the saved Study chosen; choosing Study there
    /// applies it, as choosing the shown Font does under `--font`, rather than leaving the tiles and the app disagreeing.
    func testChoosingTheSavedThemeUnderALaunchOptionAppliesIt() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        XCTAssertEqual(settings.theme, .study)
        // What the app delegate does with `--theme=rain`: the environment, nothing saved.
        QuireEnvironment.shared.setTheme(LaunchOptions(arguments: ["SuperSparrow", "--theme=rain"]).theme ?? .rain)
        XCTAssertEqual(QuireEnvironment.theme, .rain)
        var announced = 0
        let token = NotificationCenter.default.addObserver(forName: QuireEnvironment.didChangeNotification, object: nil, queue: nil) { _ in
            announced += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        settings.theme = .study
        XCTAssertEqual(QuireEnvironment.theme, .study, "the chosen tile is what the app draws")
        XCTAssertEqual(announced, 1)
        settings.theme = .study
        XCTAssertEqual(announced, 1, "choosing it again changes nothing, so nothing is announced")
    }

    /// The composer sets its window's background once; a switch must still reach it (spec §4.16), and every view the
    /// composer paints in draw(_:) redraws in the new theme.
    func testAnOpenComposerFollowsASwitch() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = ComposeWindowController(client: harness.environment.engine, account: ListTestSupport.accountA,
                                               accounts: [ListTestSupport.accountA], mode: .new)
        defer { composer.closeWithoutSaving() }
        let window = try XCTUnwrap(composer.window)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let frameView = try XCTUnwrap(window.contentView?.superview)
        func paper(_ theme: QuireTheme) -> NSColor { NSColor(quireRGBA: QuireColorToken.paper.values(theme: theme).light) }
        func resolved(_ color: NSColor) -> NSColor? {
            var out: NSColor?
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) }
            return out
        }
        XCTAssertEqual(resolved(window.backgroundColor), paper(.study).usingColorSpace(.sRGB))
        QuireEnvironment.shared.setTheme(.rain)
        XCTAssertEqual(resolved(window.backgroundColor), paper(.rain).usingColorSpace(.sRGB), "the window background is Rain's paper")
        XCTAssertEqual(frameView.layer?.needsDisplay(), true, "the frame view redraws the background")
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.layer?.needsDisplay(), true, "the composer's content view redraws")
    }
}
