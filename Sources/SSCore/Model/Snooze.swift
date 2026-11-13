import Foundation

/// A conversation put away until a time (Later, docs/DATA-MODEL.md "Snoozes"). It was archived when it was snoozed
/// and moves back to the Inbox at `dueAt` with its latest message marked unread. Both halves are ordinary operations,
/// so every device sees the same state; only the timer lives on this Mac.
public struct Snooze: Hashable, Sendable {
    public var conversationID: ConversationID
    /// When it comes back: an instant, chosen as a local time when it was snoozed.
    public var dueAt: Date
    /// When it was snoozed or last rescheduled. Mail that arrives in the conversation after this ends the snooze.
    public var createdAt: Date

    public init(conversationID: ConversationID, dueAt: Date, createdAt: Date) {
        self.conversationID = conversationID
        self.dueAt = dueAt
        self.createdAt = createdAt
    }

    /// Whether a conversation of these messages stands for mail put away, which a snooze needs and keeps needing: out of
    /// the Inbox, out of the Trash, and not one whose mail from others is all in the Trash or Spam while the user's own
    /// copies stay in Sent Items and Drafts (`MailActionRecord.isOwnFolderCopy`), as Move to Trash leaves them on
    /// Microsoft and Mark as Spam on both providers: its return would bring the deleted or spam mail back, or the user's
    /// own copy in its place. The stores keep a snooze only while this holds (`SnoozeTable` writes it in SQL); the window
    /// asks it of the messages as snoozing would leave them, archived, so L never promises a return the store would refuse.
    public static func canHold(_ messages: [MessageMetadata]) -> Bool {
        let visible = messages.filter { $0.roles.isDisjoint(with: [.trash, .spam]) }
        guard !visible.isEmpty, !visible.contains(where: \.isInInbox) else { return false }
        let others = messages.filter { !MailActionRecord.isOwnFolderCopy($0) }
        let away = { (message: MessageMetadata) in !message.roles.isDisjoint(with: [.trash, .spam]) }
        return !(others.contains(where: away) && others.allSatisfy(away))
    }

    /// One conversation's snooze to write, or to end when `until` is nil (`MailStoring.setSnoozes`).
    public struct Change: Hashable, Sendable {
        public var conversationID: ConversationID
        public var until: Date?
        /// The return mark to put back (`conversations.returned_at`): an undo of what took a conversation back from Later
        /// out of the Inbox (Archive, Move to Trash, Snooze) restores its place under Today and its Back tag. Written
        /// after the operations, and only where they have put the conversation back in the Inbox with older mail, as a
        /// refresh keeps the mark.
        public var returnedAt: Date?

        public init(conversationID: ConversationID, until: Date?, returnedAt: Date? = nil) {
            self.conversationID = conversationID
            self.until = until
            self.returnedAt = returnedAt
        }
    }
}
