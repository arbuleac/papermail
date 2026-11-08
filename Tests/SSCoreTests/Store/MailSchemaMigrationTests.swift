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
        XCTAssertEqual(migrated.first?.email, "acct-a@example.com", "existing columns survive")

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

    /// M1: v3 left the design facts of earlier bodies NULL, which read as styled with colours, so in Dark mode
    /// every old message, plain ones included, took the colours notice. A plain body is recognised by its
    /// wrapper at once, and the engine backfills the facts from the stored source.
    func testBodiesStoredBeforeV3RenderPlainAndGetTheirFactsBackfilled() async throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        let plain = try MailStoreCodec.compress("<div class=\"ss-body ss-plain\"><p>Lunch at noon?</p></div>")
            .map { String(format: "%02X", $0) }.joined()
        let text = try MailStoreCodec.compress("Lunch at noon?").map { String(format: "%02X", $0) }.joined()
        let source = "<html><body style=\"background:#fde\"><p>Big sale</p></body></html>"
        let styledHTML = try MailStoreCodec.compress(source).map { String(format: "%02X", $0) }.joined()
        let styled = try MailStoreCodec.compress("<div class=\"ss-body\"><p>Big sale</p></div>").map { String(format: "%02X", $0) }.joined()
        try writeVersion1Database(at: path, then: """
            INSERT INTO messages (account_id, provider_id, conversation_provider_id, references_json, subject, snippet,
                                  from_json, to_json, cc_json, bcc_json, reply_to_json, date_ms, roles, is_read,
                                  is_starred, inbox_section, has_attachments, label_ids_json, has_body)
            VALUES ('acct-a', 'm2', 'c2', '[]', 'Lunch', 'Lunch at noon?', '{"address":"bob@example.com","name":"Bob"}',
                    '[]', '[]', '[]', '[]', \(base + 70_000), 1, 0, 0, 'unknown', 0, '[]', 1),
                   ('acct-a', 'm3', 'c3', '[]', 'Sale', 'Big sale', '{"address":"shop@example.com","name":"Shop"}',
                    '[]', '[]', '[]', '[]', \(base + 80_000), 1, 0, 0, 'unknown', 0, '[]', 1);
            INSERT INTO bodies (account_id, provider_id, html, text, rendered_html, plain_text, attachments_json)
            VALUES ('acct-a', 'm2', NULL, X'\(text)', X'\(plain)', 'Lunch at noon?', '[]'),
                   ('acct-a', 'm3', X'\(styledHTML)', NULL, X'\(styled)', 'Big sale', '[]');
            """)
        let store = try SQLiteMailStore(path: path)
        defer { try? store.close() }
        let account = AccountID("acct-a")
        let plainID = MessageID(accountID: account, providerID: "m2")
        let styledID = MessageID(accountID: account, providerID: "m3")
        let accounts = Dictionary(uniqueKeysWithValues: try store.accounts().map { ($0.id, $0) })

        // Before any backfill: the plain body reads as plain from its wrapper, with no parse.
        let plainBody = try XCTUnwrap(try store.body(for: plainID))
        XCTAssertNil(plainBody.typesetting)
        let payload = RenderPayloadBuilder().build(messages: [try XCTUnwrap(try store.message(plainID))], bodies: [plainID: plainBody],
                                                   accounts: accounts)
        XCTAssertEqual(payload.messages.first?.typesetting, .plain)
        XCTAssertEqual(payload.messages.first?.declaresColors, false)

        // The engine's backfill: every body v3 left NULL, worked out again from the stored source.
        XCTAssertEqual(Set(try store.messageIDsMissingDesignFacts(accountID: account, limit: 10)), [MessageID(accountID: account, providerID: "m1"), plainID, styledID])
        let hydrator = Hydrator(accountID: account, store: store, provider: ScriptedProvider(accountID: account, kind: .gmail),
                                sanitizer: HTMLSanitizer(), tuning: SyncTuning())
        let written = await hydrator.backfillDesignFacts()
        XCTAssertEqual(written, 3)
        XCTAssertEqual(try store.body(for: plainID)?.typesetting, .plain)
        XCTAssertEqual(try store.body(for: plainID)?.declaresColors, false)
        XCTAssertEqual(try store.body(for: styledID)?.declaresColors, true, "the sender's background is a declared colour")
        XCTAssertEqual(try store.body(for: plainID)?.plainText, "Lunch at noon?", "the rest of the body is untouched")
        XCTAssertTrue(try store.messageIDsMissingDesignFacts(accountID: account, limit: 10).isEmpty)
        let again = await hydrator.backfillDesignFacts()
        XCTAssertEqual(again, 0, "done once, the backfill stops looking")
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

    /// v8 adds two tables and changes no existing one, so the file a v7 build leaves is a v8 file without those
    /// tables and their ledger row. The test makes one from a migrated file holding mail, an operation and sync
    /// state, opens it with the current build, and checks that nothing was lost and the new tables work.
    func testVersion7DatabaseGainsBackfillMarksAndKeepsItsData() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        let account = AccountID("acct-a")
        let m1 = MessageID(accountID: account, providerID: "m1")
        let m2 = MessageID(accountID: account, providerID: "m2")
        let started = MailStoreCodec.date(base + 30_000)
        do {
            let store = try SQLiteMailStore(path: path)
            try store.upsertMessages([MessageMetadata(
                id: m2, conversationID: ConversationID(accountID: account, providerID: "c2"), subject: "Zebra report",
                snippet: "Stripes", from: EmailAddress(name: "Ann", address: "ann@example.com"), to: [],
                date: MailStoreCodec.date(base + 120_000), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
            )])
            try store.setSyncCursor("cursor-7", for: account)
            try store.setBootstrapState(BootstrapState(startedAt: started, nextPage: "page-2", pagesDone: 1, messagesSeen: 2), for: account)
            try store.enqueue(Operation(id: "op-star", accountID: account, change: .setStarred(true), targets: [m1],
                                        createdAt: MailStoreCodec.date(base + 200_000)))
            try store.close()
        }
        // v9 came after v8, so a v7 file has neither.
        try execute("""
            DROP TABLE backfill_live_marks;
            DROP TABLE backfill_seen;
            DELETE FROM grdb_migrations WHERE identifier = 'v8-backfill-marks';
            ALTER TABLE accounts DROP COLUMN signature;
            DELETE FROM grdb_migrations WHERE identifier = 'v9-account-signature';
            """, at: path)
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations ORDER BY identifier", at: path).compactMap(\.first), [
            "v1-mailbox", "v2-body-render-facts", "v3-body-typesetting", "v4-account-ink", "v5-failed-operation-mark",
            "v6-operation-priors", "v7-body-design-facts-backfill",
        ])

        let store = try SQLiteMailStore(path: path)
        XCTAssertEqual(try store.message(m1)?.isStarred, true)
        XCTAssertEqual(try store.message(m2)?.subject, "Zebra report")
        XCTAssertEqual(try store.body(for: m1)?.plainText, "Hello there")
        XCTAssertEqual(try store.syncCursor(for: account), "cursor-7")
        XCTAssertEqual(try store.bootstrapState(for: account), BootstrapState(startedAt: started, nextPage: "page-2", pagesDone: 1, messagesSeen: 2))
        XCTAssertEqual(try store.pendingOperations(accountID: account, limit: 10).map(\.id), ["op-star"])
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .inbox)).map(\.id.providerID), ["c2", "c1"])
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all, searchText: "hello")).map(\.id.providerID), ["c1"])
        try store.verifyFullTextIndex()

        // The new tables take marks, a later mark replacing an earlier one's flag, and the backfill writes read them.
        try store.markLiveChanges(accountID: account, upserted: ["m1"], deleted: ["m9"])
        try store.markLiveChanges(accountID: account, upserted: ["m9"], deleted: ["m1"])
        try store.markLiveChanges(accountID: AccountID("acct-b"), upserted: ["b1"], deleted: [])
        try store.markBackfillSeen(accountID: account, providerIDs: ["m2", "m2"])
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: account, providerIDs: ["m1", "m2", "m9"], includeStored: false), ["m1", "m9"])
        try store.close()

        XCTAssertEqual(try query("SELECT account_id, provider_id, deleted FROM backfill_live_marks ORDER BY account_id, provider_id", at: path), [
            ["acct-a", "m1", "1"], ["acct-a", "m9", "0"], ["acct-b", "b1", "0"],
        ])
        XCTAssertEqual(try query("SELECT account_id, provider_id FROM backfill_seen", at: path), [["acct-a", "m2"]])
        for table in ["backfill_live_marks", "backfill_seen"] {
            let ddl = try XCTUnwrap(try query("SELECT sql FROM sqlite_master WHERE name = '\(table)'", at: path).first?.first ?? nil)
            XCTAssertTrue(ddl.contains("WITHOUT ROWID"), table)
            let keys = try query("SELECT \"table\", \"from\", on_delete FROM pragma_foreign_key_list('\(table)')", at: path)
            XCTAssertEqual(keys, [["accounts", "account_id", "CASCADE"]], table)
        }
        // The foreign key itself removes an account's marks, whichever path deletes the account row.
        try execute("PRAGMA foreign_keys = ON; DELETE FROM accounts WHERE id = 'acct-b';", at: path)
        XCTAssertEqual(try query("SELECT COUNT(*) FROM backfill_live_marks WHERE account_id = 'acct-b'", at: path), [["0"]])

        let reopened = try SQLiteMailStore(path: path)
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.finishBackfill(accountID: account, sweepUnseen: true), 0,
                       "m1 carries a live mark and m2 was listed, so the sweep keeps both")
        XCTAssertNotNil(try reopened.message(m1))
        XCTAssertNotNil(try reopened.message(m2))
        XCTAssertEqual(try query("SELECT COUNT(*) FROM backfill_live_marks", at: path), [["0"]])
    }

    /// v9 adds `accounts.signature` and nothing else, so the file a v8 build leaves is a v9 file without that column
    /// and its ledger row. Opened by the current build, every account has no signature (NULL, never one read from the
    /// provider), the monograms and ink slots set before stay, and the column takes a signature.
    func testVersion8DatabaseGainsAnEmptySignatureAndKeepsItsMonograms() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        let a = AccountID("acct-a")
        let b = AccountID("acct-b")
        do {
            let store = try SQLiteMailStore(path: path)
            try store.setMonogram("Ax", for: a)
            try store.setInkSlot(7, for: b)
            try store.setSyncCursor("cursor-8", for: a)
            try store.close()
        }
        try execute("""
            ALTER TABLE accounts DROP COLUMN signature;
            DELETE FROM grdb_migrations WHERE identifier = 'v9-account-signature';
            """, at: path)
        XCTAssertFalse(try query("SELECT name FROM pragma_table_info('accounts')", at: path).compactMap(\.first).contains("signature"))

        let store = try SQLiteMailStore(path: path)
        let migrated = try store.accounts()
        XCTAssertEqual(migrated.count, accounts.count)
        XCTAssertEqual(migrated.map(\.signature), Array(repeating: nil, count: accounts.count), "no account has a signature")
        XCTAssertEqual(migrated.first { $0.id == a }?.monogram, "Ax", "the monogram is untouched")
        XCTAssertEqual(migrated.first { $0.id == b }?.inkSlot, 7)
        XCTAssertEqual(try store.syncCursor(for: a), "cursor-8")
        XCTAssertEqual(try store.message(MessageID(accountID: a, providerID: "m1"))?.subject, "Hello")

        try store.setSignature("<div><p><b>Alex</b></p></div>", for: a)
        XCTAssertEqual(try store.accounts().first { $0.id == a }?.signature, "<div><p><b>Alex</b></p></div>")
        XCTAssertEqual(try store.accounts().first { $0.id == a }?.monogram, "Ax")
        try store.close()
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations WHERE identifier = 'v9-account-signature'", at: path), [["v9-account-signature"]])
        XCTAssertEqual(try query("SELECT type, \"notnull\", dflt_value FROM pragma_table_info('accounts') WHERE name = 'signature'", at: path),
                       [["TEXT", "0", nil]], "TEXT NULL with no default")
    }

    // MARK: Raw SQLite

    private func withDatabase<T>(at path: String, _ work: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw XCTSkip("could not open the SQLite file")
        }
        defer { sqlite3_close(db) }
        return try work(db)
    }

    private func execute(_ sql: String, at path: String) throws {
        try withDatabase(at: path) { db in
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
                let text = message.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(message)
                XCTFail("SQL failed: \(text)")
                throw CancellationError()
            }
        }
    }

    /// Every row of `sql`, each column as text (NULL as nil).
    private func query(_ sql: String, at path: String) throws -> [[String?]] {
        try withDatabase(at: path) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                XCTFail("SQL failed: \(String(cString: sqlite3_errmsg(db)))")
                throw CancellationError()
            }
            defer { sqlite3_finalize(statement) }
            var rows: [[String?]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) }
                })
            }
            return rows
        }
    }
}
