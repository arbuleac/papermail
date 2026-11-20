import AppKit
import SSCore

/// A text view Help Me Write writes into (spec §5.56): the quick reply's field or a reply composer's body. The two
/// owners answer what differs between them (whose text is the user's, where the card goes, what the reply answers);
/// `WriteSession` does the rest the same way for both.
@MainActor
protocol WriteField: AnyObject {
    /// The text view the reply goes into. Its identity is the writer's field (`AIFieldID`).
    var writeTextView: NSTextView { get }
    /// The view the card is drawn in, above everything else there.
    var cardHost: NSView { get }
    /// The user's own text: the quick reply's whole text; a composer's body above its signature (the quoted original is
    /// never in the text). Sent as their notes and replaced by the reply.
    var ownTextRange: NSRange { get }
    /// The attributes the reply's text takes at `range`: the field's writing style, never a signature's or a picture's mark.
    func writeAttributes(at range: NSRange) -> [NSAttributedString.Key: Any]
    /// Where the card goes in `cardHost`, `size` big: under `range`'s last line (the caret, the selection or the reply
    /// written so far), or above it where there is no room.
    func cardFrame(size: NSSize, anchoredTo range: NSRange) -> NSRect
    /// While a write streams the field refuses the user's own edits, so the stream and typing never interleave.
    var refusesEdits: Bool { get set }
    /// The card opened or closed: the quick reply stays open around its text while focus is in the card.
    func cardDidChange(isOpen: Bool)
    /// The stream changed the text without an edit being reported: the field takes its new height.
    func streamDidUpdate()
    /// What the write needs from the conversation, read now on the main thread (its bodies are read off it, after
    /// `keepBodies`); nil when the field answers nothing any more.
    func writeContext() -> WriteContextInputs?
}

/// The conversation a write answers, as the field's owner knows it: everything `ReplyContextBuilder` reads, so the
/// bodies can be read and redacted off the main thread.
struct WriteContextInputs: Sendable {
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
