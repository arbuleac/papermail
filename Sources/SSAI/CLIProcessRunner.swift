import Foundation
import SSCore

/// Runs the user's Claude Code or Codex for one request: a fresh process in a new empty 0700 folder under
/// `temporaryDirectory` (removed afterwards), a minimal environment without API keys, the request on stdin (never
/// argv, which `ps` shows), stdout read line by line, stderr kept to 8 KB and treated as mail, idle and total timeouts
/// ending in SIGTERM then SIGKILL, and cancellation ending the process.
///
/// One runner is shared by every provider a factory builds, so the version checks it caches (`CLIToolCache`) hold
/// across writes.
public struct CLIProcessRunner: Sendable {
    /// Where each run's private working folder is made: the app's temporary directory.
    let temporaryDirectory: URL
    let limits: CLILimits
    let base: CLIBaseEnvironment
    /// Searched in order when Settings names no CLI (SPEC §3): never a login shell, whose PATH a GUI app lacks.
    let searchFolders: [URL]
    let cache: CLIToolCache
    /// The runs not ended yet, shared by every copy of this runner: `endAll` ends them when the app goes away.
    let running = CLIRunningSet()

    /// The run folders' name prefix; folders left by a crash are swept once they are clearly stale.
    static let folderPrefix = "ss-ai-"

    /// Variables a CLI must never get from us: with one of these set, Claude Code and Codex use the key instead of the
    /// user's own sign-in, which Settings promised.
    static let withheldVariables: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"]

    public init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        let base = CLIBaseEnvironment.current
        self.init(temporaryDirectory: temporaryDirectory, limits: .standard, base: base,
                  searchFolders: Self.standardFolders(home: base.home))
    }

    /// A runner that looks for CLIs in `searchFolders` instead of the standard ones: the app's tests find a CLI in a
    /// folder of their own with it, whatever this Mac has installed.
    public init(searchFolders: [URL]) {
        self.init(temporaryDirectory: FileManager.default.temporaryDirectory, limits: .standard, base: .current,
                  searchFolders: searchFolders)
    }

    init(temporaryDirectory: URL, limits: CLILimits, base: CLIBaseEnvironment, searchFolders: [URL]) {
        self.temporaryDirectory = temporaryDirectory
        self.limits = limits
        self.base = base
        self.searchFolders = searchFolders
        self.cache = CLIToolCache()
    }

    static func standardFolders(home: String) -> [URL] {
        [
            URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        ]
    }

    // MARK: Finding a CLI

    /// The CLI a provider would run: the one chosen in Settings when it is an executable file, else the first found in
    /// ~/.local/bin, /opt/homebrew/bin, /usr/local/bin. Nil when there is none (or the kind has no CLI). For Settings'
    /// CLI path row; looks at the file system only.
    public func locate(_ kind: AIProviderKind, chosen: String?) -> URL? {
        guard let name = kind.executableName else { return nil }
        return locate(name, chosen: chosen)
    }

    func locate(_ name: String, chosen: String?) -> URL? {
        if let chosen = chosen?.trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty {
            let path = (chosen as NSString).expandingTildeInPath
            if Self.isExecutableFile(path) { return URL(fileURLWithPath: path) }
        }
        for folder in searchFolders {
            let candidate = folder.appendingPathComponent(name, isDirectory: false)
            if Self.isExecutableFile(candidate.path) { return candidate }
        }
        return nil
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: Running

    /// Starts `command` and streams its stdout lines, then its exit. Ending the iteration early (the consumer was
    /// cancelled, or stopped reading) ends the process. Throws `AIError.notInstalled` when it cannot be started.
    func run(_ command: CLICommand) -> AsyncThrowingStream<CLIOutput, Error> {
        AsyncThrowingStream { continuation in
            // Ended for good (`endAll`): nothing starts, a version check or sign-in check no more than a write.
            guard !running.isClosed else {
                continuation.finish(throwing: AIError.cancelled)
                return
            }
            let folder: URL
            do {
                folder = try makeFolder()
            } catch {
                continuation.finish(throwing: AIError.badResponse(code: 0))
                return
            }
            let process = CLIProcess(
                command: command, limits: limits, folder: folder,
                environment: environment(for: command.executable, folder: folder, adding: command.environment),
                registry: running,
                onLine: { continuation.yield(.line($0)) },
                onExit: { exit in
                    continuation.yield(.exit(exit))
                    continuation.finish()
                })
            continuation.onTermination = { termination in
                if case .cancelled = termination { process.stop() }
            }
            do {
                try process.start()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Ends every run this runner started, at once, and returns once they are gone with their folders, or after
    /// `grace` plus a moment: the app is quitting or its window graph is going away, and a CLI must not outlive it with
    /// a request in hand. SIGTERM to each CLI's group, then SIGKILL to what is left after `grace`. The runner starts
    /// nothing after this (`AIError.cancelled`), so a write still preparing as the app quits launches no CLI.
    public func endAll(grace: Duration = .milliseconds(500)) async {
        let processes = running.close()
        guard !processes.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            for process in processes { process.signalNow(SIGTERM) }
            let clock = ContinuousClock()
            let deadline = clock.now + grace
            while clock.now < deadline, processes.contains(where: { !$0.hasEnded }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            for process in processes where !process.hasEnded { process.signalNow(SIGKILL) }
            // A killed process ends at once; its folder goes when its exit is seen.
            let killed = clock.now + .milliseconds(300)
            while clock.now < killed, processes.contains(where: { !$0.hasEnded }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }.value
    }

    /// Runs a short command to its end and returns its output (cut at `captureBytes`).
    func capture(_ command: CLICommand) async throws -> CLICapture {
        var lines: [Data] = []
        var size = 0
        for try await output in run(command) {
            switch output {
            case .line(let line):
                guard size < limits.captureBytes else { continue }
                lines.append(line)
                size += line.count + 1
            case .exit(let exit):
                return CLICapture(stdout: Data(lines.joined(separator: [0x0A])), exit: exit)
            }
        }
        try Task.checkCancellation()
        throw AIError.cancelled
    }

    /// A short command for `tool`: no input, the quick limit for both timeouts.
    func quick(_ executable: URL, _ arguments: [String], tool: CLITool) -> CLICommand {
        CLICommand(executable: executable, arguments: { _ in arguments }, environment: tool.environment, input: nil,
                   keepFile: nil, idleTimeout: limits.quick, totalTimeout: limits.quick)
    }

    /// HOME, USER (without it Claude Code cannot find its sign-in in the Keychain), LANG, PATH with only the system
    /// folders and the CLI's own, TMPDIR = the run's folder, then the CLI's own variables. Nothing else is inherited:
    /// not the app's environment, and never an API key.
    func environment(for executable: URL, folder: URL, adding extra: [String: String]) -> [String: String] {
        var environment = extra.filter { !Self.withheldVariables.contains($0.key) }
        environment["HOME"] = base.home
        environment["USER"] = base.user
        environment["LANG"] = base.language
        let cliFolder = executable.deletingLastPathComponent().path
        environment["PATH"] = ["/usr/bin", "/bin"].contains(cliFolder) ? "/usr/bin:/bin" : "/usr/bin:/bin:" + cliFolder
        environment["TMPDIR"] = folder.path
        return environment
    }

    private func makeFolder() throws -> URL {
        sweepStaleFolders()
        let folder = temporaryDirectory.appendingPathComponent(Self.folderPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Once per directory and app run: folders a crash left behind. Stale means untouched for 15 minutes, far beyond
    /// any run's 2-minute limit, so a run in progress is never swept.
    private func sweepStaleFolders() {
        guard CLIFolderSweep.shared.claim(temporaryDirectory.standardizedFileURL.path) else { return }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: temporaryDirectory.path) else { return }
        let cutoff = Date().addingTimeInterval(-15 * 60)
        for name in names where name.hasPrefix(Self.folderPrefix) {
            let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            guard let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? manager.removeItem(at: url)
        }
    }
}

/// Who runs the CLI: the user's own home, login name and language.
struct CLIBaseEnvironment: Sendable, Equatable {
    var home: String
    var user: String
    var language: String

    static var current: CLIBaseEnvironment {
        let environment = ProcessInfo.processInfo.environment
        func value(_ name: String) -> String? {
            guard let value = environment[name], !value.isEmpty else { return nil }
            return value
        }
        return CLIBaseEnvironment(home: value("HOME") ?? NSHomeDirectory(), user: value("USER") ?? NSUserName(),
                                  language: value("LANG") ?? "en_US.UTF-8")
    }
}

/// Which temporary directories were already swept in this app run.
final class CLIFolderSweep: @unchecked Sendable {
    static let shared = CLIFolderSweep()

    private let lock = NSLock()
    private var swept: Set<String> = []

    /// True the first time `directory` is claimed.
    func claim(_ directory: String) -> Bool {
        lock.withLock { swept.insert(directory).inserted }
    }
}
