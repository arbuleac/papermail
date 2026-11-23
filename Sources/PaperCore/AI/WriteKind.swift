import Foundation

/// What a Help Me Write request writes. A closed set, because three things turn on it and none may be guessed: which
/// fixed instructions the model reads (and so which prompt version the log names), which permission the user must have
/// given in Settings › AI, and whether the answer's first line is read as a subject.
public enum WriteKind: String, Sendable, Hashable, CaseIterable {
    /// A reply (the quick reply, a reply or reply-all composer), written from the conversation it answers.
    case reply
    /// A new message, written from the user's brief alone. A forward whose forwarded message is not there to read is
    /// written the same way, so it is this kind too.
    case newMessage
    /// The message above a forwarded one, written from that one message as the composer holds it.
    case forward

    /// The version of this kind's prompt, for the debug log, tests and a bug report. Never sent to a provider.
    public var promptVersion: String {
        switch self {
        case .reply: return WritePrompt.version
        case .newMessage: return WritePrompt.newMessageVersion
        case .forward: return WritePrompt.forwardVersion
        }
    }

    /// Whether a write of this kind would have nothing to write from: such a write never sends. A reply has its
    /// conversation and a forward its forwarded message; a new message has only what the user gave, so it needs notes,
    /// a selection or an instruction that still says something once cleaned. A subject alone is not a brief, and
    /// neither are the recipients' names: neither is asked about here.
    ///
    /// With `ask.instruction` left empty this is also the test of whether ⌘J can write at once in the field as it
    /// stands, or has to ask what to write.
    public func hasNothingToWriteFrom(_ ask: WriteAsk) -> Bool {
        switch self {
        case .reply, .forward: return false
        case .newMessage: return !ReplyContextBuilder.cleaned(ask, limit: .max).hasBrief
        }
    }

    /// The part of `ask` that is longer than Help Me Write sends, as the failure to show; nil when all of it can go.
    /// Notes and a selection are refused whole for every kind: the draft would replace all of them, having read only a
    /// part. So is a new message's or a forward's instruction, which can be the whole brief; a reply's is still cut to
    /// the limit, as it always was.
    public func lengthRefusal(of ask: WriteAsk, limits: ReplyContextBuilder.Limits = .standard) -> AIError? {
        switch ask.draft {
        case .selection(let part) where ReplyContextBuilder.exceedsAskLimit(part, limits: limits):
            return .tooLong(selection: true)
        case .notes(let part) where ReplyContextBuilder.exceedsAskLimit(part, limits: limits):
            return .tooLong(selection: false)
        default:
            break
        }
        if self != .reply, ReplyContextBuilder.exceedsAskLimit(ask.instruction, limits: limits) { return .instructionTooLong }
        return nil
    }
}
