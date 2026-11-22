import Foundation

/// What a message new to the store is given as it arrives, inside the write that stores it (docs/DATA-MODEL.md,
/// "Arrival rules"). Pure, so both stores and the window answer the same way.
///
/// Only the mute acts here. Sender rules live on the server (Gmail filters, Outlook inbox rules), which archives or
/// trashes the sender's mail before this Mac sees it; the store only keeps their mirror, which `keepsSnooze` reads.
public enum ArrivalRule {
    /// The change the mute makes to `message`; nil when none applies. Spam is left where the provider put it, and only
    /// mail in the Inbox is archived, whoever sent it: a muted conversation stays out of the Inbox whoever writes.
    public static func change(for message: MessageMetadata, inMutedConversation muted: Bool) -> MetadataChange? {
        guard muted, !message.roles.contains(.spam), message.isInInbox else { return nil }
        return .archive
    }

    /// Whether mail arriving in the conversation leaves its snooze alone (docs/DATA-MODEL.md, "Snoozes"): mail in a muted
    /// conversation, or from a sender with a rule in the store's mirror of the server's, is mail the user has said is not
    /// news, whatever became of it (archived by the mute, archived or trashed by the server's rule before it arrived, or
    /// still in the Inbox while the rule is on its way). Ending the snooze for it would leave the conversation archived
    /// with nothing to bring it back at its time; the summary refresh still ends the snooze when the conversation is back
    /// in the Inbox, in the Trash or gone, as for any write.
    public static func keepsSnooze(inMutedConversation muted: Bool, senderRule: SenderRule.Action?) -> Bool {
        muted || senderRule != nil
    }
}
