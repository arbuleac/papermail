import SQLite3
import XCTest
@testable import SSCore

/// Opening a database written by an older build. The v1 file is built here with plain SQLite (the v1 DDL plus
/// GRDB's migration ledger saying only v1 ran), so the test exercises exactly what an upgrading user's file
/// goes through: every later migration, then the store reading the result.
final class MailSchemaMigrationTests: XCTestCase {
    private var directory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSchemaMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    private let base: Int64 = 1_767_225_600_000 // 2026-01-01T00:00:00Z in ms

    /// Twelve accounts, inserted out of creation order, two of them created in the same millisecond so the id
    /// has to break the tie.
    private let accounts: [(id: String, addedAt: Int64)] = [
        ("acct-k", 10_000), ("acct-a", 0), ("acct-c", 2_000), ("acct-b", 1_000), ("acct-e", 4_000),
        ("acct-d", 3_000), ("acct-g", 6_000), ("acct-f", 5_000), ("acct-i", 8_000), ("acct-h", 7_000),
        ("acct-j2", 9_000), ("acct-j1", 9_000),
    ]

    private func writeVersion1Database(at path: String, then extraSQL: String = "") throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            throw XCTSkip("could not create a SQLite file")
        }
        defer { sqlite3_close(db) }
        func run(_ sql: String) throws {
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
                let text = message.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(message)
                XCTFail("v1 setup failed: \(text)")
                throw CancellationError()
            }
        }
        try run(MailSchema.v1)
        try run("""
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
            INSERT INTO grdb_migrations (identifier) VALUES ('v1-mailbox');
            """)
        for account in accounts {
            try run("""
                INSERT INTO accounts (id, kind, email, display_name, color_hex, added_at)
                VALUES ('\(account.id)', 'gmail', '\(account.id)@example.com', 'Owner', '#4A90E2', \(base + account.addedAt));
                """)
        }
        // A message with a v1 body row and its conversation summary, as the v1 store would have left them.
        let rendered = try MailStoreCodec.compress("<div>Hello there</div>").map { String(format: "%02X", $0) }.joined()
        try run("""
            INSERT INTO messages (account_id, provider_id, conversation_provider_id, references_json, subject, snippet,
                                  from_json, to_json, cc_json, bcc_json, reply_to_json, date_ms, roles, is_read,
                                  is_starred, inbox_section, has_attachments, label_ids_json, has_body)
            VALUES ('acct-a', 'm1', 'c1', '[]', 'Hello', 'Hello there', '{"address":"bob@example.com","name":"Bob"}',
                    '[]', '[]', '[]', '[]', \(base + 60_000), 1, 0, 0, 'unknown', 0, '[]', 1);
            INSERT INTO bodies (account_id, provider_id, html, text, rendered_html, plain_text, attachments_json)
            VALUES ('acct-a', 'm1', NULL, NULL, X'\(rendered)', 'Hello there', '[]');
            INSERT INTO message_fts(rowid, subject, participants, body)
            SELECT id, subject, participants, body FROM message_fts_content;
            INSERT INTO conversations (account_id, provider_id, subject, snippet, participants_json, latest_date_ms,
                                       latest_provider_id, message_count, unread_count, is_starred, has_attachments,
                                       in_inbox, in_sent, in_drafts, in_trash, inbox_section, has_pending_ops)
            VALUES ('acct-a', 'c1', 'Hello', 'Hello there', '[{"address":"bob@example.com","name":"Bob"}]',
                    \(base + 60_000), 'm1', 1, 1, 0, 0, 1, 0, 0, 0, 'unknown', 0);
            """)
        if !extraSQL.isEmpty { try run(extraSQL) }
    }

    func testVersion1DatabaseMigratesAndBackfillsInkSlots() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)

        let store = try SQLiteMailStore(path: path)
        defer { try? store.close() }

        // Creation order, lowest unused slot each time, wrapping after ten; the tie goes to the smaller id.
        let migrated = try store.accounts()
        XCTAssertEqual(migrated.map(\.id.rawValue), [
            "acct-a", "acct-b", "acct-c", "acct-d", "acct-e", "acct-f", "acct-g", "acct-h", "acct-i", "acct-j1",
            "acct-j2", "acct-k",
        ])
        XCTAssertEqual(migrated.map(\.inkSlot), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1])
        XCTAssertEqual(migrated.map(\.monogram), Array(repeating: nil, count: accounts.count))
        XCTAssertEqual(migrated.first?.colorHex, "#4A90E2", "existing columns survive")

        // The engine's rule agrees with the backfill, so the next account added takes the slot it would have.
        var taken: [Int] = []
        for _ in migrated { taken.append(AccountInkSlot.next(taken: taken)) }
        XCTAssertEqual(taken, migrated.map(\.inkSlot))

        // Bodies stored by v1 keep NULL facts, which render as styled.
        let message = MessageID(accountID: AccountID("acct-a"), providerID: "m1")
        let body = try XCTUnwrap(try store.body(for: message))
        XCTAssertEqual(body.plainText, "Hello there")
        XCTAssertNil(body.typesetting)
        XCTAssertNil(body.declaresColors)
        XCTAssertNil(body.coveredByNewYork)
        XCTAssertNil(body.hasQuotedContent)
        let payload = RenderPayloadBuilder().build(
            messages: [try XCTUnwrap(try store.message(message))], bodies: [message: body],
            accounts: Dictionary(uniqueKeysWithValues: migrated.map { ($0.id, $0) })
        )
        XCTAssertEqual(payload.messages.first?.typesetting, .styled)
        XCTAssertEqual(payload.messages.first?.declaresColors, true)

        // The v1 summary row reads back unmarked and the list query works over the new column.
        let inbox = try store.conversations(ConversationQuery(view: .inbox))
        XCTAssertEqual(inbox.map(\.id.providerID), ["c1"])
        XCTAssertNil(inbox.first?.failedOperation)
        XCTAssertEqual(inbox.first?.unreadCount, 1)

        // And every new column takes writes.
        try store.setInkSlot(9, for: AccountID("acct-a"))
        try store.setMonogram("Ex", for: AccountID("acct-a"))
        XCTAssertEqual(try store.accounts().first?.inkSlot, 9)
        XCTAssertEqual(try store.accounts().first?.monogram, "Ex")
        var stored = body
        stored.typesetting = .unstyled
        stored.declaresColors = false
        stored.coveredByNewYork = true
        try store.saveBody(stored, for: message)
        XCTAssertEqual(try store.body(for: message)?.typesetting, .unstyled)
        var operation = Operation(accountID: AccountID("acct-a"), change: .archive, targets: [message])
        try store.enqueue(operation)
        XCTAssertTrue(try store.conversations(ConversationQuery(view: .inbox)).isEmpty)
        operation.status = .failed
        try store.updateOperation(operation)
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all)).first?.failedOperation, .archive)
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .inbox)).first?.failedOperation, .archive,
                       "the give-up put the conversation back, through the v6 prior columns")
    }

    func testOperationsQueuedBeforeV6GiveBackOnceAPollReportsTheirTargets() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        let star = try MailStoreCodec.json(MetadataChange.setStarred(true))
        let read = try MailStoreCodec.json(MetadataChange.setRead(true))
        // Two operations an older build queued on m1, with their local effects already applied.
        try writeVersion1Database(at: path, then: """
            UPDATE messages SET is_starred = 1, is_read = 1 WHERE provider_id = 'm1';
            INSERT INTO operations (id, account_id, change_json, targets_json, created_at, status, attempts)
            VALUES ('op-star', 'acct-a', '\(star)', '["m1"]', \(base + 70_000), 'pending', 0),
                   ('op-read', 'acct-a', '\(read)', '["m1"]', \(base + 71_000), 'pending', 0);
            INSERT INTO operation_targets (operation_id, account_id, provider_id)
            VALUES ('op-star', 'acct-a', 'm1'), ('op-read', 'acct-a', 'm1');
            """)
        let store = try SQLiteMailStore(path: path)
        defer { try? store.close() }
        let account = AccountID("acct-a")
        let id = MessageID(accountID: account, providerID: "m1")
        func giveUp(_ operationID: String, _ change: MetadataChange, at offset: Int64) throws {
            try store.updateOperation(Operation(
                id: operationID, accountID: account, change: change, targets: [id],
                createdAt: MailStoreCodec.date(base + offset), status: .failed, attempts: 25,
                nextAttemptAt: MailStoreCodec.date(base + offset + 86_400_000)
            ))
        }

        // Nothing recorded what the read replaced, so giving it up leaves the message as it is.
        try giveUp("op-read", .setRead(true), at: 71_000)
        XCTAssertEqual(try store.message(id)?.isRead, true)

        // A poll reports m1 as the provider has it; the star still wins and now knows what it replaced.
        var reported = try XCTUnwrap(try store.message(id))
        reported.isStarred = false
        reported.isRead = false
        try store.upsertMessages([reported])
        XCTAssertEqual(try store.message(id)?.isStarred, true)
        try giveUp("op-star", .setStarred(true), at: 70_000)
        XCTAssertEqual(try store.message(id)?.isStarred, false)
        // The row names the newer of the two failures.
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all)).first?.failedOperation, .markRead)
    }

    func testReopeningAMigratedDatabaseChangesNothing() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        do {
            let store = try SQLiteMailStore(path: path)
            try store.setInkSlot(5, for: AccountID("acct-b"))
            try store.close()
        }
        // The backfill ran once: a second open must not hand the slots out again.
        let reopened = try SQLiteMailStore(path: path)
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.accounts().first { $0.id == AccountID("acct-b") }?.inkSlot, 5)
    }
}
