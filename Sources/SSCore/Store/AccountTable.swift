import Foundation
import GRDB

/// SQL for `accounts`, including the per-account sync state columns and the wipe that resets them.
enum AccountTable {
    static func all(_ db: Database) throws -> [Account] {
        try Row.fetchAll(db, sql: """
            SELECT id, kind, email, display_name, color_hex, added_at FROM accounts ORDER BY added_at, id
            """).map { row in
            Account(
                id: AccountID(row[0]),
                kind: ProviderKind(rawValue: row[1]) ?? .gmail,
                email: row[2],
                displayName: row[3],
                colorHex: row[4],
                addedAt: MailStoreCodec.date(row[5])
            )
        }
    }

    /// Sync columns are deliberately left alone: re-saving an account after a profile refresh must not drop
    /// its cursor.
    static func upsert(_ account: Account, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO accounts (id, kind, email, display_name, color_hex, added_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind, email = excluded.email, display_name = excluded.display_name,
                color_hex = excluded.color_hex, added_at = excluded.added_at
            """, arguments: [
                account.id.rawValue, account.kind.rawValue, account.email, account.displayName, account.colorHex,
                MailStoreCodec.milliseconds(account.addedAt),
            ])
    }

    static func delete(_ id: AccountID, in db: Database) throws {
        // The foreign keys would cascade on their own, but the FTS index needs the message rows while it is
        // being cleaned, so the wipe runs first.
        try wipe(id, in: db)
        try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [id.rawValue])
    }

    static func wipe(_ id: AccountID, in db: Database) throws {
        try FullTextIndex.removeAll(accountID: id, in: db)
        let accountID = id.rawValue
        try db.execute(sql: "DELETE FROM messages WHERE account_id = ?", arguments: [accountID])
        try db.execute(sql: "DELETE FROM conversations WHERE account_id = ?", arguments: [accountID])
        // Operations and pending sends are kept: they are what the user asked for and the provider has not
        // seen yet. After a reset the re-bootstrapped messages take the pending changes again, and queued
        // mail still goes out. Deleting the account removes them through the foreign keys.
        try db.execute(sql: "DELETE FROM contacts WHERE account_id = ?", arguments: [accountID])
        try db.execute(sql: "UPDATE accounts SET sync_cursor = NULL, bootstrap_json = NULL WHERE id = ?", arguments: [accountID])
    }

    // MARK: Sync state

    static func syncCursor(for id: AccountID, in db: Database) throws -> String? {
        try Row.fetchOne(db, sql: "SELECT sync_cursor FROM accounts WHERE id = ?", arguments: [id.rawValue])
            .flatMap { $0[0] }
    }

    static func setSyncCursor(_ cursor: String?, for id: AccountID, in db: Database) throws {
        try db.execute(sql: "UPDATE accounts SET sync_cursor = ? WHERE id = ?", arguments: [cursor, id.rawValue])
        guard db.changesCount == 1 else { throw StoreError.notFound }
    }

    static func bootstrapState(for id: AccountID, in db: Database) throws -> BootstrapState? {
        let json: String? = try Row.fetchOne(db, sql: "SELECT bootstrap_json FROM accounts WHERE id = ?", arguments: [id.rawValue])
            .flatMap { $0[0] }
        return try json.map { try MailStoreCodec.decode(BootstrapState.self, from: $0) }
    }

    static func setBootstrapState(_ state: BootstrapState?, for id: AccountID, in db: Database) throws {
        let json = try state.map { try MailStoreCodec.json($0) }
        try db.execute(sql: "UPDATE accounts SET bootstrap_json = ? WHERE id = ?", arguments: [json, id.rawValue])
        guard db.changesCount == 1 else { throw StoreError.notFound }
    }
}
