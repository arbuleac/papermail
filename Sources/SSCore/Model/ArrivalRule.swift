import Foundation

/// What a message new to the store is given as it arrives, inside the write that stores it (docs/DATA-MODEL.md,
/// "Arrival rules"). Pure, so both stores and the window answer the same way.
public enum ArrivalRule {
    /// The change the rules make to `message`, given whether its conversation is muted and the sender rule, if any, for
    /// its From address; nil when none applies. Spam is left where the provider put it. Block wins over everything
    /// (Trash is further out than the archive) and never takes the user's own sent mail or drafts, which a rule for one's
    /// own address would otherwise throw away; the archive takes only mail in the Inbox, the mute's whatever its sender,
    /// since a muted conversation stays out of the Inbox whoever writes.
    public static func change(for message: MessageMetadata, inMutedConversation muted: Bool,
                              senderRule: SenderRule.Action?) -> MetadataChange? {
        guard !message.roles.contains(.spam) else { return nil }
        let isOwn = message.roles.contains(.sent) || message.roles.contains(.drafts)
        if senderRule == .trash, !isOwn, !message.roles.contains(.trash) { return .trash }
        guard message.isInInbox else { return nil }
        if muted || (senderRule == .archive && !isOwn) { return .archive }
        return nil
    }

    /// Whether mail arriving in the conversation leaves its snooze alone (docs/DATA-MODEL.md, "Snoozes"): mail in a muted
    /// conversation, or from a sender with a rule, is mail the user has said is not news, whatever the rule does to it (an
    /// archive, a Move to Trash, or nothing where a provider's filter put it away already). Ending the snooze for it would
    /// leave the conversation archived with nothing to bring it back at its time; the summary refresh still ends the
    /// snooze when the conversation is back in the Inbox, in the Trash or gone, as for any write.
    public static func keepsSnooze(inMutedConversation muted: Bool, senderRule: SenderRule.Action?) -> Bool {
        muted || senderRule != nil
    }
}
