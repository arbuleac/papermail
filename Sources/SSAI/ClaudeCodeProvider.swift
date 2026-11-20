import Foundation
import SSCore

/// Claude through the user's own Claude Code CLI and its sign-in: the verified recipe of cli.md §B.2 (every tool, MCP
/// server, slash command and plugin off, no session kept, one turn, a budget cap), the request on stdin, `stream-json`
/// parsed by `ClaudeCodeStream`.
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

    public init(model: String?, executablePath: String?, runner: CLIProcessRunner) {
        self.model = model
        self.executablePath = executablePath
        self.runner = runner
    }

    /// The recipe. `instructions` is the app's fixed text, never mail, so argv may carry it; the mail goes to stdin.
    static func arguments(model: String?, instructions: String) -> [String] {
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        if let model, !model.isEmpty { arguments += ["--model", model] }
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

    /// Found, a supported version, and signed in (`claude auth status` exits 0). Says how it is signed in, never who:
    /// the email and organisation it prints are not read.
    public func health() async -> AIHealth {
        do {
            let (executable, version) = try await runner.prepare(Self.tool, chosen: executablePath)
            let status = try await runner.capture(runner.quick(executable, ["auth", "status"], tool: Self.tool))
            if status.exit.timedOut { throw AIError.timedOut }
            guard let method = Self.signIn(from: status) else { throw AIError.signedOut }
            return .ready(detail: "Claude Code \(version) · \(method)")
        } catch {
            return CLIHealthWords.health(for: AIError.from(error), tool: Self.tool)
        }
    }

    static func signIn(from status: CLICapture) -> String? {
        guard status.exit.succeeded else { return nil }
        let object = CLIJSON.object(status.stdout)
        if object?["loggedIn"] as? Bool == false { return nil }
        return object?["authMethod"] as? String == "claude.ai" ? "signed in with claude.ai" : "signed in"
    }

    /// Signed out needs no check first: Claude Code then fails locally, before any request leaves the Mac.
    public func write(_ request: AIWriteRequest) -> AsyncThrowingStream<AIWriteEvent, Error> {
        let runner = runner
        let chosen = executablePath
        let model = request.model ?? model
        return CLIReplyStream.make(ClaudeCodeStream()) {
            let (executable, version) = try await runner.prepare(Self.tool, chosen: chosen)
            let arguments = Self.arguments(model: model, instructions: request.instructions)
            let command = CLICommand(executable: executable, arguments: { _ in arguments }, environment: Self.tool.environment,
                                     input: Data(request.userTurn.utf8), keepFile: nil, idleTimeout: runner.limits.idle,
                                     totalTimeout: min(runner.limits.total, request.deadline))
            return (runner, command, version)
        }
    }
}
