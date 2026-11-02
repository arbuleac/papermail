import Foundation

/// What the command line asked for. `--reset-demo` implies `--demo`: wiping the demo mailbox only makes
/// sense on the way into it. `--snapshot-settings` implies it too, so Settings shows accounts without ever
/// opening the real mail database.
struct LaunchOptions: Equatable {
    var demo = false
    var resetDemo = false
    /// Debug aid: render the main window into this PNG a few seconds after launch. Drawn by the app itself,
    /// so it works without the Screen Recording permission `screencapture` needs. In demo mode the first
    /// inbox conversation is opened and the reader's web content is composited in.
    var snapshotPath: String?
    /// Debug aid (demo mode): open a reply to the first inbox conversation and render its composer here.
    var composeSnapshotPath: String?
    /// Debug aid: force the app's appearance ("light" or "dark") regardless of the system setting, so
    /// snapshots can verify both appearances from one machine.
    var appearance: String?
    /// Debug aid: open the design gallery (Debug › Design Gallery) at launch.
    var gallery = false
    /// Debug aid: render the whole design gallery page into this PNG, then quit.
    var gallerySnapshotPath: String?
    /// Debug aid: render the welcome screen (no accounts) into this PNG, then quit. It is drawn over a
    /// throwaway empty store in a temporary directory; the real mail database is never opened.
    var welcomeSnapshotPath: String?
    /// Debug aid (demo mode): render every Settings tab, stacked top to bottom, into this PNG, then quit.
    var settingsSnapshotPath: String?
    /// Debug aid: every welcome-screen state of spec §5.39 (rest, waiting, preparing the demo, demo failed,
    /// sign-in error, no OAuth client), stacked, over a throwaway store, then quit.
    var welcomeStatesSnapshotPath: String?
    /// Debug aid (demo mode): the Settings states of spec §5.40 (adding, add failed, reconnecting, empty, the
    /// OAuth notices and Saved), stacked, then quit.
    var settingsStatesSnapshotPath: String?
    /// Debug aid (demo mode): the main window with the keyboard cheat sheet open, then quit.
    var cheatSheetSnapshotPath: String?
    /// Debug aid (demo mode): the main window with the g-sequence HUD showing, then quit.
    var hudSnapshotPath: String?
    /// Debug aid: the app's alert inventory (spec §5.33) as the system draws it, then quit.
    var alertsSnapshotPath: String?

    init(arguments: [String] = CommandLine.arguments) {
        for argument in arguments.dropFirst() {
            switch argument {
            case "--demo":
                demo = true
            case "--reset-demo":
                demo = true
                resetDemo = true
            case "--gallery":
                gallery = true
            case let value where value.hasPrefix("--snapshot="):
                snapshotPath = Self.value(of: value, after: "--snapshot=")
            case let value where value.hasPrefix("--appearance="):
                appearance = Self.value(of: value, after: "--appearance=")
            case let value where value.hasPrefix("--snapshot-compose="):
                composeSnapshotPath = Self.value(of: value, after: "--snapshot-compose=")
            case let value where value.hasPrefix("--snapshot-gallery="):
                gallerySnapshotPath = Self.value(of: value, after: "--snapshot-gallery=")
            case let value where value.hasPrefix("--snapshot-welcome="):
                welcomeSnapshotPath = Self.value(of: value, after: "--snapshot-welcome=")
            case let value where value.hasPrefix("--snapshot-settings="):
                settingsSnapshotPath = Self.value(of: value, after: "--snapshot-settings=")
                demo = true
            case let value where value.hasPrefix("--snapshot-welcome-states="):
                welcomeStatesSnapshotPath = Self.value(of: value, after: "--snapshot-welcome-states=")
            case let value where value.hasPrefix("--snapshot-settings-states="):
                settingsStatesSnapshotPath = Self.value(of: value, after: "--snapshot-settings-states=")
                demo = true
            case let value where value.hasPrefix("--snapshot-cheatsheet="):
                cheatSheetSnapshotPath = Self.value(of: value, after: "--snapshot-cheatsheet=")
                demo = true
            case let value where value.hasPrefix("--snapshot-hud="):
                hudSnapshotPath = Self.value(of: value, after: "--snapshot-hud=")
                demo = true
            case let value where value.hasPrefix("--snapshot-alerts="):
                alertsSnapshotPath = Self.value(of: value, after: "--snapshot-alerts=")
            default:
                // LaunchServices adds -NSDocumentRevisionsDebugMode and friends; ignore anything unknown.
                break
            }
        }
    }

    /// The snapshots that quit the app once written. `--snapshot` and `--snapshot-compose` leave it running,
    /// as they always have.
    var hasQuittingSnapshots: Bool {
        gallerySnapshotPath != nil || welcomeSnapshotPath != nil || settingsSnapshotPath != nil || welcomeStatesSnapshotPath != nil
            || settingsStatesSnapshotPath != nil || cheatSheetSnapshotPath != nil || hudSnapshotPath != nil || alertsSnapshotPath != nil
    }

    /// The gallery, welcome and alert snapshots need no mail store of the user's (or the demo's); with nothing
    /// else asked for, launch skips opening one.
    var needsMailEnvironment: Bool {
        snapshotPath != nil || composeSnapshotPath != nil || settingsSnapshotPath != nil || settingsStatesSnapshotPath != nil
            || cheatSheetSnapshotPath != nil || hudSnapshotPath != nil || !hasQuittingSnapshots
    }

    /// An empty value (`--snapshot-gallery=`) asks for nothing.
    private static func value(of argument: String, after prefix: String) -> String? {
        let value = String(argument.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }
}
