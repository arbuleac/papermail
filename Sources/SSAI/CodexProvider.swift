import Foundation
import SSCore

/// GPT through the user's own Codex CLI and its ChatGPT sign-in (`codex exec --json --ephemeral …`, every tool and
/// feature off). Codex delivers the whole message at the end, as `.replaceAll`.
///
/// STUB (step 1 of the build): compiles under its final name and initializer so the factory, the app and the tests
/// can be written against it. The CLI track replaces the body: finding the CLI, health (`codex --version`, `codex login
/// status`, `codex features list`), the login check again right before every send, the verified recipe through
/// `CLIProcessRunner`, JSONL parsing with `JSONLineReader`, and the error mapping to `AIError`.
public struct CodexProvider: AIProvider {
    public let kind: AIProviderKind = .codex
    /// The model id; nil passes no `-m`, leaving the CLI's own default.
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
