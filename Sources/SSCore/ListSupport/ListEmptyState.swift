import Foundation

/// The empty list's sentence and hint (spec §5.9): one serif sentence and one hint for every view and sync
/// state, chosen without AppKit so the copy table can be tested.
public struct ListEmptyState: Hashable, Sendable {
    /// The only glyphs an empty list carries.
    public enum Glyph: Hashable, Sendable {
        /// Inbox zero: the brand mark.
        case brandMark
        /// Offline with nothing cached: `wifi.slash`.
        case offline
    }

    public let sentence: String
    public let hint: String
    public let glyph: Glyph?
    /// A link after the hint that acts: the empty search's “Search Gmail” or “Try again” (`ServerSearchRow.emptyHint`).
    public let link: String?

    public init(sentence: String, hint: String, glyph: Glyph? = nil, link: String? = nil) {
        self.sentence = sentence
        self.hint = hint
        self.glyph = glyph
        self.link = link
    }

    /// What an empty list says for `query`.
    ///
    /// - Parameters:
    ///   - isOfflineWithNothingCached: no network and no account in the view has ever finished a sync, so the
    ///     list is empty because nothing could arrive, not because the mailbox is.
    ///   - firstSyncFinishedAccount: the name of the account whose first sync finished in this session with
    ///     nothing for this view ("No mail in Contoso yet").
    ///   - olderMailDownloading: an account in the view is still listing its older mail, so what the view will
    ///     hold is not known yet: the view's own sentence, without its promise about what lands here.
    ///   - serverSearch: a search with no local results can ask the server (§5.10): line 2 offers it, then says how
    ///     it went, in the empty state's own words.
    public static func make(query: ConversationQuery, isOfflineWithNothingCached: Bool = false,
                            firstSyncFinishedAccount: String? = nil, olderMailDownloading: Bool = false,
                            serverSearch: ServerSearchRow? = nil) -> ListEmptyState {
        if let text = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let sentence = "No results for “\(text)”"
            guard let serverSearch else {
                return ListEmptyState(sentence: sentence, hint: "Search looks at subjects, people and message text.")
            }
            let line = serverSearch.emptyHint
            return ListEmptyState(sentence: sentence, hint: line.text ?? "", link: line.link)
        }
        if isOfflineWithNothingCached {
            return ListEmptyState(sentence: "You're offline", hint: "Mail will appear when you reconnect.", glyph: .offline)
        }
        if let account = firstSyncFinishedAccount {
            return ListEmptyState(sentence: "No mail in \(account) yet", hint: "Sync finished. New mail will land here.")
        }
        let settled = settledState(query)
        guard olderMailDownloading else { return settled }
        // No brand mark either: inbox zero is not reached while older inbox mail may still be on its way.
        return ListEmptyState(sentence: settled.sentence, hint: "Older mail is still downloading.")
    }

    private static func settledState(_ query: ConversationQuery) -> ListEmptyState {
        switch query.view {
        case .inbox:
            // The Inbox always shows all of its mail (§5.5): there is no Focused or Other list to be empty.
            return ListEmptyState(sentence: "Nothing left to read.", hint: "New mail will land here.", glyph: .brandMark)
        case .starred:
            return ListEmptyState(sentence: "No starred conversations", hint: "Press S to star one.")
        case .sent:
            return ListEmptyState(sentence: "No sent mail", hint: "Messages you send appear here.")
        case .drafts:
            return ListEmptyState(sentence: "Nothing in Drafts", hint: "Drafts you start here are kept on this Mac.")
        case .trash:
            return ListEmptyState(sentence: "Trash is empty", hint: "Conversations you move to Trash appear here.")
        case .all:
            return ListEmptyState(sentence: "No mail", hint: "Every conversation in this account appears here, archived ones too.")
        case .later:
            // Rarely seen: the view returns to the Inbox once nothing in scope is snoozed (§5.2).
            return ListEmptyState(sentence: "Nothing snoozed", hint: "Press L to bring a conversation back later.")
        }
    }
}
