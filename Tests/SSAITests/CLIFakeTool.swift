import Foundation
import XCTest
import SSCore
@testable import SSAI

/// A fake `claude` or `codex`: a `#!/bin/sh` script written at test time into a throwaway folder that stands in for
/// ~/.local/bin. It records what it was given (argv one file per argument, the environment, the working folder, its
/// mode and contents, stdin) and replays a recorded fixture, so tests see exactly what the real CLI would be handed
/// without running it.
final class CLIFakeTool {
    /// The test's own folder; everything below lives in it and goes with it.
    let root: URL
    /// The first search folder (~/.local/bin's stand-in).
    let bin: URL
    /// The second and third (/opt/homebrew/bin, /usr/local/bin).
    let otherBins: [URL]
    /// The runner's temporary directory: run folders appear and must disappear here.
    let temporary: URL
    /// What the script records.
    let spy: URL
    let home: URL

    init() throws {
        // The real path (/private/var/…, not /var/…), as the fake's `pwd -P` reports it.
        let temporaryRoot = URL(fileURLWithPath: Self.realPath(FileManager.default.temporaryDirectory.path), isDirectory: true)
        root = temporaryRoot.appendingPathComponent("ssai-cli-tests-\(UUID().uuidString)", isDirectory: true)
        bin = root.appendingPathComponent("local-bin", isDirectory: true)
        otherBins = [root.appendingPathComponent("homebrew-bin", isDirectory: true),
                     root.appendingPathComponent("usr-local-bin", isDirectory: true)]
        temporary = root.appendingPathComponent("tmp", isDirectory: true)
        spy = root.appendingPathComponent("spy", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        for folder in [bin, temporary, spy, home] + otherBins {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Sweeping is once per directory and test run; this test's directory is new, so claim it as swept.
        _ = CLIFolderSweep.shared.claim(temporary.standardizedFileURL.path)
    }

    /// Symlinks resolved, /private kept (`URL.resolvingSymlinksInPath()` drops it).
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static let fastLimits = CLILimits(idle: .seconds(10), total: .seconds(20), killGrace: .milliseconds(300),
                                      drain: .milliseconds(300), quick: .seconds(10), stderrBytes: 8 * 1024,
                                      captureBytes: 1 << 20)

    func runner(limits: CLILimits = CLIFakeTool.fastLimits) -> CLIProcessRunner {
        CLIProcessRunner(temporaryDirectory: temporary, limits: limits,
                         base: CLIBaseEnvironment(home: home.path, user: "someone", language: "en_US.UTF-8"),
                         searchFolders: [bin] + otherBins)
    }

    // MARK: Writing the fake

    /// What the fake does for each way it is called. Each snippet is shell that ends the script (`exit N`).
    struct Behaviour {
        var version = "printf '%s\\n' '2.1.322 (Claude Code)'; exit 0"
        var authStatus = "exit 0"
        var loginStatus = "exit 0"
        var featuresList = "exit 0"
        /// The run itself (`-p …` or `exec …`), after the script has recorded argv, env, cwd and stdin.
        var main = "exit 0"
        /// Recording stdin reads it to the end first; false leaves it unread.
        var readsInput = true
    }

    @discardableResult
    func install(_ name: String, in folder: URL? = nil, _ behaviour: Behaviour) throws -> URL {
        let spy = Self.quoted(self.spy.path)
        let input = behaviour.readsInput ? "/bin/cat > \(spy)/stdin" : ": unread"
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(spy)/invocations
        # Claude Code's global isolation options come before a subcommand (`--restricted --setting-sources "" auth status`).
        while :; do
          case "$1" in
            --restricted) shift ;;
            --setting-sources) shift 2 ;;
            *) break ;;
          esac
        done
        printf '%s %s\\n' "$1" "$2" >> \(spy)/calls
        case "$1" in
          --version) \(behaviour.version) ;;
        esac
        case "$1 $2" in
          "auth status") \(behaviour.authStatus) ;;
          "login status") \(behaviour.loginStatus) ;;
          "features list") \(behaviour.featuresList) ;;
        esac
        i=0
        for argument in "$@"; do
          i=$((i + 1))
          printf '%s' "$argument" > \(spy)/arg.$i
        done
        printf '%s' "$i" > \(spy)/argc
        /usr/bin/env > \(spy)/env
        pwd -P > \(spy)/cwd
        /usr/bin/stat -f %Lp . > \(spy)/mode
        /bin/ls -A . > \(spy)/listing
        \(input)
        \(behaviour.main)

        """
        let url = (folder ?? bin).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Replays a recorded stdout (and stderr) and exits with `status`.
    static func replay(_ fixture: String, stderr: String? = nil, status: Int32 = 0) -> String {
        var shell = "/bin/cat \(quoted(FixtureFiles.url(fixture).path))"
        if let stderr { shell += "; /bin/cat \(quoted(FixtureFiles.url(stderr).path)) >&2" }
        return shell + "; exit \(status)"
    }

    /// Replays a recorded Claude Code run as `FixtureFiles.isolatedClaude` gives it (the user's own plugin left out, as
    /// `--setting-sources ""` does), with the recorded stderr, and exits with `status`.
    func replayIsolated(_ fixture: String, stderr: String? = nil, status: Int32 = 0) throws -> String {
        var shell = "/bin/cat \(Self.quoted(try isolatedCopy(fixture).path))"
        if let stderr { shell += "; /bin/cat \(Self.quoted(FixtureFiles.url(stderr).path)) >&2" }
        return shell + "; exit \(status)"
    }

    /// `FixtureFiles.isolatedClaude(fixture)` as a file in the test's folder, for a fake to print.
    func isolatedCopy(_ fixture: String) throws -> URL {
        let copy = root.appendingPathComponent("isolated-" + (fixture as NSString).lastPathComponent)
        try Data(try FixtureFiles.isolatedClaude(fixture).utf8).write(to: copy)
        return copy
    }

    /// Prints `lines` (JSON written by the test) and exits with `status`.
    static func emit(_ lines: [String], status: Int32 = 0) -> String {
        lines.map { "printf '%s\\n' \(quoted($0))" }.joined(separator: "; ") + "; exit \(status)"
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Reading what it recorded

    /// The main run's argv, in order (the executable itself excluded).
    func arguments() throws -> [String] {
        let count = Int(try String(contentsOf: spy.appendingPathComponent("argc"), encoding: .utf8)) ?? 0
        return try (0..<count).map { try String(contentsOf: spy.appendingPathComponent("arg.\($0 + 1)"), encoding: .utf8) }
    }

    func environment() throws -> [String: String] {
        let text = try String(contentsOf: spy.appendingPathComponent("env"), encoding: .utf8)
        var environment: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            environment[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return environment
    }

    func recorded(_ name: String) -> String? {
        try? String(contentsOf: spy.appendingPathComponent(name), encoding: .utf8)
    }

    /// `$1 $2` of every call, in order: "--version ", "auth status", "-p --output-format", "exec --json"…
    func calls() -> [String] {
        (recorded("calls") ?? "").split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Every call's whole argv, joined by spaces (an empty argument shows as two spaces), in order.
    func invocations() -> [String] {
        (recorded("invocations") ?? "").split(separator: "\n").map(String.init)
    }

    /// The run folders still in the runner's temporary directory.
    func leftoverFolders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
    }

    /// Waits until `condition` holds, up to `timeout`.
    func wait(timeout: TimeInterval = 5, for condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

/// Collects a provider's stream.
func collectCLIWrite(_ stream: AsyncThrowingStream<AIWriteEvent, Error>) async -> (events: [AIWriteEvent], error: Error?) {
    var events: [AIWriteEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}
