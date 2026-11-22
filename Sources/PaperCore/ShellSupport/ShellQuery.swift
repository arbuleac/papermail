import Foundation

/// The list query the main window asks for, from what the header and the account strip show.
public enum ShellQuery {
    /// Search looks through everything but the trash, the way people expect a mail search to work, so while
    /// there is search text the view on screen does not apply, Later included; an `in:` operator picks the view
    /// instead (`in:sent` searches Sent from any view, `in:trash` the Trash). The account scope applies either way.
    /// The text is parsed here (`SearchQuery(parsing:)`), so the stores and a provider's own search get the same
    /// terms. The Inbox always shows all of its mail: the provider's Focused/Other category is stored only to
    /// round-trip provider state, never filtered on (spec §5.5).
    public static func make(scope accountIDs: [AccountID]?, view: MailboxView, searchText: String,
                            timeZone: TimeZone = .current) -> ConversationQuery {
        var query = ConversationQuery(accountIDs: accountIDs, view: view)
        if let search = SearchQuery(parsing: searchText, timeZone: timeZone) {
            query.view = search.mailbox ?? .all
            query.search = search
        }
        // Later is never paged (it orders by a time ahead, which `before` cannot page): it is read whole.
        if query.view == .later { query.limit = laterLimit }
        return query
    }

    /// What the Later view reads at once: far more than anyone snoozes.
    public static let laterLimit = 10_000
}
