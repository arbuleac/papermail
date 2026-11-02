import Foundation

/// The words feedback uses for mail actions (spec §4.13, §5.30): the toast's past tense, its coalesced form,
/// the command's menu name that an undo confirms itself with, and the failure line of an operation the
/// provider gave up on.
public enum MailActionCopy {
    /// “Archived”, or coalesced “Archived 3 conversations” / “Marked 3 as unread”.
    public static func toast(for change: MetadataChange, count: Int = 1) -> String {
        let n = count.formatted(.number.grouping(.automatic))
        switch change {
        case .archive: return count > 1 ? "Archived \(n) conversations" : "Archived"
        case .trash: return count > 1 ? "Moved \(n) conversations to Trash" : "Moved to Trash"
        case .moveToInbox, .restoreFromTrash: return count > 1 ? "Moved \(n) conversations to Inbox" : "Moved to Inbox"
        case .setRead(true): return count > 1 ? "Marked \(n) as read" : "Marked as read"
        case .setRead(false): return count > 1 ? "Marked \(n) as unread" : "Marked as unread"
        case .setStarred(true): return count > 1 ? "Starred \(n) conversations" : "Starred"
        case .setStarred(false): return count > 1 ? "Unstarred \(n) conversations" : "Unstarred"
        }
    }

    /// The command as the menus name it, which Edit › Undo and the confirmation toast repeat.
    public static func commandName(for change: MetadataChange) -> String {
        switch change {
        case .archive: return "Archive"
        case .trash: return "Move to Trash"
        case .moveToInbox, .restoreFromTrash: return "Move to Inbox"
        case .setRead(true): return "Mark as Read"
        case .setRead(false): return "Mark as Unread"
        case .setStarred(true): return "Star"
        case .setStarred(false): return "Unstar"
        }
    }

    /// “Undid Archive”: the action-less toast an undo confirms itself with.
    public static func undoConfirmation(for change: MetadataChange) -> String {
        "Undid \(commandName(for: change))"
    }

    /// Edit › Undo's title while `change` is the undo target: “Undo Archive”.
    public static func undoMenuTitle(for change: MetadataChange) -> String {
        "Undo \(commandName(for: change))"
    }

    /// Only actions that take a row out of the view, or change several rows at once, get a toast: starring or
    /// marking one conversation unread does not, because the row itself shows the change (§4.13).
    public static func wantsToast(for change: MetadataChange, in view: MailboxView, isSearching: Bool, count: Int = 1) -> Bool {
        if count > 1 { return true }
        // Search looks through everything but the trash, so only moving to the trash takes a result away.
        if isSearching { return change == .trash }
        switch change {
        case .archive: return view == .inbox
        case .trash: return view != .trash
        case .moveToInbox, .restoreFromTrash: return view == .trash
        case .setStarred(false): return view == .starred
        case .setStarred(true), .setRead: return false
        }
    }

    /// “Couldn't archive. Restored.”: the toast for an operation the provider refused, whose change the store
    /// has already put back.
    public static func failure(for kind: OperationKind) -> String {
        switch kind {
        case .archive: return "Couldn't archive. Restored."
        case .moveToInbox, .restoreFromTrash: return "Couldn't move to Inbox. Restored."
        case .markRead: return "Couldn't mark as read. Restored."
        case .markUnread: return "Couldn't mark as unread. Restored."
        case .star: return "Couldn't star. Restored."
        case .unstar: return "Couldn't unstar. Restored."
        case .trash: return "Couldn't move to Trash. Restored."
        }
    }
}
