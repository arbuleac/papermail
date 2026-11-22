import Foundation
import PaperCore

/// One CLI run as `CLIProcessRunner` starts it. The request travels in `input` (stdin), never in `arguments`: every
/// process on the Mac can read another's argv with `ps`.
struct CLICommand: Sendable {
    var executable: URL
    /// The user's action this run answers (spec §3b): no CLI starts without one, and each start is recorded against it.
    var action: AIUserAction
    /// The arguments, given the run's private folder (Codex takes it for `-C` and `--output-last-message`).
    var arguments: @Sendable (_ folder: URL) -> [String]
    /// The CLI's own variables (cli.md), added to the runner's minimal environment. API-key variables are withheld
    /// even when listed here, so the user's sign-in is what the CLI uses.
    var environment: [String: String] = [:]
    /// Written to stdin, which is then closed; nil closes stdin at once.
    var input: Data?
    /// A file in the run's folder handed back at exit, before the folder is removed (Codex's last message).
    var keepFile: String?
    /// No stdout for this long ends the process.
    var idleTimeout: Duration
    /// The whole run's limit.
    var totalTimeout: Duration
}

/// What a run produces, in order: complete stdout lines, then exactly one exit.
enum CLIOutput: Sendable, Equatable {
    case line(Data)
    case exit(CLIExit)
}

/// How a run ended. `stderr` is the last 8 KB the CLI wrote there; it may quote the request, so it is mail: it is only
/// searched for known failure words, never logged above debug, shown, or put in an error.
struct CLIExit: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case exited(Int32)
        case signaled(Int32)
    }

    var status: Status
    /// The runner ended it: no output for the idle timeout, or the total timeout.
    var timedOut: Bool
    var stderr: Data
    var keptFile: Data?

    var succeeded: Bool { status == .exited(0) && !timedOut }

    /// A number for `AIError.badResponse`: the exit status, or 128 + the signal, as shells report it.
    var code: Int {
        switch status {
        case .exited(let status): return Int(status)
        case .signaled(let signal): return 128 + Int(signal)
        }
    }
}

/// A short command's whole output (`--version`, `auth status`, `features list`).
struct CLICapture: Sendable {
    var stdout: Data
    var exit: CLIExit

    var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// The runner's limits (SPEC §3). Tests shorten them; the app uses `standard`.
struct CLILimits: Sendable {
    /// No stdout for this long during a write ends the process.
    var idle: Duration = .seconds(30)
    /// A write's whole limit; a request's own shorter deadline wins.
    var total: Duration = .seconds(120)
    /// Between SIGTERM and SIGKILL.
    var killGrace: Duration = .seconds(2)
    /// After the CLI exits, how long a helper it started may keep the pipes open before the runner stops reading.
    var drain: Duration = .seconds(1)
    /// `--version`, `auth status`, `login status`, `features list`.
    var quick: Duration = .seconds(15)
    var stderrBytes = 8 * 1024
    /// A short command's output is cut here (a features list is a few KB).
    var captureBytes = 1 << 20

    static let standard = CLILimits()
}
