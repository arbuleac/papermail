import AppKit
import SSCore
import SSDesign
import SwiftUI
import XCTest
@testable import SuperSparrowApp

/// Settings › General › Mail links (spec §5.40, roadmap Q1.3): it says so while SuperSparrow opens mail links,
/// otherwise offers Set as Default Mail App, which asks macOS once and then shows what LaunchServices answers; a
/// failure stays in the row's own words, never an alert. Every test goes through `FakeMailtoHandler`, so none reads
/// or changes the Mac's real default mail app.
@MainActor
final class DefaultMailAppSettingsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            suites = []
        }
        super.tearDown()
    }

    private func spin(until condition: () -> Bool) {
        ListTestSupport.spin(until: condition, timeout: 3)
    }

    // MARK: The model

    func testItAsksWhichAppOpensMailLinks() {
        let isDefault = DefaultMailAppModel(handler: FakeMailtoHandler(isDefault: true))
        XCTAssertEqual(isDefault.state, .unknown, "nothing is shown before the answer")
        isDefault.refresh()
        spin { isDefault.state != .unknown }
        XCTAssertEqual(isDefault.state, .isDefault)

        let other = DefaultMailAppModel(handler: FakeMailtoHandler(isDefault: false))
        other.refresh()
        spin { other.state != .unknown }
        XCTAssertEqual(other.state, .notDefault)
    }

    func testTheButtonAsksMacOSOnceThenShowsTheResult() {
        let handler = FakeMailtoHandler()
        handler.holdsSet = true
        let model = DefaultMailAppModel(handler: handler)
        model.refresh()
        spin { model.state == .notDefault }

        model.makeDefault()
        spin { handler.makeDefaultCalls == 1 }
        XCTAssertEqual(model.state, .setting, "waiting for the user in macOS's confirmation")
        model.makeDefault()
        model.refresh()
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(handler.makeDefaultCalls, 1, "a second press while macOS asks does nothing")
        XCTAssertEqual(model.state, .setting, "and a refresh does not answer over it")

        handler.release()
        spin { model.state != .setting }
        XCTAssertEqual(model.state, .isDefault)
        XCTAssertEqual(handler.makeDefaultCalls, 1)
    }

    func testKeepingTheOtherAppBringsTheButtonBackWithoutWords() {
        let handler = FakeMailtoHandler()
        handler.setMakesDefault = false
        let model = DefaultMailAppModel(handler: handler)
        model.makeDefault()
        spin { model.state != .setting }
        XCTAssertEqual(model.state, .notDefault, "the user said no; nothing failed")

        handler.failure = CocoaError(.userCancelled)
        model.makeDefault()
        spin { handler.makeDefaultCalls == 2 && model.state != .setting }
        XCTAssertEqual(model.state, .notDefault, "a cancellation is the user's choice too")
    }

    func testAFailureStaysInWordsUntilAnAttemptSucceeds() {
        let handler = FakeMailtoHandler()
        handler.failure = NSError(domain: NSOSStatusErrorDomain, code: -10814)
        let model = DefaultMailAppModel(handler: handler)
        model.makeDefault()
        spin { model.state != .setting }
        XCTAssertEqual(model.state, .failed)

        model.refresh()
        spin { handler.isDefaultCalls >= 2 }
        ListTestSupport.spin(for: 0.05)
        XCTAssertEqual(model.state, .failed, "asking again does not hide the failure while it is still true")

        handler.failure = nil
        model.makeDefault()
        spin { model.state != .setting }
        XCTAssertEqual(model.state, .isDefault)
    }

    /// Trying again after a failure keeps its words while macOS asks (the row does not shrink under the dialog), and a
    /// retry the user declines or cancels is no success, so they stay after it too.
    func testAFailureStaysThroughARetryThatDoesNotSucceed() {
        let handler = FakeMailtoHandler()
        handler.failure = NSError(domain: NSOSStatusErrorDomain, code: -10814)
        let model = DefaultMailAppModel(handler: handler)
        model.makeDefault()
        spin { model.state != .setting }
        XCTAssertEqual(model.state, .failed)
        let failed = model.row

        handler.failure = nil
        handler.setMakesDefault = false
        handler.holdsSet = true
        model.makeDefault()
        spin { handler.makeDefaultCalls == 2 }
        XCTAssertEqual(model.state, .setting)
        XCTAssertEqual(model.row, .init(buttonTitle: DefaultMailAppModel.buttonTitle, isButtonEnabled: false,
                                        failure: DefaultMailAppModel.failureWords), "the words stay while macOS asks")
        handler.release()
        spin { model.state != .setting }
        XCTAssertEqual(model.state, .failed, "the user kept the other app: no attempt has succeeded")
        XCTAssertEqual(model.row, failed)

        handler.holdsSet = false
        handler.failure = CocoaError(.userCancelled)
        model.makeDefault()
        spin { handler.makeDefaultCalls == 3 && model.state != .setting }
        XCTAssertEqual(model.state, .failed, "nor after a cancellation")

        handler.failure = nil
        handler.setMakesDefault = true
        model.makeDefault()
        spin { handler.makeDefaultCalls == 4 && model.state != .setting }
        XCTAssertEqual(model.state, .isDefault)
        XCTAssertNil(model.row.failure)
    }

    func testAFailureThatLeftSuperSparrowTheDefaultSaysSo() {
        let handler = FakeMailtoHandler()
        handler.failure = NSError(domain: NSOSStatusErrorDomain, code: -50)
        handler.answersDefault = true
        let model = DefaultMailAppModel(handler: handler)
        model.makeDefault()
        spin { model.state != .setting }
        XCTAssertEqual(model.state, .isDefault, "LaunchServices' answer wins over the error")
    }

    // MARK: The row

    func testWhatTheRowShowsInEachState() {
        let handler = FakeMailtoHandler()
        let model = DefaultMailAppModel(handler: handler)
        XCTAssertEqual(model.row, .init(), "nothing before the first answer, rather than a button that may vanish")
        model.showForSnapshot(.isDefault)
        XCTAssertEqual(model.row, .init(words: "SuperSparrow is your default mail app."))
        model.showForSnapshot(.notDefault)
        XCTAssertEqual(model.row, .init(buttonTitle: "Set as Default Mail App", isButtonEnabled: true))
        model.showForSnapshot(.setting)
        XCTAssertEqual(model.row, .init(buttonTitle: "Set as Default Mail App", isButtonEnabled: false))
        model.showForSnapshot(.failed)
        XCTAssertEqual(model.row, .init(buttonTitle: "Set as Default Mail App", isButtonEnabled: true,
                                        failure: "Couldn't make SuperSparrow the default mail app. You can also choose it in Mail › Settings › General."))
        XCTAssertEqual(handler.isDefaultCalls + handler.makeDefaultCalls, 0, "a snapshot asks nothing")
    }

    private func throwawaySettings() throws -> AppSettings {
        let suite = "SuperSparrowAppTests.DefaultMailApp.\(UUID().uuidString)"
        suites.append(suite)
        return AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    /// The General tab as Settings hosts it, in an ordered window far off screen, sized to its content.
    private func host(_ model: DefaultMailAppModel) throws -> (window: NSWindow, view: NSHostingView<GeneralSettingsView>) {
        let view = NSHostingView(rootView: GeneralSettingsView(settings: try throwawaySettings(), defaultMailApp: model,
                                                               mailboxSize: MailboxSizeModel(measure: { 292_000_000 }),
                                                               launchAtLogin: LaunchAtLoginModel(handler: FakeLoginItem())))
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

    /// The button's place while Mail links is the last row (no failure under it), from the top of the content: the
    /// field column's leading edge, centred in the 40 pt row above the bottom padding. Rows only ever grow below it.
    private func buttonPoint(in view: NSView) -> NSPoint {
        let s = Quire.Layout.Settings.self
        return NSPoint(x: s.padX + s.labelColumn + s.labelGap + 12, y: view.bounds.height - s.padBottom - s.row / 2)
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

    func testTheButtonCallsTheSetterOnceThenTheRowSaysSo() throws {
        let handler = FakeMailtoHandler()
        handler.holdsSet = true
        let model = DefaultMailAppModel(handler: handler)
        let (window, view) = try host(model)
        defer { close(window) }
        spin { model.state == .notDefault }
        XCTAssertGreaterThanOrEqual(handler.isDefaultCalls, 1, "the row asks as it appears")
        fit(view)
        let button = buttonPoint(in: view)

        click(button, in: view)
        spin { handler.makeDefaultCalls == 1 }
        XCTAssertEqual(model.state, .setting, "macOS is asking the user")
        fit(view)
        click(button, in: view)
        XCTAssertEqual(handler.makeDefaultCalls, 1, "the disabled button calls nothing")

        handler.release()
        spin { model.state == .isDefault }
        XCTAssertEqual(handler.makeDefaultCalls, 1, "the setter is called once")
        XCTAssertEqual(model.row.words, DefaultMailAppModel.isDefaultWords)
        XCTAssertNil(window.attachedSheet)
    }

    func testAFailureShowsUnderTheButtonWhichStaysToTryAgain() throws {
        let handler = FakeMailtoHandler()
        handler.failure = NSError(domain: NSOSStatusErrorDomain, code: -10814)
        let model = DefaultMailAppModel(handler: handler)
        let (window, view) = try host(model)
        defer { close(window) }
        spin { model.state == .notDefault }
        fit(view)
        let before = view.fittingSize.height
        let button = buttonPoint(in: view)

        click(button, in: view)
        spin { model.state == .failed }
        fit(view)
        XCTAssertGreaterThanOrEqual(view.fittingSize.height - before, QuireFont.Role.meta.lineHeight,
                                    "the failure takes its own lines under the row")
        XCTAssertNil(window.attachedSheet, "no alert")

        handler.failure = nil
        click(button, in: view)
        spin { model.state != .failed && model.state != .setting }
        XCTAssertEqual(handler.makeDefaultCalls, 2, "the button is still there, above the failure")
        XCTAssertEqual(model.state, .isDefault)
        fit(view)
        XCTAssertEqual(view.fittingSize.height, before, accuracy: 0.5, "the failure goes once it is no longer true")
    }

    func testTheSettingsWindowAsksOnlyItsHandler() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DefaultMailAppSettingsTests-\(UUID().uuidString)")
        let environment = try AppEnvironment.makeScratch(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = FakeMailtoHandler(isDefault: true)
        let controller = SettingsWindowController(environment: environment, settings: try throwawaySettings(), mailtoHandler: handler,
                                                  loginItem: FakeLoginItem())
        defer { controller.tearDown() }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        controller.show(tab: .general)
        spin { controller.defaultMailApp.state == .isDefault }
        XCTAssertGreaterThanOrEqual(handler.isDefaultCalls, 1, "General asks the handler it was given")

        // Back from Mail's settings, where the user chose Mail again.
        handler.answersDefault = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        spin { controller.defaultMailApp.state == .notDefault }
        XCTAssertEqual(controller.defaultMailApp.state, .notDefault, "the app coming to the front asks again")

        controller.model.tab = .accounts
        ListTestSupport.spin(for: 0.05)
        let asked = handler.isDefaultCalls
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        window.performClose(nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        ListTestSupport.spin(for: 0.05)
        XCTAssertEqual(handler.isDefaultCalls, asked, "nobody asks while General is not on screen")

        handler.answersDefault = true
        controller.show(tab: .general)
        spin { controller.defaultMailApp.state == .isDefault }
        XCTAssertEqual(controller.defaultMailApp.state, .isDefault, "switching back to General asks again")

        // Closed and reopened on General: the tab's view never left the window.
        window.performClose(nil)
        handler.answersDefault = false
        controller.show()
        spin { controller.defaultMailApp.state == .notDefault }
        XCTAssertEqual(controller.defaultMailApp.state, .notDefault, "reopening on General asks again")
        window.performClose(nil)
    }
}
