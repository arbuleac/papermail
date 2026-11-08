import Foundation
import GRDB

/// Maintenance of `message_fts`, the FTS5 external-content index whose content table is the
/// `message_fts_content` view over `messages` and `bodies`.
///
/// FTS5 external-content tables need the exact indexed values back when a row is deleted, so every change to a
/// message's subject, sender, recipients or body is bracketed by `remove` (old values from the view) and `insert`
/// (new values from the view). Reading both sides from the same view keeps the index consistent by construction,
/// and every write path (upsert, a body saved whole or already evicted, delete) goes through these two.
enum FullTextIndex {
    private static let insertSQL = """
        INSERT INTO message_fts(rowid, subject, sender, recipients, body)
        SELECT id, subject, sender, recipients, body FROM message_fts_content WHERE id = ?
        """

    private static let removeSQL = """
        INSERT INTO message_fts(message_fts, rowid, subject, sender, recipients, body)
        SELECT 'delete', id, subject, sender, recipients, body FROM message_fts_content WHERE id = ?
        """

    static func insert(rowid: Int64, in db: Database) throws {
        try db.cachedStatement(sql: insertSQL).execute(arguments: [rowid])
    }

    static func remove(rowid: Int64, in db: Database) throws {
        try db.cachedStatement(sql: removeSQL).execute(arguments: [rowid])
    }

    /// Drops every index entry of an account. Must run before the account's message rows are deleted.
    static func removeAll(accountID: AccountID, in db: Database) throws {
        let othersRemain = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE account_id != ?)",
            arguments: [accountID.rawValue]
        ) ?? false
        if othersRemain {
            try db.execute(sql: """
                INSERT INTO message_fts(message_fts, rowid, subject, sender, recipients, body)
                SELECT 'delete', id, subject, sender, recipients, body FROM message_fts_content WHERE account_id = ?
                """, arguments: [accountID.rawValue])
        } else {
            // Wiping the only account: a single delete-all beats walking a 100k-row doclist.
            try db.execute(sql: "INSERT INTO message_fts(message_fts) VALUES ('delete-all')")
        }
    }

    /// FTS5's strict integrity check: with the flag set it also compares the index with the content view, so a
    /// stale entry for a deleted or re-indexed message surfaces as an error instead of as a wrong search hit.
    static func verify(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO message_fts(message_fts, rank) VALUES ('integrity-check', 1)")
    }

    /// The MATCH expression for a search's index terms, which a message must satisfy: every term that is not negated
    /// (joined with AND, so one message holds them all, as words always had to) and none that is. FTS5's NOT needs
    /// something on its left, so a search whose index terms are all negated gets the negated ones joined with OR and
    /// `inverted` set: the messages it describes are the ones that do not match. Nil when the search has none.
    static func matchExpression(for search: SearchQuery?) -> (expression: String, inverted: Bool)? {
        var positive: [String] = []
        var negative: [String] = []
        for term in search?.terms ?? [] {
            guard let fragment = fragment(for: term) else { continue }
            if term.negated { negative.append(fragment) } else { positive.append(fragment) }
        }
        let excluded = negative.joined(separator: " OR ")
        guard !positive.isEmpty else { return negative.isEmpty ? nil : (excluded, true) }
        let required = positive.joined(separator: " AND ")
        return (negative.isEmpty ? required : "(\(required)) NOT (\(excluded))", false)
    }

    /// One term as an FTS5 phrase: quoted (`stringContent`), so punctuation and FTS syntax in what was typed cannot
    /// change the query (a word with punctuation in it becomes its tokens side by side), with a column filter for
    /// `from:`, `to:` and `subject:`, and the prefix mark on the term still being typed. Nil for a term the index does
    /// not answer or one with nothing indexable in it.
    static func fragment(for term: SearchTerm) -> String? {
        let column: String?
        let value: String
        switch term.kind {
        case .text(let text), .phrase(let text): (column, value) = (nil, text)
        case .from(let text): (column, value) = ("sender", text)
        case .to(let text): (column, value) = ("recipients", text)
        case .subject(let text): (column, value) = ("subject", text)
        case .unread, .read, .starred, .attachment, .before, .after, .mailbox: return nil
        }
        guard SearchGrammar.isIndexable(value) else { return nil }
        let phrase = "\"\(stringContent(value))\"" + (term.isPrefix ? "*" : "")
        return column.map { "\($0) : \(phrase)" } ?? phrase
    }

    /// `value` as the inside of an FTS5 string, so nothing typed can end the string early: every quote doubled, FTS5's
    /// own escape. It works on Unicode scalars, not Characters, because a quote that a combining mark, variation
    /// selector or joiner follows is one Character with it (which `replacingOccurrences(of: "\"")` passes over) and
    /// still a quote byte to FTS5. The tokenizer then splits words at the quote as `FullTextMatcher` does, where
    /// dropping it would join them (`foo"bar` is foo and bar). NUL becomes a space: the bound text would end there.
    static func stringContent(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": scalars.append(contentsOf: ["\"", "\""] as [Unicode.Scalar])
            case "\0": scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
