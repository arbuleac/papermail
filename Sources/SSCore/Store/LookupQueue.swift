import Foundation
import GRDB

/// SQL for `queued_lookups` (docs/DATA-MODEL.md): stored messages the live lane is to look up by id, a bounded number
/// per poll, because the folder that held them is gone and no delta will report them again. Sync bookkeeping: no
/// observation reads it.
enum LookupQueue {
    /// The account's stored messages whose folder is one of `folderIDs`. A scan of the account's rows (there is no
    /// `folder_id` index, which every message write would pay for): a folder disappears rarely. Read on a reader, since
    /// in a 300,000-message mailbox the scan takes 60 ms, which a local action waiting for the writer would add to its own.
    static func messages(accountID: AccountID, inFolders folderIDs: [String], in db: Database) throws -> [String] {
        let folders = Array(Set(folderIDs))
        var found: [String] = []
        for start in stride(from: 0, to: folders.count, by: BackfillMarks.chunkSize) {
            let chunk = Array(folders[start..<min(start + BackfillMarks.chunkSize, folders.count)])
            found += try String.fetchAll(db, sql: """
                SELECT provider_id FROM messages
                WHERE account_id = ? AND folder_id IN (\(databaseQuestionMarks(count: chunk.count)))
                """, arguments: StatementArguments([accountID.rawValue] + chunk))
        }
        return found
    }

    /// Queues those of `providerIDs` (from `messages(accountID:inFolders:in:)`) still stored in one of `folderIDs`, each
    /// by its key; one already queued keeps its tries. Returns how many it queued.
    static func queue(accountID: AccountID, providerIDs: [String], inFolders folderIDs: [String], in db: Database) throws -> Int {
        let folders = Array(Set(folderIDs))
        guard !folders.isEmpty, !providerIDs.isEmpty else { return 0 }
        let insert = try db.makeStatement(sql: """
            INSERT OR IGNORE INTO queued_lookups (account_id, provider_id, tries)
            SELECT account_id, provider_id, 0 FROM messages
            WHERE account_id = ? AND provider_id = ? AND folder_id IN (\(databaseQuestionMarks(count: folders.count)))
            """)
        var queued = 0
        for providerID in providerIDs {
            try insert.execute(arguments: StatementArguments([accountID.rawValue, providerID] + folders))
            queued += db.changesCount
        }
        return queued
    }

    /// Up to `limit` of the account's queued lookups with the tries each has failed, in id order.
    static func next(accountID: AccountID, limit: Int, in db: Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT provider_id, tries FROM queued_lookups WHERE account_id = ? ORDER BY provider_id LIMIT ?
            """), arguments: [accountID.rawValue, max(0, limit)])
        var queued: [String: Int] = [:]
        for row in rows { queued[row[0]] = row[1] }
        return queued
    }

    /// Drops `settled` from the queue and counts a failed try against each of `retried`.
    static func settle(accountID: AccountID, settled: [String], retried: [String], in db: Database) throws {
        let drop = try db.cachedStatement(sql: "DELETE FROM queued_lookups WHERE account_id = ? AND provider_id = ?")
        for providerID in settled { try drop.execute(arguments: [accountID.rawValue, providerID]) }
        let count = try db.cachedStatement(sql: """
            UPDATE queued_lookups SET tries = tries + 1 WHERE account_id = ? AND provider_id = ?
            """)
        for providerID in retried { try count.execute(arguments: [accountID.rawValue, providerID]) }
    }

    static func clear(_ accountID: AccountID, in db: Database) throws {
        try db.execute(sql: "DELETE FROM queued_lookups WHERE account_id = ?", arguments: [accountID.rawValue])
    }
}
