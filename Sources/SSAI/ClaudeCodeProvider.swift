import Foundation
import SSCore

/// Claude through the user's own Claude Code CLI and its sign-in: the verified recipe of cli.md §B.2 (every tool, MCP
/// server, slash command and plugin off, no session kept, one turn, a budget cap), plus none of the user's, project's
/// or local settings (`isolation`: no `env` block, key helper, hooks or plugins of theirs), the request on stdin,
/// `stream-json` parsed by `ClaudeCodeStream`.
///
/// The consent sheet promises Anthropic under the user's Claude plan, so `claude auth status`, asked with the same
/// isolation, must say a claude.ai sign-in to Anthropic's own API (`firstParty`, not Bedrock, Vertex or a gateway)
/// before every send, and the run's own init line must say no API key is in use (`ClaudeCodeStream`).
public struct ClaudeCodeProvider: AIProvider {
    public let kind: AIProviderKind = .claudeCode
    /// The CLI alias (“opus”, “sonnet”, “haiku”); nil passes no `--model`, leaving the CLI's own default.
    let model: String?
    /// The CLI chosen in Settings; nil searches ~/.local/bin, /opt/homebrew/bin, /usr/local/bin.
    let executablePath: String?
    let runner: CLIProcessRunner

    /// 2.1.322 is the version the recipe was verified on (some of its flags, `--max-turns` among them, are not in
    /// older help texts); a 3.x may change the flags or the lines.
    static let tool = CLITool(
        kind: .claudeCode, executableName: "claude", minimum: CLIVersion(2, 1, 322), below: CLIVersion(3),
        environment: [
            "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1",
            "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        ],
        signedOutWords: "Claude Code is signed out. Run claude in Terminal.")

    /// A ceiling per request on what the CLI may spend; a short reply costs a fraction of a cent.
    static let budgetUSD = "0.25"

    /// None of the user's, project's or local settings files, for the run and for `auth status` alike (both are global
    /// options): `--restricted` ignores them and drops the code-running tools, `--setting-sources ""` names no source.
    /// Checked on 2.1.322 with outbound network denied, so nothing left the Mac: a settings `env` block with an API key
    /// made `apiKeySource` read `ANTHROPIC_API_KEY` without these and `none` with either; a user plugin left the init
    /// line; `auth status` stopped reporting a settings file's Bedrock; and the claude.ai sign-in was still found (the
    /// run went on to its request). Managed (policy) settings still apply, as an organisation intends.
    static let isolation = ["--restricted", "--setting-sources", ""]

    public init(model: String?, executablePath: String?, runner: CLIProcessRunner) {
        self.model = model
        self.executablePath = executablePath
        self.runner = runner
    }

    /// The recipe. `instructions` is the app's fixed text, never mail, so argv may carry it; the mail goes to stdin.
    static func arguments(model: String?, instructions: String) -> [String] {
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        if let model, !model.isEmpty { arguments += ["--model", model] }
        arguments += isolation
        arguments += [
            "--tools", "",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--safe-mode", "--disable-slash-commands",
            "--permission-mode", "dontAsk", "--permission-prompts", "none",
            "--no-session-persistence",
            "--max-turns", "1", "--max-budget-usd", budgetUSD,
            "--system-prompt", instructions,
            "--input-format", "text",
        ]
        return arguments
    }

    /// Found, a supported version, and signed in with claude.ai to Anthropic itself. Says how it is signed in, never
    /// who: the email and organisation it prints are not read.
    public func health() async -> AIHealth {
        do {
            let (executable, version) = try await runner.prepare(Self.tool, chosen: executablePath)
            let method = try await Self.signIn(executable, runner: runner)
            return .ready(detail: "Claude Code \(version) · \(method)")
        } catch {
            return CLIHealthWords.health(for: AIError.from(error), tool: Self.tool)
        }
    }

    /// `claude auth status` with the run's isolation, read for whether and how it is signed in: `signedOut`, or
    /// `otherSignIn` when it would send elsewhere than Anthropic's own API (`apiProvider` other than `firstParty`) or with
    /// something other than the user's claude.ai sign-in (an API key, a Console login), which the consent sheet did not
    /// name.
    static func signIn(_ executable: URL, runner: CLIProcessRunner) async throws -> String {
        let status = try await runner.capture(runner.quick(executable, isolation + ["auth", "status"], tool: tool))
        if status.exit.timedOut { throw AIError.timedOut }
        return try signIn(from: status)
    }

    static func signIn(from status: CLICapture) throws -> String {
        guard status.exit.succeeded else { throw AIError.signedOut }
        guard let object = CLIJSON.object(status.stdout) else { throw AIError.badResponse(code: 0) }
        if object["loggedIn"] as? Bool == false { throw AIError.signedOut }
        guard object["apiProvider"] as? String == "firstParty", object["authMethod"] as? String == "claude.ai" else {
            throw AIError.otherSignIn
        }
        return "signed in with claude.ai"
    }

    /// The sign-in is checked right before every send: a Claude Code set to another service since the card opened
    /// sends nothing.
    public func write(_ request: AIWriteRequest) -> AsyncThrowingStream<AIWriteEvent, Error> {
        let runner = runner
        let chosen = executablePath
        let model = request.model ?? model
        return CLIReplyStream.make(ClaudeCodeStream()) {
            let (executable, version) = try await runner.prepare(Self.tool, chosen: chosen)
            _ = try await Self.signIn(executable, runner: runner)
            try Task.checkCancellation()
            let arguments = Self.arguments(model: model, instructions: request.instructions)
            let command = CLICommand(executable: executable, arguments: { _ in arguments }, environment: Self.tool.environment,
                                     input: Data(request.userTurn.utf8), keepFile: nil, idleTimeout: runner.limits.idle,
                                     totalTimeout: min(runner.limits.total, request.deadline))
            return (runner, command, version)
        }
    }
}
