import Foundation

/// What the user typed into search: the text as typed, for the empty state and for a provider's own search, and
/// the terms `ShellQuery` parsed from it, which both stores match the same way. Several terms all apply (AND).
public struct SearchQuery: Hashable, Sendable {
    /// The field's text, trimmed. Never empty: a blank field is no search at all.
    public var text: String
    /// In the order typed. Empty when nothing in the text can be matched (punctuation alone, an operator still
    /// being typed): the search then shows everything its view holds, as a word that matches nothing yet would not.
    public var terms: [SearchTerm]

    public init(text: String, terms: [SearchTerm]) {
        self.text = text
        self.terms = terms
    }

    /// The first `in:` term that is not negated: the view the search looks through in place of the one on screen.
    public var mailbox: MailboxView? {
        for term in terms where !term.negated {
            if case .mailbox(let view) = term.kind { return view }
        }
        return nil
    }

    /// True when an `is:unread` or `is:read` term, negated or not, filters the results, so reading a result can
    /// take it out of them (see `ConversationQuery.openConversationID`).
    public var filtersOnReadState: Bool {
        terms.contains { term in
            switch term.kind {
            case .unread, .read: return true
            default: return false
            }
        }
    }
}
