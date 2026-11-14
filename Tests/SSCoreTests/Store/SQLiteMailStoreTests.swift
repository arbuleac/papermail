import SQLite3
import XCTest
@testable import SSCore

/// Behavior only the SQLite store has: a file that survives reopening, the full-text index, body compression
/// and the query plans the performance budgets depend on. The shared contract lives in `MailStoreContractTests`.
final class SQLiteMailStoreTests: XCTestCase {
    private let accountA = AccountID("acct-a")
    private let accountB = AccountID("acct-b")
    private let base = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
    private var temporaryDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMailStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: Fixture helpers

    private func temporaryPath(_ components: String...) throws -> String {
        let directory = try XCTUnwrap(temporaryDirectory)
        return components.reduce(directory) { $0.appendingPathComponent($1) }.path
    }

    private func store(with accounts: [AccountID]? = nil) throws -> SQLiteMailStore {
        let store = try SQLiteMailStore.inMemory()
        try seedAccounts(in: store, accounts ?? [accountA, accountB])
        return store
    }

    private func seedAccounts(in store: SQLiteMailStore, _ ids: [AccountID]) throws {
        for (index, id) in ids.enumerated() {
            try store.upsertAccount(Account(
                id: id, kind: .gmail, email: "\(id.rawValue)@example.com", displayName: "Owner \(index)",
                addedAt: base.addingTimeInterval(Double(index) * 60)
            ))
        }
    }

    private func date(_ offsetSeconds: TimeInterval) -> Date {
        MailboxClock.aligned(base.addingTimeInterval(offsetSeconds))
    }

    private func message(
        _ providerID: String,
        in conversation: String,
        account: AccountID? = nil,
        subject: String = "Subject",
        from: EmailAddress? = EmailAddress(name: "Alice", address: "alice@example.com"),
        to: [EmailAddress] = [EmailAddress(name: "Owner", address: "acct-a@example.com")],
        cc: [EmailAddress] = [],
        date: Date? = nil,
        roles: Set<MailboxRole> = [.inbox],
        isRead: Bool = true
    ) -> MessageMetadata {
        let accountID = account ?? accountA
        return MessageMetadata(
            id: MessageID(accountID: accountID, providerID: providerID),
            conversationID: ConversationID(accountID: accountID, providerID: conversation),
            subject: subject,
            snippet: "snippet of \(providerID)",
            from: from,
            to: to,
            cc: cc,
            date: date ?? self.date(0),
            roles: roles,
            isRead: isRead,
            isStarred: false,
            hasAttachments: false
        )
    }

    private func body(_ text: String, html: String? = nil) -> StoredBody {
        StoredBody(
            body: MessageBody(html: html ?? "<p>\(text)</p>", text: text, attachments: []),
            renderedHTML: "<div>\(text)</div>",
            plainText: text
        )
    }

    private func search(_ text: String, in store: SQLiteMailStore, view: MailboxView = .all, accountIDs: [AccountID]? = nil) throws -> [String] {
        try store.conversations(ConversationQuery(accountIDs: accountIDs, view: view, searchText: text)).map(\.id.providerID)
    }

    private func permissions(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }

    // MARK: Persistence

    func testPersistsAcrossCloseAndReopen() throws {
        let path = try temporaryPath("nested", "deeper", "mail.sqlite")
        let target = MessageID(accountID: accountA, providerID: "m2")
        let send = PendingSend(id: "send-1", message: OutgoingMessage(
            accountID: accountA, to: [EmailAddress(address: "bob@example.com")], subject: "Hi", html: "<p>Hi</p>", text: "Hi"
        ), createdAt: date(1), sendAfter: date(6))
        let bootstrap = BootstrapState(startedAt: date(0), nextPage: "page-3", pagesDone: 2, messagesSeen: 400)

        do {
            let first = try SQLiteMailStore(path: path)
            try seedAccounts(in: first, [accountA])
            try first.upsertMessages([
                message("m1", in: "c", subject: "Quarterly budget", date: date(100), isRead: false),
                message("m2", in: "c", subject: "Re: Quarterly budget", date: date(200), isRead: false),
            ])
            try first.saveBody(body("The spreadsheet is attached"), for: target)
            try first.setSyncCursor("history-42", for: accountA)
            try first.setBootstrapState(bootstrap, for: accountA)
            try first.enqueue(Operation(id: "op-1", accountID: accountA, change: .setStarred(true), targets: [target], createdAt: date(300)))
            try first.enqueueSend(send)
            try first.close()
        }

        XCTAssertEqual(try permissions(of: path) & 0o777, 0o600)
        XCTAssertEqual(try permissions(of: try temporaryPath("nested", "deeper")) & 0o777, 0o700)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            XCTAssertEqual(try permissions(of: path + suffix) & 0o777, 0o600, suffix)
        }

        let reopened = try SQLiteMailStore(path: path)
        XCTAssertEqual(try reopened.accounts().map(\.id), [accountA])
        XCTAssertEqual(try reopened.syncCursor(for: accountA), "history-42")
        XCTAssertEqual(try reopened.bootstrapState(for: accountA), bootstrap)
        XCTAssertEqual(try reopened.messages(in: ConversationID(accountID: accountA, providerID: "c")).map(\.id.providerID), ["m1", "m2"])
        XCTAssertEqual(try reopened.body(for: target), body("The spreadsheet is attached"))
        XCTAssertEqual(try reopened.messageIDsMissingBodies(accountID: accountA, limit: 10).map(\.providerID), ["m1"])

        let inbox = try reopened.conversations(ConversationQuery(view: .inbox))
        XCTAssertEqual(inbox.map(\.id.providerID), ["c"])
        XCTAssertEqual(inbox.first?.unreadCount, 2)
        XCTAssertEqual(inbox.first?.isStarred, true, "the queued star survives")
        XCTAssertEqual(inbox.first?.hasPendingOperations, true)
        XCTAssertEqual(try reopened.pendingOperations(accountID: accountA, limit: 10).map(\.id), ["op-1"])
        XCTAssertEqual(try reopened.pendingSends(), [send])
        XCTAssertEqual(try search("spreadsheet", in: reopened), ["c"], "the full-text index is on disk too")
        XCTAssertEqual(try reopened.suggestAddresses(prefix: "ali", limit: 5).map(\.address), ["alice@example.com"])
        try reopened.verifyFullTextIndex()

        // Reopening again runs the migrations a third time without complaint.
        try reopened.close()
        XCTAssertEqual(try SQLiteMailStore(path: path).accounts().count, 1)
    }

    func testCallsAfterCloseThrow() throws {
        let store = try SQLiteMailStore(path: try temporaryPath("mail.sqlite"))
        try store.close()
        XCTAssertThrowsError(try store.accounts())
    }

    func testInMemoryStoresAreIndependent() throws {
        let first = try store(with: [accountA])
        let second = try store(with: [accountB])
        try first.upsertMessages([message("m1", in: "c")])
        XCTAssertEqual(try first.accounts().map(\.id), [accountA])
        XCTAssertEqual(try second.accounts().map(\.id), [accountB])
        XCTAssertEqual(try second.conversations(ConversationQuery(view: .all)), [])
    }

    // MARK: Full-text search

    func testSearchCoversSubjectParticipantsAndBody() throws {
        let store = try store()
        let hiro = EmailAddress(name: "Hiro Nakamura", address: "hiro@example.com")
        let ingrid = EmailAddress(name: "Ingrid Larsen", address: "ingrid@example.com")
        let zoe = EmailAddress(name: "Zoë Müller", address: "zoe@example.com")
        let quinn = EmailAddress(address: "quinn.varga@example.com")
        try store.upsertMessages([
            message("m1", in: "c1", subject: "Quarterly budget review", from: hiro, date: date(100)),
            message("m2", in: "c2", subject: "Lunch on Thursday?", from: ingrid, cc: [zoe], date: date(200)),
            message("m3", in: "c3", subject: "Trip itinerary", from: quinn, date: date(300)),
            message("m4", in: "c4", subject: "Budget leftovers", from: hiro, date: date(400), roles: [.trash]),
            message("m5", in: "c5", account: accountB, subject: "Budget for the other account", from: ingrid, date: date(500)),
        ])
        try store.saveBody(body("The spreadsheet is attached"), for: MessageID(accountID: accountA, providerID: "m1"))
        try store.saveBody(body("Pizza and sushi"), for: MessageID(accountID: accountA, providerID: "m2"))

        // Subject, with the view predicates still applied on top of the hits.
        XCTAssertEqual(try search("budget", in: store), ["c5", "c1"])
        XCTAssertEqual(try search("budget", in: store, view: .inbox), ["c5", "c1"])
        XCTAssertEqual(try search("budget", in: store, view: .trash), ["c4"])
        XCTAssertEqual(try search("budget", in: store, accountIDs: [accountA]), ["c1"])
        XCTAssertEqual(try search("budget", in: store, accountIDs: [accountB]), ["c5"])

        // Body text.
        XCTAssertEqual(try search("spreadsheet", in: store), ["c1"])
        XCTAssertEqual(try search("sushi", in: store), ["c2"])

        // Participants: sender name, cc name with diacritics folded, address parts of a sender without a name.
        XCTAssertEqual(try search("nakamura", in: store), ["c1"])
        XCTAssertEqual(try search("hiro", in: store), ["c1"])
        XCTAssertEqual(try search("muller", in: store), ["c2"])
        XCTAssertEqual(try search("Zoë", in: store), ["c2"])
        XCTAssertEqual(try search("quinn", in: store), ["c3"])
        XCTAssertEqual(try search("varga", in: store), ["c3"])

        // Several tokens must all match, across columns.
        XCTAssertEqual(try search("budget spreadsheet", in: store), ["c1"])
        XCTAssertEqual(try search("nakamura spreadsheet", in: store), ["c1"])
        XCTAssertEqual(try search("budget pizza", in: store), [])

        // Results keep the list order: latest conversation first.
        XCTAssertEqual(try search("example", in: store), ["c5", "c3", "c2", "c1"])

        // Nothing to search for means no search.
        XCTAssertEqual(try search("", in: store), ["c5", "c3", "c2", "c1"])
        XCTAssertEqual(try search("   ", in: store), ["c5", "c3", "c2", "c1"])
        XCTAssertEqual(try search("?!", in: store), ["c5", "c3", "c2", "c1"])
        XCTAssertEqual(try search("zzz", in: store), [])
    }

    func testSearchTreatsTheLastTokenAsAPrefix() throws {
        let store = try store(with: [accountA])
        try store.upsertMessages([
            message("m1", in: "c1", subject: "Quarterly budget review", from: EmailAddress(name: "Hiro Nakamura", address: "hiro@example.com"), date: date(100)),
            message("m2", in: "c2", subject: "Lunch on Thursday?", date: date(200)),
        ])
        try store.saveBody(body("The spreadsheet is attached"), for: MessageID(accountID: accountA, providerID: "m1"))

        XCTAssertEqual(try search("budg", in: store), ["c1"])
        XCTAssertEqual(try search("spreadsh", in: store), ["c1"])
        XCTAssertEqual(try search("nakam", in: store), ["c1"])
        XCTAssertEqual(try search("lunch thu", in: store), ["c2"])
        XCTAssertEqual(try search("quarterly budget rev", in: store), ["c1"])
        XCTAssertEqual(try search("budg review", in: store), [], "only the last token is a prefix")
        XCTAssertEqual(try search("t", in: store), ["c2", "c1"], "a single letter narrows as the user keeps typing")
    }

    func testSearchDoesNotInterpretQueryOperators() throws {
        let store = try store(with: [accountA])
        try store.upsertMessages([message("m1", in: "c1", subject: "Quarterly budget review", date: date(100))])
        // Unquoted, FTS5 would read these as syntax (a grouping error, a boolean OR that matches c1, a column filter).
        // `subject:` is the search's own operator (`SearchGrammar`), not FTS5's column filter.
        XCTAssertEqual(try search("(budget", in: store), ["c1"])
        XCTAssertEqual(try search("budget OR nothing", in: store), [])
        XCTAssertEqual(try search("\"budget\" NOT review", in: store), [])
        XCTAssertEqual(try search("{subject}:budget", in: store), [])
        XCTAssertEqual(try search("body:budget", in: store), [])
        XCTAssertEqual(try search("budget*", in: store), ["c1"])
    }

    func testUpsertReindexesChangedSubjectsAndParticipants() throws {
        let store = try store(with: [accountA])
        let original = message("m1", in: "c1", subject: "Trip itinerary", from: EmailAddress(name: "Quinn Varga", address: "quinn@example.com"))
        try store.upsertMessages([original])
        XCTAssertEqual(try search("itinerary", in: store), ["c1"])

        var changed = original
        changed.subject = "Flight details"
        changed.from = EmailAddress(name: "Rosa Petrov", address: "rosa@example.com")
        try store.upsertMessages([changed])
        XCTAssertEqual(try search("itinerary", in: store), [])
        XCTAssertEqual(try search("varga", in: store), [])
        XCTAssertEqual(try search("flight", in: store), ["c1"])
        XCTAssertEqual(try search("petrov", in: store), ["c1"])
        try store.verifyFullTextIndex()

        // Re-saving a body replaces the old text in the index.
        try store.saveBody(body("first draft"), for: original.id)
        try store.saveBody(body("final version"), for: original.id)
        XCTAssertEqual(try search("draft", in: store), [])
        XCTAssertEqual(try search("final", in: store), ["c1"])
        try store.verifyFullTextIndex()
    }

    /// A message without a body is indexed by its snippet (v13), so a poll that changes only the snippet re-indexes it,
    /// and the body's arrival replaces it; the index stays exactly what the view says throughout.
    func testUpsertReindexesAChangedSnippetUntilTheBodyArrives() throws {
        let store = try store(with: [accountA])
        var original = message("m1", in: "c1", subject: "Tax documents")
        original.snippet = "Forms for the landlord"
        try store.upsertMessages([original])
        XCTAssertEqual(try search("landlord", in: store), ["c1"])

        var changed = original
        changed.snippet = "Forms for the accountant"
        try store.upsertMessages([changed])
        XCTAssertEqual(try search("landlord", in: store), [])
        XCTAssertEqual(try search("accountant", in: store), ["c1"])
        try store.verifyFullTextIndex()

        try store.saveBody(body("both attached"), for: original.id)
        XCTAssertEqual(try search("accountant", in: store), [])
        XCTAssertEqual(try search("attached", in: store), ["c1"])
        try store.verifyFullTextIndex()
        // With the body stored the snippet no longer counts, though a change to it still re-indexes harmlessly.
        changed.snippet = "Something else"
        try store.upsertMessages([changed])
        XCTAssertEqual(try search("something", in: store), [])
        try store.verifyFullTextIndex()
    }

    func testDeleteMessagesRemovesFullTextRows() throws {
        let store = try store(with: [accountA])
        try store.upsertMessages([
            message("m1", in: "c", subject: "Zebra crossing", date: date(100)),
            message("m2", in: "c", subject: "Yak butter", date: date(200)),
            message("m3", in: "d", subject: "Xylophone lessons", date: date(300)),
        ])
        try store.saveBody(body("zebra body"), for: MessageID(accountID: accountA, providerID: "m1"))
        try store.saveBody(body("xylophone body"), for: MessageID(accountID: accountA, providerID: "m3"))
        XCTAssertEqual(try search("zebra", in: store), ["c"])

        try store.deleteMessages([MessageID(accountID: accountA, providerID: "m1")])
        XCTAssertEqual(try search("zebra", in: store), [], "neither the subject nor the body of a deleted message matches")
        XCTAssertEqual(try search("yak", in: store), ["c"])
        try store.verifyFullTextIndex()

        try store.deleteMessages([MessageID(accountID: accountA, providerID: "m2")])
        XCTAssertEqual(try search("yak", in: store), [])
        try store.verifyFullTextIndex()

        // m3 holds the highest rowid, which SQLite hands to the next inserted message. A stale index entry
        // would make the newcomer answer for "xylophone".
        try store.deleteMessages([MessageID(accountID: accountA, providerID: "m3")])
        try store.upsertMessages([message("m4", in: "e", subject: "Unrelated", date: date(400))])
        XCTAssertEqual(try search("xylophone", in: store), [])
        XCTAssertEqual(try search("unrelated", in: store), ["e"])
        try store.verifyFullTextIndex()
    }

    func testWipeAndDeleteAccountClearTheIndex() throws {
        let store = try store()
        try store.upsertMessages([
            message("m1", in: "c1", subject: "Zebra crossing", date: date(100)),
            message("m2", in: "c2", account: accountB, subject: "Zebra stripes", from: EmailAddress(address: "b@example.com"), date: date(200)),
        ])
        try store.saveBody(body("zebra body"), for: MessageID(accountID: accountA, providerID: "m1"))
        XCTAssertEqual(try search("zebra", in: store), ["c2", "c1"])

        try store.wipeMailData(for: accountA)
        XCTAssertEqual(try search("zebra", in: store), ["c2"])
        try store.verifyFullTextIndex()

        try store.deleteAccount(accountB)
        XCTAssertEqual(try search("zebra", in: store), [])
        try store.verifyFullTextIndex()

        // The last account's wipe takes the delete-all path; it must leave a usable index behind.
        try store.upsertMessages([message("m3", in: "c3", subject: "Zebra again", date: date(300))])
        XCTAssertEqual(try search("zebra", in: store), ["c3"])
        try store.verifyFullTextIndex()
    }

    func testBackfillWritesAndSweepKeepTheIndexExact() throws {
        let store = try store(with: [accountA])
        try store.upsertMessages([
            message("m1", in: "c1", subject: "Quarterly plan", date: date(100)),
            message("m2", in: "c2", subject: "Yak shaving", date: date(200)),
        ])
        try store.saveBody(body("budget numbers"), for: MessageID(accountID: accountA, providerID: "m1"))

        // A refresh that changes indexed fields, one that changes none, and a new message, in one page.
        XCTAssertEqual(try store.writeBackfillMessages([
            message("m1", in: "c1", subject: "Revised plan", date: date(100)),
            message("m2", in: "c2", subject: "Yak shaving", date: date(200), isRead: false),
            message("m3", in: "c3", subject: "Zebra crossing", date: date(300)),
        ], refreshExisting: true), 3)
        XCTAssertEqual(try search("quarterly", in: store), [])
        XCTAssertEqual(try search("revised", in: store), ["c1"])
        XCTAssertEqual(try search("budget", in: store), ["c1"])
        XCTAssertEqual(try search("zebra", in: store), ["c3"])
        try store.verifyFullTextIndex()

        try store.markBackfillSeen(accountID: accountA, providerIDs: ["m2"])
        XCTAssertEqual(try store.finishBackfill(accountID: accountA, sweepUnseen: true), 2)
        XCTAssertEqual(try search("plan", in: store), [])
        XCTAssertEqual(try search("budget", in: store), [])
        XCTAssertEqual(try search("zebra", in: store), [])
        XCTAssertEqual(try search("yak", in: store), ["c2"])
        try store.verifyFullTextIndex()
    }

    func testSearchObservationFollowsNewMail() throws {
        let store = try store(with: [accountA])
        try store.upsertMessages([message("m1", in: "c1", subject: "Quarterly budget", date: date(100))])
        let initial = expectation(description: "initial")
        let afterChange = expectation(description: "after change")
        let box = ObservedValues()
        let observation = store.observeConversations(ConversationQuery(view: .inbox, searchText: "budg")) { summaries in
            XCTAssertTrue(Thread.isMainThread)
            let ids = summaries.map(\.id.providerID)
            if box.append(ids) == 1 { initial.fulfill() }
            if ids == ["c2", "c1"] { afterChange.fulfill() }
        }
        wait(for: [initial], timeout: 2)
        XCTAssertEqual(box.values.first, ["c1"])
        try store.upsertMessages([message("m2", in: "c2", subject: "Budget again", date: date(200))])
        wait(for: [afterChange], timeout: 2)
        observation.cancel()
    }

    /// A full-text search over a large mailbox takes tens of milliseconds for a short prefix; started from
    /// the main thread it must not run there, while list views keep their synchronous first page.
    func testSearchObservationDeliversOffTheCallingTurn() throws {
        let store = try store(with: [accountA])
        try store.upsertMessages([message("m1", in: "c1", subject: "Quarterly budget", date: date(100))])
        XCTAssertTrue(Thread.isMainThread)

        let listBox = ObservedValues()
        let list = store.observeConversations(ConversationQuery(view: .inbox)) { listBox.append($0.map(\.id.providerID)) }
        XCTAssertEqual(listBox.values, [["c1"]], "list views still get their first page synchronously")

        let searchBox = ObservedValues()
        let delivered = expectation(description: "search results")
        let search = store.observeConversations(ConversationQuery(view: .inbox, searchText: "b")) { summaries in
            XCTAssertTrue(Thread.isMainThread)
            searchBox.append(summaries.map(\.id.providerID))
            delivered.fulfill()
        }
        XCTAssertTrue(searchBox.values.isEmpty, "the search query ran on the main thread")
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(searchBox.values, [["c1"]])
        list.cancel()
        search.cancel()
    }

    /// Hydration saves one body after another and every save rewrites the message's full-text row; with
    /// search results on screen each one used to re-deliver identical rows to the main thread, where the
    /// list then re-read its scrolled tail pages.
    func testSearchObservationIgnoresBodySavesThatChangeNoRow() throws {
        let store = try store(with: [accountA])
        let ids = (1...5).map { "m\($0)" }
        try store.upsertMessages(ids.enumerated().map { message($1, in: "c\($0)", subject: "Invoice \($0)", date: date(TimeInterval(100 + $0))) })
        let box = ObservedValues()
        let initial = expectation(description: "initial")
        let changed = expectation(description: "new mail")
        let observation = store.observeConversations(ConversationQuery(view: .inbox, searchText: "invoice")) { summaries in
            let count = box.append(summaries.map(\.id.providerID))
            if count == 1 { initial.fulfill() }
            if summaries.count == 6 { changed.fulfill() }
        }
        wait(for: [initial], timeout: 2)
        for id in ids {
            try store.saveBody(body("invoice body \(id)"), for: MessageID(accountID: accountA, providerID: id))
        }
        try store.upsertMessages([message("m6", in: "c6", subject: "Invoice 6", date: date(200))])
        wait(for: [changed], timeout: 2)
        XCTAssertEqual(box.values.count, 2, "body saves that leave every row as it was must not re-deliver: \(box.values)")
        observation.cancel()
    }

    /// A search whose read fails (the full-text table dropped behind the store's back, standing in for a damaged
    /// index or an I/O error) stops, and says so to its subscriber, which would otherwise wait for rows that never
    /// come: the list's `list.search` interval ends on it.
    func testSearchObservationReportsAFailedRead() throws {
        let path = try temporaryPath("mail.sqlite")
        let store = try SQLiteMailStore(path: path)
        try seedAccounts(in: store, [accountA])
        try store.upsertMessages([message("m1", in: "c1", subject: "Quarterly budget", date: date(100))])
        try dropFullTextTable(inFileAt: path)

        let box = ObservedValues()
        let failed = expectation(description: "error")
        let observation = store.observeConversations(
            ConversationQuery(view: .inbox, searchText: "budg"),
            onChange: { box.append($0.map(\.id.providerID)) },
            onError: { _ in
                XCTAssertTrue(Thread.isMainThread)
                failed.fulfill()
            }
        )
        wait(for: [failed], timeout: 2)
        XCTAssertTrue(box.values.isEmpty, "a failed read delivers no rows: \(box.values)")
        observation.cancel()
        try store.close()
    }

    /// The outbox's summaries are read without the message, which a Send Later message keeps for days with its
    /// attachments inline, and a state write never rewrites it: with the message's column made unreadable, both work.
    func testOutboxSummariesNeverReadTheMessage() throws {
        let path = try temporaryPath("outbox.sqlite")
        let store = try SQLiteMailStore(path: path)
        try seedAccounts(in: store, [accountA])
        let file = OutgoingAttachment(filename: "plan.pdf", mimeType: "application/pdf", data: Data(repeating: 7, count: 300_000))
        let message = OutgoingMessage(accountID: accountA, to: [EmailAddress(name: "Ben", address: "ben@example.com")], subject: "Plan",
                                      html: "<p>Attached</p>", text: "Attached", attachments: [file])
        let send = PendingSend(id: "l1", message: message, createdAt: base, sendAfter: base.addingTimeInterval(86_400), status: .later,
                               draftID: UUID())
        try store.enqueueSend(send)
        XCTAssertEqual(try store.pendingSend(id: "l1"), send)
        try store.close()

        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK,
              sqlite3_exec(handle, "UPDATE pending_sends SET message_json = 'unreadable'", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return XCTFail("could not change the message: \(String(cString: sqlite3_errmsg(handle)))")
        }
        sqlite3_close(handle)

        let reopened = try SQLiteMailStore(path: path)
        XCTAssertEqual(try reopened.pendingSendSummaries(), [PendingSendSummary(send)], "the summaries never decode the message")
        var missed = PendingSendSummary(send)
        missed.status = .missed
        try reopened.updateSend(missed)
        XCTAssertEqual(try reopened.pendingSendSummaries(), [missed])
        XCTAssertThrowsError(try reopened.pendingSend(id: "l1"), "the message stays as it was: a state write never rewrites it")
        try reopened.close()
    }

    private func dropFullTextTable(inFileAt path: String) throws {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(path, &handle) == SQLITE_OK,
              sqlite3_exec(handle, "DROP TABLE message_fts", nil, nil, nil) == SQLITE_OK else {
            return XCTFail("could not drop the full-text table: \(String(cString: sqlite3_errmsg(handle)))")
        }
    }

    func testRenderFactsRoundTrip() throws {
        let store = try store(with: [accountA])
        try store.upsertMessages([message("m1", in: "c")])
        let id = MessageID(accountID: accountA, providerID: "m1")
        var stored = body("quoted")
        stored.hasQuotedContent = true
        stored.blockedRemoteImageCount = 3
        try store.saveBody(stored, for: id)
        XCTAssertEqual(try store.body(for: id)?.hasQuotedContent, true)
        XCTAssertEqual(try store.body(for: id)?.blockedRemoteImageCount, 3)
    }

    // MARK: Compression

    func testCompressionRoundTrip() throws {
        XCTAssertEqual(try MailStoreCodec.decompress(try MailStoreCodec.compress("")), "")

        let unicode = "Grüße aus Zürich — 東京 — 🦜 <b>bold</b>\n\ttabs"
        XCTAssertEqual(try MailStoreCodec.decompress(try MailStoreCodec.compress(unicode)), unicode)

        let html = String(repeating: "<tr><td style=\"padding:4px\">Quarterly budget line item</td></tr>\n", count: 4_000)
        let compressed = try MailStoreCodec.compress(html)
        XCTAssertLessThan(compressed.count, html.utf8.count / 10, "typical email HTML shrinks by an order of magnitude")
        XCTAssertEqual(try MailStoreCodec.decompress(compressed), html)

        XCTAssertThrowsError(try MailStoreCodec.decompress(Data("not zlib".utf8)))
    }

    func testStoredBodiesSurviveCompressionAndReopen() throws {
        let path = try temporaryPath("mail.sqlite")
        let id = MessageID(accountID: accountA, providerID: "m1")
        let html = String(repeating: "<p>Grüße aus Zürich 🦜</p>", count: 2_000)
        let stored = StoredBody(
            body: MessageBody(html: html, text: "Grüße aus Zürich", attachments: [
                AttachmentInfo(id: "att", filename: "map.png", mimeType: "image/png", sizeBytes: 12, contentID: "map", isInline: true),
            ]),
            renderedHTML: "<div class=\"ss-body\">\(html)</div>",
            plainText: "Grüße aus Zürich"
        )
        do {
            let store = try SQLiteMailStore(path: path)
            try seedAccounts(in: store, [accountA])
            try store.upsertMessages([message("m1", in: "c")])
            try store.saveBody(stored, for: id)
            XCTAssertEqual(try store.body(for: id), stored)
            try store.close()
        }
        let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        XCTAssertLessThan(fileSize, stored.renderedHTML.utf8.count, "the file holds the compressed form, not the HTML")
        XCTAssertEqual(try SQLiteMailStore(path: path).body(for: id), stored)
    }

    func testBodiesForUnknownMessagesAreDroppedAndBatchesAreSaved() throws {
        let store = try store(with: [accountA])
        let unknown = MessageID(accountID: accountA, providerID: "gone")
        try store.saveBody(body("late"), for: unknown)
        XCTAssertNil(try store.body(for: unknown))

        try store.upsertMessages([message("m1", in: "c", date: date(100)), message("m2", in: "c", date: date(200))])
        try store.saveBodies([
            (id: MessageID(accountID: accountA, providerID: "m1"), body: body("first")),
            (id: MessageID(accountID: accountA, providerID: "m2"), body: body("second")),
            (id: unknown, body: body("late")),
        ])
        XCTAssertEqual(try store.messageIDsMissingBodies(accountID: accountA, limit: 10), [])
        XCTAssertEqual(try search("second", in: store), ["c"])
        try store.verifyFullTextIndex()
    }

    // MARK: Query plans

    func testListQueriesStayOnTheirIndexes() throws {
        let store = try store()
        try store.upsertMessages([message("m1", in: "c")])

        let inbox = try store.queryPlan(for: ConversationQuery(view: .inbox))
        XCTAssertEqual(inbox.filter { $0.hasPrefix("SEARCH") || $0.hasPrefix("SCAN") }.count, 1, "one indexed select: \(inbox)")
        XCTAssertTrue(inbox.contains { $0.contains("USING INDEX conversations_inbox") }, "\(inbox)")

        // Paged by the Inbox's own date (v11), the expression the index is built on, so the page is a range read on it.
        let filtered = try store.queryPlan(for: ConversationQuery(accountIDs: [accountA], view: .inbox, section: .focused, unreadOnly: true, before: date(0)))
        XCTAssertTrue(filtered.contains { $0.contains("USING INDEX conversations_inbox") && $0.contains("<expr><?") }, "\(filtered)")

        XCTAssertTrue(try store.queryPlan(for: ConversationQuery(view: .starred)).contains { $0.contains("USING INDEX conversations_starred") })
        XCTAssertTrue(try store.queryPlan(for: ConversationQuery(view: .sent)).contains { $0.contains("USING INDEX conversations_sent") })
        XCTAssertTrue(try store.queryPlan(for: ConversationQuery(view: .all)).contains { $0.contains("USING INDEX conversations_latest") })

        let search = try store.queryPlan(for: ConversationQuery(view: .inbox, searchText: "budget"))
        XCTAssertTrue(search.contains { $0.contains("VIRTUAL TABLE INDEX") }, "hits come from FTS5: \(search)")
        // The hits become conversation keys through one scan of the covering index, never a table lookup per hit,
        // whether the search keeps what matches or, all its words negated, what does not.
        // What a search of the server found is a second test in the same scan, not a plan of its own.
        let found: Set<ConversationID> = [ConversationID(accountID: accountA, providerID: "c"),
                                          ConversationID(accountID: accountB, providerID: "d")]
        for text in ["budget", "-budget", "from:alice is:unread -budget"] {
            for matches in [[], found] {
                let plan = try store.queryPlan(for: ConversationQuery(view: .inbox, searchText: text, serverMatches: matches))
                XCTAssertTrue(plan.contains { $0.contains("COVERING INDEX messages_by_conversation") }, "\(text): \(plan)")
                XCTAssertFalse(plan.contains { $0.contains("INTEGER PRIMARY KEY") }, "\(text): \(plan)")
                XCTAssertEqual(plan.filter { $0.contains("USE TEMP B-TREE FOR DISTINCT") }, [], "\(text): \(plan)")
            }
        }
    }
}
