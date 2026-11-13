import Foundation
import GRDB

/// SQL for `pending_sends`, the outbox of undo-sends and Send Later messages.
enum PendingSendTable {
    private static let columns = "id, account_id, message_json, created_at, send_after, status, attempts, last_error, draft_id"

    static func save(_ send: PendingSend, in db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO pending_sends (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                account_id = excluded.account_id, message_json = excluded.message_json,
                created_at = excluded.created_at, send_after = excluded.send_after, status = excluded.status,
                attempts = excluded.attempts, last_error = excluded.last_error, draft_id = excluded.draft_id
            """).execute(arguments: [
                send.id,
                send.message.accountID.rawValue,
                try MailStoreCodec.json(send.message),
                MailStoreCodec.milliseconds(send.createdAt),
                MailStoreCodec.milliseconds(send.sendAfter),
                send.status.rawValue,
                send.attempts,
                send.lastError,
                send.draftID?.uuidString,
            ])
    }

    static func delete(id: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM pending_sends WHERE id = ?", arguments: [id])
    }

    static func all(_ db: Database) throws -> [PendingSend] {
        try Row.fetchAll(db, sql: "SELECT \(columns) FROM pending_sends ORDER BY created_at, id").map { row in
            PendingSend(
                id: row[0],
                message: try MailStoreCodec.decode(OutgoingMessage.self, from: row[2]),
                createdAt: MailStoreCodec.date(row[3]),
                sendAfter: MailStoreCodec.date(row[4]),
                status: PendingSendStatus(rawValue: row[5]) ?? .scheduled,
                attempts: row[6],
                lastError: row[7],
                draftID: (row[8] as String?).flatMap(UUID.init(uuidString:))
            )
        }
    }
}
