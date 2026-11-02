import Foundation
import SSCore

/// What the reader asks its owner to do. The window controller performs these because they move the
/// selection, open windows or keep the undo stack; the reader itself only reads from the store.
enum ConversationAction {
    case reply(MessageID)
    case replyAll(MessageID)
    case forward(MessageID)
    case archive(ConversationID)
    /// The desired starred state, already inverted from the current one.
    case star(ConversationID, Bool)
    case trash(ConversationID)
    /// Out of the Trash (the Trash view's Archive slot, spec §5.12).
    case moveToInbox(ConversationID)
    /// Informational: the reader has already opened Quick Look for it.
    case openAttachment(MessageID, AttachmentInfo)
    /// Continue Editing on a read-only draft (spec §5.19).
    case continueDraft(MessageID)
    /// Discard Draft, after the reader's "Discard this draft?" alert was confirmed.
    case discardDraft(ConversationID)
    /// The quick reply's "Show" after an undo that came once the selection had moved on.
    case reveal(ConversationID)
}
