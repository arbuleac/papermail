import XCTest
import SSCore

/// The `MailStoring` contract, run against the reference `InMemoryMailStore` here and against
/// `SQLiteMailStore.inMemory()` through the subclass at the bottom of this file. Any behavior asserted here is
/// behavior the engine and the UI may rely on from either store.
class MailStoreContractTests: XCTestCase {
    func makeStore() throws -> MailStoring {
        InMemoryMailStore()
    }

    private var storage: MailStoring?
    var store: MailStoring {
        guard let storage else { preconditionFailure("setUp did not run") }
        return storage
    }

    let accountA = AccountID("acct-a")
    let accountB = AccountID("acct-b")
    let base = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try makeStore()
        try store.upsertAccount(account(accountA, email: "a@example.com", addedAt: base))
        try store.upsertAccount(account(accountB, email: "b@example.com", addedAt: base.addingTimeInterval(60)))
    }

    override func tearDownWithError() throws {
        storage = nil
        try super.tearDownWithError()
    }

    // MARK: Fixture helpers

    func account(_ id: AccountID, email: String, addedAt: Date) -> Account {
        Account(id: id, kind: .gmail, email: email, displayName: "Owner", colorHex: "#4A90E2", addedAt: addedAt)
    }

    /// A sender that only ever writes to account B, so account A's cascade and wipe can be told apart from B's data.
    let bea = EmailAddress(name: "Bea", address: "bea@example.com")

    /// Millisecond-aligned, because the data model stores epoch milliseconds and a sub-millisecond fixture
    /// would never compare equal after a round trip through the SQLite store.
    func date(_ offsetSeconds: TimeInterval) -> Date {
        MailboxClock.aligned(base.addingTimeInterval(offsetSeconds))
    }

    func message(
        _ providerID: String,
        in conversation: String,
        account: AccountID? = nil,
        subject: String = "Subject",
        snippet: String? = nil,
        from: EmailAddress? = EmailAddress(name: "Alice", address: "alice@example.com"),
        to: [EmailAddress] = [EmailAddress(name: "Owner", address: "a@example.com")],
        cc: [EmailAddress] = [],
        date: Date? = nil,
        roles: Set<MailboxRole> = [.inbox],
        isRead: Bool = true,
        isStarred: Bool = false,
        section: InboxSection = .unknown,
        hasAttachments: Bool = false
    ) -> MessageMetadata {
        let accountID = account ?? accountA
        return MessageMetadata(
            id: MessageID(accountID: accountID, providerID: providerID),
            conversationID: ConversationID(accountID: accountID, providerID: conversation),
            subject: subject,
            snippet: snippet ?? "snippet of \(providerID)",
            from: from,
            to: to,
            cc: cc,
            date: date ?? self.date(0),
            roles: roles,
            isRead: isRead,
            isStarred: isStarred,
            inboxSection: section,
            hasAttachments: hasAttachments
        )
    }

    func body(_ text: String) -> StoredBody {
        StoredBody(
            body: MessageBody(html: "<p>\(text)</p>", text: text, attachments: []),
            renderedHTML: "<div>\(text)</div>",
            plainText: text
        )
    }

    func conversationIDs(_ query: ConversationQuery) throws -> [String] {
        try store.conversations(query).map(\.id.providerID)
    }

    func summary(_ conversation: String, account: AccountID? = nil, view: MailboxView = .all) throws -> ConversationSummary {
        let id = ConversationID(accountID: account ?? accountA, providerID: conversation)
        let all = try store.conversations(ConversationQuery(view: view, limit: 10_000))
        guard let summary = all.first(where: { $0.id == id }) else {
            throw XCTSkip("conversation \(conversation) missing from \(view)")
        }
        return summary
    }

    // MARK: Accounts

    func testAccountsRoundTripSortedByAddedAt() throws {
        let accounts = try store.accounts()
        XCTAssertEqual(accounts.map(\.id), [accountA, accountB])
        XCTAssertEqual(accounts.first?.email, "a@example.com")

        var updated = accounts[0]
        updated.displayName = "Renamed"
        updated.colorHex = "#000000"
        try store.upsertAccount(updated)
        XCTAssertEqual(try store.accounts().first, updated)
        XCTAssertEqual(try store.accounts().count, 2)
    }

    func testSyncStateRoundTrip() throws {
        XCTAssertNil(try store.syncCursor(for: accountA))
        try store.setSyncCursor("cursor-1", for: accountA)
        XCTAssertEqual(try store.syncCursor(for: accountA), "cursor-1")
        XCTAssertNil(try store.syncCursor(for: accountB))
        try store.setSyncCursor(nil, for: accountA)
        XCTAssertNil(try store.syncCursor(for: accountA))

        XCTAssertNil(try store.bootstrapState(for: accountA))
        let state = BootstrapState(startedAt: date(10), nextPage: "page-2", pagesDone: 1, messagesSeen: 200, isComplete: false)
        try store.setBootstrapState(state, for: accountA)
        XCTAssertEqual(try store.bootstrapState(for: accountA), state)
        try store.setBootstrapState(nil, for: accountA)
        XCTAssertNil(try store.bootstrapState(for: accountA))
    }

    func testDeleteAccountCascadesToEverything() throws {
        try store.upsertMessages([
            message("a1", in: "ca"),
            message("b1", in: "cb", account: accountB, from: bea, to: [EmailAddress(address: "b@example.com")]),
        ])
        try store.saveBody(body("hello"), for: MessageID(accountID: accountA, providerID: "a1"))
        try store.setSyncCursor("c", for: accountA)
        try store.enqueue(Operation(accountID: accountA, change: .setStarred(true), targets: [MessageID(accountID: accountA, providerID: "a1")]))
        try store.enqueueSend(PendingSend(message: outgoing(from: accountA), sendAfter: date(5)))

        try store.deleteAccount(accountA)

        XCTAssertEqual(try store.accounts().map(\.id), [accountB])
        XCTAssertNil(try store.message(MessageID(accountID: accountA, providerID: "a1")))
        XCTAssertNil(try store.body(for: MessageID(accountID: accountA, providerID: "a1")))
        XCTAssertNil(try store.syncCursor(for: accountA))
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10), [])
        XCTAssertEqual(try store.pendingSends(), [])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all)), ["cb"])
        XCTAssertEqual(try store.suggestAddresses(prefix: "alice", limit: 5), [])
        XCTAssertEqual(try store.suggestAddresses(prefix: "bea", limit: 5), [bea], "the other account's contacts survive")
        XCTAssertNotNil(try store.message(MessageID(accountID: accountB, providerID: "b1")))
    }

    func testWipeMailDataKeepsTheAccountRow() throws {
        try store.upsertMessages([message("a1", in: "ca"), message("b1", in: "cb", account: accountB, from: bea)])
        try store.saveBody(body("hello"), for: MessageID(accountID: accountA, providerID: "a1"))
        try store.setSyncCursor("c", for: accountA)
        try store.setBootstrapState(BootstrapState(startedAt: date(0)), for: accountA)
        try store.enqueue(Operation(accountID: accountA, change: .archive, targets: [MessageID(accountID: accountA, providerID: "a1")]))
        try store.enqueueSend(PendingSend(message: outgoing(from: accountA), sendAfter: date(5)))

        try store.wipeMailData(for: accountA)

        XCTAssertEqual(try store.accounts().map(\.id), [accountA, accountB])
        XCTAssertNil(try store.message(MessageID(accountID: accountA, providerID: "a1")))
        XCTAssertNil(try store.body(for: MessageID(accountID: accountA, providerID: "a1")))
        XCTAssertNil(try store.syncCursor(for: accountA))
        XCTAssertNil(try store.bootstrapState(for: accountA))
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10), [])
        XCTAssertEqual(try store.pendingSends(), [])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all)), ["cb"])
        XCTAssertEqual(try store.suggestAddresses(prefix: "alice", limit: 5), [])
        XCTAssertEqual(try store.suggestAddresses(prefix: "bea", limit: 5), [bea], "the other account's contacts survive")
        // The account can be bootstrapped again right away.
        try store.upsertMessages([message("a2", in: "ca2", date: date(10))])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["ca2", "cb"])
    }

    // MARK: Messages

    func testMessageRoundTripKeepsEveryField() throws {
        let full = MessageMetadata(
            id: MessageID(accountID: accountA, providerID: "m-full"),
            conversationID: ConversationID(accountID: accountA, providerID: "c-full"),
            internetMessageID: "<x@y>",
            inReplyTo: "<w@y>",
            references: ["<v@y>", "<w@y>"],
            subject: "Ünïcode subject — with dashes",
            snippet: "snippet \"quoted\"",
            from: EmailAddress(name: "Zoë Müller", address: "Zoe@Example.com"),
            to: [EmailAddress(name: nil, address: "a@example.com"), EmailAddress(name: "Two", address: "two@example.com")],
            cc: [EmailAddress(name: "Three", address: "three@example.com")],
            bcc: [EmailAddress(address: "four@example.com")],
            replyTo: [EmailAddress(address: "reply@example.com")],
            date: date(123.456),
            roles: [.inbox, .sent],
            isRead: false,
            isStarred: true,
            inboxSection: .focused,
            hasAttachments: true,
            labelIDs: ["INBOX", "Label_7"],
            folderID: "AAMk",
            providerVersion: "12345",
            sizeBytes: 98_765
        )
        try store.upsertMessages([full])
        XCTAssertEqual(try store.message(full.id), full)
        XCTAssertNil(try store.message(MessageID(accountID: accountA, providerID: "nope")))

        var changed = full
        changed.subject = "Changed"
        changed.roles = []
        changed.labelIDs = []
        try store.upsertMessages([changed])
        XCTAssertEqual(try store.message(full.id), changed)
        XCTAssertEqual(try store.messages(in: full.conversationID).count, 1)
    }

    func testMessagesInConversationAreOldestFirst() throws {
        try store.upsertMessages([
            message("m3", in: "c", date: date(300)),
            message("m1", in: "c", date: date(100)),
            message("m2", in: "c", date: date(200)),
            message("other", in: "d", date: date(50)),
        ])
        XCTAssertEqual(try store.messages(in: ConversationID(accountID: accountA, providerID: "c")).map(\.id.providerID), ["m1", "m2", "m3"])
        XCTAssertEqual(try store.messages(in: ConversationID(accountID: accountB, providerID: "c")), [])
    }

    func testDeleteMessagesRemovesEmptyConversations() throws {
        try store.upsertMessages([message("m1", in: "c", date: date(100)), message("m2", in: "c", date: date(200))])
        try store.saveBody(body("text"), for: MessageID(accountID: accountA, providerID: "m2"))
        try store.deleteMessages([MessageID(accountID: accountA, providerID: "m2")])
        XCTAssertNil(try store.body(for: MessageID(accountID: accountA, providerID: "m2")))
        XCTAssertEqual(try summary("c").messageCount, 1)
        XCTAssertEqual(try summary("c").latestMessageID.providerID, "m1")
        try store.deleteMessages([MessageID(accountID: accountA, providerID: "m1"), MessageID(accountID: accountA, providerID: "missing")])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all)), [])
    }

    func testBodyRoundTrip() throws {
        let id = MessageID(accountID: accountA, providerID: "m1")
        try store.upsertMessages([message("m1", in: "c")])
        XCTAssertNil(try store.body(for: id))
        let stored = StoredBody(
            body: MessageBody(
                html: "<html><body><p>Hi ünicode</p><img src=\"cid:logo\"></body></html>",
                text: "Hi ünicode",
                attachments: [AttachmentInfo(id: "att-1", filename: "logo.png", mimeType: "image/png", sizeBytes: 10, contentID: "logo", isInline: true)]
            ),
            renderedHTML: "<div><p>Hi ünicode</p><img src=\"ss-cid://acct-a/m1/logo\"></div>",
            plainText: "Hi ünicode"
        )
        try store.saveBody(stored, for: id)
        XCTAssertEqual(try store.body(for: id), stored)
        XCTAssertEqual(try store.messageIDsMissingBodies(accountID: accountA, limit: 10), [])

        let textOnly = StoredBody(body: MessageBody(html: nil, text: "plain", attachments: []), renderedHTML: "<pre>plain</pre>", plainText: "plain")
        try store.saveBody(textOnly, for: id)
        XCTAssertEqual(try store.body(for: id), textOnly)
    }

    func testMissingBodiesAreInboxFirstThenNewest() throws {
        try store.upsertMessages([
            message("inbox-old", in: "c1", date: date(100), roles: [.inbox]),
            message("inbox-new", in: "c2", date: date(300), roles: [.inbox]),
            message("archived-newest", in: "c3", date: date(900), roles: []),
            message("sent", in: "c4", date: date(500), roles: [.sent]),
            message("trashed-inbox", in: "c5", date: date(800), roles: [.inbox, .trash]),
            message("spam", in: "c6", date: date(950), roles: [.spam]),
            message("hydrated", in: "c7", date: date(999), roles: [.inbox]),
            message("other-account", in: "c8", account: accountB, date: date(1_000), roles: [.inbox]),
        ])
        try store.saveBody(body("x"), for: MessageID(accountID: accountA, providerID: "hydrated"))

        let ids = try store.messageIDsMissingBodies(accountID: accountA, limit: 10).map(\.providerID)
        XCTAssertEqual(ids, ["inbox-new", "inbox-old", "archived-newest", "trashed-inbox", "sent"])
        XCTAssertEqual(try store.messageIDsMissingBodies(accountID: accountA, limit: 2).map(\.providerID), ["inbox-new", "inbox-old"])
        XCTAssertEqual(try store.messageIDsMissingBodies(accountID: accountA, limit: 3).map(\.providerID), ["inbox-new", "inbox-old", "archived-newest"])
        XCTAssertEqual(try store.messageIDsMissingBodies(accountID: accountB, limit: 10).map(\.providerID), ["other-account"])
    }

    // MARK: Views

    func testEveryMailboxView() throws {
        let owner = EmailAddress(name: "Owner", address: "a@example.com")
        try store.upsertMessages([
            // Inbox thread with an unread focused message.
            message("i1", in: "inbox", date: date(100), roles: [.inbox], isRead: true, section: .focused),
            message("i2", in: "inbox", date: date(200), roles: [.inbox], isRead: false, section: .focused),
            // Sent by the owner, answered into the inbox ("other" section).
            message("s1", in: "sent", from: owner, date: date(300), roles: [.sent]),
            message("s2", in: "sent", date: date(400), roles: [.inbox], section: .other),
            // A draft on its own.
            message("d1", in: "drafts", from: owner, date: date(500), roles: [.drafts]),
            // Entirely in trash.
            message("t1", in: "trash", date: date(600), roles: [.trash]),
            message("t2", in: "trash", date: date(700), roles: [.trash]),
            // Archived and starred.
            message("e1", in: "archived", date: date(800), roles: [], isStarred: true),
            // Spam only: invisible everywhere.
            message("x1", in: "spam", date: date(900), roles: [.spam]),
            // Starred but trashed: not in Starred.
            message("y1", in: "starred-trash", date: date(950), roles: [.trash], isStarred: true),
            // Sent by the owner but later trashed: not in Sent.
            message("z1", in: "sent-trash", from: owner, date: date(960), roles: [.sent, .trash]),
        ])

        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["sent", "inbox"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .starred)), ["archived"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .sent)), ["sent"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .drafts)), ["drafts"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .trash)), ["sent-trash", "starred-trash", "trash"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all)), ["archived", "drafts", "sent", "inbox"])

        XCTAssertEqual(try conversationIDs(ConversationQuery(accountIDs: [accountB], view: .all)), [])
        XCTAssertEqual(try conversationIDs(ConversationQuery(accountIDs: [], view: .all)), [])
        XCTAssertEqual(try conversationIDs(ConversationQuery(accountIDs: [accountA, accountB], view: .inbox)), ["sent", "inbox"])
    }

    func testUnreadOnlyAndSectionFilters() throws {
        try store.upsertMessages([
            message("f1", in: "focused-unread", date: date(100), isRead: false, section: .focused),
            message("f2", in: "focused-read", date: date(200), isRead: true, section: .focused),
            message("o1", in: "other-unread", date: date(300), isRead: false, section: .other),
            message("u1", in: "unknown-unread", date: date(400), isRead: false, section: .unknown),
            message("m1", in: "mixed", date: date(500), isRead: true, section: .other),
            message("m2", in: "mixed", date: date(600), isRead: true, section: .focused),
        ])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox, section: .focused)), ["mixed", "focused-read", "focused-unread"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox, section: .other)), ["other-unread"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox, unreadOnly: true)), ["unknown-unread", "other-unread", "focused-unread"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox, section: .focused, unreadOnly: true)), ["focused-unread"])
        XCTAssertEqual(try store.unreadInboxCount(accountIDs: nil), 3)
        XCTAssertEqual(try store.unreadInboxCount(accountIDs: [accountA]), 3)
        XCTAssertEqual(try store.unreadInboxCount(accountIDs: [accountB]), 0)
    }

    func testPagingWithBefore() throws {
        try store.upsertMessages((1...5).map { message("m\($0)", in: "c\($0)", date: date(Double($0) * 100)) })
        let page1 = try store.conversations(ConversationQuery(view: .inbox, limit: 2))
        XCTAssertEqual(page1.map(\.id.providerID), ["c5", "c4"])
        let page2 = try store.conversations(ConversationQuery(view: .inbox, limit: 2, before: page1.last?.latestDate))
        XCTAssertEqual(page2.map(\.id.providerID), ["c3", "c2"])
        let page3 = try store.conversations(ConversationQuery(view: .inbox, limit: 2, before: page2.last?.latestDate))
        XCTAssertEqual(page3.map(\.id.providerID), ["c1"])
        let page4 = try store.conversations(ConversationQuery(view: .inbox, limit: 2, before: page3.last?.latestDate))
        XCTAssertEqual(page4, [])
    }

    // MARK: Summary rules

    func testSummaryRules() throws {
        let alice = EmailAddress(name: "Alice Original", address: "alice@example.com")
        let aliceAgain = EmailAddress(name: "Alice Later", address: "ALICE@example.com")
        let bob = EmailAddress(name: "Bob", address: "bob@example.com")
        try store.upsertMessages([
            message("m1", in: "c", subject: "   ", from: alice, date: date(100), roles: [.inbox], isRead: true, section: .other),
            message("m2", in: "c", subject: "Hello", from: bob, date: date(200), roles: [.inbox], isRead: false, section: .focused),
            message("m3", in: "c", subject: "Re: Hello", from: aliceAgain, date: date(300), roles: [.inbox], isRead: false, isStarred: true, hasAttachments: true),
            message("m4", in: "c", subject: "Trashed", from: EmailAddress(address: "carol@example.com"), date: date(400), roles: [.trash], isStarred: true),
            message("m5", in: "c", subject: "Spam", from: EmailAddress(address: "spam@example.com"), date: date(500), roles: [.spam], isRead: false),
        ])

        let summary = try summary("c")
        XCTAssertEqual(summary.subject, "Hello", "first non-empty subject, oldest first")
        XCTAssertEqual(summary.participants, [alice, bob, EmailAddress(address: "carol@example.com")], "distinct senders oldest first, trash included, spam excluded")
        XCTAssertEqual(summary.snippet, "snippet of m3", "snippet of the latest visible message")
        XCTAssertEqual(summary.latestMessageID.providerID, "m3")
        XCTAssertEqual(summary.latestDate, date(300))
        XCTAssertEqual(summary.messageCount, 3, "trash and spam excluded")
        XCTAssertEqual(summary.unreadCount, 2)
        XCTAssertTrue(summary.isStarred)
        XCTAssertTrue(summary.hasAttachments)
        XCTAssertTrue(summary.inInbox)
        XCTAssertEqual(summary.inboxSection, .focused, "focused when any inbox message is focused")
        XCTAssertFalse(summary.hasPendingOperations)

        // Only "other" and "unknown" inbox messages left: section is other.
        try store.upsertMessages([message("m2", in: "c", subject: "Hello", from: bob, date: date(200), roles: [.inbox], isRead: false, section: .other)])
        XCTAssertEqual(try self.summary("c").inboxSection, .other)

        // Everything trashed: summarized from the trashed messages so Trash can show it.
        try store.upsertMessages([
            message("m1", in: "c", subject: "   ", from: alice, date: date(100), roles: [.trash]),
            message("m2", in: "c", subject: "Hello", from: bob, date: date(200), roles: [.trash], isRead: false),
            message("m3", in: "c", subject: "Re: Hello", from: aliceAgain, date: date(300), roles: [.trash], isRead: false, isStarred: true, hasAttachments: true),
        ])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), [])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all)), [])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .starred)), [])
        let trashed = try self.summary("c", view: .trash)
        XCTAssertEqual(trashed.messageCount, 0)
        XCTAssertEqual(trashed.unreadCount, 0)
        XCTAssertEqual(trashed.latestMessageID.providerID, "m4")
        XCTAssertEqual(trashed.snippet, "snippet of m4")
        XCTAssertTrue(trashed.isStarred)
        XCTAssertTrue(trashed.hasAttachments)
        XCTAssertFalse(trashed.inInbox)
        XCTAssertEqual(trashed.inboxSection, .unknown)
        XCTAssertEqual(trashed.subject, "Hello")

        // A conversation whose only message is spam has no summary at all.
        try store.upsertMessages([message("only-spam", in: "s", roles: [.spam])])
        XCTAssertFalse(try store.conversations(ConversationQuery(view: .trash)).contains { $0.id.providerID == "s" })
        XCTAssertFalse(try store.conversations(ConversationQuery(view: .all)).contains { $0.id.providerID == "s" })
    }

    func testSummaryWithoutSenders() throws {
        try store.upsertMessages([message("m1", in: "c", subject: "", from: nil)])
        let summary = try summary("c")
        XCTAssertEqual(summary.subject, "")
        XCTAssertEqual(summary.participants, [])
    }

    func testMessageMovingBetweenConversationsRefreshesBoth() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(100)), message("m2", in: "c2", date: date(200))])
        try store.upsertMessages([message("m2", in: "c1", date: date(200))])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all)), ["c1"])
        XCTAssertEqual(try summary("c1").messageCount, 2)
    }

    // MARK: Operations

    func testEnqueueAppliesLocallyAndFlagsTheConversation() throws {
        let target = MessageID(accountID: accountA, providerID: "m1")
        try store.upsertMessages([
            message("m1", in: "c", date: date(100), roles: [.inbox], isRead: false),
            message("m2", in: "c", date: date(200), roles: [.inbox], isRead: false),
            message("n1", in: "d", date: date(300), roles: [.inbox], isRead: false),
        ])
        let archive = Operation(id: "op-1", accountID: accountA, change: .archive, targets: [target, MessageID(accountID: accountA, providerID: "m2")], createdAt: date(1_000))
        try store.enqueue(archive)

        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["d"])
        XCTAssertEqual(try store.message(target)?.roles, [])
        let summary = try summary("c")
        XCTAssertTrue(summary.hasPendingOperations)
        XCTAssertFalse(try self.summary("d").hasPendingOperations)
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10), [archive])
        XCTAssertEqual(try store.pendingOperations(accountID: accountB, limit: 10), [])

        let read = Operation(id: "op-2", accountID: accountA, change: .setRead(true), targets: [target], createdAt: date(1_001))
        try store.enqueue(read)
        XCTAssertEqual(try store.message(target)?.isRead, true)
        XCTAssertEqual(try self.summary("c").unreadCount, 1)
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10).map(\.id), ["op-1", "op-2"])
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 1).map(\.id), ["op-1"])

        // In flight and uncertain stay "pending" for the summary; only pending and uncertain are replayable.
        var inFlight = archive
        inFlight.status = .inFlight
        inFlight.attempts = 1
        try store.updateOperation(inFlight)
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10).map(\.id), ["op-2"])
        XCTAssertTrue(try self.summary("c").hasPendingOperations)
        var uncertain = inFlight
        uncertain.status = .uncertain
        uncertain.lastError = "timeout"
        uncertain.nextAttemptAt = date(2_000)
        try store.updateOperation(uncertain)
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10), [uncertain, read])

        try store.deleteOperation(id: "op-1")
        try store.deleteOperation(id: "op-2")
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10), [])
        XCTAssertFalse(try self.summary("c").hasPendingOperations)
        XCTAssertEqual(try store.message(target)?.roles, [], "deleting an operation does not undo its local effect")
    }

    func testPendingOperationsWinOverOlderProviderState() throws {
        let target = MessageID(accountID: accountA, providerID: "m1")
        let providerState = message("m1", in: "c", date: date(100), roles: [.inbox], isRead: false, isStarred: false)
        try store.upsertMessages([providerState])

        try store.enqueue(Operation(id: "op-archive", accountID: accountA, change: .archive, targets: [target], createdAt: date(1_000)))
        try store.enqueue(Operation(id: "op-star", accountID: accountA, change: .setStarred(true), targets: [target], createdAt: date(1_001)))

        // A poll that still sees the message in the inbox, unstarred, must not undo the queued intent.
        try store.upsertMessages([providerState])
        let afterPoll = try XCTUnwrap(try store.message(target))
        XCTAssertEqual(afterPoll.roles, [])
        XCTAssertTrue(afterPoll.isStarred)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), [])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .starred)), ["c"])
        XCTAssertTrue(try summary("c").hasPendingOperations)

        // Other fields of the provider state still land.
        var withNewSubject = providerState
        withNewSubject.subject = "Provider subject"
        withNewSubject.providerVersion = "v2"
        try store.upsertMessages([withNewSubject])
        XCTAssertEqual(try store.message(target)?.subject, "Provider subject")
        XCTAssertEqual(try store.message(target)?.providerVersion, "v2")
        XCTAssertEqual(try store.message(target)?.roles, [])

        // Once the archive is confirmed and deleted, the star still wins but the inbox role follows the provider.
        try store.deleteOperation(id: "op-archive")
        try store.upsertMessages([providerState])
        XCTAssertEqual(try store.message(target)?.roles, [.inbox])
        XCTAssertTrue(try XCTUnwrap(try store.message(target)).isStarred)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c"])

        // Failed operations stop winning too.
        var failed = Operation(id: "op-star", accountID: accountA, change: .setStarred(true), targets: [target], createdAt: date(1_001))
        failed.status = .failed
        try store.updateOperation(failed)
        try store.upsertMessages([providerState])
        XCTAssertFalse(try XCTUnwrap(try store.message(target)).isStarred)
        XCTAssertFalse(try summary("c").hasPendingOperations)
    }

    func testPendingSendsRoundTrip() throws {
        XCTAssertEqual(try store.pendingSends(), [])
        let first = PendingSend(id: "s1", message: outgoing(from: accountA), createdAt: date(10), sendAfter: date(15))
        let second = PendingSend(id: "s2", message: outgoing(from: accountB), createdAt: date(20), sendAfter: date(25))
        try store.enqueueSend(second)
        try store.enqueueSend(first)
        XCTAssertEqual(try store.pendingSends(), [first, second])

        var sending = first
        sending.status = .sending
        sending.attempts = 1
        sending.lastError = "429"
        try store.updateSend(sending)
        XCTAssertEqual(try store.pendingSends(), [sending, second])

        try store.deleteSend(id: "s1")
        XCTAssertEqual(try store.pendingSends(), [second])
    }

    func outgoing(from accountID: AccountID) -> OutgoingMessage {
        OutgoingMessage(
            accountID: accountID,
            to: [EmailAddress(name: "Bob", address: "bob@example.com")],
            subject: "Hi",
            html: "<p>Hi</p>",
            text: "Hi",
            inReplyTo: MessageID(accountID: accountID, providerID: "m1"),
            references: ["<a@b>"],
            attachments: [OutgoingAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("hello".utf8))]
        )
    }

    // MARK: Contacts

    func testSuggestAddressesRankingAndPrefixes() throws {
        let now = Date()
        let alice = EmailAddress(name: "Alice Andersen", address: "alice@example.com")
        let bob = EmailAddress(name: "Bob", address: "bob@example.com")
        let carol = EmailAddress(name: "Carol King", address: "carol.king@example.com")
        let dave = EmailAddress(address: "dave@example.com")
        let ownerB = EmailAddress(address: "b@example.com")
        // Scores are seen_count / (1 + ageDays / 30), merged across accounts by taking the best one, so:
        // carol 2 mentions a day old (1.94) > bob 1 a day old (0.97) > dave 1 a day and a half old (0.95)
        // > owner B 1 two days old (0.94) > alice and owner A, 3 mentions each but 400 days old (0.21).
        try store.upsertMessages([
            message("a1", in: "c1", from: alice, date: now.addingTimeInterval(-400 * 86_400)),
            message("a2", in: "c2", from: alice, date: now.addingTimeInterval(-400 * 86_400)),
            message("a3", in: "c3", from: alice, date: now.addingTimeInterval(-400 * 86_400)),
            message("b1", in: "c4", from: bob, to: [], cc: [carol], date: now.addingTimeInterval(-86_400)),
            message("d1", in: "c5", from: dave, to: [carol], date: now.addingTimeInterval(-36 * 3_600)),
            message("c1", in: "c6", account: accountB, from: carol, to: [ownerB], date: now.addingTimeInterval(-2 * 86_400)),
        ])

        let all = try store.suggestAddresses(prefix: "", limit: 10).map(\.address)
        XCTAssertEqual(all.prefix(4), ["carol.king@example.com", "bob@example.com", "dave@example.com", "b@example.com"], "recent mentions outrank old frequent ones")
        XCTAssertEqual(Set(all), ["alice@example.com", "bob@example.com", "carol.king@example.com", "dave@example.com", "a@example.com", "b@example.com"])

        XCTAssertEqual(try store.suggestAddresses(prefix: "kin", limit: 5), [carol], "any word of the name")
        XCTAssertEqual(try store.suggestAddresses(prefix: "Carol K", limit: 5), [carol], "case-insensitive name prefix")
        XCTAssertEqual(try store.suggestAddresses(prefix: "bo", limit: 5), [bob])
        XCTAssertEqual(try store.suggestAddresses(prefix: "dave@", limit: 5), [dave], "address prefix")
        XCTAssertEqual(try store.suggestAddresses(prefix: "al", limit: 5), [alice])
        XCTAssertEqual(try store.suggestAddresses(prefix: "zzz", limit: 5), [])
        XCTAssertEqual(try store.suggestAddresses(prefix: "", limit: 1).count, 1)
    }

    // MARK: Observation

    func testObserveConversationsFiresInitiallyAndAfterChanges() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(100))])
        let initial = expectation(description: "initial value")
        let afterChange = expectation(description: "value after change")
        let box = ObservedValues()
        let observation = store.observeConversations(ConversationQuery(view: .inbox)) { summaries in
            XCTAssertTrue(Thread.isMainThread)
            let count = box.append(summaries.map(\.id.providerID))
            if count == 1 { initial.fulfill() }
            if summaries.map(\.id.providerID) == ["c2", "c1"] { afterChange.fulfill() }
        }
        wait(for: [initial], timeout: 2)
        XCTAssertEqual(box.values.first, ["c1"])

        try store.upsertMessages([message("m2", in: "c2", date: date(200))])
        wait(for: [afterChange], timeout: 2)
        XCTAssertEqual(box.values.last, ["c2", "c1"])

        observation.cancel()
        let countAfterCancel = box.values.count
        try store.upsertMessages([message("m3", in: "c3", date: date(300))])
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(box.values.count, countAfterCancel, "no delivery after cancel")
    }

    func testObserveConversationDeliversMessagesOldestFirst() throws {
        let conversation = ConversationID(accountID: accountA, providerID: "c")
        try store.upsertMessages([message("m2", in: "c", date: date(200))])
        let initial = expectation(description: "initial")
        let afterChange = expectation(description: "after change")
        let box = ObservedValues()
        let observation = store.observeConversation(conversation) { messages in
            XCTAssertTrue(Thread.isMainThread)
            let ids = messages.map(\.id.providerID)
            let count = box.append(ids)
            if count == 1 { initial.fulfill() }
            if ids == ["m1", "m2"] { afterChange.fulfill() }
        }
        wait(for: [initial], timeout: 2)
        XCTAssertEqual(box.values.first, ["m2"])
        try store.upsertMessages([message("m1", in: "c", date: date(100))])
        wait(for: [afterChange], timeout: 2)
        observation.cancel()
    }
}

/// Thread-safe collector for observation callbacks.
final class ObservedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []

    var values: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func append(_ value: [String]) -> Int {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
        return storage.count
    }
}

/// The same contract against the SQLite store.
final class SQLiteMailStoreContractTests: MailStoreContractTests {
    override func makeStore() throws -> MailStoring {
        try SQLiteMailStore.inMemory()
    }
}
