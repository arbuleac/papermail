import Foundation

/// The list query the main window asks for, from what the header and the account strip show.
public enum ShellQuery {
    /// Search looks through everything but the trash, the way people expect a mail search to work, so while
    /// there is search text the view does not apply. The Inbox always shows all of its mail: the provider's
    /// Focused/Other category is stored only to round-trip provider state, never filtered on (spec §5.5).
    public static func make(scope accountIDs: [AccountID]?, view: MailboxView, searchText: String) -> ConversationQuery {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !trimmed.isEmpty
        var query = ConversationQuery(
            accountIDs: accountIDs,
            view: searching ? .all : view,
            searchText: searching ? trimmed : nil
        )
        // Later is never paged (it orders by a time ahead, which `before` cannot page): it is read whole.
        if query.view == .later { query.limit = laterLimit }
        return query
    }

    /// What the Later view reads at once: far more than anyone snoozes.
    public static let laterLimit = 10_000
}
