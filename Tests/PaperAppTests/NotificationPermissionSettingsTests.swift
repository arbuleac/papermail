import AppKit
import PaperCore
import PaperDesign
import SwiftUI
import UserNotifications
import XCTest
@testable import PaperApp

/// Settings › General › Notifications' line (spec §5.40, §5.28): while macOS keeps notifications, and with them the Dock
/// badge, from Paper, General says so with the one button that can change it: Open Notifications where only System
/// Settings can, Allow… while macOS has never asked. Nothing while nothing stands in the way. Every test goes through
/// `FakeNotificationPermission`, so none reads the Mac's real notification settings or puts macOS's prompt up.
@MainActor
final class NotificationPermissionSettingsTests: XCTestCase {
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

    private func answered(_ permission: NotificationPermission) -> (model: NotificationPermissionModel, fake: FakeNotificationPermission) {
        let fake = FakeNotificationPermission(permission)
        let model = NotificationPermissionModel(handler: fake)
        model.refresh()
        spin { model.permission != nil }
        return (model, fake)
    }

    // MARK: The model

    func testTheLineFollowsMacOSsAnswer() {
        let model = NotificationPermissionModel(handler: FakeNotificationPermission(.denied))
        XCTAssertNil(model.line, "no line before the answer, rather than one that may vanish")

        XCTAssertEqual(answered(.denied).model.line, .init(words: "Off in System Settings", buttonTitle: "Open Notifications",
                                                           action: .openSettings,
                                                           caption: "No notifications and no Dock badge until they're allowed there."))
        XCTAssertEqual(answered(.allowedWithoutBadge).model.line, .init(words: "Dock badge off in System Settings",
                                                                        buttonTitle: "Open Notifications", action: .openSettings))
        XCTAssertEqual(answered(.notAsked).model.line, .init(words: "Not allowed yet", buttonTitle: "Allow…", action: .ask))
        XCTAssertNil(answered(.allowed).model.line, "nothing stands in the way")
        XCTAssertNil(answered(.unavailable).model.line, "a bare build has no notification center to ask")
    }

    func testOpenNotificationsOpensSystemSettingsAndAsksNothing() {
        let (model, fake) = answered(.denied)
        model.act()
        XCTAssertEqual(fake.openSettingsCalls, 1)
        XCTAssertEqual(fake.requestCalls, 0, "macOS asks only once: after Don't Allow only System Settings changes it")

        // Allowed there, the line goes as the app comes back to the front.
        fake.answers = .allowed
        model.refresh()
        spin { model.line == nil }
    }

    func testAllowPutsMacOSsPromptUpOnceThenFollowsItsAnswer() {
        let (model, fake) = answered(.notAsked)
        fake.holdsPrompt = true
        fake.promptLeaves = .denied

        model.act()
        spin { fake.requestCalls == 1 }
        XCTAssertTrue(model.isAsking)
        model.act()
        model.refresh()
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(fake.requestCalls, 1, "presses while the prompt is up do nothing")
        XCTAssertEqual(fake.openSettingsCalls, 0)

        fake.release()
        spin { model.permission == .denied }
        XCTAssertFalse(model.isAsking)
        XCTAssertEqual(model.line?.action, .openSettings, "Don't Allow: from now on only System Settings")
    }

    func testASnapshotAsksAndOpensNothing() async {
        let fake = FakeNotificationPermission(.allowed)
        let model = NotificationPermissionModel(handler: fake)
        model.showForSnapshot(.denied)
        model.refresh()
        model.act()
        ListTestSupport.spin(for: 0.05)
        XCTAssertEqual(model.permission, .denied)
        XCTAssertEqual(fake.permissionCalls + fake.requestCalls + fake.openSettingsCalls, 0, "a snapshot asks and opens nothing")

        let snapshot = SnapshotNotificationPermission()
        let permission = await snapshot.permission()
        XCTAssertEqual(permission, .allowed, "the snapshots' stand-in never reaches macOS")
    }

    /// macOS's words in ours: Badge application icon matters only where notifications are allowed.
    func testMacOSsSettingsReadAsPermissions() async {
        XCTAssertEqual(NotificationPermission(.notDetermined, badge: .notSupported), .notAsked)
        XCTAssertEqual(NotificationPermission(.denied, badge: .enabled), .denied, "the user's case: the badge switch on, still no badge")
        XCTAssertEqual(NotificationPermission(.authorized, badge: .enabled), .allowed)
        XCTAssertEqual(NotificationPermission(.authorized, badge: .disabled), .allowedWithoutBadge)
        XCTAssertEqual(NotificationPermission(.provisional, badge: .notSupported), .allowed)

        let permission = await SystemNotificationPermission().permission()
        XCTAssertEqual(permission, .unavailable, "the tests run outside an app bundle: nothing is asked of macOS")
    }

    // MARK: The rows

    private func throwawaySettings() throws -> AppSettings {
        let suite = "PaperAppTests.NotificationPermission.\(UUID().uuidString)"
        suites.append(suite)
        return AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    private func height(of model: NotificationPermissionModel, settings: AppSettings) -> CGFloat {
        let view = NSHostingView(rootView: GeneralSettingsView(settings: settings, defaultMailApp: DefaultMailAppModel(handler: FakeMailtoHandler()),
                                                               mailboxSize: MailboxSizeModel(measure: { 292_000_000 }),
                                                               launchAtLogin: LaunchAtLoginModel(handler: FakeLoginItem()),
                                                               notificationPermission: model))
        ListTestSupport.spin(for: 0.05)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width, Quire.Layout.Settings.width, accuracy: 0.5)
        return view.fittingSize.height
    }

    /// The line is one row in the field column, with its caption under it while notifications are off; it shows with
    /// New mail off too, since the Dock badge goes with the permission, not with the toggle.
    func testTheLineIsOneRowUnderNotificationsWhateverTheToggleSays() throws {
        let settings = try throwawaySettings()
        let model = NotificationPermissionModel(handler: FakeNotificationPermission())
        model.showForSnapshot(.allowed)
        let allowed = height(of: model, settings: settings)
        model.showForSnapshot(nil)
        XCTAssertEqual(height(of: model, settings: settings), allowed, accuracy: 0.5, "before the answer, no line")

        model.showForSnapshot(.allowedWithoutBadge)
        let badgeOff = height(of: model, settings: settings)
        XCTAssertEqual(badgeOff - allowed, Quire.Layout.Settings.row, accuracy: 0.5, "the line is one row")

        model.showForSnapshot(.denied)
        let denied = height(of: model, settings: settings)
        XCTAssertGreaterThanOrEqual(denied - badgeOff, QuireFont.Role.meta.lineHeight, "its caption takes its own line under it")

        settings.notificationsEnabled = false
        XCTAssertEqual(height(of: model, settings: settings), denied, accuracy: 0.5, "New mail off: the badge still needs it")
    }

    /// The words and the button share one row of the field column, as At login's approval line does.
    func testTheWordsAndTheButtonFitTheFieldColumn() {
        let s = Quire.Layout.Settings.self
        let field = s.width - 2 * s.padX - s.labelColumn
        let font = QuireFont.font(.snippet)
        for words in [NotificationPermissionModel.deniedWords, NotificationPermissionModel.badgeOffWords, NotificationPermissionModel.notAskedWords] {
            let wordsWidth = (words as NSString).size(withAttributes: [.font: font]).width
            let button = (NotificationPermissionModel.openNotificationsTitle as NSString).size(withAttributes: [.font: font]).width + 2 * 12
            XCTAssertLessThan(s.statusGlyph + s.statusGlyphGap + wordsWidth + s.statusButtonGap + button, field, "“\(words)” fits")
        }
    }

    func testTheSettingsWindowAsksItsNotificationPermissionWhileGeneralShows() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotificationPermissionSettingsTests-\(UUID().uuidString)")
        let environment = try AppEnvironment.makeScratch(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeNotificationPermission(.denied)
        let controller = SettingsWindowController(environment: environment, settings: try throwawaySettings(), mailtoHandler: FakeMailtoHandler(),
                                                  loginItem: FakeLoginItem(), notifications: fake)
        defer { controller.tearDown() }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        controller.show(tab: .general)
        spin { controller.notificationPermission.permission == .denied }

        // Back from System Settings, where the user allowed notifications.
        fake.answers = .allowed
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        spin { controller.notificationPermission.permission == .allowed }
        XCTAssertNil(controller.notificationPermission.line)

        controller.model.tab = .accounts
        ListTestSupport.spin(for: 0.05)
        let asked = fake.permissionCalls
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        ListTestSupport.spin(for: 0.05)
        XCTAssertEqual(fake.permissionCalls, asked, "nobody asks while General is not on screen")
        XCTAssertEqual(fake.requestCalls, 0, "and nothing puts macOS's prompt up on its own")
    }
}
