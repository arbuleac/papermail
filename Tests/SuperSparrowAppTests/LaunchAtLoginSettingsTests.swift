import AppKit
import SSCore
import SSDesign
import SwiftUI
import XCTest
@testable import SuperSparrowApp

/// Settings › General › At login (spec §5.40, roadmap Q2.7): a toggle that shows where macOS says SuperSparrow stands as
/// a login item, asks macOS once per press and then shows its answer; a line with Open Login Items while macOS waits for
/// the user's approval; a disabled toggle with a caption where macOS cannot open this copy at login; a failure in the
/// row's own words, never an alert. Every test goes through `FakeLoginItem`, so none reads or changes the Mac's real
/// login items.
@MainActor
final class LaunchAtLoginSettingsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            suites = []
        }
        super.tearDown()
    }

    private func spin(until condition: () -> Bool) {
        XCTAssertTrue(ListTestSupport.spin(until: condition, timeout: 3), "timed out")
    }

    private func answered(_ status: LoginItemStatus) -> (model: LaunchAtLoginModel, item: FakeLoginItem) {
        let item = FakeLoginItem(status)
        let model = LaunchAtLoginModel(handler: item)
        model.refresh()
        spin { model.state != .unknown }
        return (model, item)
    }

    // MARK: The model

    func testItAsksMacOSWhereSuperSparrowStands() {
        let model = LaunchAtLoginModel(handler: FakeLoginItem(.enabled))
        XCTAssertEqual(model.state, .unknown)
        XCTAssertEqual(model.row, .init(), "no toggle before the answer, rather than one that may flip")

        XCTAssertEqual(answered(.enabled).model.state, .on)
        XCTAssertEqual(answered(.notRegistered).model.state, .off)
        XCTAssertEqual(answered(.requiresApproval).model.state, .needsApproval)
        XCTAssertEqual(answered(.notFound).model.state, .unavailable)
    }

    func testTurningItOnAsksMacOSOnceThenShowsTheAnswer() {
        let (model, item) = answered(.notRegistered)
        item.holdsChange = true

        model.setOn(true)
        spin { item.registerCalls == 1 }
        XCTAssertEqual(model.row.isOn, true, "the toggle moves as pressed")
        XCTAssertEqual(model.state, .off, "macOS has not answered yet")
        model.setOn(false)
        model.setOn(true)
        model.refresh()
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(item.changeCalls, 1, "presses while macOS answers do nothing")
        XCTAssertEqual(model.row.isOn, true, "and a refresh does not answer over the change")

        item.release()
        spin { model.pending == nil }
        XCTAssertEqual(model.state, .on)
        XCTAssertEqual(model.row, .init(isOn: true))
        XCTAssertEqual(item.registerCalls, 1)
        XCTAssertEqual(item.unregisterCalls, 0)
    }

    func testTurningItOffUnregisters() {
        let (model, item) = answered(.enabled)
        model.setOn(true)
        ListTestSupport.spin(for: 0.05)
        XCTAssertEqual(item.changeCalls, 0, "already on: nothing to ask")

        model.setOn(false)
        spin { model.pending == nil && item.unregisterCalls == 1 }
        XCTAssertEqual(model.state, .off)
        XCTAssertEqual(model.row, .init(isOn: false))
        XCTAssertEqual(item.registerCalls, 0)
    }

    /// macOS may hold the item for the user's approval: the toggle stays on, as the user asked, with the line and its
    /// button under it; no failure, since nothing failed. Turning it off withdraws the request.
    func testAnItemWaitingForApprovalIsOnWithTheLine() {
        let (model, item) = answered(.notRegistered)
        item.registerLeaves = .requiresApproval
        model.setOn(true)
        spin { model.pending == nil && item.registerCalls == 1 }
        XCTAssertEqual(model.state, .needsApproval)
        XCTAssertEqual(model.row, .init(isOn: true, needsApproval: true))

        model.openLoginItems()
        XCTAssertEqual(item.openSettingsCalls, 1, "Open Login Items opens System Settings")
        XCTAssertEqual(item.changeCalls, 1, "and changes nothing itself")

        // Approved in System Settings, then back to the app.
        item.answers = .enabled
        model.refresh()
        spin { model.state == .on }
        XCTAssertFalse(model.row.needsApproval)

        // Turned off in System Settings since: macOS reports it as waiting for approval again.
        item.answers = .requiresApproval
        model.refresh()
        spin { model.state == .needsApproval }
        model.setOn(false)
        spin { model.pending == nil && item.unregisterCalls == 1 }
        XCTAssertEqual(model.state, .off)
        XCTAssertEqual(model.row, .init(isOn: false), "the line goes with the request")
    }

    func testMacOSsAnswerWinsOverAnError() {
        let (model, item) = answered(.notRegistered)
        item.failure = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        item.answers = .enabled
        model.setOn(true)
        spin { model.pending == nil && item.registerCalls == 1 }
        XCTAssertEqual(model.state, .on)
        XCTAssertNil(model.row.failure, "macOS has it on: nothing failed for the user")
    }

    func testAFailureStaysInWordsUntilMacOSStandsWhereAsked() {
        let (model, item) = answered(.notRegistered)
        item.failure = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        model.setOn(true)
        spin { model.pending == nil && item.registerCalls == 1 }
        XCTAssertEqual(model.state, .off)
        XCTAssertEqual(model.row, .init(isOn: false, failure: LaunchAtLoginModel.turnOnFailureWords), "the toggle goes back where macOS says")

        model.refresh()
        spin { item.statusCalls >= 3 }
        ListTestSupport.spin(for: 0.05)
        XCTAssertEqual(model.row.failure, LaunchAtLoginModel.turnOnFailureWords, "asking again does not hide a failure still true")

        // A retry keeps the words while macOS answers, and after a retry that fails too.
        item.holdsChange = true
        model.setOn(true)
        spin { item.registerCalls == 2 }
        XCTAssertEqual(model.row, .init(isOn: true, failure: LaunchAtLoginModel.turnOnFailureWords))
        item.release()
        spin { model.pending == nil }
        XCTAssertEqual(model.row.failure, LaunchAtLoginModel.turnOnFailureWords)

        item.holdsChange = false
        item.failure = nil
        model.setOn(true)
        spin { model.pending == nil && item.registerCalls == 3 }
        XCTAssertEqual(model.state, .on)
        XCTAssertNil(model.row.failure)
    }

    /// The user added SuperSparrow in System Settings after a failure: the words go as the app comes back.
    func testAFailureGoesOnceTheUserFixedItInSystemSettings() {
        let (model, item) = answered(.enabled)
        item.failure = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        model.setOn(false)
        spin { model.pending == nil && item.unregisterCalls == 1 }
        XCTAssertEqual(model.row, .init(isOn: true, failure: LaunchAtLoginModel.turnOffFailureWords))

        item.answers = .notRegistered
        model.refresh()
        spin { model.state == .off }
        XCTAssertNil(model.row.failure)
    }

    /// One line under the toggle at a time: a turn-off that fails while macOS waits for approval shows its words, which
    /// name Login Items, in place of the approval line, which comes back once the words go.
    func testAFailureTakesTheApprovalLinesPlace() {
        let (model, item) = answered(.requiresApproval)
        XCTAssertEqual(model.row, .init(isOn: true, needsApproval: true))
        item.failure = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        model.setOn(false)
        spin { model.pending == nil && item.unregisterCalls == 1 }
        XCTAssertEqual(model.state, .needsApproval)
        XCTAssertEqual(model.row, .init(isOn: true, failure: LaunchAtLoginModel.turnOffFailureWords))

        item.failure = nil
        model.setOn(true)
        ListTestSupport.spin(for: 0.05)
        XCTAssertEqual(item.registerCalls, 0, "still on as far as the user asked: nothing to ask")
        model.setOn(false)
        spin { model.pending == nil && item.unregisterCalls == 2 }
        XCTAssertEqual(model.row, .init(isOn: false))
    }

    func testUnavailableDisablesTheToggleWithACaption() {
        let (model, item) = answered(.notFound)
        XCTAssertEqual(model.row, .init(isOn: false, isToggleEnabled: false, caption: LaunchAtLoginModel.unavailableWords))
        model.setOn(true)
        ListTestSupport.spin(for: 0.05)
        XCTAssertEqual(item.changeCalls, 0, "the disabled toggle asks nothing")

        // A failure that leaves macOS unable to find the app says so once, in the caption.
        let (other, failing) = answered(.notRegistered)
        failing.failure = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        failing.answers = .notFound
        other.setOn(true)
        spin { other.pending == nil && failing.registerCalls == 1 }
        XCTAssertEqual(other.row, .init(isOn: false, isToggleEnabled: false, caption: LaunchAtLoginModel.unavailableWords))
    }

    func testWhatTheRowShowsInEachState() {
        let item = FakeLoginItem()
        let model = LaunchAtLoginModel(handler: item)
        model.showForSnapshot(.on)
        XCTAssertEqual(model.row, .init(isOn: true))
        model.showForSnapshot(.off)
        XCTAssertEqual(model.row, .init(isOn: false))
        model.showForSnapshot(.needsApproval)
        XCTAssertEqual(model.row, .init(isOn: true, needsApproval: true))
        model.showForSnapshot(.unavailable)
        XCTAssertEqual(model.row, .init(isOn: false, isToggleEnabled: false,
                                        caption: "Not available for this copy of SuperSparrow. Move it to the Applications folder and open it from there."))
        model.showForSnapshot(.off, failed: .turnOn)
        XCTAssertEqual(model.row, .init(isOn: false, failure: "Couldn't set SuperSparrow to open at login. You can add it in System Settings › General › Login Items & Extensions."))
        model.showForSnapshot(.on, failed: .turnOff)
        XCTAssertEqual(model.row, .init(isOn: true, failure: "Couldn't stop SuperSparrow opening at login. You can remove it in System Settings › General › Login Items & Extensions."))

        model.refresh()
        model.setOn(false)
        model.openLoginItems()
        ListTestSupport.spin(for: 0.05)
        XCTAssertEqual(item.statusCalls + item.changeCalls + item.openSettingsCalls, 0, "a snapshot asks and changes nothing")
    }

    /// The snapshots' stand-in never reaches macOS and always reads as off.
    func testTheSnapshotLoginItemAnswersOffAndChangesNothing() async {
        let item = SnapshotLoginItem()
        let status = await item.status()
        XCTAssertEqual(status, .notRegistered)
        do {
            try await item.register()
            XCTFail("a snapshot never registers")
        } catch {}
    }

    // MARK: The rows

    private func throwawaySettings() throws -> AppSettings {
        let suite = "SuperSparrowAppTests.LaunchAtLogin.\(UUID().uuidString)"
        suites.append(suite)
        return AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    private func general(_ model: LaunchAtLoginModel, settings: AppSettings? = nil,
                         defaultMailApp: DefaultMailAppModel? = nil) throws -> NSHostingView<GeneralSettingsView> {
        NSHostingView(rootView: GeneralSettingsView(settings: try settings ?? throwawaySettings(),
                                                    defaultMailApp: defaultMailApp ?? DefaultMailAppModel(handler: FakeMailtoHandler()),
                                                    mailboxSize: MailboxSizeModel(measure: { 292_000_000 }), launchAtLogin: model))
    }

    /// The General tab as Settings hosts it, in an ordered window far off screen, sized to its content.
    private func host(_ model: LaunchAtLoginModel, settings: AppSettings? = nil,
                      defaultMailApp: DefaultMailAppModel? = nil) throws -> (window: NSWindow, view: NSHostingView<GeneralSettingsView>) {
        let view = try general(model, settings: settings, defaultMailApp: defaultMailApp)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        fit(view)
        return (window, view)
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

    /// The field column's leading edge.
    private var fieldX: CGFloat {
        let s = Quire.Layout.Settings.self
        return s.padX + s.labelColumn + s.labelGap
    }

    /// The centre of the row `rowsAbove` rows above Mail links, the last row while it shows no failure, from the top
    /// of the content.
    private func rowMidY(rowsAboveMailLinks rowsAbove: Int, in view: NSView) -> CGFloat {
        let s = Quire.Layout.Settings.self
        return view.bounds.height - s.padBottom - s.row * CGFloat(rowsAbove) - s.row / 2
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
        ListTestSupport.spin(for: 0.05)
    }

    func testTheToggleRegistersOnceAndTheApprovalButtonOpensLoginItems() throws {
        let item = FakeLoginItem(.notRegistered)
        item.registerLeaves = .requiresApproval
        let model = LaunchAtLoginModel(handler: item)
        let (window, view) = try host(model)
        defer { close(window) }
        spin { model.state == .off }
        XCTAssertGreaterThanOrEqual(item.statusCalls, 1, "the row asks as it appears")
        fit(view)
        let rowsBefore = view.fittingSize.height

        // The toggle's track, in At login's row just above Mail links.
        click(NSPoint(x: fieldX + Quire.Layout.Toggle.width / 2, y: rowMidY(rowsAboveMailLinks: 1, in: view)), in: view)
        spin { model.state == .needsApproval }
        XCTAssertEqual(item.registerCalls, 1, "one press asks macOS once")
        XCTAssertEqual(item.unregisterCalls, 0)
        fit(view)
        XCTAssertEqual(view.fittingSize.height - rowsBefore, Quire.Layout.Settings.row, accuracy: 0.5, "the approval line is a row of its own")
        XCTAssertNil(window.attachedSheet, "no alert")

        // Open Login Items, after the glyph and the words, in the line that now sits just above Mail links.
        let s = Quire.Layout.Settings.self
        let words = (LaunchAtLoginModel.approvalWords as NSString).size(withAttributes: [.font: QuireFont.font(.snippet)]).width
        let buttonX = fieldX + s.statusGlyph + s.statusGlyphGap + words + s.statusButtonGap + 24
        click(NSPoint(x: buttonX, y: rowMidY(rowsAboveMailLinks: 1, in: view)), in: view)
        XCTAssertEqual(item.openSettingsCalls, 1, "Open Login Items opens System Settings")
        XCTAssertEqual(item.changeCalls, 1, "and changes nothing")
    }

    func testAFailureShowsUnderTheToggleWhichStaysToTryAgain() throws {
        let item = FakeLoginItem(.notRegistered)
        item.failure = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        let model = LaunchAtLoginModel(handler: item)
        let (window, view) = try host(model)
        defer { close(window) }
        spin { model.state == .off }
        fit(view)
        let before = view.fittingSize.height
        let toggle = NSPoint(x: fieldX + Quire.Layout.Toggle.width / 2, y: rowMidY(rowsAboveMailLinks: 1, in: view))

        click(toggle, in: view)
        spin { model.failed == .turnOn && model.pending == nil }
        fit(view)
        XCTAssertGreaterThanOrEqual(view.fittingSize.height - before, QuireFont.Role.meta.lineHeight,
                                    "the failure takes its own lines under the row")
        XCTAssertNil(window.attachedSheet, "no alert")

        item.failure = nil
        click(toggle, in: view)
        spin { model.state == .on }
        XCTAssertEqual(item.registerCalls, 2, "the toggle is still there, above the failure")
        fit(view)
        XCTAssertEqual(view.fittingSize.height, before, accuracy: 0.5, "the failure goes once it is no longer true")
    }

    /// Before the first answer the row holds no toggle but keeps its height, so nothing moves when the toggle appears.
    func testTheRowKeepsItsHeightWhileItWaitsForTheAnswer() throws {
        let item = FakeLoginItem(.enabled)
        let model = LaunchAtLoginModel(handler: item)
        model.showForSnapshot(.unknown)
        let (window, view) = try host(model)
        defer { close(window) }
        XCTAssertNil(model.row.isOn)
        let unanswered = view.fittingSize.height

        model.showForSnapshot(.on)
        fit(view)
        XCTAssertEqual(view.fittingSize.height, unanswered, accuracy: 0.5)
        XCTAssertEqual(LaunchAtLoginModel.accessibilityLabel, "Open SuperSparrow at login", "VoiceOver reads the toggle with its moment")
    }

    /// General never scrolls (§5.40): with every line it can show at once (the seven-accounts caption, Mail links'
    /// failure, and At login's tallest line, whichever it is) it stays shorter than Accounts at its tallest, so a screen
    /// that shows Accounts whole shows General whole.
    func testGeneralAtItsTallestStaysShorterThanAccounts() throws {
        let settings = try throwawaySettings()
        settings.accountWasAdded(totalAccounts: 7)
        XCTAssertTrue(settings.showsSevenAccountsCaption)
        let mail = DefaultMailAppModel(handler: FakeMailtoHandler())
        mail.showForSnapshot(.failed)
        let login = LaunchAtLoginModel(handler: FakeLoginItem())
        login.showForSnapshot(.on)
        let (window, view) = try host(login, settings: settings, defaultMailApp: mail)
        defer { close(window) }
        let states: [(LaunchAtLoginModel.State, LaunchAtLoginModel.Change?)] = [
            (.on, nil), (.needsApproval, nil), (.unavailable, nil), (.off, .turnOn), (.on, .turnOff), (.needsApproval, .turnOff),
        ]
        var heights: [CGFloat] = []
        for (state, failed) in states {
            login.showForSnapshot(state, failed: failed)
            fit(view)
            heights.append(view.fittingSize.height)
            XCTAssertEqual(view.fittingSize.width, Quire.Layout.Settings.width, accuracy: 0.5)
        }

        let tallest = heights.max() ?? 0
        XCTAssertEqual(heights[1] - heights[0], Quire.Layout.Settings.row, accuracy: 0.5, "the approval line is one row")
        let accountsTallest: CGFloat = 760
        XCTAssertLessThanOrEqual(tallest, accountsTallest, "General at its tallest is \(tallest) pt")
    }

    func testTheSettingsWindowAsksOnlyItsLoginItem() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchAtLoginSettingsTests-\(UUID().uuidString)")
        let environment = try AppEnvironment.makeScratch(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = FakeLoginItem(.enabled)
        let controller = SettingsWindowController(environment: environment, settings: try throwawaySettings(), mailtoHandler: FakeMailtoHandler(),
                                                  loginItem: item)
        defer { controller.tearDown() }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        controller.show(tab: .general)
        spin { controller.launchAtLogin.state == .on }
        XCTAssertGreaterThanOrEqual(item.statusCalls, 1, "General asks the login item it was given")

        // Back from System Settings, where the user turned SuperSparrow off in Login Items.
        item.answers = .requiresApproval
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        spin { controller.launchAtLogin.state == .needsApproval }

        controller.model.tab = .accounts
        ListTestSupport.spin(for: 0.05)
        let asked = item.statusCalls
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        window.performClose(nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        ListTestSupport.spin(for: 0.05)
        XCTAssertEqual(item.statusCalls, asked, "nobody asks while General is not on screen")

        // Closed and reopened on General: the tab's view never left the window.
        item.answers = .enabled
        controller.show(tab: .general)
        spin { controller.launchAtLogin.state == .on }
        window.performClose(nil)
        item.answers = .notRegistered
        controller.show()
        spin { controller.launchAtLogin.state == .off }
        window.performClose(nil)
        XCTAssertEqual(item.changeCalls + item.openSettingsCalls, 0, "showing Settings changes nothing")
    }
}
