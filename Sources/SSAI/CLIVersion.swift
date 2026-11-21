import Foundation
import SSCore

/// A CLI's version as it prints it (`2.1.322 (Claude Code)`, `codex-cli 0.163.0`): the first dotted number.
struct CLIVersion: Sendable, Comparable, Hashable, CustomStringConvertible {
    let components: [Int]

    init(_ components: Int...) {
        self.components = components
    }

    /// The first run of at least two dot-separated numbers in `text`; nil when there is none.
    init?(parsing text: String) {
        let characters = Array(text.unicodeScalars.prefix(4_096))
        func isDigit(_ index: Int) -> Bool {
            index < characters.count && ("0"..."9").contains(characters[index])
        }
        var index = 0
        while index < characters.count {
            guard isDigit(index) else {
                index += 1
                continue
            }
            var parts: [Int] = []
            var number = ""
            while index < characters.count {
                if isDigit(index) {
                    number.unicodeScalars.append(characters[index])
                } else if characters[index] == ".", !number.isEmpty, isDigit(index + 1) {
                    parts.append(Int(number.prefix(9)) ?? 0)
                    number = ""
                } else {
                    break
                }
                index += 1
            }
            parts.append(Int(number.prefix(9)) ?? 0)
            if parts.count >= 2 {
                self.components = parts
                return
            }
        }
        return nil
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    /// Missing components count as zero: 3 == 3.0.0.
    private var trimmed: [Int] {
        var components = components
        while components.last == 0 { components.removeLast() }
        return components
    }

    static func == (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
        lhs.trimmed == rhs.trimmed
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(trimmed)
    }

    static func < (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// What a provider needs to know about its CLI: its name, the versions this build was tested with, and the variables
/// it runs with (cli.md).
struct CLITool: Sendable {
    let kind: AIProviderKind
    let executableName: String
    /// At least this version: the recipe's flags were verified on it.
    let minimum: CLIVersion
    /// Below this one: a new major version may change the flags or the JSON lines.
    let below: CLIVersion
    let environment: [String: String]
    /// Settings' status line when the sign-in check fails (SPEC §2).
    let signedOutWords: String
    /// Versions inside the tested range that still hand the model a tool under the recipe, so they never run: the
    /// recipe promises a reply written from what was sent and nothing else (no command, no file of this Mac, no agent).
    var keepsToolsOn: [Range<CLIVersion>] = []

    func supports(_ version: CLIVersion) -> Bool {
        version >= minimum && version < below
    }

    /// Why `version` cannot run the recipe: too old (an update helps), too new (it does not), or one whose tools the
    /// recipe cannot turn off; nil when it can.
    func refusal(of version: CLIVersion) -> AIError? {
        if version < minimum { return .unsupportedVersion(found: version.description) }
        if version >= below { return .newerVersion(found: version.description) }
        if keepsToolsOn.contains(where: { $0.contains(version) }) { return .toolsStayOn(found: version.description) }
        return nil
    }
}

/// Version checks per executable file, so a write does not run `--version` (and Codex's `features list`) again until
/// the file changes, as an update does: a new version is a new file.
final class CLIToolCache: @unchecked Sendable {
    struct Identity: Hashable, Sendable {
        let path: String
        let fileNumber: UInt64
        let size: UInt64
        let modified: Double
    }

    enum Verdict: Sendable, Equatable {
        case supported(CLIVersion)
        /// Too old, too new, or keeping its tools on (`AIError.unsupportedVersion`, `.newerVersion`, `.toolsStayOn`).
        case refused(AIError)
    }

    private let lock = NSLock()
    private var verdicts: [Identity: Verdict] = [:]

    func verdict(for identity: Identity) -> Verdict? {
        lock.withLock { verdicts[identity] }
    }

    func remember(_ verdict: Verdict, for identity: Identity) {
        lock.withLock { verdicts[identity] = verdict }
    }

    /// The file the path leads to (symlinks followed: ~/.local/bin/claude points into a folder per version).
    static func identity(of executable: URL) -> Identity? {
        let path = executable.resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return Identity(path: path,
                        fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                        size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                        modified: (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)
    }
}

extension CLIProcessRunner {
    /// Finds `tool`'s executable and checks its version, plus `verify` (Codex's feature names), once per executable
    /// file. Throws `notInstalled`, `unsupportedVersion(found:)`, `newerVersion(found:)` or `toolsStayOn(found:)`
    /// (remembered until the file changes), or what running `--version` threw (not remembered: it may pass next time).
    func prepare(_ tool: CLITool, chosen: String?, action: AIUserAction,
                 verify: (@Sendable (URL, CLIVersion) async throws -> Void)? = nil) async throws -> (URL, CLIVersion) {
        guard let executable = locate(tool.executableName, chosen: chosen) else { throw AIError.notInstalled }
        let identity = CLIToolCache.identity(of: executable)
        if let identity, let verdict = cache.verdict(for: identity) {
            switch verdict {
            case .supported(let version): return (executable, version)
            case .refused(let error): throw error
            }
        }
        let printed = try await capture(quick(executable, ["--version"], tool: tool, action: action))
        if printed.exit.timedOut { throw AIError.timedOut }
        guard printed.exit.succeeded, let version = CLIVersion(parsing: printed.text) else {
            throw AIError.badResponse(code: printed.exit.code)
        }
        do {
            if let refusal = tool.refusal(of: version) { throw refusal }
            try await verify?(executable, version)
        } catch let error as AIError where error.isVersionVerdict {
            if let identity { cache.remember(.refused(error), for: identity) }
            throw error
        }
        if let identity { cache.remember(.supported(version), for: identity) }
        return (executable, version)
    }
}

extension AIError {
    /// A verdict on the CLI's version, kept until its file changes.
    var isVersionVerdict: Bool {
        switch self {
        case .unsupportedVersion, .newerVersion, .toolsStayOn: return true
        default: return false
        }
    }
}

extension CLIProcessRunner {
    /// What this Mac shows of `tool` without running it (spec §3b): where it is, and its version when an earlier check
    /// found it or the file's real path names it (~/.local/bin/claude leads to …/claude/versions/2.1.322, Homebrew's
    /// codex to …/Caskroom/codex/0.163.0/bin/codex). Never starts a process: `--version` is a launch, and launches wait
    /// for the user's Write or Check. Nil when the CLI is not found.
    func localState(_ tool: CLITool, chosen: String?) -> (executable: URL, verdict: CLIToolCache.Verdict?)? {
        guard let executable = locate(tool.executableName, chosen: chosen) else { return nil }
        if let identity = CLIToolCache.identity(of: executable), let verdict = cache.verdict(for: identity) {
            return (executable, verdict)
        }
        guard let version = Self.version(inPathOf: executable) else { return (executable, nil) }
        if let refusal = tool.refusal(of: version) { return (executable, .refused(refusal)) }
        return (executable, .supported(version))
    }

    /// The last folder or file name on the CLI's real path that is a version and nothing else (“2.1.322”).
    static func version(inPathOf executable: URL) -> CLIVersion? {
        for component in executable.resolvingSymlinksInPath().pathComponents.reversed() {
            guard component.first?.isNumber == true, component.allSatisfy({ $0.isNumber || $0 == "." }),
                  let version = CLIVersion(parsing: component), version.description == component else { continue }
            return version
        }
        return nil
    }
}

/// The shared parts of a CLI provider's status line.
enum CLIHealthWords {
    /// The status from this Mac alone (`CLIProcessRunner.localState`): not found, a version this build refuses, or found
    /// (with its version when known). Whether it is signed in is learnt only by Check or Write.
    static func local(_ tool: CLITool, chosen: String?, runner: CLIProcessRunner) -> AIHealth {
        guard let state = runner.localState(tool, chosen: chosen) else {
            return .needsSetup(reason: AIHealth.notFoundWords(for: tool.kind))
        }
        switch state.verdict {
        case .refused(let error)?:
            return health(for: error, tool: tool)
        case .supported(let version)?:
            return .ready(detail: "\(tool.kind.displayName) \(version) found")
        case nil:
            return .ready(detail: "\(tool.kind.displayName) found")
        }
    }

    /// What Settings › AI says when a check failed with `error`.
    static func health(for error: AIError, tool: CLITool) -> AIHealth {
        switch error {
        case .notInstalled:
            return .needsSetup(reason: AIHealth.notFoundWords(for: tool.kind))
        case .signedOut:
            return .needsSetup(reason: tool.signedOutWords)
        case .unsupportedVersion, .newerVersion, .toolsStayOn, .otherSignIn:
            return .needsSetup(reason: error.message(for: tool.kind))
        default:
            return .unavailable(reason: error.message(for: tool.kind))
        }
    }
}

/// What a CLI wrote to stderr, searched for words that explain a failure. The text itself is never kept or shown.
enum CLIStderr {
    /// The CLI rejected a flag, a feature name or a config key: this build's recipe does not fit that version.
    static func rejectsArguments(_ stderr: Data) -> Bool {
        let text = String(decoding: stderr, as: UTF8.self).lowercased()
        return ["unknown option", "unexpected argument", "unknown feature flag", "unrecognized subcommand",
                "unknown configuration", "unknown field", "unknown variant"].contains { text.contains($0) }
    }
}
