import GRDB
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

    /// Takes v11 back out of a migrated file, as the tests of earlier versions need: a file from before v11 has no
    /// snoozes, no `returned_at`, and its Inbox index on the latest date.
    private let withoutV11 = """
        DROP TABLE snoozes;
        DROP INDEX conversations_inbox;
        ALTER TABLE conversations DROP COLUMN returned_at;
        CREATE INDEX conversations_inbox ON conversations(in_inbox, latest_date_ms DESC);
        DELETE FROM grdb_migrations WHERE identifier = 'v11-snoozes';
        """

    /// Takes v14 back out of a migrated file, for the tests that build a file from before it by reverting a current one:
    /// a file from before v14 has no list headers on its messages.
    private let withoutV14 = """
        ALTER TABLE messages DROP COLUMN list_unsubscribe;
        ALTER TABLE messages DROP COLUMN list_unsubscribe_post;
        DELETE FROM grdb_migrations WHERE identifier = 'v14-list-unsubscribe';
        """

    /// Takes v15 back out of a migrated file, as `withoutV14` takes v14: a file from before v15 has no invitation stored
    /// with its bodies and no answer recorded on its messages.
    private let withoutV15 = """
        ALTER TABLE bodies DROP COLUMN invitation_json;
        ALTER TABLE messages DROP COLUMN invitation_reply;
        DELETE FROM grdb_migrations WHERE identifier = 'v15-calendar-invitations';
        """

    /// Takes v16 back out of a migrated file: a file from before it mutes nothing (the partial index goes first, since a
    /// column an index reads cannot be dropped).
    private let withoutV16 = """
        DROP INDEX conversations_muted;
        ALTER TABLE conversations DROP COLUMN muted;
        DELETE FROM grdb_migrations WHERE identifier = 'v16-conversation-mute';
        """

    /// Takes v17 back out of a migrated file: a file from before it has no sender rules.
    private let withoutV17 = """
        DROP TABLE sender_rules;
        DELETE FROM grdb_migrations WHERE identifier = 'v17-sender-rules';
        """

    /// Takes v18 back out of a migrated file: a file from before it keeps no draft and no summary with a send (the column
    /// order v18 changed is left as it is; nothing reads the table by position).
    private let withoutV18 = """
        ALTER TABLE pending_sends DROP COLUMN draft_id;
        ALTER TABLE pending_sends DROP COLUMN summary_json;
        DELETE FROM grdb_migrations WHERE identifier = 'v18-scheduled-sends';
        """

    /// Takes v19 back out of a migrated file: a file from before it has no lookup queue.
    private let withoutV19 = """
        DROP TABLE queued_lookups;
        DELETE FROM grdb_migrations WHERE identifier = 'v19-sync-robustness';
        """

    /// Takes v20 back out of a migrated file: a file from before it has no calendar and no mail times (their indexes go
    /// with the tables).
    private let withoutV20 = """
        DROP TABLE mail_times;
        DROP TABLE calendar_events;
        DELETE FROM grdb_migrations WHERE identifier = 'v20-calendar';
        """

    private let withoutV21 = """
        DROP INDEX conversations_latest;
        CREATE INDEX conversations_latest ON conversations(latest_date_ms DESC);
        DELETE FROM grdb_migrations WHERE identifier = 'v21-search-walk';
        """

    /// Takes v22 back out of a migrated file: a file from before it keeps no face choice.
    private let withoutV22 = """
        ALTER TABLE accounts DROP COLUMN face;
        DELETE FROM grdb_migrations WHERE identifier = 'v22-account-face';
        """

    /// Takes v23 back out of a migrated file: a file from before it keeps its sender rules on this Mac alone, with no
    /// server ids and no state against the server.
    private let withoutV23 = """
        ALTER TABLE sender_rules DROP COLUMN server_ids;
        ALTER TABLE sender_rules DROP COLUMN sync;
        DELETE FROM grdb_migrations WHERE identifier = 'v23-server-rules';
        """

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
        // v9 to v15 came after v8, so a v7 file has none of them (`revertSQL` takes v12 and v13 back).
        try execute(withoutV23 + withoutV22 + withoutV21 + withoutV20 + withoutV19 + withoutV18 + withoutV17 + withoutV16 + withoutV15 + withoutV14 + """
            \(FullTextVersion10.revertSQL)
            DROP TABLE backfill_live_marks;
            DROP TABLE backfill_seen;
            DELETE FROM grdb_migrations WHERE identifier = 'v8-backfill-marks';
            ALTER TABLE accounts DROP COLUMN signature;
            DELETE FROM grdb_migrations WHERE identifier = 'v9-account-signature';
            ALTER TABLE bodies DROP COLUMN evicted;
            DELETE FROM grdb_migrations WHERE identifier = 'v10-body-eviction';
            """ + withoutV11, at: path)
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
        try execute(withoutV23 + withoutV22 + withoutV21 + withoutV20 + withoutV19 + withoutV18 + withoutV17 + withoutV16 + withoutV15 + withoutV14 + """
            \(FullTextVersion10.revertSQL)
            ALTER TABLE accounts DROP COLUMN signature;
            DELETE FROM grdb_migrations WHERE identifier = 'v9-account-signature';
            ALTER TABLE bodies DROP COLUMN evicted;
            DELETE FROM grdb_migrations WHERE identifier = 'v10-body-eviction';
            """ + withoutV11, at: path)
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

    /// v22 adds `accounts.face` and nothing else, so the file a v21 build leaves is a v22 file without that column and
    /// its ledger row. Opened by the current build, every account's face is automatic (NULL: the paper face its ink slot
    /// picks, Quire §5.55), the monograms, ink slots and signatures set before stay, and the column takes a choice.
    func testVersion21DatabaseGainsAnAutomaticFaceAndKeepsItsMonograms() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        let a = AccountID("acct-a")
        let b = AccountID("acct-b")
        do {
            let store = try SQLiteMailStore(path: path)
            try store.setMonogram("Ax", for: a)
            try store.setInkSlot(7, for: b)
            try store.setSignature("<div><p>Alex</p></div>", for: a)
            try store.close()
        }
        try execute(withoutV23 + withoutV22, at: path)
        XCTAssertFalse(try query("SELECT name FROM pragma_table_info('accounts')", at: path).compactMap(\.first).contains("face"))

        let store = try SQLiteMailStore(path: path)
        let migrated = try store.accounts()
        XCTAssertEqual(migrated.count, accounts.count)
        XCTAssertEqual(Set(migrated.map(\.face)), [.automatic], "no account has chosen a face")
        XCTAssertEqual(migrated.first { $0.id == a }?.monogram, "Ax", "the monogram is untouched")
        XCTAssertEqual(migrated.first { $0.id == a }?.signature, "<div><p>Alex</p></div>")
        XCTAssertEqual(migrated.first { $0.id == b }?.inkSlot, 7)

        try store.setFace(.paper("fox"), for: a)
        try store.setFace(.monogram, for: b)
        XCTAssertEqual(try store.accounts().first { $0.id == a }?.face, .paper("fox"))
        XCTAssertEqual(try store.accounts().first { $0.id == b }?.face, .monogram)
        XCTAssertEqual(try store.accounts().first { $0.id == a }?.monogram, "Ax")
        try store.close()
        XCTAssertEqual(try query("SELECT face FROM accounts WHERE id IN ('acct-a', 'acct-b') ORDER BY id", at: path),
                       [["paper:fox"], ["monogram"]])
        XCTAssertEqual(try query("SELECT type, \"notnull\", dflt_value FROM pragma_table_info('accounts') WHERE name = 'face'", at: path),
                       [["TEXT", "0", nil]], "TEXT NULL with no default")
    }

    /// v10 adds `bodies.evicted` and nothing else, so the file a v9 build leaves is a v10 file without that column and
    /// its ledger row. Opened by the current build, every body is whole (0), the store reads them as before, and the
    /// file keeps the `auto_vacuum` it was created with: switching an existing file to INCREMENTAL takes a full VACUUM,
    /// which the store never runs, so incremental vacuum steps do nothing there. A new file is created INCREMENTAL.
    func testVersion9DatabaseGainsTheEvictedMarkAndKeepsItsVacuumMode() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        let m1 = MessageID(accountID: AccountID("acct-a"), providerID: "m1")
        do {
            let store = try SQLiteMailStore(path: path)
            try store.setSignature("<div><p>Alex</p></div>", for: AccountID("acct-a"))
            try store.close()
        }
        try execute(withoutV23 + withoutV22 + withoutV21 + withoutV20 + withoutV19 + withoutV18 + withoutV17 + withoutV16 + withoutV15 + withoutV14 + """
            \(FullTextVersion10.revertSQL)
            ALTER TABLE bodies DROP COLUMN evicted;
            DELETE FROM grdb_migrations WHERE identifier = 'v10-body-eviction';
            """ + withoutV11, at: path)
        XCTAssertFalse(try query("SELECT name FROM pragma_table_info('bodies')", at: path).compactMap(\.first).contains("evicted"))
        XCTAssertEqual(try query("PRAGMA auto_vacuum", at: path), [["0"]], "an earlier build's file has no auto_vacuum")

        let store = try SQLiteMailStore(path: path)
        XCTAssertEqual(try store.body(for: m1)?.plainText, "Hello there", "the body stored before v10 reads as before")
        XCTAssertEqual(try store.bodyRowState(for: m1)?.evicted, false)
        XCTAssertEqual(try store.accounts().first { $0.id == AccountID("acct-a") }?.signature, "<div><p>Alex</p></div>")
        XCTAssertEqual(try store.autoVacuumMode(), 0, "the migration does not change auto_vacuum")
        XCTAssertNil(try store.reclaimFreePages(upTo: 16), "so incremental vacuum steps do nothing on this file")
        try store.deleteMessages([m1])
        XCTAssertNil(try store.reclaimFreePages(upTo: 16), "even with free pages to hand back")
        try store.close()
        XCTAssertEqual(try query("SELECT type, \"notnull\", dflt_value FROM pragma_table_info('bodies') WHERE name = 'evicted'", at: path),
                       [["INTEGER", "1", "0"]], "INTEGER NOT NULL DEFAULT 0")
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations WHERE identifier = 'v10-body-eviction'", at: path),
                       [["v10-body-eviction"]])
        XCTAssertEqual(try query("PRAGMA auto_vacuum", at: path), [["0"]], "never a full VACUUM behind the user's back")

        let fresh = try XCTUnwrap(directory).appendingPathComponent("fresh.sqlite").path
        let created = try SQLiteMailStore(path: fresh)
        XCTAssertEqual(try created.autoVacuumMode(), 2, "a new file is created for incremental vacuum")
        try created.close()
        XCTAssertEqual(try query("PRAGMA auto_vacuum", at: fresh), [["2"]])
        let reopened = try SQLiteMailStore(path: fresh)
        XCTAssertEqual(try reopened.autoVacuumMode(), 2, "and keeps it")
        try reopened.close()
    }

    /// v11 adds `snoozes`, `conversations.returned_at` and rebuilds `conversations_inbox` on the Inbox's own date. A
    /// real v10 file (the v1 file brought to v10 by the migrations as they shipped) holding an Inbox conversation and an
    /// archived one opens with nothing snoozed and nothing returned, its Inbox in the same order on the new index, and
    /// takes snoozes and returns at once.
    func testVersion10DatabaseGainsSnoozesAndReturnedAt() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        try MailSchema.migrateFile(at: path, upTo: "v10-body-eviction")
        XCTAssertEqual(try query("SELECT COUNT(*) FROM grdb_migrations", at: path), [["10"]], "a v10 file")
        XCTAssertTrue(try query("SELECT name FROM sqlite_master WHERE name = 'snoozes'", at: path).isEmpty)
        // An archived conversation beside the v1 file's Inbox one, older than it.
        try execute("""
            INSERT INTO messages (account_id, provider_id, conversation_provider_id, references_json, subject, snippet,
                                  from_json, to_json, cc_json, bcc_json, reply_to_json, date_ms, roles, is_read,
                                  is_starred, inbox_section, has_attachments, label_ids_json, has_body)
            VALUES ('acct-a', 'm2', 'c2', '[]', 'Invoice', 'Due Friday', '{"address":"ann@example.com","name":"Ann"}',
                    '[]', '[]', '[]', '[]', \(base + 30_000), 0, 1, 0, 'unknown', 0, '[]', 0);
            INSERT INTO conversations (account_id, provider_id, subject, snippet, participants_json, latest_date_ms,
                                       latest_provider_id, message_count, unread_count, is_starred, has_attachments,
                                       in_inbox, in_sent, in_drafts, in_trash, inbox_section, has_pending_ops)
            VALUES ('acct-a', 'c2', 'Invoice', 'Due Friday', '[{"address":"ann@example.com","name":"Ann"}]',
                    \(base + 30_000), 'm2', 1, 0, 0, 0, 0, 0, 0, 0, 'unknown', 0);
            """, at: path)

        let store = try SQLiteMailStore(path: path)
        XCTAssertTrue(try store.snoozes().isEmpty)
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .inbox)).map(\.id.providerID), ["c1"])
        XCTAssertNil(try store.conversations(ConversationQuery(view: .inbox)).first?.returnedAt)
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all)).map(\.id.providerID), ["c1", "c2"])
        XCTAssertTrue(try store.queryPlan(for: ConversationQuery(view: .inbox)).contains { $0.contains("USING INDEX conversations_inbox") })

        let c2 = ConversationID(accountID: AccountID("acct-a"), providerID: "c2")
        let due = MailStoreCodec.date(base + 90_000)
        try store.setSnoozes([Snooze.Change(conversationID: c2, until: due)], enqueueing: [], at: MailStoreCodec.date(base + 40_000))
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .later)).map(\.snoozedUntil), [due])
        let back = MailStoreCodec.date(base + 100_000)
        try store.returnDueSnoozes(at: back, limit: 10) { id, messages in
            [Operation(accountID: id.accountID, change: .moveToInbox, targets: messages.map(\.id), createdAt: back)]
        }
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .inbox)).map(\.id.providerID), ["c2", "c1"],
                       "back from Later, it sorts above newer mail")
        try store.close()

        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations WHERE identifier = 'v11-snoozes'", at: path), [["v11-snoozes"]])
        XCTAssertEqual(try query("SELECT type, \"notnull\", dflt_value FROM pragma_table_info('conversations') WHERE name = 'returned_at'", at: path),
                       [["INTEGER", "0", nil]], "INTEGER NULL with no default")
        XCTAssertEqual(try query("SELECT returned_at FROM conversations WHERE provider_id = 'c1'", at: path), [[nil]], "nothing came back before v11")
        XCTAssertEqual(try query("SELECT \"table\", \"from\", on_delete FROM pragma_foreign_key_list('snoozes')", at: path),
                       [["accounts", "account_id", "CASCADE"]])
        let index = try XCTUnwrap(try query("SELECT sql FROM sqlite_master WHERE name = 'conversations_inbox'", at: path).first?.first ?? nil)
        XCTAssertTrue(index.contains("COALESCE(returned_at, latest_date_ms) DESC"), index)
        // The foreign key removes an account's snoozes, whichever path deletes the account row.
        try execute("""
            PRAGMA foreign_keys = ON;
            INSERT INTO snoozes (account_id, provider_id, due_at, created_at) VALUES ('acct-b', 'cb', 1, 0);
            DELETE FROM accounts WHERE id = 'acct-b';
            """, at: path)
        XCTAssertEqual(try query("SELECT COUNT(*) FROM snoozes WHERE account_id = 'acct-b'", at: path), [["0"]])

        let reopened = try SQLiteMailStore(path: path)
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.conversations(ConversationQuery(view: .inbox)).first?.returnedAt, back, "kept across a reopen")
    }

    /// v12 splits the index's `participants` into `sender` and `recipients` and rebuilds it from the stored rows. The
    /// file is a real v11 one: a v1 file taken through the shipped migrations up to v11 and no further, holding mail
    /// indexed as v11 indexed it (one `participants` column: the sender, To and Cc, never Bcc). Opened by the current
    /// build, the index has the new columns and holds every stored message, Bcc included: `from:` and `to:` find
    /// what they should, plain words what they found before, the strict integrity check passes, and later writes
    /// keep it so.
    func testVersion11DatabaseRebuildsTheIndexWithSenderAndRecipients() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path, then: """
            INSERT INTO messages (account_id, provider_id, conversation_provider_id, references_json, subject, snippet,
                                  from_json, to_json, cc_json, bcc_json, reply_to_json, date_ms, roles, is_read,
                                  is_starred, inbox_section, has_attachments, label_ids_json, has_body)
            VALUES ('acct-a', 'm2', 'c2', '[]', 'Lisbon flat', 'Keys', '{"address":"ana@example.org","name":"Ana Silva"}',
                    '[{"address":"acct-a@example.com","name":"Owner"}]', '[{"address":"carol@example.com","name":"Carol"}]',
                    '[{"address":"dana@example.net","name":"Dana Reyes"}]', '[]', \(base + 90_000), 1, 1, 0, 'unknown', 0, '[]', 0);
            INSERT INTO message_fts(rowid, subject, participants, body)
            SELECT id, subject, participants, body FROM message_fts_content WHERE provider_id = 'm2';
            INSERT INTO conversations (account_id, provider_id, subject, snippet, participants_json, latest_date_ms,
                                       latest_provider_id, message_count, unread_count, is_starred, has_attachments,
                                       in_inbox, in_sent, in_drafts, in_trash, inbox_section, has_pending_ops)
            VALUES ('acct-a', 'c2', 'Lisbon flat', 'Keys', '[{"address":"ana@example.org","name":"Ana Silva"}]',
                    \(base + 90_000), 'm2', 1, 0, 0, 0, 1, 0, 0, 0, 'unknown', 0);
            """)
        try MailSchema.migrateFile(at: path, upTo: "v11-snoozes")
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations ORDER BY rowid", at: path).compactMap(\.first).last,
                       "v11-snoozes")
        XCTAssertEqual(try query("SELECT name FROM pragma_table_info('message_fts')", at: path).compactMap(\.first),
                       ["subject", "participants", "body"])

        let store = try SQLiteMailStore(path: path)
        XCTAssertEqual(try query("SELECT name FROM pragma_table_info('message_fts')", at: path).compactMap(\.first),
                       ["subject", "sender", "recipients", "body"])
        try store.verifyFullTextIndex()
        func search(_ text: String) throws -> [String] {
            try store.conversations(ShellQuery.make(scope: nil, view: .inbox, searchText: text)).map(\.id.providerID)
        }
        XCTAssertEqual(try search("from:bob"), ["c1"])
        XCTAssertEqual(try search("from:\"Ana Silva\""), ["c2"])
        XCTAssertEqual(try search("from:carol"), [], "Carol is in cc")
        XCTAssertEqual(try search("to:carol"), ["c2"])
        XCTAssertEqual(try search("to:dana"), ["c2"], "Bcc, which v10 never indexed, from the stored row")
        XCTAssertEqual(try search("to:owner"), ["c2"])
        XCTAssertEqual(try search("hello"), ["c1"], "body text, as before")
        XCTAssertEqual(try search("bob"), ["c1"], "a plain word still searches the people")
        XCTAssertEqual(try search("carol"), ["c2"])
        XCTAssertEqual(try search("subject:lisbon"), ["c2"])

        // Every write after the migration keeps the rebuilt index whole.
        let m2 = MessageID(accountID: AccountID("acct-a"), providerID: "m2")
        var message = try XCTUnwrap(try store.message(m2))
        message.bcc = [EmailAddress(name: "Erin Moss", address: "erin@example.com")]
        try store.upsertMessages([message])
        try store.saveBody(StoredBody(body: MessageBody(html: nil, text: "keys under the mat", attachments: []),
                                      renderedHTML: "<p>keys under the mat</p>", plainText: "keys under the mat"), for: m2)
        try store.verifyFullTextIndex()
        XCTAssertEqual(try search("to:dana"), [])
        XCTAssertEqual(try search("to:erin mat"), ["c2"])
        try store.deleteMessages([MessageID(accountID: AccountID("acct-a"), providerID: "m1")])
        try store.verifyFullTextIndex()
        XCTAssertEqual(try search("from:bob"), [])
        try store.close()
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations WHERE identifier = 'v12-search-columns'", at: path),
                       [["v12-search-columns"]])
    }

    /// v13 indexes a message without a body by its snippet. The file is a real v12 one (a v1 file taken through the
    /// shipped migrations up to v12) holding such a message, metadata the first download or a search of the server
    /// stored, indexed with an empty body. Opened by the current build, it is found by its snippet's words, the stored
    /// body of another message is indexed as before, the index matches the view exactly, and a body arriving later
    /// takes the snippet's place.
    func testVersion12DatabaseFindsMessagesWithoutABodyByTheirSnippet() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path, then: """
            INSERT INTO messages (account_id, provider_id, conversation_provider_id, references_json, subject, snippet,
                                  from_json, to_json, cc_json, bcc_json, reply_to_json, date_ms, roles, is_read,
                                  is_starred, inbox_section, has_attachments, label_ids_json, has_body)
            VALUES ('acct-a', 'm2', 'c2', '[]', 'Tax documents', 'Forms for the landlord',
                    '{"address":"ann@example.com","name":"Ann"}', '[]', '[]', '[]', '[]', \(base + 120_000), 0, 1, 0,
                    'unknown', 0, '[]', 0);
            INSERT INTO message_fts(rowid, subject, participants, body)
            SELECT id, subject, participants, body FROM message_fts_content WHERE provider_id = 'm2';
            INSERT INTO conversations (account_id, provider_id, subject, snippet, participants_json, latest_date_ms,
                                       latest_provider_id, message_count, unread_count, is_starred, has_attachments,
                                       in_inbox, in_sent, in_drafts, in_trash, inbox_section, has_pending_ops)
            VALUES ('acct-a', 'c2', 'Tax documents', 'Forms for the landlord', '[{"address":"ann@example.com","name":"Ann"}]',
                    \(base + 120_000), 'm2', 1, 0, 0, 0, 0, 0, 0, 0, 'unknown', 0);
            """)
        try MailSchema.migrateFile(at: path, upTo: "v12-search-columns")
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations ORDER BY rowid", at: path).compactMap(\.first).last,
                       "v12-search-columns")
        XCTAssertEqual(try query("SELECT rowid FROM message_fts WHERE message_fts MATCH 'landlord'", at: path), [],
                       "v12 indexed the message with an empty body")
        func search(_ text: String, in store: SQLiteMailStore) throws -> [String] {
            try store.conversations(ConversationQuery(view: .all, searchText: text)).map(\.id.providerID)
        }

        let store = try SQLiteMailStore(path: path)
        XCTAssertEqual(try search("landlord", in: store), ["c2"], "found by its snippet")
        XCTAssertEqual(try search("hello", in: store), ["c1"], "a stored body is indexed as before")
        XCTAssertEqual(try search("from:ann", in: store), ["c2"], "its other columns as v12 indexed them")
        try store.verifyFullTextIndex()

        let text = "Both forms are attached"
        try store.saveBody(StoredBody(body: MessageBody(html: nil, text: text, attachments: []), renderedHTML: "<div>\(text)</div>",
                                      plainText: text), for: MessageID(accountID: AccountID("acct-a"), providerID: "m2"))
        XCTAssertEqual(try search("attached", in: store), ["c2"])
        XCTAssertEqual(try search("landlord", in: store), [], "the body takes the snippet's place")
        try store.verifyFullTextIndex()
        try store.close()
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations WHERE identifier = 'v13-server-search'", at: path),
                       [["v13-server-search"]])
    }

    /// v14 adds `messages.list_unsubscribe` and `list_unsubscribe_post` and nothing else. The file is a real v13 one (a v1
    /// file taken through the shipped migrations up to v13 and no further). Opened by the current build, every message it
    /// holds reads with no headers (nothing fetches them back) and offers no way to unsubscribe, the rest reads as before
    /// with the index untouched, and the columns take the headers a later fetch brings, kept across a write that carries
    /// none.
    func testVersion13DatabaseGainsEmptyListHeadersAndKeepsItsMail() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        try MailSchema.migrateFile(at: path, upTo: "v13-server-search")
        try execute("UPDATE accounts SET signature = '<div><p>Alex</p></div>' WHERE id = 'acct-a'", at: path)
        let account = AccountID("acct-a")
        let m1 = MessageID(accountID: account, providerID: "m1")
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations ORDER BY rowid", at: path).compactMap(\.first).last,
                       "v13-server-search")
        let columns = try query("SELECT name FROM pragma_table_info('messages')", at: path).compactMap(\.first)
        XCTAssertFalse(columns.contains("list_unsubscribe"))

        let store = try SQLiteMailStore(path: path)
        let stored = try XCTUnwrap(try store.message(m1))
        XCTAssertEqual(stored.subject, "Hello", "the mail stored before v14 reads as before")
        XCTAssertNil(stored.listUnsubscribe, "with no headers: nothing fetches them back")
        XCTAssertNil(stored.listUnsubscribePost)
        XCTAssertNil(UnsubscribeMethod(message: stored), "so it offers no way to unsubscribe")
        XCTAssertEqual(try store.body(for: m1)?.plainText, "Hello there")
        XCTAssertEqual(try store.accounts().first { $0.id == account }?.signature, "<div><p>Alex</p></div>")
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all, searchText: "hello")).map(\.id.providerID), ["c1"])
        try store.verifyFullTextIndex()

        var fetchedAgain = stored
        fetchedAgain.listUnsubscribe = "<mailto:leave@example.com>"
        fetchedAgain.listUnsubscribePost = "List-Unsubscribe=One-Click"
        try store.upsertMessages([fetchedAgain])
        try store.upsertMessages([stored])
        XCTAssertEqual(try store.message(m1)?.listUnsubscribe, "<mailto:leave@example.com>", "kept across a write without them")
        try store.verifyFullTextIndex()
        try store.close()

        for column in ["list_unsubscribe", "list_unsubscribe_post"] {
            XCTAssertEqual(try query("SELECT type, \"notnull\", dflt_value FROM pragma_table_info('messages') WHERE name = '\(column)'", at: path),
                           [["TEXT", "0", nil]], "\(column): TEXT NULL with no default")
        }
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations WHERE identifier = 'v14-list-unsubscribe'", at: path),
                       [["v14-list-unsubscribe"]])
        XCTAssertEqual(try query("SELECT list_unsubscribe_post FROM messages WHERE provider_id = 'm1'", at: path),
                       [["List-Unsubscribe=One-Click"]])
    }

    /// v15 adds `bodies.invitation_json` and `messages.invitation_reply` and nothing else, both NULL for what is already
    /// stored: a body stored before shows no card until it is fetched again, and nobody has answered an invitation here
    /// yet. The file is a real v14 one (a v1 file taken through the shipped migrations up to v14 and no further) whose
    /// message carries the list headers v14 stores. Opened by the current build, its mail reads as before, headers
    /// included, with no invitation and no answer, and the new columns are TEXT NULL.
    func testVersion14DatabaseGainsTheInvitationColumnsAndKeepsItsData() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        try MailSchema.migrateFile(at: path, upTo: "v14-list-unsubscribe")
        try execute("UPDATE messages SET list_unsubscribe = '<mailto:leave@example.com>' WHERE provider_id = 'm1'", at: path)
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations ORDER BY rowid", at: path).compactMap(\.first).last,
                       "v14-list-unsubscribe")
        XCTAssertFalse(try query("SELECT name FROM pragma_table_info('bodies')", at: path).compactMap(\.first).contains("invitation_json"))
        XCTAssertFalse(try query("SELECT name FROM pragma_table_info('messages')", at: path).compactMap(\.first).contains("invitation_reply"))

        let m1 = MessageID(accountID: AccountID("acct-a"), providerID: "m1")
        let store = try SQLiteMailStore(path: path)
        XCTAssertEqual(try store.body(for: m1)?.plainText, "Hello there", "the body stored before v15 reads as before")
        XCTAssertNil(try store.body(for: m1)?.invitation, "with no card until it is fetched again")
        let stored = try XCTUnwrap(try store.message(m1))
        XCTAssertNil(stored.invitationReply, "nobody has answered here yet")
        XCTAssertEqual(stored.listUnsubscribe, "<mailto:leave@example.com>", "v14's headers read beside the new column")
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all, searchText: "hello")).map(\.id.providerID), ["c1"])
        try store.verifyFullTextIndex()
        try store.close()
        XCTAssertEqual(try query("SELECT type, \"notnull\", dflt_value FROM pragma_table_info('bodies') WHERE name = 'invitation_json'", at: path),
                       [["TEXT", "0", nil]], "TEXT NULL with no default")
        XCTAssertEqual(try query("SELECT type, \"notnull\", dflt_value FROM pragma_table_info('messages') WHERE name = 'invitation_reply'", at: path),
                       [["TEXT", "0", nil]], "TEXT NULL with no default")
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations WHERE identifier = 'v15-calendar-invitations'", at: path),
                       [["v15-calendar-invitations"]])
    }

    /// v16 adds `conversations.muted` (0 for every row, so nothing is muted) and the partial index the upsert asks once
    /// per write, and nothing else. The file is a real v15 one. Opened by the current build its mail reads as before, a
    /// conversation can be muted, and mail arriving in it is archived.
    func testVersion15DatabaseGainsTheMuteAndKeepsItsMail() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        try MailSchema.migrateFile(at: path, upTo: "v15-calendar-invitations")
        XCTAssertFalse(try query("SELECT name FROM pragma_table_info('conversations')", at: path).compactMap(\.first).contains("muted"))

        let account = AccountID("acct-a")
        let c1 = ConversationID(accountID: account, providerID: "c1")
        let store = try SQLiteMailStore(path: path)
        let summary = try XCTUnwrap(try store.conversations(ConversationQuery(view: .inbox)).first)
        XCTAssertEqual(summary.id, c1, "the mail stored before v16 reads as before")
        XCTAssertFalse(summary.isMuted, "nothing is muted")
        try store.setMuted(true, conversations: [c1], enqueueing: [
            Operation(accountID: account, change: .archive, targets: [MessageID(accountID: account, providerID: "m1")]),
        ])
        try store.upsertMessages([MessageMetadata(
            id: MessageID(accountID: account, providerID: "m2"), conversationID: c1, subject: "Re: Hello", snippet: "More",
            from: EmailAddress(name: "Bob", address: "bob@example.com"), date: MailStoreCodec.date(base + 90_000),
            roles: [.inbox], isRead: false, isStarred: false, hasAttachments: false
        )])
        XCTAssertTrue(try store.conversations(ConversationQuery(view: .inbox)).isEmpty, "mail arriving in it is archived")
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all)).first?.isMuted, true)
        try store.verifyFullTextIndex()
        try store.close()

        XCTAssertEqual(try query("SELECT type, \"notnull\", dflt_value FROM pragma_table_info('conversations') WHERE name = 'muted'", at: path),
                       [["INTEGER", "1", "0"]], "INTEGER NOT NULL DEFAULT 0")
        XCTAssertEqual(try query("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'conversations_muted'", at: path),
                       [["conversations_muted"]])
        let plan = try query("EXPLAIN QUERY PLAN SELECT DISTINCT account_id FROM conversations WHERE muted = 1", at: path)
        XCTAssertTrue(plan.contains { $0.contains { $0?.contains("conversations_muted") == true } },
                      "the once-per-write look reads the partial index: \(plan)")
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations WHERE identifier = 'v16-conversation-mute'", at: path),
                       [["v16-conversation-mute"]])
    }

    /// v17 adds the empty `sender_rules` table and nothing else. The file is a real v16 one with a conversation muted.
    /// Opened by the current build the mute stays, a rule can be set, and it cascades with its account.
    func testVersion16DatabaseGainsSenderRulesAndKeepsItsMutes() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        try MailSchema.migrateFile(at: path, upTo: "v16-conversation-mute")
        try execute("UPDATE conversations SET muted = 1 WHERE provider_id = 'c1'", at: path)
        XCTAssertTrue(try query("SELECT name FROM sqlite_master WHERE name = 'sender_rules'", at: path).isEmpty)

        let account = AccountID("acct-a")
        let store = try SQLiteMailStore(path: path)
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .inbox)).first?.isMuted, true, "v16's mute reads as before")
        XCTAssertTrue(try store.senderRules().isEmpty)
        try store.setSenderRule(.trash, for: "deals@shop.example", accountID: account, enqueueing: [],
                                at: MailStoreCodec.date(base + 100_000))
        XCTAssertEqual(try store.senderRules().map(\.address), ["deals@shop.example"])
        try store.deleteAccount(account)
        XCTAssertTrue(try store.senderRules().isEmpty, "removed with its account")
        try store.close()

        XCTAssertEqual(try query("SELECT name, type, \"notnull\", pk FROM pragma_table_info('sender_rules') ORDER BY cid", at: path), [
            ["account_id", "TEXT", "1", "1"], ["address", "TEXT", "1", "2"], ["action", "TEXT", "1", "0"], ["created_at", "INTEGER", "1", "0"],
            ["server_ids", "TEXT", "0", "0"], ["sync", "TEXT", "1", "0"],
        ], "v17's columns, then v23's")
        XCTAssertEqual(try query("""
            SELECT identifier FROM grdb_migrations WHERE identifier IN ('v16-conversation-mute', 'v17-sender-rules')
            ORDER BY rowid
            """, at: path).compactMap(\.first), ["v16-conversation-mute", "v17-sender-rules"])
    }

    /// v19 adds the queue of lookups for a folder the provider reports gone (`queued_lookups`) and nothing else. The
    /// file is a real v15 one; opened by the current build its mail reads as before, the queue is empty, and an
    /// account's lookups go with the account.
    func testVersion15DatabaseGainsAnEmptyLookupQueueAndKeepsItsData() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        try MailSchema.migrateFile(at: path, upTo: "v15-calendar-invitations")
        try execute("UPDATE messages SET folder_id = 'F-GONE' WHERE provider_id = 'm1'", at: path)
        XCTAssertTrue(try query("SELECT name FROM sqlite_master WHERE name = 'queued_lookups'", at: path).isEmpty)

        let account = AccountID("acct-a")
        let store = try SQLiteMailStore(path: path)
        XCTAssertEqual(try store.body(for: MessageID(accountID: account, providerID: "m1"))?.plainText, "Hello there")
        XCTAssertEqual(try store.queuedLookups(accountID: account, limit: 10), [:])
        XCTAssertEqual(try store.queueLookups(accountID: account, inFolders: ["F-GONE"]), 1)
        XCTAssertEqual(try store.queuedLookups(accountID: account, limit: 10), ["m1": 0])
        try store.close()
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations ORDER BY rowid", at: path).compactMap(\.first).last,
                       "v23-server-rules")
        try execute("PRAGMA foreign_keys = ON; DELETE FROM accounts WHERE id = 'acct-a';", at: path)
        XCTAssertEqual(try query("SELECT COUNT(*) FROM queued_lookups", at: path), [["0"]], "an account's lookups go with it")
    }

    /// v20 adds the calendar (`calendar_events`) and the times found in mail (`mail_times`), both empty, and nothing else.
    /// The file is a real v19 one; opened by the current build its mail reads as before, a read of a calendar and a time
    /// found in a body are written, and each goes the way its rows are keyed: a wipe of the mail takes the times and keeps
    /// the events, deleting a message takes its times, and removing the account takes the rest.
    func testVersion19DatabaseGainsTheCalendarAndKeepsItsMail() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        try MailSchema.migrateFile(at: path, upTo: "v19-sync-robustness")
        for table in ["calendar_events", "mail_times"] {
            XCTAssertTrue(try query("SELECT name FROM sqlite_master WHERE name = '\(table)'", at: path).isEmpty, table)
        }

        let account = AccountID("acct-a")
        let m1 = MessageID(accountID: account, providerID: "m1")
        let c1 = ConversationID(accountID: account, providerID: "c1")
        let week = DateInterval(start: MailStoreCodec.date(base), duration: 7 * 86_400)
        let store = try SQLiteMailStore(path: path)
        XCTAssertEqual(try store.body(for: m1)?.plainText, "Hello there", "the mail reads as before")
        XCTAssertEqual(try store.calendarEvents(in: week, accountIDs: nil), [])
        let event = CalendarEvent(id: CalendarEvent.localID(accountID: account, providerID: "evt-1"), accountID: account,
                                  providerID: "evt-1", title: "Standup", start: MailStoreCodec.date(base + 3_600_000),
                                  end: MailStoreCodec.date(base + 5_400_000))
        try store.replaceCalendarEvents([event], accountID: account, window: week)
        try store.saveMailTimes([MailTime(messageID: m1, start: MailStoreCodec.date(base + 7_200_000), phrase: "at 2am")], for: m1)
        XCTAssertEqual(try store.calendarEvents(in: week, accountIDs: nil), [event])
        XCTAssertEqual(try store.mailTimes(in: c1).map(\.phrase), ["at 2am"])
        try store.close()

        XCTAssertEqual(try query("SELECT name, type, \"notnull\", pk FROM pragma_table_info('calendar_events') ORDER BY cid", at: path), [
            ["id", "TEXT", "1", "1"], ["account_id", "TEXT", "1", "0"], ["provider_id", "TEXT", "0", "0"], ["title", "TEXT", "1", "0"],
            ["location", "TEXT", "0", "0"], ["start_ms", "INTEGER", "1", "0"], ["end_ms", "INTEGER", "1", "0"],
            ["is_all_day", "INTEGER", "1", "0"], ["response", "TEXT", "1", "0"], ["is_free", "INTEGER", "1", "0"],
            ["join_url", "TEXT", "0", "0"], ["web_url", "TEXT", "0", "0"], ["organizer", "TEXT", "0", "0"],
            ["invitation_uid", "TEXT", "0", "0"], ["source_account_id", "TEXT", "0", "0"], ["source_provider_id", "TEXT", "0", "0"],
            ["client_key", "TEXT", "0", "0"], ["sync", "TEXT", "1", "0"], ["updated_ms", "INTEGER", "0", "0"],
            ["queued_ms", "INTEGER", "0", "0"],
        ])
        XCTAssertEqual(try query("SELECT name, type, \"notnull\", pk FROM pragma_table_info('mail_times') ORDER BY cid", at: path), [
            ["account_id", "TEXT", "1", "1"], ["provider_id", "TEXT", "1", "2"], ["ord", "INTEGER", "1", "3"],
            ["conversation_provider_id", "TEXT", "1", "0"], ["start_ms", "INTEGER", "1", "0"], ["duration_s", "INTEGER", "0", "0"],
            ["phrase", "TEXT", "1", "0"],
        ])
        XCTAssertEqual(try query("SELECT \"table\", \"from\", \"to\", on_delete FROM pragma_foreign_key_list('calendar_events')", at: path),
                       [["accounts", "account_id", "id", "CASCADE"]])
        XCTAssertEqual(try query("""
            SELECT "table", "from", "to", on_delete FROM pragma_foreign_key_list('mail_times') ORDER BY seq
            """, at: path), [["messages", "account_id", "account_id", "CASCADE"], ["messages", "provider_id", "provider_id", "CASCADE"]])
        for table in ["calendar_events", "mail_times"] {
            let ddl = try XCTUnwrap(try query("SELECT sql FROM sqlite_master WHERE name = '\(table)'", at: path).first?.first ?? nil)
            XCTAssertFalse(ddl.contains("WITHOUT ROWID"), "\(table): a rowid table, which an observation can see")
        }
        XCTAssertEqual(try query("""
            SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name IN ('calendar_events', 'mail_times') AND sql IS NOT NULL
            ORDER BY name
            """, at: path).compactMap(\.first),
                       ["calendar_events_by_client_key", "calendar_events_by_sync", "calendar_events_by_time", "mail_times_by_conversation"])
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations ORDER BY rowid", at: path).compactMap(\.first).suffix(4),
                       ["v20-calendar", "v21-search-walk", "v22-account-face", "v23-server-rules"])

        let reopened = try SQLiteMailStore(path: path)
        try reopened.wipeMailData(for: account)
        XCTAssertEqual(try reopened.calendarEvents(in: week, accountIDs: nil), [event], "a wipe of the mail keeps the calendar")
        XCTAssertEqual(try query("SELECT COUNT(*) FROM mail_times", at: path), [["0"]], "and takes the times with the mail")
        try reopened.close()
        try execute("PRAGMA foreign_keys = ON; DELETE FROM accounts WHERE id = 'acct-a';", at: path)
        XCTAssertEqual(try query("SELECT COUNT(*) FROM calendar_events", at: path), [["0"]], "an account's events go with it")
    }

    /// v18 rebuilds `pending_sends` with `draft_id` and `summary_json`, NULL for every send already in the outbox (those
    /// are undo-sends, which keep no draft), and the message last, so a read of the summaries stops short of it. The file
    /// is a real v15 one (a v1 file taken through the shipped migrations up to v15) with a send held in its undo window;
    /// opened by the current build, the send reads as before, whole and as a summary made from its message, with no draft,
    /// and the runner would still send it as an undo-send. The rebuilt table still goes with its account.
    func testVersion15DatabaseGainsTheDraftColumnAndKeepsItsOutbox() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        try MailSchema.migrateFile(at: path, upTo: "v15-calendar-invitations")
        XCTAssertFalse(try query("SELECT name FROM pragma_table_info('pending_sends')", at: path).compactMap(\.first).contains("draft_id"))
        let message = try MailStoreCodec.json(OutgoingMessage(accountID: AccountID("acct-a"), to: [EmailAddress(address: "ben@example.com")],
                                                              subject: "Lunch", html: "<p>Noon?</p>", text: "Noon?"))
        try execute("""
            INSERT INTO pending_sends (id, account_id, message_json, created_at, send_after, status, attempts, last_error)
            VALUES ('s1', 'acct-a', '\(message.replacingOccurrences(of: "'", with: "''"))', \(base), \(base + 5_000), 'scheduled', 0, NULL);
            """, at: path)

        let store = try SQLiteMailStore(path: path)
        let sends = try store.pendingSends()
        XCTAssertEqual(sends.map(\.id), ["s1"])
        XCTAssertEqual(sends.first?.status, .scheduled)
        XCTAssertNil(sends.first?.draftID, "an undo-send keeps no draft")
        XCTAssertEqual(sends.first?.message.subject, "Lunch")
        let summaries = try store.pendingSendSummaries()
        XCTAssertEqual(summaries, sends.map(PendingSendSummary.init), "read from the message, which it has no summary of")
        XCTAssertNil(summaries.first.flatMap(SendLaterState.init), "and is never listed in Drafts")
        try store.close()
        XCTAssertEqual(try query("SELECT name FROM pragma_table_info('pending_sends') ORDER BY cid", at: path).compactMap(\.first),
                       ["id", "account_id", "created_at", "send_after", "status", "attempts", "last_error", "draft_id", "summary_json",
                        "message_json"], "the message last")
        for column in ["draft_id", "summary_json"] {
            XCTAssertEqual(try query("SELECT type, \"notnull\", dflt_value FROM pragma_table_info('pending_sends') WHERE name = '\(column)'",
                                     at: path), [["TEXT", "0", nil]], "\(column): TEXT NULL with no default")
        }
        XCTAssertEqual(try query("SELECT draft_id, summary_json FROM pending_sends", at: path), [[nil, nil]])
        XCTAssertEqual(try query("SELECT \"table\", \"from\", \"to\", on_delete FROM pragma_foreign_key_list('pending_sends')", at: path),
                       [["accounts", "account_id", "id", "CASCADE"]])
        XCTAssertTrue(try query("SELECT identifier FROM grdb_migrations ORDER BY rowid", at: path).compactMap(\.first)
            .contains("v18-scheduled-sends"))
    }

    /// v23 makes `sender_rules` the mirror of the server's rules: `server_ids` (NULL) and `sync` (NOT NULL, 'saved' by
    /// default) and nothing else. The file is a real v22 one whose rules the previous build kept on this Mac alone. Opened
    /// by the current build every one of them is `creating`, with no server id, so the engine uploads each once (oldest
    /// first); a read that finds an identical rule on the server adopts it, a rule set from then on is `creating` too, and
    /// the rows still go with their account.
    func testVersion22DatabaseUploadsItsSenderRulesOnce() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        try MailSchema.migrateFile(at: path, upTo: "v22-account-face")
        XCTAssertFalse(try query("SELECT name FROM pragma_table_info('sender_rules')", at: path).compactMap(\.first).contains("sync"))
        try execute("""
            INSERT INTO sender_rules (account_id, address, action, created_at) VALUES
                ('acct-a', 'news@letter.example', 'archive', \(base + 2_000)),
                ('acct-a', 'deals@shop.example', 'trash', \(base + 1_000)),
                ('acct-b', 'deals@shop.example', 'archive', \(base + 3_000));
            """, at: path)

        let a = AccountID("acct-a")
        let b = AccountID("acct-b")
        let store = try SQLiteMailStore(path: path)
        XCTAssertEqual(try store.senderRules(), [
            SenderRule(accountID: a, address: "deals@shop.example", action: .trash, createdAt: MailStoreCodec.date(base + 1_000),
                       sync: .creating),
            SenderRule(accountID: a, address: "news@letter.example", action: .archive, createdAt: MailStoreCodec.date(base + 2_000),
                       sync: .creating),
            SenderRule(accountID: b, address: "deals@shop.example", action: .archive, createdAt: MailStoreCodec.date(base + 3_000),
                       sync: .creating),
        ], "every rule this Mac kept is on its way to the server, with no server id")
        XCTAssertEqual(try store.pendingSenderRules(accountID: a).map(\.address), ["deals@shop.example", "news@letter.example"],
                       "oldest first")

        // The server already has one of them (set on another Mac running an earlier build, say): adopted, not made twice.
        try store.replaceServerSenderRules(accountID: a, with: [ServerSenderRule(serverID: "f1", address: "deals@shop.example",
                                                                                 action: .trash)],
                                           readAt: MailStoreCodec.date(base + 9_000))
        XCTAssertEqual(try store.senderRules().filter { $0.accountID == a }.map { "\($0.address) \($0.sync.rawValue) \($0.serverIDs)" },
                       ["deals@shop.example saved [\"f1\"]", "news@letter.example creating []"])
        try store.setSenderRule(.trash, for: "promo@shop.example", accountID: b, enqueueing: [], at: MailStoreCodec.date(base + 10_000))
        XCTAssertEqual(try store.pendingSenderRules(accountID: b).map(\.address), ["deals@shop.example", "promo@shop.example"])
        try store.close()

        XCTAssertEqual(try query("""
            SELECT name, type, "notnull", dflt_value FROM pragma_table_info('sender_rules') WHERE name IN ('server_ids', 'sync')
            ORDER BY cid
            """, at: path), [["server_ids", "TEXT", "0", nil], ["sync", "TEXT", "1", "'saved'"]])
        XCTAssertEqual(try query("SELECT account_id, address, server_ids, sync FROM sender_rules ORDER BY account_id, address", at: path), [
            ["acct-a", "deals@shop.example", "[\"f1\"]", "saved"], ["acct-a", "news@letter.example", nil, "creating"],
            ["acct-b", "deals@shop.example", nil, "creating"], ["acct-b", "promo@shop.example", nil, "creating"],
        ], "ids as a JSON array, NULL while the rule is not on the server")
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations ORDER BY rowid", at: path).compactMap(\.first).last,
                       "v23-server-rules")
        try execute("PRAGMA foreign_keys = ON; DELETE FROM accounts WHERE id = 'acct-a';", at: path)
        XCTAssertEqual(try query("SELECT COUNT(*) FROM sender_rules WHERE account_id = 'acct-a'", at: path), [["0"]],
                       "a rule still goes with its account")
    }

    /// The eight migrations since the last release, on one real v15 file (a v1 file taken through the shipped migrations up
    /// to v15) holding mail, a muted-to-be conversation and a send in its undo window. Opened by the current build it runs
    /// v16-conversation-mute, v17-sender-rules, v18-scheduled-sends, v19-sync-robustness, v20-calendar, v21-search-walk,
    /// v22-account-face and v23-server-rules, in that order and nothing else; everything it held reads as before, each new
    /// table or column starts empty, the date index carries the flags a search tests, and reopening it runs nothing.
    func testVersion15DatabaseTakesTheEightNewMigrationsInOrder() throws {
        let newMigrations = ["v16-conversation-mute", "v17-sender-rules", "v18-scheduled-sends", "v19-sync-robustness",
                             "v20-calendar", "v21-search-walk", "v22-account-face", "v23-server-rules"]
        XCTAssertEqual(Array(MailSchema.migrator().migrations.suffix(8)), newMigrations, "registered in this order, last")
        let path = try XCTUnwrap(directory).appendingPathComponent("mail.sqlite").path
        try writeVersion1Database(at: path)
        try MailSchema.migrateFile(at: path, upTo: "v15-calendar-invitations")
        let message = try MailStoreCodec.json(OutgoingMessage(accountID: AccountID("acct-a"), to: [EmailAddress(address: "ben@example.com")],
                                                              subject: "Lunch", html: "<p>Noon?</p>", text: "Noon?"))
        try execute("""
            INSERT INTO pending_sends (id, account_id, message_json, created_at, send_after, status, attempts, last_error)
            VALUES ('s1', 'acct-a', '\(message.replacingOccurrences(of: "'", with: "''"))', \(base), \(base + 5_000), 'scheduled', 0, NULL);
            """, at: path)
        let before = try query("SELECT identifier FROM grdb_migrations ORDER BY rowid", at: path).compactMap(\.first)
        XCTAssertEqual(before.last, "v15-calendar-invitations")
        XCTAssertTrue(Set(before).isDisjoint(with: newMigrations))

        let account = AccountID("acct-a")
        let c1 = ConversationID(accountID: account, providerID: "c1")
        let store = try SQLiteMailStore(path: path)
        XCTAssertEqual(try store.body(for: MessageID(accountID: account, providerID: "m1"))?.plainText, "Hello there")
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .inbox)).map(\.id), [c1], "the mail reads as before")
        XCTAssertFalse(try store.isMuted(c1), "v16: nothing muted")
        XCTAssertTrue(try store.senderRules().isEmpty, "v17 and v23: no rules")
        let sends = try store.pendingSends()
        XCTAssertEqual(sends.map(\.id), ["s1"], "v18: the outbox kept")
        XCTAssertEqual(sends.first?.status, .scheduled)
        XCTAssertNil(sends.first?.draftID)
        XCTAssertEqual(try store.queuedLookups(accountID: account, limit: 10), [:], "v19: no lookups queued")
        XCTAssertEqual(try store.calendarEvents(in: DateInterval(start: .distantPast, end: .distantFuture), accountIDs: nil), [],
                       "v20: no events")
        XCTAssertEqual(try store.mailTimes(in: c1), [], "v20: no mail times")
        XCTAssertEqual(Set(try store.accounts().map(\.face)), [.automatic], "v22: no face chosen")
        // Each works once there.
        try store.setMuted(true, conversations: [c1], enqueueing: [])
        XCTAssertTrue(try store.isMuted(c1))
        try store.verifyFullTextIndex()
        try store.close()

        let after = try query("SELECT identifier FROM grdb_migrations ORDER BY rowid", at: path).compactMap(\.first)
        XCTAssertEqual(Array(after.dropFirst(before.count)), newMigrations, "the eight, in order, and nothing else")
        XCTAssertEqual(try query("SELECT name FROM pragma_index_info('conversations_latest') ORDER BY seqno", at: path).compactMap(\.first), [
            "latest_date_ms", "in_inbox", "in_sent", "in_drafts", "in_trash", "is_starred", "has_attachments", "unread_count",
            "message_count", "inbox_section", "account_id", "provider_id",
        ], "v21: the date index carries every flag a search tests")
        try SQLiteMailStore(path: path).close()
        XCTAssertEqual(try query("SELECT identifier FROM grdb_migrations ORDER BY rowid", at: path).compactMap(\.first), after,
                       "reopening runs nothing")
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
