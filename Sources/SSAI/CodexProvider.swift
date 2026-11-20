import Foundation
import SSCore

/// GPT through the user's own Codex CLI and its ChatGPT sign-in: the recipe of cli.md §C.2 plus SPEC §4b (user config,
/// rules, project docs, MCP, web search, history and every tool feature off; no environment, permissions, apps or
/// skills text in the prompt), the request on stdin, our instructions as `developer_instructions`. Codex delivers the
/// whole message at the end, as `.replaceAll`.
///
/// Signed out, `codex exec` still uploads the prompt and retries for about 17 seconds, so `codex login status` is
/// checked right before every send and nothing is sent without it.
public struct CodexProvider: AIProvider {
    public let kind: AIProviderKind = .codex
    /// The model id; nil passes no `-m`, leaving the CLI's own default.
    let model: String?
    /// The CLI chosen in Settings; nil searches ~/.local/bin, /opt/homebrew/bin, /usr/local/bin.
    let executablePath: String?
    let runner: CLIProcessRunner

    /// 0.163.0 is the version the recipe was verified on; a 1.x may change `exec --json`. Newer 0.x versions run if
    /// `features list` still names every feature the recipe turns off.
    static let tool = CLITool(kind: .codex, executableName: "codex", minimum: CLIVersion(0, 163, 0), below: CLIVersion(1),
                              environment: [:], signedOutWords: "Codex is signed out. Run codex login in Terminal.")

    /// Every feature that gives the model a tool, turned off per run (`--disable`; never `codex features disable`,
    /// which edits the user's config). An unknown name makes `exec` fail, so `features list` is checked first.
    static let disabledFeatures = [
        "shell_tool", "unified_exec", "view_image", "apps", "plugins", "remote_plugin", "hooks", "memories",
        "multi_agent", "image_generation", "browser_use", "browser_use_external", "in_app_browser", "computer_use",
        "goals", "tool_suggest", "skill_search", "sleep_tool", "shell_snapshot", "workspace_dependencies",
        "realtime_conversation",
    ]

    /// Codex writes the final message here too: the reply when no `agent_message` line came through.
    static let lastMessageFile = "last-message.txt"

    public init(model: String?, executablePath: String?, runner: CLIProcessRunner) {
        self.model = model
        self.executablePath = executablePath
        self.runner = runner
    }

    /// The recipe. `instructions` is the app's fixed text, never mail, so argv may carry it; the mail goes to stdin
    /// (the final `-`).
    static func arguments(model: String?, instructions: String, folder: URL) -> [String] {
        var arguments = [
            "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
            "--strict-config", "-C", folder.path, "-s", "read-only",
        ]
        if let model, !model.isEmpty { arguments += ["-m", model] }
        let settings = [
            #"model_reasoning_effort="low""#,
            #"web_search="disabled""#,
            "mcp_servers={}",
            "project_doc_max_bytes=0",
            #"approval_policy="never""#,
            "analytics.enabled=false",
            "feedback.enabled=false",
            "check_for_update_on_startup=false",
            #"history.persistence="none""#,
            #"otel.exporter="none""#,
            #"shell_environment_policy.inherit="none""#,
            "include_environment_context=false",
            "include_permissions_instructions=false",
            "include_apps_instructions=false",
            "skills.include_instructions=false",
            "developer_instructions=" + tomlString(instructions),
        ]
        for setting in settings { arguments += ["-c", setting] }
        for feature in disabledFeatures { arguments += ["--disable", feature] }
        arguments += ["--output-last-message", folder.appendingPathComponent(lastMessageFile).path, "-"]
        return arguments
    }

    /// A TOML basic string, which is how `-c key=value` reads its value.
    static func tomlString(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            case "\u{08}": quoted += "\\b"
            case "\u{0C}": quoted += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    quoted += String(format: "\\u%04X", scalar.value)
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        return quoted + "\""
    }

    /// Found, a supported version whose features list names every disabled feature, and signed in.
    public func health() async -> AIHealth {
        do {
            let (executable, version) = try await prepare(runner, chosen: executablePath)
            let method = try await Self.signIn(executable, runner: runner)
            return .ready(detail: "Codex \(version) · \(method)")
        } catch {
            return CLIHealthWords.health(for: AIError.from(error), tool: Self.tool)
        }
    }

    public func write(_ request: AIWriteRequest) -> AsyncThrowingStream<AIWriteEvent, Error> {
        let runner = runner
        let chosen = executablePath
        let model = request.model ?? model
        let provider = self
        return CLIReplyStream.make(CodexStream()) {
            let (executable, version) = try await provider.prepare(runner, chosen: chosen)
            // Right before the send: signed out, nothing goes.
            _ = try await Self.signIn(executable, runner: runner)
            try Task.checkCancellation()
            let instructions = request.instructions
            let command = CLICommand(
                executable: executable,
                arguments: { folder in Self.arguments(model: model, instructions: instructions, folder: folder) },
                environment: Self.tool.environment, input: Data(request.userTurn.utf8), keepFile: Self.lastMessageFile,
                idleTimeout: runner.limits.idle, totalTimeout: min(runner.limits.total, request.deadline))
            return (runner, command, version)
        }
    }

    private func prepare(_ runner: CLIProcessRunner, chosen: String?) async throws -> (URL, CLIVersion) {
        try await runner.prepare(Self.tool, chosen: chosen) { executable, version in
            try await Self.checkFeatures(executable, version: version, runner: runner)
        }
    }

    /// Every feature the recipe disables must still exist under that name in this version.
    static func checkFeatures(_ executable: URL, version: CLIVersion, runner: CLIProcessRunner) async throws {
        let listing = try await runner.capture(runner.quick(executable, ["features", "list"], tool: tool))
        if listing.exit.timedOut { throw AIError.timedOut }
        guard listing.exit.succeeded, Set(disabledFeatures).isSubset(of: featureNames(in: listing.text)) else {
            throw AIError.unsupportedVersion(found: version.description)
        }
    }

    /// The first column of `features list` (`name  stage  effective`).
    static func featureNames(in listing: String) -> Set<String> {
        Set(listing.split(whereSeparator: \.isNewline).compactMap { line in
            line.split(whereSeparator: \.isWhitespace).first.map(String.init)
        })
    }

    /// `codex login status` exits 0 when signed in. Its words are read only to say whether that is with ChatGPT; with an
    /// API key it also prints part of the key, which goes nowhere.
    static func signIn(_ executable: URL, runner: CLIProcessRunner) async throws -> String {
        let status = try await runner.capture(runner.quick(executable, ["login", "status"], tool: tool))
        if status.exit.timedOut { throw AIError.timedOut }
        guard status.exit.succeeded else { throw AIError.signedOut }
        let said = status.text + String(decoding: status.exit.stderr, as: UTF8.self)
        return said.range(of: "chatgpt", options: .caseInsensitive) != nil ? "signed in with ChatGPT" : "signed in"
    }
}
