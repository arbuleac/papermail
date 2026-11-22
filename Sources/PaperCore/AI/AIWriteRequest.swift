import Foundation

/// Everything one Help Me Write sends, already built by `WritePrompt` from a `ReplyContext`: providers send these
/// fields and nothing else, so what leaves the Mac is decided here, in PaperCore, where it is tested. It is mail: it is
/// never logged above debug and never placed in an error.
public struct AIWriteRequest: Sendable, Hashable {
    /// Paper's fixed instructions (the system prompt). Never contains mail.
    public var instructions: String
    /// The fenced, redacted conversation (`WritePrompt.transcript`).
    public var transcript: String
    /// The user's part: their instruction, and their notes or the selection to rewrite, fenced (`WritePrompt.task`).
    public var task: String
    /// The model id or CLI alias; nil leaves the choice to the provider (a CLI's own default).
    public var model: String?
    /// The output cap; nil means the provider's own (Anthropic 16,000, which thinking counts toward; OpenAI 4,000).
    public var maxOutputTokens: Int?
    /// The whole write's time budget. `AIWriter` enforces it; providers keep their own shorter idle timeouts.
    public var deadline: Duration
    /// The prompt's version (`WritePrompt.version`), for the debug log and tests.
    public var promptVersion: String

    public init(instructions: String, transcript: String, task: String, model: String? = nil, maxOutputTokens: Int? = nil,
                deadline: Duration = AIWriteRequest.defaultDeadline, promptVersion: String = WritePrompt.version) {
        self.instructions = instructions
        self.transcript = transcript
        self.task = task
        self.model = model
        self.maxOutputTokens = maxOutputTokens
        self.deadline = deadline
        self.promptVersion = promptVersion
    }

    /// Two minutes: the CLIs' hard limit, and far beyond a short reply on any API.
    public static let defaultDeadline: Duration = .seconds(120)

    /// The single user turn every provider sends: the conversation, then the user's ask. API providers put it in
    /// their user message; CLIs write it to stdin, never to argv.
    public var userTurn: String {
        transcript + "\n\n" + task
    }
}
