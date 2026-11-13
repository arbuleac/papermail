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
}
