import Foundation
import GRDB

/// SQL for `snoozes` and `conversations.returned_at` (docs/DATA-MODEL.md, "Snoozes"). The rules, mirrored by
/// `InMemoryMailStore`:
/// - a snooze is written only for a conversation that is stored and holds mail put away (`holdsSnooze`: out of the
///   Inbox and out of the Trash, counting the user's own copies out), after the operations written with it;
/// - it ends on its own when a summary refresh finds its conversation no longer holding mail put away (back in the
///   Inbox, in the Trash, or gone: every message deleted or in Spam), and when mail that is not the user's own arrives
///   in it after it was snoozed: the provider puts such mail in the Inbox anyway. Mail the mute or a sender rule covers
///   is not news, so it leaves the snooze to the refresh (`ArrivalRule.keepsSnooze`);
/// - returning deletes it, applies and queues the operations, and marks the conversation `returned_at`, which a
///   refresh keeps only while the conversation is in the Inbox and no newer mail has come; an undo of what took it out
///   of the Inbox puts the mark back with its inverse operations (`Snooze.Change.returnedAt`).
enum SnoozeTable {
    /// Whether the conversation row `c` stands for mail put away, which a snooze needs: out of the Inbox, out of the
    /// Trash, and not one whose mail from others is all in the Trash while the user's own copies stay in Sent Items and
    /// Drafts (`MailActionRecord.isOwnFolderCopy`), as Move to Trash leaves them on Microsoft. Its return would otherwise
    /// bring the deleted mail back, or the user's own copy in its place. `Snooze.canHold` is the same rule in Swift, which
    /// the in-memory store and the window use.
    private static let holdsSnooze: String = {
        let own = "((m.roles & \(MailStoreCodec.inboxBit)) = 0 AND (m.roles & \(MailStoreCodec.sentBit | MailStoreCodec.draftsBit)) != 0)"
        let ofC = "m.account_id = c.account_id AND m.conversation_provider_id = c.provider_id AND (m.roles & \(MailStoreCodec.spamBit)) = 0"
        return """
            c.in_inbox = 0 AND c.in_trash = 0 AND NOT (
                EXISTS (SELECT 1 FROM messages m WHERE \(ofC) AND (m.roles & \(MailStoreCodec.trashBit)) != 0 AND NOT \(own))
                AND NOT EXISTS (SELECT 1 FROM messages m WHERE \(ofC) AND (m.roles & \(MailStoreCodec.trashBit)) = 0 AND NOT \(own)))
            """
    }()

    // MARK: Reads

    /// Joined to the summary rows, so a snooze whose conversation a wipe dropped stays out of sight (and out of the
    /// Later tile's count) until its mail is back.
    static func all(_ db: Database) throws -> [Snooze] {
        try Row.fetchAll(db.cachedStatement(sql: """
            SELECT s.account_id, s.provider_id, s.due_at, s.created_at FROM snoozes s
            JOIN conversations c ON c.account_id = s.account_id AND c.provider_id = s.provider_id
            ORDER BY s.due_at, s.account_id, s.provider_id
            """)).map { row in
            Snooze(conversationID: ConversationID(accountID: AccountID(row[0]), providerID: row[1]),
                   dueAt: MailStoreCodec.date(row[2]), createdAt: MailStoreCodec.date(row[3]))
        }
    }

    /// Whether `returnDue` would find anything, so the timer's common case never takes the writer.
    static func hasDue(at now: Date, in db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM snoozes WHERE due_at <= ?)"),
                          arguments: [MailStoreCodec.milliseconds(now)]) ?? false
    }

    // MARK: Writes

    /// After the caller has applied the operations that go with the changes, so a conversation just archived counts as
    /// out of the Inbox and one an undo moved back counts as in it. Rescheduling replaces the time and starts the snooze
    /// over (`created_at`); a return mark is put back where the conversation is in the Inbox (`markReturned`).
    static func set(_ changes: [Snooze.Change], now: Date, in db: Database) throws {
        let write = try db.cachedStatement(sql: """
            INSERT INTO snoozes (account_id, provider_id, due_at, created_at)
            SELECT ?, ?, ?, ? WHERE EXISTS (
                SELECT 1 FROM conversations c WHERE c.account_id = ? AND c.provider_id = ? AND \(holdsSnooze))
            ON CONFLICT(account_id, provider_id) DO UPDATE SET due_at = excluded.due_at, created_at = excluded.created_at
            """)
        let end = try db.cachedStatement(sql: "DELETE FROM snoozes WHERE account_id = ? AND provider_id = ?")
        let created = MailStoreCodec.milliseconds(now)
        for change in changes {
            let account = change.conversationID.accountID.rawValue
            let conversation = change.conversationID.providerID
            if let until = change.until {
                try write.execute(arguments: [account, conversation, MailStoreCodec.milliseconds(until), created, account, conversation])
            } else {
                try end.execute(arguments: [account, conversation])
            }
            if let returnedAt = change.returnedAt {
                try markReturned(change.conversationID, at: returnedAt, in: db)
            }
        }
    }

    /// Marks the conversation returned at `date` if it is in the Inbox and its newest mail is older, the rule a refresh
    /// keeps the mark by; otherwise the mark would be dropped by the next refresh anyway.
    static func markReturned(_ conversation: ConversationID, at date: Date, in db: Database) throws {
        let ms = MailStoreCodec.milliseconds(date)
        try db.cachedStatement(sql: """
            UPDATE conversations SET returned_at = ?
            WHERE account_id = ? AND provider_id = ? AND in_inbox = 1 AND latest_date_ms < ?
            """).execute(arguments: [ms, conversation.accountID.rawValue, conversation.providerID, ms])
    }

    /// Mail new to the store arrived in the conversation: a snooze set before it was received ends. The user's own sent
    /// mail and drafts never end one (replying to a snoozed conversation keeps it put away), and nor does spam. The upsert
    /// does not call it for mail the mute or a sender rule covers (`ArrivalRule.keepsSnooze`).
    static func endForArrival(of message: MessageMetadata, in db: Database) throws {
        guard message.roles.isDisjoint(with: [.sent, .drafts, .spam]) else { return }
        try db.cachedStatement(sql: "DELETE FROM snoozes WHERE account_id = ? AND provider_id = ? AND created_at < ?")
            .execute(arguments: [message.id.accountID.rawValue, message.conversationID.providerID,
                                 MailStoreCodec.milliseconds(message.date)])
    }

    /// Part of every summary refresh, before the touched set is cleared: a touched conversation that is back in the
    /// Inbox (⇧I, a drop, another device, new mail), in the Trash (on Microsoft, all but the user's own copies) or gone
    /// is no longer snoozed. Driven by the snoozes, a handful of rows, so a refresh with nothing snoozed costs nothing.
    static func endForTouched(in db: Database) throws {
        try db.cachedStatement(sql: """
            DELETE FROM snoozes
            WHERE EXISTS (SELECT 1 FROM temp.\(MailSchema.touchedTable) t
                          WHERE t.account_id = snoozes.account_id AND t.provider_id = snoozes.provider_id)
              AND NOT EXISTS (SELECT 1 FROM conversations c
                              WHERE c.account_id = snoozes.account_id AND c.provider_id = snoozes.provider_id
                                AND \(holdsSnooze))
            """).execute()
    }

    /// One transaction: every snooze due by `now` (at most `limit`, soonest first; for an account in `dueBy`, only those
    /// due by its date) is deleted, its operations applied and queued, and its conversation marked returned once the
    /// operations have put it back in the Inbox.
    static func returnDue(at now: Date, dueBy: [AccountID: Date], limit: Int,
                          operations: (ConversationID, [MessageMetadata]) -> [Operation],
                          in db: Database) throws -> [ConversationID] {
        let nowMS = MailStoreCodec.milliseconds(now)
        // Held-back rows are skipped after the read, so the read is not limited then (-1): they would fill the batch. What
        // is due at one moment is a handful of keys.
        let rows = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT account_id, provider_id, due_at FROM snoozes WHERE due_at <= ? ORDER BY due_at, account_id, provider_id LIMIT ?
            """), arguments: [nowMS, dueBy.isEmpty ? max(0, limit) : -1])
        let cutoffs = dueBy.mapValues(MailStoreCodec.milliseconds)
        let due = rows.compactMap { row -> ConversationID? in
            let id = ConversationID(accountID: AccountID(row[0]), providerID: row[1])
            if let cutoff = cutoffs[id.accountID], (row[2] as Int64) > cutoff { return nil }
            return id
        }.prefix(max(0, limit))
        let end = try db.cachedStatement(sql: "DELETE FROM snoozes WHERE account_id = ? AND provider_id = ?")
        var returned: [ConversationID] = []
        for conversation in due {
            try end.execute(arguments: [conversation.accountID.rawValue, conversation.providerID])
            let messages = try MessageTable.fetch(in: conversation, db: db)
            guard !messages.isEmpty else { continue }
            for operation in operations(conversation, messages) where !operation.targets.isEmpty {
                try OperationTable.enqueue(operation, in: db)
            }
            returned.append(conversation)
        }
        // After every operation, whose refreshes would otherwise judge the mark against the old Inbox state. Only a
        // conversation now in the Inbox takes it, and only when its mail is older, as the refresh rule keeps it.
        for conversation in returned {
            try markReturned(conversation, at: now, in: db)
        }
        return returned
    }
}
