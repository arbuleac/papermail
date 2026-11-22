import AppKit
import SSCore
@testable import SSDesign
import SwiftUI
import XCTest
@testable import SuperSparrowApp

/// Settings › Experimental (spec §5.58): the sixth tab, after AI, its lead caption and two toggles within the height cap, the
/// toggles driving the settings; the three settings' defaults, the gate turning reader mode on and off with it, one
/// announcement per change, persistence under their keys, and the snapshots' in-memory hold that never saves. Settings
/// live in throwaway defaults suites, so nothing reads or writes the developer's own choices.
@MainActor
final class ExperimentalSettingsTests: XCTestCase {
    /// The tab's height cap: far under Accounts' 760 pt, so it never scrolls.
    static let heightCap: CGFloat = 320

    private var suites: [String] = []
    private var observers: [NSObjectProtocol] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            suites = []
        }
        super.tearDown()
    }

    // MARK: The tab

    /// A sixth tab, appended after AI so no tab a user knows moves, with its symbol; the window shows the whole tab, which
    /// never scrolls, and the toolbar's choice is the model's.
    func testTheSixthTabIsExperimentalAfterAI() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExperimentalSettingsTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let environment = try AppEnvironment.makeScratch(in: directory)
        let controller = SettingsWindowController(environment: environment, settings: settings, mailtoHandler: FakeMailtoHandler(),
                                                  loginItem: FakeLoginItem())
        defer { controller.tearDown() }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        controller.show(tab: .experimental)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["Accounts", "OAuth", "General", "Appearance", "AI", "Experimental"])
        XCTAssertEqual(tabs.selectedTabViewItemIndex, 5)
        XCTAssertNotNil(tabs.tabViewItems[5].image, "the tab's symbol draws")
        XCTAssertEqual(Quire.Icon.experimentalTab, "flask")
        XCTAssertTrue(controller.settings === settings, "the window hands the snapshots the settings its tabs show")

        let tab = try XCTUnwrap(tabs.tabViewItems[5].viewController?.view)
        XCTAssertTrue(ListTestSupport.spin(until: { self.focusables(in: tab).count == 2 }, timeout: 3), "the tab is laid out")
        let height = tab.fittingSize.height
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height, height, accuracy: 0.5, "the window shows the whole tab")
        XCTAssertLessThanOrEqual(height, Self.heightCap, "never scrolls: \(height) pt")

        tabs.selectedTabViewItemIndex = 4
        XCTAssertEqual(controller.model.tab, .ai)
        tabs.selectedTabViewItemIndex = 5
        XCTAssertEqual(controller.model.tab, .experimental, "choosing the tab in the toolbar is the model's choice")
        controller.model.tab = .general
        XCTAssertEqual(tabs.selectedTabViewItemIndex, 2)
    }

    /// The lead caption, then two toggles in the field column, one per experiment, and nothing else to press; captions wrap
    /// rather than widen the window.
    func testTheTabHoldsTheLeadCaptionAndTwoToggles() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let (view, window) = hostTab(settings)
        defer { close(window) }
        let s = Quire.Layout.Settings.self
        let toggles = focusables(in: view)
        XCTAssertEqual(toggles.count, 2, "Offer reader mode and Block trackers")
        for toggle in toggles {
            XCTAssertEqual(toggle.frame.minX, fieldX, accuracy: 0.5, "in the field column")
        }
        let lead = QuireFont.Role.meta.lineHeight
        XCTAssertGreaterThanOrEqual(toggles[0].frame.minY, s.padTop + lead + s.captionGap, "under the lead caption")
        XCTAssertEqual(view.fittingSize.width, s.width, accuracy: 0.5, "captions wrap rather than widen")
        XCTAssertLessThanOrEqual(view.fittingSize.height, Self.heightCap)

        XCTAssertEqual(ExperimentalSettingsView.leadCaption, "Features still taking shape. They may change or go away.")
        XCTAssertEqual(ExperimentalSettingsView.readerModeTitle, "Offer reader mode")
        XCTAssertEqual(ExperimentalSettingsView.trackersTitle, "Block trackers")
        XCTAssertTrue(ExperimentalSettingsView.readerModeCaption.hasSuffix("\u{21E7}\u{2318}R."), "names reader mode's key")
        for words in [ExperimentalSettingsView.leadCaption, ExperimentalSettingsView.readerModeCaption, ExperimentalSettingsView.trackersCaption] {
            XCTAssertFalse(words.contains("\u{2014}") || words.contains("\u{2013}"), "no long dashes in UI words: \(words)")
        }
    }

    /// A click on each toggle turns its experiment on, and another turns it off; Offer reader mode takes reader mode with it.
    func testTheTogglesTurnTheExperimentsOnAndOff() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let (view, window) = hostTab(settings)
        defer { close(window) }
        let toggles = focusables(in: view)
        XCTAssertEqual(toggles.count, 2)
        let track = { (toggle: NSView) in NSPoint(x: toggle.frame.minX + Quire.Layout.Toggle.width / 2, y: toggle.frame.midY) }

        click(track(toggles[0]), in: view)
        XCTAssertTrue(settings.offersReaderMode)
        XCTAssertTrue(settings.readerModeOn, "the user sees what they enabled")
        XCTAssertFalse(settings.blocksTrackers, "each toggle is its own")
        click(track(toggles[1]), in: view)
        XCTAssertTrue(settings.blocksTrackers)

        click(track(toggles[0]), in: view)
        XCTAssertFalse(settings.offersReaderMode)
        XCTAssertFalse(settings.readerModeOn)
        click(track(toggles[1]), in: view)
        XCTAssertFalse(settings.blocksTrackers)
    }

    // MARK: The settings

    func testEveryExperimentIsOffByDefault() throws {
        let defaults = try throwawayDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.offersReaderMode)
        XCTAssertFalse(settings.readerModeOn)
        XCTAssertFalse(settings.blocksTrackers)
        XCTAssertFalse(AppSettings.blocksTrackersNow(defaults))
        XCTAssertFalse(settings.keepsExperimentsInMemory)
    }

    /// The gate turns reader mode on as it turns on and off as it turns off; between, reader mode is the reader's to flip and
    /// the gate stays. Reader mode never turns on while the gate is off.
    func testTheGateTurnsReaderModeOnAndOff() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        settings.readerModeOn = true
        XCTAssertFalse(settings.readerModeOn, "never on while the experiment is off")

        settings.offersReaderMode = true
        XCTAssertTrue(settings.readerModeOn, "on with its gate")
        settings.readerModeOn = false
        XCTAssertTrue(settings.offersReaderMode, "the reader's switch leaves the gate alone")
        XCTAssertFalse(settings.readerModeOn)
        settings.readerModeOn = true
        XCTAssertTrue(settings.readerModeOn)

        settings.offersReaderMode = false
        XCTAssertFalse(settings.readerModeOn, "off with its gate")
        settings.offersReaderMode = true
        XCTAssertTrue(settings.readerModeOn, "on again with its gate, whatever the reader last chose")
    }

    /// Each change posts its notification once, a gate change that moves reader mode included; a value set again posts
    /// nothing, and neither notification stands for the other.
    func testEachChangeIsAnnouncedOnce() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        var readerMode = 0
        var trackers = 0
        observe(AppSettings.readerModeChanged, from: settings) { readerMode += 1 }
        observe(AppSettings.trackerBlockingChanged, from: settings) { trackers += 1 }

        settings.offersReaderMode = true
        XCTAssertEqual(readerMode, 1, "the gate and the reader mode it turned on: one change")
        settings.offersReaderMode = true
        XCTAssertEqual(readerMode, 1, "a value set again is no change")
        settings.readerModeOn = false
        XCTAssertEqual(readerMode, 2)
        settings.offersReaderMode = false
        XCTAssertEqual(readerMode, 3, "the gate off with reader mode already off")
        settings.readerModeOn = true
        XCTAssertEqual(readerMode, 3, "refused while the gate is off, so nothing changed")
        XCTAssertEqual(trackers, 0)

        settings.blocksTrackers = true
        settings.blocksTrackers = true
        XCTAssertEqual(trackers, 1)
        settings.blocksTrackers = false
        XCTAssertEqual(trackers, 2)
        XCTAssertEqual(readerMode, 3, "tracker blocking is not reader mode's")
    }

    /// Each value is saved under its key and read back by the next launch; reader mode saved on under a gate that is off
    /// reads as off.
    func testTheExperimentsPersistUnderTheirKeys() throws {
        let defaults = try throwawayDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.offersReaderMode = true
        settings.blocksTrackers = true
        let saved = saved(in: defaults)
        XCTAssertEqual(saved["experimental.readerMode"] as? Bool, true)
        XCTAssertEqual(saved["readerMode.on"] as? Bool, true)
        XCTAssertEqual(saved["experimental.blockTrackers"] as? Bool, true)
        XCTAssertTrue(AppSettings.blocksTrackersNow(defaults), "code off the main actor reads what is saved")

        let again = AppSettings(defaults: defaults)
        XCTAssertTrue(again.offersReaderMode)
        XCTAssertTrue(again.readerModeOn)
        XCTAssertTrue(again.blocksTrackers)

        again.readerModeOn = false
        XCTAssertFalse(AppSettings(defaults: defaults).readerModeOn, "the reader's choice is kept")
        XCTAssertTrue(AppSettings(defaults: defaults).offersReaderMode)

        defaults.set(false, forKey: "experimental.readerMode")
        defaults.set(true, forKey: "readerMode.on")
        XCTAssertFalse(AppSettings(defaults: defaults).readerModeOn, "never on while the experiment is off, whatever was saved")
        defaults.set(false, forKey: "experimental.blockTrackers")
        XCTAssertFalse(AppSettings.blocksTrackersNow(defaults))
    }

    /// Held in memory for a snapshot's run, the experiments change and are announced as ever, but nothing is saved.
    func testHeldInMemoryTheExperimentsAreAnnouncedButNeverSaved() throws {
        let defaults = try throwawayDefaults()
        let settings = AppSettings(defaults: defaults)
        var readerMode = 0
        var trackers = 0
        observe(AppSettings.readerModeChanged, from: settings) { readerMode += 1 }
        observe(AppSettings.trackerBlockingChanged, from: settings) { trackers += 1 }

        settings.keepsExperimentsInMemory = true
        settings.offersReaderMode = true
        settings.blocksTrackers = true
        XCTAssertTrue(settings.readerModeOn)
        XCTAssertEqual(readerMode, 1)
        XCTAssertEqual(trackers, 1)
        for key in ["experimental.readerMode", "readerMode.on", "experimental.blockTrackers"] {
            XCTAssertNil(saved(in: defaults)[key], "\(key) is never saved")
        }
        let next = AppSettings(defaults: defaults)
        XCTAssertFalse(next.offersReaderMode)
        XCTAssertFalse(next.readerModeOn)
        XCTAssertFalse(next.blocksTrackers)
        XCTAssertFalse(AppSettings.blocksTrackersNow(defaults), "it reads what is saved")
    }

    // MARK: Support

    private func throwawayDefaults() throws -> UserDefaults {
        let suite = "SuperSparrowAppTests.Experimental.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        suiteNames[ObjectIdentifier(defaults)] = suite
        return defaults
    }

    private var suiteNames: [ObjectIdentifier: String] = [:]

    /// What `defaults` has saved: its suite's own values, without the defaults `AppSettings` registers.
    private func saved(in defaults: UserDefaults) -> [String: Any] {
        suiteNames[ObjectIdentifier(defaults)].flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
    }

    private func observe(_ name: Notification.Name, from settings: AppSettings, _ count: @escaping @MainActor () -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: settings, queue: nil) { _ in
            MainActor.assumeIsolated { count() }
        })
    }

    /// The field column's leading edge.
    private var fieldX: CGFloat {
        let s = Quire.Layout.Settings.self
        return s.padX + s.labelColumn + s.labelGap
    }

    /// The tab as Settings hosts it, in Light, in an ordered window far off screen sized to its content.
    private func hostTab(_ settings: AppSettings) -> (view: NSView, window: NSWindow) {
        let view = NSHostingView(rootView: QuireThemeRoot(ExperimentalSettingsView(settings: settings)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        fit(view)
        return (view, window)
    }

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

    /// The tab's keyboard controls, top to bottom: SwiftUI gives each focusable control a key-view proxy under its hosting
    /// view, framed as the control.
    private func focusables(in view: NSView) -> [NSView] {
        view.subviews
            .filter { String(describing: type(of: $0)).hasSuffix("KeyViewProxy") }
            .sorted { $0.frame.minY < $1.frame.minY }
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
}
