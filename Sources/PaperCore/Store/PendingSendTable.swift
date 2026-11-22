import Foundation
import GRDB

/// SQL for `pending_sends`, the outbox of undo-sends and Send Later messages.
///
/// The message (`message_json`, attachments inline) is the table's last column and its summary (`summary_json`, the
/// recipients, subject and plain text) comes before it (v18), so a read of the summaries never walks the message's
/// overflow pages: a Send Later message can wait for days with megabytes of attachments, and the outbox is read every
/// second while a send is on its way.
enum PendingSendTable {
    private static let columns = "id, account_id, created_at, send_after, status, attempts, last_error, draft_id"

    /// What `summary_json` holds: the message as the outbox's readers show it.
    private struct StoredSummary: Codable {
        var to: [EmailAddress]
        var cc: [EmailAddress]
        var bcc: [EmailAddress]
        var subject: String
        var text: String
        var inReplyTo: MessageID?
        var isForward: Bool
        var hasFiles: Bool
    }

    static func save(_ send: PendingSend, in db: Database) throws {
        let summary = PendingSendSummary(send)
        let stored = StoredSummary(to: summary.to, cc: summary.cc, bcc: summary.bcc, subject: summary.subject, text: summary.text,
                                   inReplyTo: summary.inReplyTo, isForward: summary.isForward, hasFiles: summary.hasFiles)
        try db.cachedStatement(sql: """
            INSERT INTO pending_sends (\(columns), summary_json, message_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                account_id = excluded.account_id, created_at = excluded.created_at, send_after = excluded.send_after,
                status = excluded.status, attempts = excluded.attempts, last_error = excluded.last_error,
                draft_id = excluded.draft_id, summary_json = excluded.summary_json, message_json = excluded.message_json
            """).execute(arguments: [
                send.id,
                send.message.accountID.rawValue,
                MailStoreCodec.milliseconds(send.createdAt),
                MailStoreCodec.milliseconds(send.sendAfter),
                send.status.rawValue,
                send.attempts,
                send.lastError,
                send.draftID?.uuidString,
                try MailStoreCodec.json(stored),
                try MailStoreCodec.json(send.message),
            ])
    }

    /// The state only: the message is never rewritten for a status change.
    static func updateState(_ send: PendingSendSummary, in db: Database) throws {
        try db.cachedStatement(sql: """
            UPDATE pending_sends SET send_after = ?, status = ?, attempts = ?, last_error = ? WHERE id = ?
            """).execute(arguments: [
                MailStoreCodec.milliseconds(send.sendAfter),
                send.status.rawValue,
                send.attempts,
                send.lastError,
                send.id,
            ])
    }

    static func delete(id: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM pending_sends WHERE id = ?", arguments: [id])
    }

    static func all(_ db: Database) throws -> [PendingSend] {
        try Row.fetchAll(db, sql: "SELECT \(columns), message_json FROM pending_sends ORDER BY created_at, id").map(send(from:))
    }

    static func send(id: String, in db: Database) throws -> PendingSend? {
        try Row.fetchOne(db, sql: "SELECT \(columns), message_json FROM pending_sends WHERE id = ?", arguments: [id]).map(send(from:))
    }

    /// The message is read only for a row with no summary, one a build from before v18 queued.
    static func summaries(_ db: Database) throws -> [PendingSendSummary] {
        try Row.fetchAll(db, sql: """
            SELECT \(columns), summary_json, CASE WHEN summary_json IS NULL THEN message_json END
            FROM pending_sends ORDER BY created_at, id
            """).map { row in
            if let json = row[8] as String? {
                let stored = try MailStoreCodec.decode(StoredSummary.self, from: json)
                return PendingSendSummary(
                    id: row[0], accountID: AccountID(row[1]), createdAt: MailStoreCodec.date(row[2]), sendAfter: MailStoreCodec.date(row[3]),
                    status: status(row[4]), attempts: row[5], lastError: row[6], draftID: draftID(row[7]), to: stored.to, cc: stored.cc,
                    bcc: stored.bcc, subject: stored.subject, text: stored.text, inReplyTo: stored.inReplyTo, isForward: stored.isForward,
                    hasFiles: stored.hasFiles
                )
            }
            return PendingSendSummary(try send(from: row, messageColumn: 9))
        }
    }

    private static func send(from row: Row) throws -> PendingSend {
        try send(from: row, messageColumn: 8)
    }

    private static func send(from row: Row, messageColumn: Int) throws -> PendingSend {
        PendingSend(
            id: row[0],
            message: try MailStoreCodec.decode(OutgoingMessage.self, from: row[messageColumn]),
            createdAt: MailStoreCodec.date(row[2]),
            sendAfter: MailStoreCodec.date(row[3]),
            status: status(row[4]),
            attempts: row[5],
            lastError: row[6],
            draftID: draftID(row[7])
        )
    }

    /// A value a build does not know reads as `scheduled`.
    private static func status(_ raw: String) -> PendingSendStatus {
        PendingSendStatus(rawValue: raw) ?? .scheduled
    }

    private static func draftID(_ raw: String?) -> UUID? {
        raw.flatMap(UUID.init(uuidString:))
    }
}
