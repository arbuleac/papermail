import AppKit
import PaperCore

/// A text view Help Me Write writes into (spec §5.56): the quick reply's field or a composer's body. The owners answer
/// what differs between them (whose text is the user's, the host's height, what is written there and from what);
/// `WriteSession` and its marks in the text (`WriteInlineLayer`) do the rest the same way for all.
@MainActor
protocol WriteField: AnyObject {
    /// The text view the reply goes into. Its identity is the writer's field (`AIFieldID`).
    var writeTextView: NSTextView { get }
    /// What a write here writes now: a reply, a new message, or the message above a forwarded one. The words, the
    /// chips and what ⌘J does on an empty field follow it, and so does the permission it needs
    /// (`HelpMeWrite.availability(for:)`): a Turn On given for replies makes no other field ready. A forward whose
    /// forwarded message is not there to read is written as a new message is, so it answers `.newMessage`.
    var writeKind: WriteKind { get }
    /// The field as Analytics names what is composed in it (`kind`): `reply` or `replyAll`, `new`, `forward`. Never
    /// `draft`: a kept draft opened again is written in as what it is.
    var analyticsKind: AnalyticsSignal.ComposeKind { get }
    /// The user's own text: the quick reply's whole text; a composer's body above its signature (the quoted original is
    /// never in the text). Sent as their notes and replaced by the reply.
    var ownTextRange: NSRange { get }
    /// The attributes the reply's text takes at `range`: the field's writing style, never a signature's or a picture's mark.
    func writeAttributes(at range: NSRange) -> [NSAttributedString.Key: Any]
    /// While a write streams the field refuses the user's own edits, so the stream and typing never interleave.
    var refusesEdits: Bool { get set }
    /// The stream changed the text without an edit being reported: the field takes its new height.
    func streamDidUpdate()
    /// Why only a selection can be rewritten here now, in the words ⌘J shows under the caret's line; nil where a whole
    /// draft can be written. A forward whose forwarded message is still loading, and a body the composer cannot tell
    /// the user's words from quoted mail in: there is no ghost there, and ⌘J without a selection sends nothing.
    var selectionOnlyReason: String? { get }
    /// What the write is made from, read now on the main thread, as the user asks and never before (the request is
    /// built from it off the main thread); nil when the field can be written in no more (a send has taken it).
    func writeContext() -> WriteContextInputs?
    /// A draft landed with a subject for its message: the owner sets it, if it still takes one, as part of the draft's
    /// one undo step. Called inside that step's open group on `undo`, where the owner registers the inverse. False when
    /// nothing was set (the field has no Subject, or the user has typed one since).
    func commitSubject(_ subject: String, undo: UndoManager?) -> Bool
    /// Help me write's marks in the text, made by the field's owner with its text view.
    var writeLayer: WriteInlineLayer { get }
    /// The quick reply's placeholder (“Reply to Sam…”) shows on its empty text: the ghost follows its words, this far
    /// after the caret. nil where there is none (a composer's body).
    var placeholderWidth: CGFloat? { get }
    /// A reserved block (the prompt line, the afterline) opened, closed or moved: the owner lays the field out again, its
    /// height grown by the block's `overflow`.
    func reservedSpaceDidChange()
    /// The quick reply stays open around its text while the prompt line or a write holds it, though the keyboard may be in
    /// the prompt line; a composer is always open.
    func setHeldOpen(_ held: Bool)
    /// Puts the keyboard in the text.
    func focusText()
}

extension WriteField {
    /// A field whose whole text is the user's own and always there to write from.
    var selectionOnlyReason: String? { nil }

    /// A field with no Subject of its own takes none.
    func commitSubject(_ subject: String, undo: UndoManager?) -> Bool { false }
}

/// What a write is made from, as the field's owner holds it when the user asks. Read on the main thread at that moment;
/// `request(for:configuration:)` turns it into the finished request off it, so the session starts every kind of write
/// the same way, from one place.
enum WriteContextInputs: Sendable {
    /// A reply: the conversation it answers, whose bodies are read from the store.
    case reply(ReplyWriteInputs)
    /// A new message or a forward: plain values the composer window itself holds, and nothing read from anywhere else.
    case composed(ComposeWriteInputs)

    /// What the request will write. A forward whose forwarded message is not in hand is a new message here.
    var kind: WriteKind {
        switch self {
        case .reply: return .reply
        case .composed(let inputs): return inputs.kind
        }
    }

    /// Whether a write of `ask` asks for a subject with its draft: a new message the composer would take one for, its
    /// Subject empty by Send's own test, and never a selection's rewrite. Known as the write starts, so Analytics can
    /// say one was asked for; `AIWriteRequest.wantsSubject`, built later from the same values, says the same.
    func wantsSubject(for ask: WriteAsk) -> Bool {
        guard case .composed(let inputs) = self, inputs.kind == .newMessage, inputs.wantsSubject, !ask.isRewrite else { return false }
        return inputs.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The whole request for `ask`; nil when nothing may be sent (a new message with nothing to write from, a part of
    /// the ask too long to send). Reads stored bodies and redacts: off the main thread.
    func request(for ask: WriteAsk, configuration: AIProviderConfiguration) -> AIWriteRequest? {
        switch self {
        case .reply(let inputs):
            return WritePrompt.request(for: inputs.build(ask: ask), appendsSignature: inputs.appendsSignature, configuration: configuration)
        case .composed(let inputs):
            return inputs.request(for: ask, configuration: configuration)
        }
    }
}

/// The conversation a reply answers, as the field's owner knows it: everything `ReplyContextBuilder` reads, so the
/// bodies can be read and redacted off the main thread.
struct ReplyWriteInputs: Sendable {
    var store: any MailStoring
    /// The conversation's visible messages (drafts are dropped by the builder).
    var messages: [MessageMetadata]
    /// The message the reply answers.
    var target: MessageID?
    var accounts: [Account]
    /// The replying account adds a signature below the reply, so the model leaves out a sign-off.
    var appendsSignature: Bool

    /// The context for `ask`, reading each message's stored text: off the main thread (the bodies decompress).
    func build(ask: WriteAsk) -> ReplyContext {
        let store = store
        return ReplyContextBuilder(accounts: accounts).build(messages: messages, replyingTo: target, ask: ask) { message in
            guard let stored = try? store.body(for: message.id) else { return nil }
            let text = stored.plainText.isEmpty ? (stored.body.text ?? "") : stored.plainText
            return ReplyContextBuilder.Body(plainText: text, attachmentCount: stored.body.attachments.filter { !$0.isInline }.count)
        }
    }
}
