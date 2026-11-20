import Foundation
import SSCore

/// Runs the user's Claude Code or Codex for one request: a fresh process in a new empty 0700 folder under
/// `temporaryDirectory` (removed afterwards), a minimal environment without API keys, the request on stdin (never
/// argv, which `ps` shows), stdout read line by line, stderr kept to 8 KB and treated as mail, idle and total timeouts
/// ending in SIGTERM then SIGKILL, and cancellation ending the process.
///
/// STUB (step 1 of the build): compiles under its final name and initializer so the factory can build it. The CLI
/// track designs and builds the rest of its API.
public struct CLIProcessRunner: Sendable {
    /// Where each run's private working folder is made: the app's temporary directory.
    let temporaryDirectory: URL

    public init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectory = temporaryDirectory
    }
}
