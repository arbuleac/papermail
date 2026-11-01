import Foundation
import GRDB

/// SQL for the outbox: `operations` and the `operation_targets` lookup table behind "pending operations win".
enum OperationTable {
    /// Statuses whose local effect must survive an older provider observation.
    static let liveStatusList = "('pending', 'inFlight', 'uncertain')"

    private static let columns = """
        id, account_id, change_json, targets_json, created_at, status, attempts, last_error, next_attempt_at
        """

    // MARK: Pending operations win

    static func accountsWithLiveOperations(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT DISTINCT account_id FROM operations WHERE status IN \(liveStatusList)"))
    }

    /// Changes queued for a message, oldest first, so replaying them on top of provider state is deterministic.
    static func liveChanges(for id: MessageID, in db: Database) throws -> [MetadataChange] {
        let statement = try db.cachedStatement(sql: """
            SELECT o.change_json FROM operation_targets t
            JOIN operations o ON o.id = t.operation_id
            WHERE t.account_id = ? AND t.provider_id = ? AND o.status IN \(liveStatusList)
            ORDER BY o.created_at, o.id
            """)
        return try String.fetchAll(statement, arguments: [id.accountID.rawValue, id.providerID])
            .map { try MailStoreCodec.decode(MetadataChange.self, from: $0) }
    }

    // MARK: Writes

    static func enqueue(_ operation: Operation, in db: Database) throws {
        try MailSchema.ensureTouchedTable(db)
        for target in operation.targets {
            guard let current = try MessageTable.fetch(target, in: db) else { continue }
            try MessageTable.updateFlags(applying(operation.change, to: current), in: db)
            try ConversationTable.touch(current.conversationID, in: db)
        }
        try save(operation, in: db)
        try ConversationTable.refreshTouched(db)
    }

    static func update(_ operation: Operation, in db: Database) throws {
        try MailSchema.ensureTouchedTable(db)
        try touchTargets(of: operation.id, in: db)
        try save(operation, in: db)
        try touchTargets(of: operation.id, in: db)
        try ConversationTable.refreshTouched(db)
    }

    static func delete(id: String, in db: Database) throws {
        try MailSchema.ensureTouchedTable(db)
        try touchTargets(of: id, in: db)
        try db.execute(sql: "DELETE FROM operations WHERE id = ?", arguments: [id])
        try ConversationTable.refreshTouched(db)
    }

    private static func save(_ operation: Operation, in db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO operations (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                account_id = excluded.account_id, change_json = excluded.change_json,
                targets_json = excluded.targets_json, created_at = excluded.created_at, status = excluded.status,
                attempts = excluded.attempts, last_error = excluded.last_error, next_attempt_at = excluded.next_attempt_at
            """).execute(arguments: [
                operation.id,
                operation.accountID.rawValue,
                try MailStoreCodec.json(operation.change),
                try MailStoreCodec.json(operation.targets.map(\.providerID)),
                MailStoreCodec.milliseconds(operation.createdAt),
                operation.status.rawValue,
                operation.attempts,
                operation.lastError,
                operation.nextAttemptAt.map(MailStoreCodec.milliseconds),
            ])
        try db.cachedStatement(sql: "DELETE FROM operation_targets WHERE operation_id = ?").execute(arguments: [operation.id])
        let insertTarget = try db.cachedStatement(sql: """
            INSERT OR IGNORE INTO operation_targets (operation_id, account_id, provider_id) VALUES (?, ?, ?)
            """)
        for target in operation.targets {
            try insertTarget.execute(arguments: [operation.id, target.accountID.rawValue, target.providerID])
        }
    }

    /// Marks the conversations of an operation's targets so `has_pending_ops` is recomputed.
    private static func touchTargets(of operationID: String, in db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT OR IGNORE INTO temp.\(MailSchema.touchedTable) (account_id, provider_id)
            SELECT m.account_id, m.conversation_provider_id FROM operation_targets t
            JOIN messages m ON m.account_id = t.account_id AND m.provider_id = t.provider_id
            WHERE t.operation_id = ?
            """).execute(arguments: [operationID])
    }

    // MARK: Reads

    static func pending(accountID: AccountID, limit: Int, in db: Database) throws -> [Operation] {
        let statement = try db.cachedStatement(sql: """
            SELECT \(columns) FROM operations
            WHERE account_id = ? AND status IN ('pending', 'uncertain')
            ORDER BY created_at, id LIMIT ?
            """)
        return try Row.fetchAll(statement, arguments: [accountID.rawValue, limit]).map(operation(from:))
    }

    private static func operation(from row: Row) throws -> Operation {
        let accountID = AccountID(row[1])
        let nextAttempt: Int64? = row[8]
        return Operation(
            id: row[0],
            accountID: accountID,
            change: try MailStoreCodec.decode(MetadataChange.self, from: row[2]),
            targets: try MailStoreCodec.decode([String].self, from: row[3])
                .map { MessageID(accountID: accountID, providerID: $0) },
            createdAt: MailStoreCodec.date(row[4]),
            status: OperationStatus(rawValue: row[5]) ?? .pending,
            attempts: row[6],
            lastError: row[7],
            nextAttemptAt: nextAttempt.map(MailStoreCodec.date)
        )
    }
}
