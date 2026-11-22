import Foundation
import GRDB

/// SQL for `mail_times` (v20, docs/DATA-MODEL.md "Mail times"): the times a message's text names, kept with the message
/// (its foreign key cascades from `messages`) and never with its body, so an eviction keeps them. No observation reads it:
/// the reader asks when a conversation is selected.
enum MailTimeTable {
    /// A time as the store keeps it: its instant to the millisecond and its length to the second.
    static func normalized(_ time: MailTime, for message: MessageID) -> MailTime {
        MailTime(messageID: message, start: MailStoreCodec.date(MailStoreCodec.milliseconds(time.start)),
                 duration: seconds(time.duration).map(TimeInterval.init), phrase: time.phrase)
    }

    /// Whole seconds; nil for none, and for a value no clock names (not finite, or beyond a century).
    static func seconds(_ duration: TimeInterval?) -> Int64? {
        guard let duration, duration.isFinite, abs(duration) < 3_155_760_000 else { return nil }
        return Int64(duration.rounded())
    }

    /// The order `mailTimes(in:)` returns: start, then the message's id, then the order the message's times were saved in.
    static func precedes(_ lhs: (time: MailTime, ord: Int), _ rhs: (time: MailTime, ord: Int)) -> Bool {
        (MailStoreCodec.milliseconds(lhs.time.start), lhs.time.messageID.providerID, lhs.ord)
            < (MailStoreCodec.milliseconds(rhs.time.start), rhs.time.messageID.providerID, rhs.ord)
    }

    /// Replaces the message's times. Each takes its conversation from the message row, so the times of a message the
    /// store does not hold (a poll deleted it while its body was read) are dropped, as its body would be.
    static func save(_ times: [MailTime], for message: MessageID, in db: Database) throws {
        let accountID = message.accountID.rawValue
        try db.cachedStatement(sql: "DELETE FROM mail_times WHERE account_id = ? AND provider_id = ?")
            .execute(arguments: [accountID, message.providerID])
        guard !times.isEmpty else { return }
        let insert = try db.cachedStatement(sql: """
            INSERT INTO mail_times (account_id, provider_id, ord, conversation_provider_id, start_ms, duration_s, phrase)
            SELECT account_id, provider_id, ?, conversation_provider_id, ?, ?, ? FROM messages WHERE account_id = ? AND provider_id = ?
            """)
        for (ord, time) in times.enumerated() {
            try insert.execute(arguments: [ord, MailStoreCodec.milliseconds(time.start), seconds(time.duration), time.phrase,
                                           accountID, message.providerID])
        }
    }

    private static let conversationTimes = """
        SELECT provider_id, start_ms, duration_s, phrase FROM mail_times
        WHERE account_id = ? AND conversation_provider_id = ?
        ORDER BY start_ms, provider_id, ord
        """

    /// One range of `mail_times_by_conversation`.
    static func times(in conversation: ConversationID, in db: Database) throws -> [MailTime] {
        let accountID = conversation.accountID
        return try Row.fetchAll(db.cachedStatement(sql: conversationTimes),
                                arguments: [accountID.rawValue, conversation.providerID]).map { row in
            let providerID: String = row[0], start: Int64 = row[1], duration: Int64? = row[2], phrase: String = row[3]
            return MailTime(messageID: MessageID(accountID: accountID, providerID: providerID), start: MailStoreCodec.date(start),
                            duration: duration.map(TimeInterval.init), phrase: phrase)
        }
    }

    static func explainTimes(in conversation: ConversationID, in db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + conversationTimes,
                         arguments: [conversation.accountID.rawValue, conversation.providerID]).map { $0["detail"] }
    }

    /// A message the provider now reports in another conversation takes its times there (the upsert calls this only then).
    static func messageMoved(_ message: MessageID, to conversation: String, in db: Database) throws {
        try db.cachedStatement(sql: """
            UPDATE mail_times SET conversation_provider_id = ? WHERE account_id = ? AND provider_id = ?
            """).execute(arguments: [conversation, message.accountID.rawValue, message.providerID])
    }
}
