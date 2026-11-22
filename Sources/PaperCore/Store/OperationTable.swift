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

    /// Replays the live operations queued for the message on top of `metadata` (provider state), oldest first
    /// so the result is deterministic, and records on each target row the state its operation now replaces.
    /// That record is what a give-up puts back (see `update`), so it follows the provider's latest report.
    static func replayLive(on metadata: MessageMetadata, in db: Database) throws -> MessageMetadata {
        var state = metadata
        for (operationID, change) in try liveOperations(on: metadata.id, newerThan: nil, in: db) {
            try recordPrior(state, operationID: operationID, in: db)
            state = applying(change, to: state)
        }
        return state
    }

    /// Live operations targeting the message, oldest first; with `newerThan`, only those queued after it.
    ///
    /// Oldest is `created_at`, then `rowid`: the order rows were queued in. Separate `perform` calls (an undo's steps)
    /// often fall in one millisecond, and ordered then by their random ids an undone trash could replay its archive
    /// before its restore. `rowid` grows with every insert and an update (`save`'s upsert) keeps it.
    private static func liveOperations(
        on id: MessageID,
        newerThan operation: Operation?,
        in db: Database
    ) throws -> [(id: String, change: MetadataChange)] {
        let rows: [Row]
        if let operation {
            let createdAt = MailStoreCodec.milliseconds(operation.createdAt)
            rows = try Row.fetchAll(db.cachedStatement(sql: """
                SELECT o.id, o.change_json FROM operation_targets t
                JOIN operations o ON o.id = t.operation_id
                WHERE t.account_id = ? AND t.provider_id = ? AND o.status IN \(liveStatusList)
                  AND (o.created_at > ? OR (o.created_at = ? AND o.rowid > (SELECT rowid FROM operations WHERE id = ?)))
                ORDER BY o.created_at, o.rowid
                """), arguments: [id.accountID.rawValue, id.providerID, createdAt, createdAt, operation.id])
        } else {
            rows = try Row.fetchAll(db.cachedStatement(sql: """
                SELECT o.id, o.change_json FROM operation_targets t
                JOIN operations o ON o.id = t.operation_id
                WHERE t.account_id = ? AND t.provider_id = ? AND o.status IN \(liveStatusList)
                ORDER BY o.created_at, o.rowid
                """), arguments: [id.accountID.rawValue, id.providerID])
        }
        return try rows.map { (id: $0[0], change: try MailStoreCodec.decode(MetadataChange.self, from: $0[1])) }
    }

    /// Stores the flags `state` has as what the operation replaces on that target (`operation_targets.prior_*`).
    private static func recordPrior(_ state: MessageMetadata, operationID: String, in db: Database) throws {
        try db.cachedStatement(sql: """
            UPDATE operation_targets SET prior_roles = ?, prior_is_read = ?, prior_is_starred = ?
            WHERE operation_id = ? AND account_id = ? AND provider_id = ?
            """).execute(arguments: [
                MailStoreCodec.roleBits(state.roles), state.isRead, state.isStarred,
                operationID, state.id.accountID.rawValue, state.id.providerID,
            ])
    }

    /// Puts back what a just-failed operation changed on each target it recorded a prior for, with the live
    /// operations queued after it replayed on top (their priors move to the restored state). Live operations
    /// queued before it are already part of its prior. Targets without a prior (queued by an older build and
    /// never reported by a poll since) and targets that are gone are left as they are.
    private static func giveBack(_ operation: Operation, in db: Database) throws {
        let priors = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT provider_id, prior_roles, prior_is_read, prior_is_starred FROM operation_targets
            WHERE operation_id = ? AND prior_roles IS NOT NULL
            """), arguments: [operation.id])
        for prior in priors {
            let id = MessageID(accountID: operation.accountID, providerID: prior[0])
            guard let current = try MessageTable.fetch(id, in: db) else { continue }
            var state = current
            state.roles = MailStoreCodec.roles(prior[1])
            state.isRead = prior[2]
            state.isStarred = prior[3]
            // An answer is local state no provider reports, so what it replaced travels in the operation itself.
            let isAnswer = operation.change.kind == .answerInvitation
            if case .answerInvitation(let answer) = operation.change { state.invitationReply = answer.previous }
            for (newerID, change) in try liveOperations(on: id, newerThan: operation, in: db) {
                try recordPrior(state, operationID: newerID, in: db)
                // A newer answer named this one as what it replaced, and this one never went out: it now replaces what
                // this one replaced, so its own give-up puts back only an answer that went out (or none).
                if isAnswer, case .answerInvitation(var newer) = change, newer.previous != state.invitationReply {
                    newer.previous = state.invitationReply
                    try db.cachedStatement(sql: "UPDATE operations SET change_json = ? WHERE id = ?")
                        .execute(arguments: [try MailStoreCodec.json(MetadataChange.answerInvitation(newer)), newerID])
                }
                state = applying(change, to: state)
            }
            guard state != current else { continue }
            try MessageTable.updateFlags(state, in: db)
            try ConversationTable.touch(current.conversationID, in: db)
        }
    }

    // MARK: Writes

    static func enqueue(_ operation: Operation, in db: Database) throws {
        try MailSchema.ensureTouchedTable(db)
        var replaced: [MessageMetadata] = []
        for target in operation.targets {
            guard let current = try MessageTable.fetch(target, in: db) else { continue }
            replaced.append(current)
            try MessageTable.updateFlags(applying(operation.change, to: current), in: db)
            try ConversationTable.touch(current.conversationID, in: db)
        }
        let previous = try savedState(of: operation.id, in: db)?.status
        try save(operation, in: db)
        // After the save, which creates the target rows the priors live on.
        for current in replaced { try recordPrior(current, operationID: operation.id, in: db) }
        try ConversationTable.refreshTouched(db)
        try FailedOperationMarks.operationWritten(operation, previousStatus: previous, in: db)
    }

    static func update(_ operation: Operation, in db: Database) throws {
        try MailSchema.ensureTouchedTable(db)
        let previous = try savedState(of: operation.id, in: db)?.status
        if let previous, previous.isLive, operation.status.isLive {
            try updateLive(operation, previous: previous, in: db)
            return
        }
        // A live operation written out of the outbox (given up, or confirmed) may drop the targets the provider took
        // on its last attempt at the same time; read before the save, which deletes their target rows.
        let taken = previous?.isLive == true
            ? try droppedTargets(of: operation, in: db).taken : []
        try touchTargets(of: operation.id, in: db)
        try save(operation, in: db)
        // A live operation written as failed has been given up: it stops winning, and the provider never took
        // the change (or a poll has already reported it, which its prior then holds), so it is put back here,
        // in the transaction that marks the conversation, rather than waiting for a poll that will not come.
        if operation.status == .failed, let previous, previous.isLive {
            try giveBack(operation, in: db)
        }
        try touchTargets(of: operation.id, in: db)
        try ConversationTable.refreshTouched(db)
        // After the refresh, so the summary rows the mark lands on exist and are current.
        try FailedOperationMarks.operationWritten(operation, previousStatus: previous, in: db)
        try FailedOperationMarks.targetsTaken(from: operation, in: taken, db: db)
    }

    /// An operation that stays live (the outbox's write-ahead before each attempt, a retry's backoff, a throttle, a
    /// narrowing to the targets still owed): `has_pending_ops` and the failed mark cannot change for a target it keeps,
    /// so only the conversations of the targets it drops or gains are refreshed. Refreshing every target's conversation
    /// on each attempt held the writer for 200 ms on an archive of 1,667 messages (Always Archive on a busy sender), which
    /// the user's next key action waited behind.
    private static func updateLive(_ operation: Operation, previous: OperationStatus, in db: Database) throws {
        let (existing, taken) = try droppedTargets(of: operation, in: db)
        let wanted = Set(operation.targets.map(\.providerID))
        // Before the save, which deletes their target rows; the gained ones after it, which creates theirs.
        try touchConversations(of: existing.subtracting(wanted), accountID: operation.accountID, in: db)
        try save(operation, in: db)
        try touchConversations(of: wanted.subtracting(existing), accountID: operation.accountID, in: db)
        if existing != wanted { try ConversationTable.refreshTouched(db) }
        try FailedOperationMarks.operationWritten(operation, previousStatus: previous, in: db)
        // The part that went out is confirmed: the failures it settles must not wait for the rest, which may take many
        // drains (`SyncTuning.maxApplyCallsPerDrain`) or never land.
        try FailedOperationMarks.targetsTaken(from: operation, in: taken, db: db)
    }

    /// The operation's saved targets, and the conversations of those it no longer lists. Only the outbox narrows a live
    /// operation, and only to the targets still owed (`OperationRunner`): every target it drops is one the provider took.
    private static func droppedTargets(of operation: Operation, in db: Database)
        throws -> (existing: Set<String>, taken: [FailedOperationMarks.ConversationKey]) {
        let existing = Set(try String.fetchAll(
            db.cachedStatement(sql: "SELECT provider_id FROM operation_targets WHERE operation_id = ?"), arguments: [operation.id]
        ))
        let dropped = existing.subtracting(operation.targets.map(\.providerID))
        guard !dropped.isEmpty else { return (existing, []) }
        let taken = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT DISTINCT m.account_id, m.conversation_provider_id FROM json_each(?) j
            CROSS JOIN messages m ON m.account_id = ? AND m.provider_id = j.value
            """), arguments: [try MailStoreCodec.json(Array(dropped)), operation.accountID.rawValue])
            .map { (accountID: $0[0] as String, providerID: $0[1] as String) }
        return (existing, taken)
    }

    /// Marks the conversations of the account's messages `providerIDs` for the refresh.
    private static func touchConversations(of providerIDs: Set<String>, accountID: AccountID, in db: Database) throws {
        guard !providerIDs.isEmpty else { return }
        try db.cachedStatement(sql: """
            INSERT OR IGNORE INTO temp.\(MailSchema.touchedTable) (account_id, provider_id)
            SELECT m.account_id, m.conversation_provider_id FROM json_each(?) j
            CROSS JOIN messages m ON m.account_id = ? AND m.provider_id = j.value
            """).execute(arguments: [try MailStoreCodec.json(Array(providerIDs)), accountID.rawValue])
    }

    /// Removes an operation without saying whether it landed: its local change stays, and the failed mark
    /// changes only when the row itself was failed (pruning), never for a live row a poll settled.
    static func delete(id: String, in db: Database) throws {
        guard let removed = try remove(id: id, in: db), removed.status == .failed else { return }
        try FailedOperationMarks.settle(.failureEnded, operationID: id, conversations: removed.conversations, in: db)
    }

    /// Removes an operation the provider applied, which settles failures created before it.
    static func confirm(id: String, in db: Database) throws {
        guard let removed = try remove(id: id, in: db) else { return }
        try FailedOperationMarks.settle(
            .confirmed(createdAt: removed.createdAt), operationID: id, conversations: removed.conversations, in: db
        )
    }

    /// What the mark rules need from a deleted row, read before the delete because the targets cascade with it.
    private struct Removed {
        var status: OperationStatus
        var createdAt: Int64
        var conversations: [FailedOperationMarks.ConversationKey]
    }

    /// Deletes the row and refreshes its conversations. Nil when there was no such row.
    private static func remove(id: String, in db: Database) throws -> Removed? {
        try MailSchema.ensureTouchedTable(db)
        guard let state = try savedState(of: id, in: db) else { return nil }
        let conversations = try FailedOperationMarks.conversations(ofOperation: id, in: db)
        try touchTargets(of: id, in: db)
        try db.execute(sql: "DELETE FROM operations WHERE id = ?", arguments: [id])
        try ConversationTable.refreshTouched(db)
        return Removed(status: state.status, createdAt: state.createdAt, conversations: conversations)
    }

    /// Failed rows whose expiry (`next_attempt_at`, see `Operation.nextAttemptAt`) has passed, oldest first,
    /// each deleted through `delete` so its conversations' marks settle in the same transaction.
    static func pruneFailed(accountID: AccountID, now: Date, in db: Database) throws -> Int {
        let ids = try String.fetchAll(db.cachedStatement(sql: """
            SELECT id FROM operations WHERE \(expiredFailure) ORDER BY created_at, rowid
            """), arguments: [accountID.rawValue, MailStoreCodec.milliseconds(now)])
        for id in ids { try delete(id: id, in: db) }
        return ids.count
    }

    /// Whether `pruneFailed` would find anything, so the common case can stay off the writer.
    static func hasExpiredFailures(accountID: AccountID, now: Date, in db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM operations WHERE \(expiredFailure))"),
                          arguments: [accountID.rawValue, MailStoreCodec.milliseconds(now)]) ?? false
    }

    /// Takes the account id and the cutoff in milliseconds; served by `operations_by_account_status`.
    private static let expiredFailure = """
        account_id = ? AND status = 'failed' AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
        """

    private static func savedState(of id: String, in db: Database) throws -> (status: OperationStatus, createdAt: Int64)? {
        guard let row = try Row.fetchOne(db.cachedStatement(sql: "SELECT status, created_at FROM operations WHERE id = ?"),
                                         arguments: [id]) else { return nil }
        return (OperationStatus(rawValue: row[0]) ?? .pending, row[1])
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
        // Target rows are kept across updates rather than rebuilt: they carry the priors a give-up puts back.
        let existing = Set(try String.fetchAll(
            db.cachedStatement(sql: "SELECT provider_id FROM operation_targets WHERE operation_id = ?"),
            arguments: [operation.id]
        ))
        let wanted = Set(operation.targets.map(\.providerID))
        guard existing != wanted else { return }
        let removed = existing.subtracting(wanted)
        if !removed.isEmpty {
            // One statement: a narrowing after a throttle may drop thousands at once.
            try db.cachedStatement(sql: """
                DELETE FROM operation_targets
                WHERE operation_id = ? AND provider_id IN (SELECT value FROM json_each(?))
                """).execute(arguments: [operation.id, try MailStoreCodec.json(Array(removed))])
        }
        let insertTarget = try db.cachedStatement(sql: """
            INSERT OR IGNORE INTO operation_targets (operation_id, account_id, provider_id) VALUES (?, ?, ?)
            """)
        for target in operation.targets where !existing.contains(target.providerID) {
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
            ORDER BY created_at, rowid LIMIT ?
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
