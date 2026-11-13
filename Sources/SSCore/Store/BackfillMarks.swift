import Foundation
import GRDB

/// SQL for `backfill_live_marks` and `backfill_seen` (docs/DATA-MODEL.md, "Backfill marks"), and the backfill
/// writes that consult them. No observation reads either table, so writing a mark never wakes the list.
enum BackfillMarks {
    /// Ids bound per IN list. Far below SQLite's parameter limit; it keeps each statement's plan and argument
    /// array small whatever page size the engine picks.
    static let chunkSize = 500

    /// Each message once, at the position of its last occurrence: that is the state `upsertMessages` would have
    /// left, and it keeps the count `writeBackfillMessages` returns a count of messages, not of entries. Shared
    /// with `InMemoryMailStore` so both stores collapse a repeated id the same way.
    static func lastOccurrences(_ messages: [MessageMetadata]) -> [MessageMetadata] {
        var seen: Set<MessageID> = []
        var kept: [MessageMetadata] = []
        for message in messages.reversed() where seen.insert(message.id).inserted {
            kept.append(message)
        }
        return kept.reversed()
    }

    // MARK: Reads

    static func skippable(accountID: AccountID, providerIDs: [String], includeStored: Bool, in db: Database) throws -> Set<String> {
        let unique = Array(Set(providerIDs))
        var found: Set<String> = []
        for start in stride(from: 0, to: unique.count, by: chunkSize) {
            let chunk = Array(unique[start..<min(start + chunkSize, unique.count)])
            found.formUnion(try present(in: "backfill_live_marks", accountID: accountID, chunk, db))
            if includeStored {
                found.formUnion(try present(in: "messages", accountID: accountID, chunk, db))
            }
        }
        return found
    }

    /// The ids of `chunk` that have a row in `table`, through its `(account_id, provider_id)` primary key.
    private static func present(in table: String, accountID: AccountID, _ chunk: [String], _ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT provider_id FROM \(table) WHERE account_id = ? AND provider_id IN (\(databaseQuestionMarks(count: chunk.count)))
            """, arguments: StatementArguments([accountID.rawValue] + chunk))
    }

    // MARK: Writes

    /// The mark check runs inside the caller's write transaction. The engine marks a live change before writing
    /// it (`MailStoring.markLiveChanges`), so a live change is either marked by now (and skipped here) or not yet
    /// written, and its write then waits for this page and overwrites it, as it should.
    static func writeMessages(_ messages: [MessageMetadata], refreshExisting: Bool, in db: Database) throws -> Int {
        let unique = lastOccurrences(messages)
        var skipped: Set<MessageID> = []
        for (accountID, group) in Dictionary(grouping: unique, by: \.id.accountID) {
            let ids = try skippable(accountID: accountID, providerIDs: group.map(\.id.providerID),
                                    includeStored: !refreshExisting, in: db)
            skipped.formUnion(ids.lazy.map { MessageID(accountID: accountID, providerID: $0) })
        }
        let written = unique.filter { !skipped.contains($0.id) }
        // Old mail, not arriving: sender rules do not take it (`ArrivalRules`).
        try MessageTable.upsert(written, senderRules: false, in: db)
        return written.count
    }

    static func markLive(accountID: AccountID, upserted: [String], deleted: [String], in db: Database) throws {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO backfill_live_marks (account_id, provider_id, deleted) VALUES (?, ?, ?)
            ON CONFLICT(account_id, provider_id) DO UPDATE SET deleted = excluded.deleted
            """)
        // Deletions last, so an id in both lists ends up deleted, as it does when the live lane applies a page.
        for providerID in upserted { try statement.execute(arguments: [accountID.rawValue, providerID, false]) }
        for providerID in deleted { try statement.execute(arguments: [accountID.rawValue, providerID, true]) }
    }

    static func markSeen(accountID: AccountID, providerIDs: [String], in db: Database) throws {
        let statement = try db.cachedStatement(sql: """
            INSERT OR IGNORE INTO backfill_seen (account_id, provider_id) VALUES (?, ?)
            """)
        for providerID in providerIDs { try statement.execute(arguments: [accountID.rawValue, providerID]) }
    }

    static func finish(accountID: AccountID, sweepUnseen: Bool, in db: Database) throws -> Int {
        var swept = 0
        if sweepUnseen {
            let ids = try String.fetchAll(db.cachedStatement(sql: unseenSQL), arguments: [accountID.rawValue])
            // Through the message delete, so the full-text rows and the conversation summaries follow.
            try MessageTable.delete(ids.map { MessageID(accountID: accountID, providerID: $0) }, in: db)
            swept = ids.count
        }
        try clear(accountID, in: db)
        return swept
    }

    static func clear(_ accountID: AccountID, in db: Database) throws {
        try db.execute(sql: "DELETE FROM backfill_live_marks WHERE account_id = ?", arguments: [accountID.rawValue])
        try db.execute(sql: "DELETE FROM backfill_seen WHERE account_id = ?", arguments: [accountID.rawValue])
    }

    /// Stored messages the reconcile neither saw nor heard about from the live lane, and that no live operation
    /// targets: a queued change on a message the listing missed is the user's intent, and the operation's own
    /// outcome (or the next poll) settles it. Each probe is a primary-key or `operation_targets_by_message` lookup.
    private static let unseenSQL = """
        SELECT m.provider_id FROM messages m
        WHERE m.account_id = ?
          AND NOT EXISTS (SELECT 1 FROM backfill_seen s
                          WHERE s.account_id = m.account_id AND s.provider_id = m.provider_id)
          AND NOT EXISTS (SELECT 1 FROM backfill_live_marks k
                          WHERE k.account_id = m.account_id AND k.provider_id = m.provider_id)
          AND NOT EXISTS (SELECT 1 FROM operation_targets t JOIN operations o ON o.id = t.operation_id
                          WHERE t.account_id = m.account_id AND t.provider_id = m.provider_id
                            AND o.status IN \(OperationTable.liveStatusList))
        """
}
