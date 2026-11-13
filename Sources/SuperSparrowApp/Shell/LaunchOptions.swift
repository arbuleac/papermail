import Foundation
import SSDesign

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
    /// Debug aid (demo mode): open the first inbox conversation in a reader window (§5.19a) and render that window here,
    /// its web content composited in.
    var readerWindowSnapshotPath: String?
    /// Debug aid: force the app's appearance ("light" or "dark") regardless of the system setting, so
    /// snapshots can verify both appearances from one machine.
    var appearance: String?
    /// Debug aid: force the Font setting ("newyork" or "sf") for this process only, so snapshots can verify both
    /// faces from one machine. Never written to the user's defaults; Settings › General › Font still shows the
    /// saved choice, and picking one there applies it as usual.
    var typeface: QuireFont.Typeface?
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
            #if DEBUG
            // Development aids, debug builds only: a release build ignores them, so nothing can make it write
            // its windows (Settings shows the configured OAuth client ID) to a path a caller picks.
            case "--gallery":
                gallery = true
            case let value where value.hasPrefix("--snapshot="):
                snapshotPath = Self.value(of: value, after: "--snapshot=")
            case let value where value.hasPrefix("--appearance="):
                appearance = Self.value(of: value, after: "--appearance=")
            case let value where value.hasPrefix("--font="):
                typeface = Self.typeface(named: Self.value(of: value, after: "--font="))
            case let value where value.hasPrefix("--snapshot-compose="):
                composeSnapshotPath = Self.value(of: value, after: "--snapshot-compose=")
            case let value where value.hasPrefix("--snapshot-reader-window="):
                readerWindowSnapshotPath = Self.value(of: value, after: "--snapshot-reader-window=")
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
            #endif
            default:
                // LaunchServices adds -NSDocumentRevisionsDebugMode and friends; ignore anything unknown.
                break
            }
        }
    }

    /// The snapshots that quit the app once written. `--snapshot`, `--snapshot-compose` and `--snapshot-reader-window`
    /// leave it running, as the first two always have.
    var hasQuittingSnapshots: Bool {
        gallerySnapshotPath != nil || welcomeSnapshotPath != nil || settingsSnapshotPath != nil || welcomeStatesSnapshotPath != nil
            || settingsStatesSnapshotPath != nil || cheatSheetSnapshotPath != nil || hudSnapshotPath != nil || alertsSnapshotPath != nil
    }

    /// Any snapshot that draws the main window or a composer from the demo: those windows then take their
    /// default size and divider positions, ignore the pointer, and never read or write the user's saved frames,
    /// so a render depends on nothing but the build (§5.1 1280 × 800, §5.20 640 × 600).
    var isWindowSnapshot: Bool {
        snapshotPath != nil || composeSnapshotPath != nil || readerWindowSnapshotPath != nil || cheatSheetSnapshotPath != nil
            || hudSnapshotPath != nil
    }

    /// Any snapshot at all. Such a launch neither reads nor writes what the app remembers between launches (the
    /// main window's account scope), so a render depends on nothing but the build and never changes the user's
    /// choice.
    var isSnapshot: Bool {
        snapshotPath != nil || composeSnapshotPath != nil || readerWindowSnapshotPath != nil || hasQuittingSnapshots
    }

    /// The gallery, welcome and alert snapshots need no mail store of the user's (or the demo's); with nothing
    /// else asked for, launch skips opening one.
    var needsMailEnvironment: Bool {
        snapshotPath != nil || composeSnapshotPath != nil || readerWindowSnapshotPath != nil || settingsSnapshotPath != nil
            || settingsStatesSnapshotPath != nil
            || cheatSheetSnapshotPath != nil || hudSnapshotPath != nil || !hasQuittingSnapshots
    }

    /// `--font=newyork` or `--font=sf`; anything else leaves the saved choice in charge.
    static func typeface(named name: String?) -> QuireFont.Typeface? {
        switch name?.lowercased() {
        case "newyork": return .newYork
        case "sf": return .sfPro
        default: return nil
        }
    }

    /// An empty value (`--snapshot-gallery=`) asks for nothing.
    private static func value(of argument: String, after prefix: String) -> String? {
        let value = String(argument.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }
}
