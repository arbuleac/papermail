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
    /// A header action with several conversations selected (spec §5.19): one change on all of them, so one
    /// toast (“Archived 3 conversations”) and one undo.
    case applyToSelection(MetadataChange, [ConversationID])
    /// Informational: the reader has already opened Quick Look for it.
    case openAttachment(MessageID, AttachmentInfo)
    /// Continue Editing on a read-only draft (spec §5.19).
    case continueDraft(MessageID)
    /// Discard Draft… on one draft or several (the header, the sheet's footer): the main window asks “Discard
    /// this draft?” (§5.33), the same alert # asks, and discards on confirm.
    case discardDrafts([ConversationID])
    /// The quick reply's "Show" after an undo that came once the selection had moved on.
    case reveal(ConversationID)
}
