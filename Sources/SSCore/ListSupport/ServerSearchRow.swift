import Foundation

/// Searching the server from the list (spec §5.10, “The end of a search”): the row that ends a search once every local
/// result is listed, and the empty search's offer (§5.9). Its words in each state, when it shows, and how many
/// conversations a search added, chosen without AppKit so the copy table and the rules can be tested.
public struct ServerSearchRow: Hashable, Sendable {
    /// Where the search goes: the provider of the one account in scope, or every account in a unified scope that has
    /// several.
    public enum Target: Hashable, Sendable {
        case provider(ProviderKind)
        case allAccounts
    }

    public enum Phase: Hashable, Sendable {
        /// The local results are all listed and the server has not been asked.
        case offer
        /// The providers are searching; the list keeps working meanwhile.
        case searching
        /// The search finished: the conversations it added to the results (0 reads “Nothing more”).
        case found(Int)
        /// The search failed for `subject` (“Gmail”, “Contoso”, “2 accounts”, “your accounts”); “Try again” runs it again.
        case failed(subject: String)
    }

    public let target: Target
    public let phase: Phase

    public init(target: Target, phase: Phase) {
        self.target = target
        self.phase = phase
    }

    // MARK: Words

    /// “Gmail”, “Outlook”, or “all accounts”: the providers' names as people know their mailboxes.
    public var place: String {
        switch target {
        case .provider(.gmail): return "Gmail"
        case .provider(.microsoft): return "Outlook"
        case .allAccounts: return "all accounts"
        }
    }

    /// The row's words: the link while it offers the search, the state after.
    public var title: String {
        switch phase {
        case .offer: return "Search \(place) for more"
        case .searching: return "Searching \(place)…"
        case .found(0): return "Nothing more \(resultPlace)"
        case .found(let count): return "Found \(SyncLineSummary.grouped(count)) more \(resultPlace)"
        case .failed(let subject): return "Couldn't search \(subject)"
        }
    }

    /// The link after the words: “Try again” once a search failed; nil otherwise (the offer is a link itself).
    public var actionTitle: String? {
        if case .failed = phase { return "Try again" }
        return nil
    }

    /// Whether a click, ↩ on the focused row or ⌘↩ in the search field runs the search now.
    public var runs: Bool {
        switch phase {
        case .offer, .failed: return true
        case .searching, .found: return false
        }
    }

    /// What VoiceOver reads for the row.
    public var accessibilityLabel: String {
        [title, actionTitle].compactMap { $0 }.joined(separator: ", ")
    }

    /// “on Gmail”, “in your accounts”.
    private var resultPlace: String {
        target == .allAccounts ? "in your accounts" : "on \(place)"
    }

    /// The empty search's line 2 (§5.9) in its own words: words, then the link that runs the search, if any. The line 1
    /// stays “No results for “…””.
    public var emptyHint: (text: String?, link: String?) {
        switch phase {
        case .offer: return ("Not on this Mac?", "Search \(place)")
        case .searching: return ("Searching \(place)…", nil)
        case .found(0): return (target == .allAccounts ? "Nothing in your accounts either." : "Nothing on \(place) either.", nil)
        case .found: return (title, nil)
        case .failed(let subject): return ("Couldn't search \(subject) ·", "Try again")
        }
    }

    /// Edit › Search Gmail for More (§5.35): title case, as menus name commands.
    public static func menuTitle(for target: Target?) -> String {
        switch target {
        case .provider(.gmail)?: return "Search Gmail for More"
        case .provider(.microsoft)?: return "Search Outlook for More"
        case .allAccounts?: return "Search All Accounts for More"
        case nil: return "Search the Server for More"
        }
    }

    // MARK: Rules

    /// The target for a list scoped to `accountIDs` (nil: every account): the provider of the one account in it, every
    /// account when it holds several, nil when it holds none.
    public static func target(scope accountIDs: [AccountID]?, accounts: [Account]) -> Target? {
        let inScope = accountIDs.map { ids in accounts.filter { ids.contains($0.id) } } ?? accounts
        guard let first = inScope.first else { return nil }
        return inScope.count == 1 ? .provider(first.kind) : .allAccounts
    }

    /// Whether the list ends with the row: there are words to search for, the first page is in and no older page is left
    /// to load, so every local result is listed. An empty search offers the same in its empty state instead.
    public static func isShown(searchText: String?, hasFirstPage: Bool, reachedEnd: Bool, hasRows: Bool) -> Bool {
        let words = searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !words.isEmpty && hasFirstPage && reachedEnd && hasRows
    }

    /// The conversations a search added to the results: those it found that the list shows now and did not before it
    /// ran. Counted from the rows, not the hits, so the number is what appeared: a hit in a conversation already listed
    /// adds nothing, and one the view's rules hide is not counted.
    public static func added(listed: [ConversationID], found: Set<ConversationID>, before: Set<ConversationID>) -> Int {
        listed.reduce(0) { $0 + (found.contains($1) && !before.contains($1) ? 1 : 0) }
    }

    /// Who “Couldn't search …” names: the provider when the search went to one account; in a unified search the one
    /// account that failed, “2 accounts”, or “your accounts” when every one did.
    public static func failureSubject(target: Target, failed: [Account], searched: Int) -> String {
        guard target == .allAccounts else { return ServerSearchRow(target: target, phase: .offer).place }
        if failed.count >= searched || failed.isEmpty { return "your accounts" }
        if failed.count == 1 { return AccountLabels.name(for: failed[0]) }
        return "\(failed.count) accounts"
    }
}
