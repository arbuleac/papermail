import Foundation

/// What a swipe on a conversation row offers (spec §5.7, Swipe): Archive on the trailing edge, and Mark as Read or
/// Mark as Unread on the leading edge, one action per edge so a swipe carried past the button has one thing to do.
/// Each is a key's change (E, U) on that one row, and is offered only where the key would change it, so a swipe never
/// shows a button that beeps. VoiceOver's custom actions on the row are the same. Pure, so which rows offer what is
/// decided and tested without windows.
public enum RowSwipe {
    /// The edge the swipe uncovers: trailing when the fingers move left (in a left-to-right layout).
    public enum Edge: Sendable, CaseIterable {
        case trailing
        case leading
    }

    /// The change a swipe uncovering `edge` makes to `row`, a row of `view` (while searching, the view the search looks
    /// through, as for the keys), or nil where that edge offers nothing.
    ///
    /// - Trailing, E's rule: Archive where the row has Inbox mail, which is what archiving takes out. In Later, where
    ///   everything is archived already, E ends the snooze and leaves the conversation archived, so a snoozed row offers
    ///   Archive there; a snoozed search result does not, as E leaves it be. Elsewhere (Sent, Trash, All Mail, Starred)
    ///   a row with no Inbox mail offers nothing.
    /// - Leading, U's rule for one row: Mark as Read while it has unread mail, else Mark as Unread.
    /// - A draft kept on this Mac is not mail in the store, so neither key changes it and it offers nothing.
    public static func change(for row: ConversationSummary, edge: Edge, view: MailboxView) -> MetadataChange? {
        guard !LocalDraftConversation.isLocal(row.id) else { return nil }
        switch edge {
        case .trailing:
            return row.inInbox || (view == .later && row.snoozedUntil != nil) ? .archive : nil
        case .leading:
            return .setRead(row.unreadCount > 0)
        }
    }

    /// The button's words, and the VoiceOver action's name: the command as the menus name it (“Archive”, “Mark as Read”,
    /// “Mark as Unread”), a verb, as every button has (§4.13).
    public static func title(for change: MetadataChange) -> String {
        MailActionCopy.commandName(for: change)
    }
}
