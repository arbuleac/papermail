import Foundation
import GRDB

/// Maintenance of `message_fts`, the FTS5 external-content index whose content table is the
/// `message_fts_content` view over `messages` and `bodies`.
///
/// FTS5 external-content tables need the exact indexed values back when a row is deleted, so every change to a
/// message's subject, participants or body is bracketed by `remove` (old values from the view) and `insert`
/// (new values from the view). Reading both sides from the same view keeps the index consistent by construction.
enum FullTextIndex {
    private static let insertSQL = """
        INSERT INTO message_fts(rowid, subject, participants, body)
        SELECT id, subject, participants, body FROM message_fts_content WHERE id = ?
        """

    private static let removeSQL = """
        INSERT INTO message_fts(message_fts, rowid, subject, participants, body)
        SELECT 'delete', id, subject, participants, body FROM message_fts_content WHERE id = ?
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
                INSERT INTO message_fts(message_fts, rowid, subject, participants, body)
                SELECT 'delete', id, subject, participants, body FROM message_fts_content WHERE account_id = ?
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

    /// Turns what the user typed into an FTS5 MATCH expression: every token is a quoted phrase (so punctuation
    /// and FTS operators in the text cannot change the query), joined with AND, and the last token is a prefix
    /// so results narrow with every keystroke. Returns nil when nothing is indexable, which means "no search".
    static func matchExpression(for searchText: String?) -> String? {
        guard let searchText else { return nil }
        let tokens = searchText
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        guard !tokens.isEmpty else { return nil }
        var phrases = tokens.map { "\"\($0)\"" }
        phrases[phrases.count - 1] += "*"
        return phrases.joined(separator: " AND ")
    }
}
