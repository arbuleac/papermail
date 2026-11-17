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
    /// Download, Download all or Save to Downloads finished (spec §5.17): the main window shows the saved toast with
    /// Show in Finder, or the error toast, as the outcome says (§5.30).
    case attachmentsSaved(AttachmentSaveOutcome)
    /// Continue Editing on a read-only draft (spec §5.19).
    case continueDraft(MessageID)
    /// Discard Draft… on one draft or several (the header, the sheet's footer): the main window asks “Discard
    /// this draft?” (§5.33), the same alert # asks, and discards on confirm.
    case discardDrafts([ConversationID])
    /// Cancel beside a Send Later message's time (spec §5.19): the schedule goes and the message stays as a draft.
    case cancelSendLater(ConversationID)
    /// The quick reply's "Show" after an undo that came once the selection had moved on.
    case reveal(ConversationID)
    /// Open in Composer (⇧⌘R), the error state's “Open in composer” and Attach (⇧⌘A) on the quick reply
    /// (spec §5.18): a reply composer to `message` holding what was typed; with `attach`, it then asks for files.
    case replyInComposer(MessageID, all: Bool, body: String, attach: Bool)
    /// A quick reply failed after its undo window (§5.18): the main window says so in an error toast whose
    /// “Open draft” reopens `draft`, which is already kept on this Mac.
    case quickReplyFailed(ComposeDraft)
    /// Esc in the quick reply: its window applies §6.1 (a toast first, then back to the list; a reader window closes over an
    /// empty bar, and gives the page the keyboard over one holding the user's work).
    case escapeQuickReply
    /// Unsubscribe, from the link beside a sender or the message's More menu (spec §5.14): the request `message`'s
    /// list headers describe, and the conversation archived.
    case unsubscribe(MessageID)
    /// A sender rule set from the message's More menu (spec, Sender rules (Q4.2)): mail from `message`'s sender is
    /// archived, or moved to the Trash, from now on, and theirs in the conversation now.
    case senderRule(SenderRule.Action, MessageID)
    /// The invitation card's Reconnect: the account signs in again, asking for permission to update its calendar
    /// (spec §5.14, §5.44).
    case reconnect(AccountID)
    /// The person menu's New Message (spec §5.14): a composer to `address` from the conversation's account.
    case newMessage(to: EmailAddress, from: AccountID)
    /// The person menu's Show Mail from This Person (spec §5.14): the main window searches `from:` the address, and the
    /// list takes the keyboard.
    case showMail(from: String)
}
