import Foundation

/// One term of a search, as `ShellQuery` parses it from the field (spec §5.6, docs/ARCHITECTURE.md "Search").
///
/// Words, phrases, `from:`, `to:` and `subject:` are matched in the full-text index: a conversation is found when one
/// of its messages matches every one of them and none that is negated, as Gmail and Microsoft Graph read the same
/// text. The other operators test the conversation as its row shows it: its unread dot, star, attachment, the date
/// of its latest message, and the view it is in; negated, they keep the rows they do not describe.
public struct SearchTerm: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A bare word, matched across every indexed column. A word with punctuation in it (`e-mail`) matches its
        /// tokens side by side, as a phrase.
        case text(String)
        /// A quoted phrase: its words side by side, in order, in one column.
        case phrase(String)
        /// `from:`, matched in the sender's name and address.
        case from(String)
        /// `to:`, matched in every recipient's name and address: to, cc and bcc.
        case to(String)
        /// `subject:`, matched in the message's subject.
        case subject(String)
        /// `is:unread`: the conversation has unread mail.
        case unread
        /// `is:read`: nothing in the conversation is unread.
        case read
        /// `is:starred`.
        case starred
        /// `has:attachment`.
        case attachment
        /// `before:`: the latest message is before local midnight starting that day.
        case before(Date)
        /// `after:`: the latest message is on that day or later (from local midnight starting it).
        case after(Date)
        /// `in:inbox`, `in:sent`, `in:drafts`, `in:trash`, `in:all`: the conversation is in that view.
        case mailbox(MailboxView)
    }

    public var kind: Kind
    /// A leading minus: a message (for an index term) or a row (for the others) must not match it.
    public var negated: Bool
    /// The last thing typed, still open (unquoted, or a quote not yet closed): its last word is matched as a prefix,
    /// so results narrow with every keystroke. Only a positive index term is ever a prefix.
    public var isPrefix: Bool

    public init(_ kind: Kind, negated: Bool = false, isPrefix: Bool = false) {
        self.kind = kind
        self.negated = negated
        self.isPrefix = isPrefix
    }

    /// True for the terms the full-text index answers.
    public var isIndexed: Bool {
        switch kind {
        case .text, .phrase, .from, .to, .subject: return true
        case .unread, .read, .starred, .attachment, .before, .after, .mailbox: return false
        }
    }
}
