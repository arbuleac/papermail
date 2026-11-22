import Foundation
import GRDB

/// SQL for `contacts`, the address book derived from message headers.
enum ContactTable {
    /// Counts every from/to/cc address of a newly stored message. Addresses are keyed lowercase so the same
    /// person written with different capitalization accumulates one score.
    static func record(_ message: MessageMetadata, in db: Database) throws {
        let statement = try db.cachedStatement(sql: """
            INSERT INTO contacts (account_id, address, name, seen_count, last_seen_ms) VALUES (?, ?, ?, 1, ?)
            ON CONFLICT(account_id, address) DO UPDATE SET
                name = COALESCE(excluded.name, contacts.name),
                seen_count = contacts.seen_count + 1,
                last_seen_ms = MAX(contacts.last_seen_ms, excluded.last_seen_ms)
            """)
        let seen = MailStoreCodec.milliseconds(message.date)
        let addresses = [message.from].compactMap { $0 } + message.to + message.cc
        for address in addresses {
            try statement.execute(arguments: [
                message.id.accountID.rawValue, address.address.lowercased(), address.name, seen,
            ])
        }
    }

    /// Ranks by `seen_count / (1 + ageDays / 30)` like the in-memory store, merging accounts by address, and
    /// matches the prefix against the address, the whole name, or any word of the name.
    static func suggest(prefix: String, limit: Int, now: Date, in db: Database) throws -> [EmailAddress] {
        let needle = prefix.lowercased()
        let nowMs = MailStoreCodec.milliseconds(now)
        let rows = try Row.fetchAll(db, sql: """
            SELECT address, name,
                   MAX(seen_count / (1.0 + MAX(0.0, (? - last_seen_ms) / 86400000.0) / 30.0)) AS score
            FROM contacts
            WHERE ? = '' OR instr(address, ?) = 1 OR instr(' ' || lower(name), ' ' || ?) > 0
            GROUP BY address
            ORDER BY score DESC, address
            LIMIT ?
            """, arguments: [nowMs, needle, needle, needle, limit])
        return rows.map { EmailAddress(name: $0[1], address: $0[0]) }
    }
}
