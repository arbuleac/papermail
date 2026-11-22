import Foundation
import GRDB

/// SQL for `sender_rules` (v17, the mirror of the server's rules since v23: docs/DATA-MODEL.md, "Sender rules"). The
/// transitions are `SenderRuleMirror`'s, shared with the in-memory store; this reads and writes the rows they need. The
/// table holds a handful of rows per account, so a transition reads the account's rows whole.
enum SenderRuleTable {
    private static let columns = "account_id, address, action, created_at, server_ids, sync"

    /// Every rule, by account and then address, as Settings lists them.
    static func all(_ db: Database) throws -> [SenderRule] {
        try Row.fetchAll(db.cachedStatement(sql: "SELECT \(columns) FROM sender_rules ORDER BY account_id, address"))
            .compactMap(rule(from:))
    }

    /// The account's rows, by address.
    static func rows(accountID: AccountID, in db: Database) throws -> [SenderRule] {
        try Row.fetchAll(db.cachedStatement(sql: "SELECT \(columns) FROM sender_rules WHERE account_id = ? ORDER BY address"),
                         arguments: [accountID.rawValue]).compactMap(rule(from:))
    }

    /// The account's rows waiting for the server, in the order they took that state (then by address).
    static func pending(accountID: AccountID, in db: Database) throws -> [SenderRule] {
        try Row.fetchAll(db.cachedStatement(sql: """
            SELECT \(columns) FROM sender_rules WHERE account_id = ? AND sync != 'saved' ORDER BY created_at, address
            """), arguments: [accountID.rawValue]).compactMap(rule(from:))
    }

    static func row(accountID: AccountID, address: String, in db: Database) throws -> SenderRule? {
        try Row.fetchOne(db.cachedStatement(sql: "SELECT \(columns) FROM sender_rules WHERE account_id = ? AND address = ?"),
                         arguments: [accountID.rawValue, address]).flatMap(rule(from:))
    }

    /// The user set, changed or removed the rule for the address.
    static func set(_ action: SenderRule.Action?, for address: String, accountID: AccountID, now: Date, in db: Database) throws {
        let address = SenderRule.normalizedAddress(address)
        guard !address.isEmpty else { return }
        let current = try row(accountID: accountID, address: address, in: db)
        let change = SenderRuleMirror.setting(action, on: current, accountID: accountID, address: address,
                                              at: MailStoreCodec.date(MailStoreCodec.milliseconds(now)))
        try apply(change, accountID: accountID, address: address, in: db)
    }

    /// A read of the server listed `server`. Nothing is written for an account the store no longer has (removed while the
    /// read was on its way).
    static func replace(accountID: AccountID, with server: [ServerSenderRule], readAt: Date, in db: Database) throws {
        guard try AccountTable.exists(accountID, in: db) else { return }
        let changes = SenderRuleMirror.replacing(try rows(accountID: accountID, in: db), accountID: accountID, with: server,
                                                 readAt: MailStoreCodec.date(MailStoreCodec.milliseconds(readAt)))
        for (address, change) in changes.sorted(by: { $0.key < $1.key }) {
            try apply(change, accountID: accountID, address: address, in: db)
        }
    }

    /// What the engine did with a pending rule; false when there was no row to settle.
    static func settle(_ outcome: SenderRuleOutcome, address: String, accountID: AccountID, in db: Database) throws -> Bool {
        let address = SenderRule.normalizedAddress(address)
        let (change, settled) = SenderRuleMirror.settling(outcome, on: try row(accountID: accountID, address: address, in: db))
        try apply(change, accountID: accountID, address: address, in: db)
        return settled
    }

    /// The accounts with any rule: the table is a few rows, read once per write.
    static func accounts(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db.cachedStatement(sql: "SELECT DISTINCT account_id FROM sender_rules")))
    }

    /// One primary-key probe; `address` already normalized. Any row counts, whatever its state: a rule on its way to the
    /// server or being deleted there is still one the user set.
    static func action(accountID: String, address: String, in db: Database) throws -> SenderRule.Action? {
        try String.fetchOne(db.cachedStatement(sql: "SELECT action FROM sender_rules WHERE account_id = ? AND address = ?"),
                            arguments: [accountID, address]).flatMap(SenderRule.Action.init(rawValue:))
    }

    // MARK: Rows

    private static func apply(_ change: SenderRuleMirror.Change, accountID: AccountID, address: String, in db: Database) throws {
        switch change {
        case .keep:
            return
        case .remove:
            try db.cachedStatement(sql: "DELETE FROM sender_rules WHERE account_id = ? AND address = ?")
                .execute(arguments: [accountID.rawValue, address])
        case .write(let rule):
            try db.cachedStatement(sql: """
                INSERT INTO sender_rules (\(columns)) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_id, address) DO UPDATE SET action = excluded.action, created_at = excluded.created_at,
                    server_ids = excluded.server_ids, sync = excluded.sync
                """).execute(arguments: [accountID.rawValue, address, rule.action.rawValue,
                                         MailStoreCodec.milliseconds(rule.createdAt), try encode(rule.serverIDs),
                                         rule.sync.rawValue])
        }
    }

    /// A row a later build wrote with an action or a state this one does not know is left out rather than guessed at.
    private static func rule(from row: Row) -> SenderRule? {
        guard let action = SenderRule.Action(rawValue: row[2]), let sync = SenderRule.Sync(rawValue: row[5]) else { return nil }
        return SenderRule(accountID: AccountID(row[0]), address: row[1], action: action, createdAt: MailStoreCodec.date(row[3]),
                          serverIDs: decode(row[4]), sync: sync)
    }

    /// A JSON array of strings, NULL when there are none (a rule not on the server yet).
    private static func encode(_ ids: [String]) throws -> String? {
        ids.isEmpty ? nil : try MailStoreCodec.json(ids)
    }

    private static func decode(_ json: String?) -> [String] {
        guard let json else { return [] }
        return (try? MailStoreCodec.decode([String].self, from: json)) ?? []
    }
}
