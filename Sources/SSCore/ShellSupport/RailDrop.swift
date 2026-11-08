import Foundation

/// What a rail folder tile does with conversation rows dragged onto it from the list (spec §5.2): Inbox moves
/// them to the inbox, Trash trashes them, Starred stars them and All Mail archives them, as ⇧I, #, S and E do;
/// Sent, Drafts and Later take nothing (a snooze needs a time, which a drop cannot give). Pure, so which drops a
/// tile takes is decided and tested without windows.
public enum RailDrop {
    /// The change a drop on `tile` makes, or nil for a tile that takes no drop. Starred only ever stars: a drop
    /// has no all-starred toggle, so dragging onto Starred never takes a star away.
    public static func change(for tile: MailboxView) -> MetadataChange? {
        switch tile {
        case .inbox: return .moveToInbox
        case .starred: return .setStarred(true)
        case .trash: return .trash
        case .all: return .archive
        case .sent, .drafts, .later: return nil
        }
    }

    /// Whether `tile` takes `rows`, the dragged conversations as the list shows them, while the rail's selected
    /// view is `view` and the list shows that view, or search results when `isSearching`. A drop that would
    /// change nothing the list shows is refused, so the tile never lights up for it and the drag ends where it
    /// began:
    ///
    /// - outside a search the selected tile takes nothing: the rows under it are already where it would put
    ///   them. A search lists mail from every view under the selected tile, so there only the rows decide,
    ///   as they do for S, E and ⇧I; Trash still refuses while selected, because # does nothing in Trash;
    /// - Inbox refuses rows that are all in the Inbox, Starred rows that are all starred, and All Mail rows none
    ///   of which is in the Inbox (archiving leaves those, the trashed among them, as they are);
    /// - a draft kept on this Mac is not mail in the store, so only Trash takes it (as Discard Draft).
    ///
    /// No rows (they left the list while being dragged) is refused too.
    public static func accepts(_ tile: MailboxView, rows: [ConversationSummary], selectedView view: MailboxView,
                               isSearching: Bool) -> Bool {
        guard change(for: tile) != nil, !rows.isEmpty else { return false }
        if tile == view, !isSearching || tile == .trash { return false }
        if tile == .trash { return true }
        let mail = rows.filter { !LocalDraftConversation.isLocal($0.id) }
        switch tile {
        case .inbox: return mail.contains { !$0.inInbox }
        case .starred: return mail.contains { !$0.isStarred }
        case .all: return mail.contains(where: \.inInbox)
        case .trash, .sent, .drafts, .later: return false
        }
    }
}
