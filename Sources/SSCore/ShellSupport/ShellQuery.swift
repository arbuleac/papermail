import Foundation

/// The list query the main window asks for, from what the header and the account strip show.
public enum ShellQuery {
    /// Search looks through everything but the trash, the way people expect a mail search to work, so while
    /// there is search text the view and the Focused/Other section do not apply.
    public static func make(scope accountIDs: [AccountID]?, view: MailboxView, section: InboxSection?, searchText: String) -> ConversationQuery {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !trimmed.isEmpty
        return ConversationQuery(
            accountIDs: accountIDs,
            view: searching ? .all : view,
            section: (!searching && view == .inbox) ? section : nil,
            searchText: searching ? trimmed : nil
        )
    }
}
