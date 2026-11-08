import Foundation
import GRDB

/// SQL for evicting bodies outside the Keep mail window (docs/DATA-MODEL.md, `bodies.evicted`). The source and the
/// rendered HTML go; `plain_text`, `attachments_json`, the design facts and the full-text row stay, so the list,
/// snippets and search are unchanged. `rendered_html` is NOT NULL since v1, so an evicted row holds an empty blob.
enum BodyEviction {
    /// The rules a body must meet, in terms of `m` (its message) and the key columns given: received before the
    /// cutoff, not a draft, and no live operation targets it (its outcome may still need the message as it is).
    private static func eligible(account: String, provider: String) -> String {
        """
        m.date_ms < ? AND (m.roles & \(MailStoreCodec.draftsBit)) = 0
        AND NOT EXISTS (SELECT 1 FROM operation_targets t JOIN operations o ON o.id = t.operation_id
                        WHERE t.account_id = \(account) AND t.provider_id = \(provider)
                          AND o.status IN \(OperationTable.liveStatusList))
        """
    }

    /// Bodies to evict next, oldest message first, from messages received at or after `start`. A read, so a sweep that
    /// finds nothing (the usual case once the window is reached) never takes the writer; the write checks every rule
    /// again.
    ///
    /// `evicted` is checked only once a row's message, the operation probe and the body row have been read (the only
    /// path is `messages_by_date`), so without `start` every batch would walk again past every body earlier batches
    /// evicted, and a first sweep of a large mailbox would cost the square of its size. `start` bounds the range from
    /// below; it is inclusive, so messages sharing the last batch's date are looked at again, which costs a few rows.
    /// `offset` skips the rows a batch has already read past, when excluded messages filled a page.
    static func candidates(receivedBefore cutoff: Date, from start: Date?, limit: Int, offset: Int = 0,
                           in db: Database) throws -> [(rowid: Int64, id: MessageID, dateMS: Int64)] {
        guard limit > 0 else { return [] }
        let rows = try Row.fetchAll(db, sql: candidatesSQL, arguments: [
            start.map(MailStoreCodec.milliseconds) ?? Int64.min, MailStoreCodec.milliseconds(cutoff), limit, offset,
        ])
        return rows.map { row in
            (rowid: row[0], id: MessageID(accountID: AccountID(row[1]), providerID: row[2]), dateMS: row[3])
        }
    }

    /// SQLite's plan for the candidate read, one line per step, so tests can pin it to a range on `messages_by_date`.
    static func explainCandidates(in db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + candidatesSQL, arguments: [0, 0, 1, 0]).map { $0["detail"] }
    }

    /// Arguments: the start (inclusive), the cutoff, the limit, the offset.
    private static let candidatesSQL = """
        SELECT b.rowid, m.account_id, m.provider_id, m.date_ms
        FROM messages m JOIN bodies b ON b.account_id = m.account_id AND b.provider_id = m.provider_id
        WHERE b.evicted = 0 AND m.date_ms >= ? AND \(eligible(account: "m.account_id", provider: "m.provider_id"))
        ORDER BY m.date_ms LIMIT ? OFFSET ?
        """

    /// Whether the message meets every rule, so a body fetched for it can be stored already evicted
    /// (`MessageTable.saveBody(_:for:evicted:in:)`). False for a message the store does not know.
    static func isEligible(_ id: MessageID, receivedBefore cutoff: Date, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM messages m WHERE m.account_id = ? AND m.provider_id = ?
                           AND \(eligible(account: "m.account_id", provider: "m.provider_id")))
            """, arguments: [id.accountID.rawValue, id.providerID, MailStoreCodec.milliseconds(cutoff)]) ?? false
    }

    /// Evicts the given bodies that still meet every rule (a body saved again, or a message an operation now targets,
    /// since the read is left alone). Returns how many it evicted.
    static func evict(_ rowids: [Int64], receivedBefore cutoff: Date, in db: Database) throws -> Int {
        let statement = try db.cachedStatement(sql: """
            UPDATE bodies SET html = NULL, text = NULL, rendered_html = X'', evicted = 1
            WHERE rowid = ? AND evicted = 0
              AND EXISTS (SELECT 1 FROM messages m
                          WHERE m.account_id = bodies.account_id AND m.provider_id = bodies.provider_id
                            AND \(eligible(account: "bodies.account_id", provider: "bodies.provider_id")))
            """)
        let milliseconds = MailStoreCodec.milliseconds(cutoff)
        var evicted = 0
        for rowid in rowids {
            try statement.execute(arguments: [rowid, milliseconds])
            evicted += db.changesCount
        }
        return evicted
    }
}
