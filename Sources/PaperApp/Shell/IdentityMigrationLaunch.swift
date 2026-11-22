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

    /// Whether this launch must only ask for the old app to be quit: it is open on a mailbox not moved yet, and opening
    /// Paper would start an empty one in the new folder, beside which a later move would leave the old one where it is.
    static func mustWait(for outcome: IdentityMigration.Outcome) -> Bool {
        outcome == .deferred(applicationSupportWaiting: true)
    }
}

/// The delegate of a launch that only asks for the old app to be quit (`IdentityMigrationLaunch.mustWait`): no store,
/// no settings, no crash reports or analytics, just the alert, and the app quits when it closes. The next launch, with
/// the old app quit, moves everything.
@MainActor
final class LegacyAppOpenDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        AppAlert.legacyAppOpen.present(on: nil)
        NSApp.terminate(nil)
    }
}
