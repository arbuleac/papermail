import Foundation

/// Everything one Help Me Write sends, already built by `WritePrompt` from a `ReplyContext`, a `NewMessageContext` or
/// a `ForwardContext`: providers send `instructions` and `userTurn` and nothing else, so what leaves the Mac is decided
/// here, in PaperCore, where it is tested. It is mail: it is never logged above debug and never placed in an error.
public struct AIWriteRequest: Sendable, Hashable {
    /// What is being written. It has no default: the permission asked of the user and the prompt's version both follow
    /// it, so a request must say which it is. Stays on this Mac.
    public var kind: WriteKind
    /// Paper's fixed instructions (the system prompt). Never contains mail, nor anything the user typed.
    public var instructions: String
    /// What the draft is written from, fenced and redacted: a reply's conversation (`WritePrompt.transcript`), a new
    /// message's subject and To first names, a forward's forwarded message; a selection's rewrite sends the same as a
    /// write of its kind. Empty only for a new message with neither a subject nor names.
    public var transcript: String
    /// The user's part: their instruction, and their notes or the selection to rewrite, fenced (`WritePrompt.task`).
    public var task: String
    /// The model id or CLI alias; nil leaves the choice to the provider (a CLI's own default).
    public var model: String?
    /// The output cap; nil means the provider's own (Anthropic 16,000, which thinking counts toward; OpenAI 4,000).
    public var maxOutputTokens: Int?
    /// The whole write's time budget. `AIWriter` enforces it; providers keep their own shorter idle timeouts.
    public var deadline: Duration
    /// The instructions asked for a first line `Subject: …`, which `AIWriter` takes off the answer and hands on as
    /// `AIWriteEvent.subject`. Only ever true for a new message's full write. Stays on this Mac.
    public var wantsSubject: Bool
    /// The ask was a selection: the answer replaces that part and is never read for a subject line. Stays on this Mac.
    public var isRewrite: Bool
    /// The code on this request's fence lines (`WritePrompt.newFence`), kept so a subject that repeats it is dropped.
    /// It travels only inside `transcript` and `task`.
    public var fence: String
    /// What a rewrite sent of the user's draft around the selection (the DRAFT form), piece by piece, so the writer
    /// reads the answer against it (`WriteRewriteAnswer`): the words it offered to change, and the text an answer must
    /// not repeat. Nil for every other request, the ALONE form included. Stays on this Mac; it travels only inside
    /// `task`.
    public var rewrite: WriteRewriteFrame?

    public init(kind: WriteKind, instructions: String, transcript: String, task: String, model: String? = nil,
                maxOutputTokens: Int? = nil, deadline: Duration = AIWriteRequest.defaultDeadline, wantsSubject: Bool = false,
                isRewrite: Bool = false, fence: String = "", rewrite: WriteRewriteFrame? = nil) {
        self.kind = kind
        self.instructions = instructions
        self.transcript = transcript
        self.task = task
        self.model = model
        self.maxOutputTokens = maxOutputTokens
        self.deadline = deadline
        self.wantsSubject = wantsSubject
        self.isRewrite = isRewrite
        self.fence = fence
        self.rewrite = rewrite
    }

    /// Two minutes: the CLIs' hard limit, and far beyond a short reply on any API.
    public static let defaultDeadline: Duration = .seconds(120)

    /// The prompt's version, for the debug log and tests: always the kind's own, so nothing a new message or a forward
    /// sends is ever logged as the reply's prompt; a rewrite's is its kind's rewrite prompt.
    public var promptVersion: String { isRewrite ? kind.rewritePromptVersion : kind.promptVersion }

    /// Whether the answer is read as a rewrite in the DRAFT form: the part, then a BEFORE or AFTER line for the words
    /// beside it (`WriteRewriteAnswer`). A rewrite that sent the selection alone passes as it comes.
    public var readsRewriteAnswer: Bool { isRewrite && rewrite != nil }

    /// Whether the answer's first line may be a subject line, to be taken off it: a new message's full write, and no
    /// other. Asked for (`wantsSubject`), it becomes the proposed subject; not asked for, a model that sent one anyway
    /// has it dropped rather than shown in the body. A reply, a forward and a rewrite are never read for one, so a
    /// “Subject:” they begin with stays in sight as text.
    public var readsSubjectLine: Bool { kind == .newMessage && !isRewrite }

    /// The single user turn every provider sends: what the draft is written from, then the user's ask. API providers
    /// put it in their user message; CLIs write it to stdin, never to argv.
    public var userTurn: String {
        transcript.isEmpty ? task : transcript + "\n\n" + task
    }
}
