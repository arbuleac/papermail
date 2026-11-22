import Foundation
import GRDB

/// SQL for `conversations.failed_op_kind`, the per-conversation mark behind the row's failed glyph.
///
/// The mark is event-maintained rather than derived, because acknowledging it must not delete the failed
/// operation and the schema keeps no per-operation acknowledgement. The rules, mirrored by `InMemoryMailStore`:
/// - an operation written as failed marks each conversation it targets with its kind, unless the conversation
///   already carries a mark and a failed operation created after this one (by `created_at`, then `id`) also
///   targets it: the mark names the newest failure;
/// - an operation that is confirmed (`confirmOperation`, or written as `confirmed`) clears the mark of each
///   conversation it targets, unless a failed operation created after it still targets that conversation; so does
///   a live operation the outbox narrows to the targets still owed, for each conversation it no longer targets,
///   since the provider took its part there (`targetsTaken`);
/// - a failure that ends (a failed row deleted, which is how pruning removes it, or written out of `failed`)
///   clears the mark of each conversation it targets, unless another failed operation still targets it.
///   Failures expire in the order they happened, so one still standing gave up after this one and, if the
///   conversation carries a mark at all, after the last acknowledgement: its mark must stay;
/// - deleting a live operation (a poll settling an uncertain one) says nothing about failures: no change;
/// - acknowledging a conversation clears its mark.
/// "Targets a conversation" means one of the operation's targets is a message of that conversation now.
enum FailedOperationMarks {
    typealias ConversationKey = (accountID: String, providerID: String)

    /// How an operation stopped standing in the way of a conversation's mark.
    enum Settlement {
        /// The provider applied it. `createdAt` is its `created_at`: failures created before it are settled.
        case confirmed(createdAt: Int64)
        /// It was a failure, and it no longer is one.
        case failureEnded
    }

    /// Applies the rules for a write that took the operation from `previousStatus` (nil when new) to its status.
    static func operationWritten(_ operation: Operation, previousStatus: OperationStatus?, in db: Database) throws {
        let settlement: Settlement
        if operation.status == .failed {
            guard previousStatus != .failed else { return }
            try mark(operation, in: db)
            return
        } else if operation.status == .confirmed, previousStatus != .confirmed {
            settlement = .confirmed(createdAt: MailStoreCodec.milliseconds(operation.createdAt))
        } else if previousStatus == .failed {
            settlement = .failureEnded
        } else {
            return
        }
        try settle(settlement, operationID: operation.id, conversations: conversations(ofOperation: operation.id, in: db), in: db)
    }

    /// The rules for the targets a live operation dropped because the provider took them (the outbox narrowing it to what
    /// is still owed): each of `conversations` the operation no longer targets had its part confirmed, and settles as a
    /// confirmation would. One it still targets waits for the rest, as the conversation's mark does.
    static func targetsTaken(from operation: Operation, in conversations: [ConversationKey], db: Database) throws {
        guard !conversations.isEmpty else { return }
        let stillTargeted = try db.cachedStatement(sql: """
            SELECT EXISTS (
                SELECT 1 FROM messages m
                CROSS JOIN operation_targets t
                    ON t.operation_id = ? AND t.account_id = m.account_id AND t.provider_id = m.provider_id
                WHERE m.account_id = ? AND m.conversation_provider_id = ?)
            """)
        // The key lookup first: almost no conversation carries a mark.
        let settled = try conversations.filter { conversation in
            try hasMark(conversation, in: db)
                && !(try Bool.fetchOne(stillTargeted, arguments: [operation.id, conversation.accountID, conversation.providerID]) ?? false)
        }
        try settle(.confirmed(createdAt: MailStoreCodec.milliseconds(operation.createdAt)), operationID: operation.id,
                   conversations: settled, in: db)
    }

    static func settle(_ settlement: Settlement, operationID: String, conversations: [ConversationKey], in db: Database) throws {
        let clear = try db.cachedStatement(sql: """
            UPDATE conversations SET failed_op_kind = NULL
            WHERE account_id = ? AND provider_id = ? AND failed_op_kind IS NOT NULL
            """)
        for conversation in conversations {
            // Every confirmed operation passes through here and almost no conversation carries a mark, so the
            // key lookup goes first and the join only runs where there is something to clear.
            guard try hasMark(conversation, in: db) else { continue }
            let standing: Bool
            switch settlement {
            case .confirmed(let createdAt):
                standing = try newerFailureExists(in: conversation, than: operationID, createdAt: createdAt, db: db)
            case .failureEnded:
                standing = try otherFailureExists(in: conversation, than: operationID, db: db)
            }
            guard !standing else { continue }
            try clear.execute(arguments: [conversation.accountID, conversation.providerID])
        }
    }

    static func hasMark(_ conversation: ConversationID, in db: Database) throws -> Bool {
        try hasMark((conversation.accountID.rawValue, conversation.providerID), in: db)
    }

    private static func hasMark(_ conversation: ConversationKey, in db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: """
            SELECT failed_op_kind IS NOT NULL FROM conversations WHERE account_id = ? AND provider_id = ?
            """), arguments: [conversation.accountID, conversation.providerID]) ?? false
    }
    static func acknowledge(_ conversation: ConversationID, in db: Database) throws {
        try db.cachedStatement(sql: """
            UPDATE conversations SET failed_op_kind = NULL
            WHERE account_id = ? AND provider_id = ? AND failed_op_kind IS NOT NULL
            """).execute(arguments: [conversation.accountID.rawValue, conversation.providerID])
    }

    /// Conversations the operation's saved targets belong to. Read before a delete: the targets cascade with it.
    static func conversations(ofOperation id: String, in db: Database) throws -> [ConversationKey] {
        try Row.fetchAll(db.cachedStatement(sql: """
            SELECT DISTINCT m.account_id, m.conversation_provider_id FROM operation_targets t
            JOIN messages m ON m.account_id = t.account_id AND m.provider_id = t.provider_id
            WHERE t.operation_id = ?
            """), arguments: [id]).map { (accountID: $0[0], providerID: $0[1]) }
    }

    private static func mark(_ operation: Operation, in db: Database) throws {
        let createdAt = MailStoreCodec.milliseconds(operation.createdAt)
        let current = try db.cachedStatement(sql: """
            SELECT failed_op_kind FROM conversations WHERE account_id = ? AND provider_id = ?
            """)
        let set = try db.cachedStatement(sql: """
            UPDATE conversations SET failed_op_kind = ? WHERE account_id = ? AND provider_id = ?
            """)
        for conversation in try conversations(ofOperation: operation.id, in: db) {
            let arguments: StatementArguments = [conversation.accountID, conversation.providerID]
            // No summary row (every message is spam, or the conversation is gone): nothing to mark.
            guard let row = try Row.fetchOne(current, arguments: arguments) else { continue }
            let existing: String? = row[0]
            if existing != nil,
               try newerFailureExists(in: conversation, than: operation.id, createdAt: createdAt, db: db) {
                continue
            }
            try set.execute(arguments: [operation.change.kind.rawValue, conversation.accountID, conversation.providerID])
        }
    }

    private static func otherFailureExists(in conversation: ConversationKey, than operationID: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: """
            SELECT EXISTS (
                SELECT 1 FROM messages m
                CROSS JOIN operation_targets t ON t.account_id = m.account_id AND t.provider_id = m.provider_id
                CROSS JOIN operations o ON o.id = t.operation_id
                WHERE m.account_id = ? AND m.conversation_provider_id = ? AND o.status = 'failed' AND o.id != ?)
            """), arguments: [conversation.accountID, conversation.providerID, operationID]) ?? false
    }

    private static func newerFailureExists(
        in conversation: ConversationKey,
        than operationID: String,
        createdAt: Int64,
        db: Database
    ) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: """
            SELECT EXISTS (
                SELECT 1 FROM messages m
                CROSS JOIN operation_targets t ON t.account_id = m.account_id AND t.provider_id = m.provider_id
                CROSS JOIN operations o ON o.id = t.operation_id
                WHERE m.account_id = ? AND m.conversation_provider_id = ?
                  AND o.status = 'failed' AND o.id != ?
                  AND (o.created_at > ? OR (o.created_at = ? AND o.id > ?)))
            """), arguments: [
                conversation.accountID, conversation.providerID, operationID, createdAt, createdAt, operationID,
            ]) ?? false
    }
}
