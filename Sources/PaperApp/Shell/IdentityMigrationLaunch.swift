import AppKit
import PaperCore

/// The first launch's move as main.swift runs it, before anything else of the app's reads or writes a setting, a folder
/// or a Keychain item (docs/ARCHITECTURE.md, "Identity"): over the user's own folders and defaults, with
/// `NSRunningApplication` saying whether the old app is open. Only in the bundled app; the bare binary and the tests stop
/// at the bundle identifier and never look at the user's folders.
@MainActor
enum IdentityMigrationLaunch {
    static func run() -> IdentityMigration.Outcome {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        guard IdentityMigration.applies(toBundleIdentifier: bundleIdentifier) else { return .notThisApp }
        return IdentityMigration(
            bundleIdentifier: bundleIdentifier,
            locations: .user,
            defaults: UserDefaults.standard,
            isLegacyAppRunning: {
                !NSRunningApplication.runningApplications(withBundleIdentifier: LegacyIdentity.bundleIdentifier).isEmpty
            }
        ).run()
    }
}

/// The delegate of a launch that opens nothing (`AppAlert.identityHold`): the old app is open on a mailbox not moved yet,
/// or the move could not bring the mailbox over, and opening Paper would start an empty one in the new folder, beside
/// which the old one would stay for good. No store, no settings, no crash reports or analytics, just the alert, and the
/// app quits when it closes; the next launch tries again.
@MainActor
final class IdentityHoldDelegate: NSObject, NSApplicationDelegate {
    private let outcome: IdentityMigration.Outcome
    private let alert: AppAlert

    init(outcome: IdentityMigration.Outcome, alert: AppAlert) {
        self.outcome = outcome
        self.alert = alert
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        let outcome = outcome
        alert.present(on: nil) { choice in
            // Show in Finder: Paper's own mailbox, the one to move out for the old one to come in.
            if outcome == .leftBehind(.mailboxInBothFolders), choice == 0 {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: SQLiteMailStore.defaultPath)])
            }
        }
        NSApp.terminate(nil)
    }
}
