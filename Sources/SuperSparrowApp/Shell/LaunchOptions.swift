import Foundation

/// What the command line asked for. `--reset-demo` implies `--demo`: wiping the demo mailbox only makes
/// sense on the way into it.
struct LaunchOptions: Equatable {
    var demo = false
    var resetDemo = false
    /// Debug aid: render the main window into this PNG a few seconds after launch. Drawn by the app itself,
    /// so it works without the Screen Recording permission `screencapture` needs (web content stays blank).
    var snapshotPath: String?

    init(arguments: [String] = CommandLine.arguments) {
        for argument in arguments.dropFirst() {
            switch argument {
            case "--demo":
                demo = true
            case "--reset-demo":
                demo = true
                resetDemo = true
            case let value where value.hasPrefix("--snapshot="):
                snapshotPath = String(value.dropFirst("--snapshot=".count))
            default:
                // LaunchServices adds -NSDocumentRevisionsDebugMode and friends; ignore anything unknown.
                break
            }
        }
    }
}
