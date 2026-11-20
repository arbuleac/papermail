import Foundation
import GRDB

/// SQL for `accounts`, including the per-account sync state columns and the wipe that resets them.
enum AccountTable {
    static func all(_ db: Database) throws -> [Account] {
        try Row.fetchAll(db, sql: """
            SELECT id, kind, email, display_name, added_at, ink_slot, monogram, signature, face FROM accounts
            ORDER BY added_at, id
            """).map { row in
            Account(
                id: AccountID(row[0]),
                kind: ProviderKind(rawValue: row[1]) ?? .gmail,
                email: row[2],
                displayName: row[3],
                addedAt: MailStoreCodec.date(row[4]),
                inkSlot: row[5],
                monogram: row[6],
                signature: row[7],
                face: AccountFace(storedValue: row[8])
            )
        }
    }

    /// Sync columns are deliberately left alone: re-saving an account after a profile refresh must not drop
    /// its cursor. The local settings (ink slot, monogram, signature, face) are written from the account as given, so a
    /// caller re-saving an account it read keeps them.
    ///
    /// `color_hex` is retired (the colour is `ink_slot`'s, drawn by the design layer) but v1 declared it NOT NULL
    /// without a default, so a new row stores an empty string and an existing row keeps whatever it had.
    static func upsert(_ account: Account, in db: Database) throws {
        try validate(inkSlot: account.inkSlot)
        try db.execute(sql: """
            INSERT INTO accounts (id, kind, email, display_name, color_hex, added_at, ink_slot, monogram, signature, face)
            VALUES (?, ?, ?, ?, '', ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind, email = excluded.email, display_name = excluded.display_name,
                added_at = excluded.added_at, ink_slot = excluded.ink_slot, monogram = excluded.monogram,
                signature = excluded.signature, face = excluded.face
            """, arguments: [
                account.id.rawValue, account.kind.rawValue, account.email, account.displayName,
                MailStoreCodec.milliseconds(account.addedAt), account.inkSlot,
                Account.normalizedMonogram(account.monogram), Account.normalizedSignature(account.signature),
                account.face.storedValue,
            ])
    }

    static func setInkSlot(_ slot: Int, for id: AccountID, in db: Database) throws {
        try validate(inkSlot: slot)
        try db.execute(sql: "UPDATE accounts SET ink_slot = ? WHERE id = ?", arguments: [slot, id.rawValue])
        guard db.changesCount == 1 else { throw StoreError.notFound }
    }

    static func setMonogram(_ monogram: String?, for id: AccountID, in db: Database) throws {
        try db.execute(sql: "UPDATE accounts SET monogram = ? WHERE id = ?", arguments: [
            Account.normalizedMonogram(monogram), id.rawValue,
        ])
        guard db.changesCount == 1 else { throw StoreError.notFound }
    }

    static func setSignature(_ signature: String?, for id: AccountID, in db: Database) throws {
        try db.execute(sql: "UPDATE accounts SET signature = ? WHERE id = ?", arguments: [
            Account.normalizedSignature(signature), id.rawValue,
        ])
        guard db.changesCount == 1 else { throw StoreError.notFound }
    }

    static func setFace(_ face: AccountFace, for id: AccountID, in db: Database) throws {
        try db.execute(sql: "UPDATE accounts SET face = ? WHERE id = ?", arguments: [face.storedValue, id.rawValue])
        guard db.changesCount == 1 else { throw StoreError.notFound }
    }

    /// Shared with `InMemoryMailStore` so both stores refuse the same slots.
    static func validate(inkSlot: Int) throws {
        guard AccountInkSlot.isValid(inkSlot) else {
            throw StoreError.conflict("ink slot \(inkSlot) is outside 0..<\(AccountInkSlot.count)")
        }
    }

    static func delete(_ id: AccountID, in db: Database) throws {
        // The foreign keys would cascade on their own, but the FTS index needs the message rows while it is
        // being cleaned, so the wipe runs first.
        try wipe(id, in: db)
        // The wipe keeps the calendar (it is not mail); the account's events go here.
        try CalendarEventTable.removeAll(id, in: db)
        try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [id.rawValue])
    }

    static func wipe(_ id: AccountID, in db: Database) throws {
        try FullTextIndex.removeAll(accountID: id, in: db)
        let accountID = id.rawValue
        // Their mail times go with the messages (the foreign key). The calendar's events stay: they are not mail, and a
        // reset of the mail cursor says nothing about the calendar.
        try db.execute(sql: "DELETE FROM messages WHERE account_id = ?", arguments: [accountID])
        try db.execute(sql: "DELETE FROM conversations WHERE account_id = ?", arguments: [accountID])
        // Operations and pending sends are kept: they are what the user asked for and the provider has not
        // seen yet. After a reset the re-bootstrapped messages take the pending changes again, and queued
        // mail still goes out. Deleting the account removes them through the foreign keys.
        try db.execute(sql: "DELETE FROM contacts WHERE account_id = ?", arguments: [accountID])
        // The marks describe a backfill of the mail just dropped; one that starts over must start unmarked.
        try BackfillMarks.clear(id, in: db)
        // Lookups of mail just dropped; a fresh bootstrap starts without them.
        try LookupQueue.clear(id, in: db)
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
