import Foundation
import SSCore

/// What the reader asks its owner to do. The window controller performs these because they move the
/// selection or open windows; the reader itself only reads from the store.
enum ConversationAction {
    case reply(MessageID)
    case replyAll(MessageID)
    case forward(MessageID)
    case archive(ConversationID)
    /// The desired starred state, already inverted from the current one.
    case star(ConversationID, Bool)
    case trash(ConversationID)
    /// Informational: the reader has already opened Quick Look for it.
    case openAttachment(MessageID, AttachmentInfo)
}
