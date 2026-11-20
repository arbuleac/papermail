import Foundation
import SSCore

/// Claude through the user's own Claude Code CLI and its sign-in (`claude -p --output-format stream-json …`, every
/// tool off, no session kept).
///
/// STUB (step 1 of the build): compiles under its final name and initializer so the factory, the app and the tests
/// can be written against it. The CLI track replaces the body: finding the CLI, health (`claude --version`, `claude auth
/// status`), the verified recipe through `CLIProcessRunner`, `stream-json` parsing with `JSONLineReader`, and the error
/// mapping to `AIError`.
public struct ClaudeCodeProvider: AIProvider {
    public let kind: AIProviderKind = .claudeCode
    /// The CLI alias (“opus”, “sonnet”, “haiku”); nil passes no `--model`, leaving the CLI's own default.
    let model: String?
    /// The CLI chosen in Settings; nil searches ~/.local/bin, /opt/homebrew/bin, /usr/local/bin.
    let executablePath: String?
    let runner: CLIProcessRunner

    public init(model: String?, executablePath: String?, runner: CLIProcessRunner) {
        self.model = model
        self.executablePath = executablePath
        self.runner = runner
    }

    public func health() async -> AIHealth {
        .unavailable(reason: "Not built yet")
    }

    public func write(_ request: AIWriteRequest) -> AsyncThrowingStream<AIWriteEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIError.unavailable) }
    }
}
