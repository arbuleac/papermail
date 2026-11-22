import XCTest
import PaperCore

/// The backfill writes and marks (docs/DATA-MODEL.md, "Backfill marks"): a backfill page fetched before a live
/// change must not overwrite it or bring a deleted message back, and a reconciling backfill removes what the
/// provider no longer has without wiping the mailbox. An extension of `MailStoreContractTests`, so both stores
/// are held to it.
extension MailStoreContractTests {
    private func id(_ providerID: String, _ account: AccountID? = nil) -> MessageID {
        MessageID(accountID: account ?? accountA, providerID: providerID)
    }

    private func search(_ text: String) throws -> [String] {
        try conversationIDs(ConversationQuery(view: .all, searchText: text))
    }

    // MARK: Skippable ids

    func testBackfillSkippableIDsAreLiveMarksPlusStoredWhenAsked() throws {
        try store.upsertMessages([
            message("s1", in: "c1", date: date(100)),
            message("s2", in: "c2", date: date(200)),
            message("bx", in: "cb", account: accountB, from: bea),
        ])
        try store.markLiveChanges(accountID: accountA, upserted: ["live"], deleted: ["gone"])
        try store.markLiveChanges(accountID: accountB, upserted: ["b-live"], deleted: [])
        let asked = ["s1", "s2", "live", "gone", "new", "bx", "b-live", "s1"]

        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountA, providerIDs: asked, includeStored: false),
                       ["live", "gone"], "a mark counts whether the live lane wrote or deleted the message")
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountA, providerIDs: asked, includeStored: true),
                       ["s1", "s2", "live", "gone"], "another account's messages and marks are not this account's")
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountB, providerIDs: asked, includeStored: true), ["bx", "b-live"])
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountA, providerIDs: [], includeStored: true), [])
    }

    func testBackfillSkippableIDsAcrossManyChunks() throws {
        // More ids than one IN list holds, with hits on both sides of every chunk boundary.
        let ids = (0..<1_203).map { String(format: "id-%04d", $0) }
        let stored = [0, 499, 500, 501, 999, 1_000, 1_202]
        let marked = [1, 498, 502, 1_001, 1_201]
        try store.upsertMessages(stored.map { message(ids[$0], in: "c\($0)", date: date(TimeInterval($0))) })
        try store.markLiveChanges(accountID: accountA, upserted: marked.map { ids[$0] }, deleted: [])

        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountA, providerIDs: ids, includeStored: false),
                       Set(marked.map { ids[$0] }))
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountA, providerIDs: ids, includeStored: true),
                       Set((stored + marked).map { ids[$0] }))
    }

    // MARK: A folder gone

    private func filed(_ providerID: String, in folder: String?, account: AccountID? = nil) -> MessageMetadata {
        var filed = message(providerID, in: "c-\(providerID)", account: account)
        filed.folderID = folder
        return filed
    }

    /// What a gone folder held is queued for the live lane to look up: this account's messages in that folder only,
    /// handed out a few at a time in id order, each keeping its tries until it is settled.
    func testAGoneFolderQueuesItsStoredMessagesForLookup() throws {
        try store.upsertMessages([
            filed("g2", in: "F-GONE"), filed("g1", in: "F-GONE"), filed("g3", in: "F-OLD"), filed("kept", in: "F-INBOX"),
            filed("none", in: nil), filed("b1", in: "F-GONE", account: accountB),
        ])

        XCTAssertEqual(try store.queueLookups(accountID: accountA, inFolders: ["F-GONE", "F-OLD"]), 3)
        XCTAssertEqual(try store.queuedLookups(accountID: accountA, limit: 2), ["g1": 0, "g2": 0])
        XCTAssertEqual(try store.queuedLookups(accountID: accountB, limit: 10), [:], "another account's mail is not queued")

        try store.settleQueuedLookups(accountID: accountA, settled: ["g1"], retried: ["g2"])
        XCTAssertEqual(try store.queuedLookups(accountID: accountA, limit: 10), ["g2": 1, "g3": 0])
        XCTAssertEqual(try store.queueLookups(accountID: accountA, inFolders: ["F-OLD"]), 0, "one already queued keeps its tries")
        XCTAssertEqual(try store.queuedLookups(accountID: accountA, limit: 10), ["g2": 1, "g3": 0])

        try store.wipeMailData(for: accountA)
        XCTAssertEqual(try store.queuedLookups(accountID: accountA, limit: 10), [:], "a wipe drops the lookups of the mail it drops")
    }

    /// A reconcile keeps the mail its enumeration leaves out only where the store already shows it there, so it reads
    /// the stored roles of a page of ids: this account's stored messages only.
    func testStoredRolesOfSomeMessages() throws {
        try store.upsertMessages([
            message("t1", in: "c1", roles: [.trash]),
            message("i1", in: "c2", roles: [.inbox]),
            message("b1", in: "c3", account: accountB, from: bea, roles: [.spam]),
        ])

        XCTAssertEqual(try store.storedRoles(accountID: accountA, providerIDs: ["t1", "i1", "b1", "nowhere", "t1"]),
                       ["t1": [.trash], "i1": [.inbox]])
        XCTAssertEqual(try store.storedRoles(accountID: accountA, providerIDs: []), [:])
    }

    // MARK: Writing a backfill page

    func testBackfillWriteAddsOnlyMissingUnmarkedMessages() throws {
        try store.upsertMessages([
            message("s1", in: "c1", subject: "Stored subject", date: date(100), isRead: false),
            // What the live lane wrote after the backfill fetched its page: read, and out of the inbox.
            message("live", in: "c3", subject: "Live subject", date: date(300), roles: [], isRead: true),
        ])
        try store.markLiveChanges(accountID: accountA, upserted: ["live"], deleted: [])

        let page = [
            message("s1", in: "c1", subject: "Stale subject", date: date(100), isRead: true),
            message("live", in: "c3", subject: "Stale subject", date: date(300), roles: [.inbox], isRead: false),
            message("n1", in: "c2", subject: "First draft", date: date(200)),
            message("n1", in: "c2", subject: "Backfilled zebra", date: date(200), isRead: false),
            message("n2", in: "c1", subject: "Reply", date: date(150), isRead: false),
        ]
        XCTAssertEqual(try store.writeBackfillMessages(page, refreshExisting: false), 2,
                       "two new messages, a repeated id counted once")

        XCTAssertEqual(try store.message(id("s1"))?.subject, "Stored subject", "a stored message is never replaced")
        XCTAssertEqual(try store.message(id("s1"))?.isRead, false)
        let live = try XCTUnwrap(try store.message(id("live")))
        XCTAssertEqual(live.subject, "Live subject", "what the live lane wrote stands")
        XCTAssertEqual(live.roles, [])
        XCTAssertTrue(live.isRead)
        XCTAssertEqual(try store.message(id("n1"))?.subject, "Backfilled zebra", "the last copy of a repeated id is written")

        // The new messages are searchable and summarized like any other write.
        XCTAssertEqual(try search("zebra"), ["c2"])
        XCTAssertEqual(try search("stale"), [])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c2", "c1"])
        let c1 = try summary("c1")
        XCTAssertEqual(c1.messageCount, 2)
        XCTAssertEqual(c1.unreadCount, 2)
        XCTAssertEqual(c1.latestMessageID, id("n2"))
        XCTAssertEqual(c1.subject, "Stored subject")
        XCTAssertEqual(try summary("c2").unreadCount, 1)

        XCTAssertEqual(try store.writeBackfillMessages(page, refreshExisting: false), 0, "a page written twice adds nothing")
        XCTAssertEqual(try store.writeBackfillMessages([], refreshExisting: true), 0)
    }

    func testRefreshingBackfillUpdatesStoredMessagesButNotMarkedOnes() throws {
        try store.upsertMessages([
            message("s1", in: "c1", subject: "Quarterly plan", date: date(100), isRead: false),
            message("live", in: "c2", subject: "Live subject", date: date(200), isRead: true, isStarred: true),
        ])
        try store.saveBody(body("budget numbers"), for: id("s1"))
        try store.markLiveChanges(accountID: accountA, upserted: ["live"], deleted: [])

        let written = try store.writeBackfillMessages([
            message("s1", in: "c1", subject: "Revised plan", date: date(100), isRead: true, isStarred: true),
            message("live", in: "c2", subject: "Stale subject", date: date(200), isRead: false),
            message("n1", in: "c3", subject: "New thread", date: date(300)),
        ], refreshExisting: true)

        XCTAssertEqual(written, 2)
        let refreshed = try XCTUnwrap(try store.message(id("s1")))
        XCTAssertEqual(refreshed.subject, "Revised plan")
        XCTAssertTrue(refreshed.isRead)
        XCTAssertTrue(refreshed.isStarred)
        XCTAssertEqual(try store.body(for: id("s1"))?.plainText, "budget numbers", "a refresh keeps the stored body")
        XCTAssertEqual(try store.message(id("live"))?.subject, "Live subject", "a refresh still leaves marked messages alone")
        XCTAssertEqual(try store.message(id("live"))?.isRead, true)
        XCTAssertNotNil(try store.message(id("n1")))

        XCTAssertEqual(try search("quarterly"), [])
        XCTAssertEqual(try search("revised"), ["c1"])
        XCTAssertEqual(try search("budget"), ["c1"], "the body stays in the index")
        let c1 = try summary("c1")
        XCTAssertEqual(c1.subject, "Revised plan")
        XCTAssertEqual(c1.unreadCount, 0)
        XCTAssertTrue(c1.isStarred)
    }

    func testPendingOperationsWinOverARefreshedBackfillRow() throws {
        let original = message("m1", in: "c", date: date(100), roles: [.inbox], isRead: false)
        try store.upsertMessages([original])
        try store.enqueue(Operation(id: "op-archive", accountID: accountA, change: .archive, targets: [original.id], createdAt: date(1_000)))
        try store.enqueue(Operation(id: "op-read", accountID: accountA, change: .setRead(true), targets: [original.id], createdAt: date(1_001)))

        var stale = original
        stale.subject = "Provider subject"
        XCTAssertEqual(try store.writeBackfillMessages([stale], refreshExisting: true), 1)

        let stored = try XCTUnwrap(try store.message(original.id))
        XCTAssertEqual(stored.subject, "Provider subject", "the provider's other fields land")
        XCTAssertEqual(stored.roles, [], "the queued archive still wins")
        XCTAssertTrue(stored.isRead, "the queued read still wins")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), [])
        XCTAssertTrue(try summary("c").hasPendingOperations)

        // The refresh is what the archive now replaces, so giving it up puts the provider's report back.
        try store.updateOperation(Operation(id: "op-archive", accountID: accountA, change: .archive, targets: [original.id],
                                            createdAt: date(1_000), status: .failed))
        XCTAssertEqual(try store.message(original.id)?.roles, [.inbox])
        XCTAssertEqual(try store.message(original.id)?.isRead, true, "the newer queued read is replayed on top")
    }

    func testADeletedMarkKeepsABackfillFromResurrectingAMessage() throws {
        let doomed = message("m1", in: "c", subject: "Zebra notice", date: date(100))
        try store.upsertMessages([doomed])
        // The live lane applies a deletion the backfill's page predates.
        try store.deleteMessages([doomed.id])
        try store.markLiveChanges(accountID: accountA, upserted: [], deleted: ["m1"])

        XCTAssertEqual(try store.writeBackfillMessages([doomed], refreshExisting: false), 0)
        XCTAssertEqual(try store.writeBackfillMessages([doomed], refreshExisting: true), 0)
        XCTAssertNil(try store.message(doomed.id))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all)), [])
        XCTAssertEqual(try search("zebra"), [])

        // A later live write replaces the mark and still keeps the backfill off; so does a page that both
        // writes and deletes the message.
        try store.markLiveChanges(accountID: accountA, upserted: ["m1"], deleted: [])
        try store.markLiveChanges(accountID: accountA, upserted: ["m2"], deleted: ["m2"])
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountA, providerIDs: ["m1", "m2"], includeStored: false), ["m1", "m2"])
        XCTAssertEqual(try store.writeBackfillMessages([doomed, message("m2", in: "c2")], refreshExisting: false), 0)

        // The marks only hold while the backfill runs.
        XCTAssertEqual(try store.finishBackfill(accountID: accountA, sweepUnseen: false), 0)
        XCTAssertEqual(try store.writeBackfillMessages([doomed], refreshExisting: false), 1)
    }

    // MARK: Finishing

    func testFinishingAReconcileSweepsWhatItNeverSaw() throws {
        try store.upsertMessages([
            message("seen", in: "c1", date: date(100)),
            message("unseen-1", in: "c1", subject: "Zebra memo", date: date(110)),
            message("unseen-2", in: "c2", date: date(200)),
            message("live", in: "c3", date: date(300)),
            message("queued", in: "c4", date: date(400)),
            message("sending", in: "c5", date: date(500)),
            message("unsure", in: "c6", date: date(600)),
            message("given-up", in: "c7", date: date(700)),
            message("b1", in: "cb", account: accountB, from: bea),
        ])
        try store.saveBody(body("zebra body"), for: id("unseen-1"))
        try store.markBackfillSeen(accountID: accountA, providerIDs: ["seen", "not-stored"])
        try store.markBackfillSeen(accountID: accountA, providerIDs: ["seen"])
        try store.markLiveChanges(accountID: accountA, upserted: ["live"], deleted: [])
        // Live operations keep their targets; a failed one is no longer the user's pending intent.
        try store.enqueue(Operation(id: "op-queued", accountID: accountA, change: .setStarred(true), targets: [id("queued")], createdAt: date(1_000)))
        var sending = Operation(id: "op-sending", accountID: accountA, change: .setRead(false), targets: [id("sending")], createdAt: date(1_001))
        try store.enqueue(sending)
        sending.status = .inFlight
        try store.updateOperation(sending)
        var unsure = Operation(id: "op-unsure", accountID: accountA, change: .archive, targets: [id("unsure")], createdAt: date(1_002))
        try store.enqueue(unsure)
        unsure.status = .uncertain
        try store.updateOperation(unsure)
        var givenUp = Operation(id: "op-given-up", accountID: accountA, change: .setStarred(true), targets: [id("given-up")], createdAt: date(1_003))
        try store.enqueue(givenUp)
        givenUp.status = .failed
        try store.updateOperation(givenUp)

        XCTAssertEqual(try store.finishBackfill(accountID: accountA, sweepUnseen: true), 3)

        for gone in ["unseen-1", "unseen-2", "given-up"] {
            XCTAssertNil(try store.message(id(gone)), gone)
        }
        for kept in ["seen", "live", "queued", "sending", "unsure"] {
            XCTAssertNotNil(try store.message(id(kept)), kept)
        }
        XCTAssertNotNil(try store.message(id("b1", accountB)), "another account's mail is not swept")
        XCTAssertNil(try store.body(for: id("unseen-1")))
        XCTAssertEqual(try search("zebra"), [], "neither the subject nor the body of a swept message matches")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all, limit: 100)).sorted(), ["c1", "c3", "c4", "c5", "c6", "cb"])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .trash)), [])
        XCTAssertFalse(try conversationIDs(ConversationQuery(view: .inbox)).contains("c6"), "the uncertain archive still wins")
        let c1 = try summary("c1")
        XCTAssertEqual(c1.messageCount, 1)
        XCTAssertEqual(c1.latestMessageID, id("seen"))

        // The marks are gone: the next reconcile starts from nothing, so it keeps only what live operations target.
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountA, providerIDs: ["live", "seen"], includeStored: false), [])
        XCTAssertEqual(try store.finishBackfill(accountID: accountA, sweepUnseen: true), 2)
        XCTAssertEqual(Set(try conversationIDs(ConversationQuery(view: .all, limit: 100))), ["c4", "c5", "c6", "cb"])
    }

    func testFinishingWithoutASweepOnlyDropsTheMarks() throws {
        try store.upsertMessages([message("m1", in: "c1"), message("m2", in: "c2")])
        try store.markLiveChanges(accountID: accountA, upserted: ["m1"], deleted: ["x"])
        try store.markLiveChanges(accountID: accountB, upserted: ["b-live"], deleted: [])
        try store.markBackfillSeen(accountID: accountA, providerIDs: ["m1"])

        XCTAssertEqual(try store.finishBackfill(accountID: accountA, sweepUnseen: false), 0)
        XCTAssertNotNil(try store.message(id("m1")))
        XCTAssertNotNil(try store.message(id("m2")))
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountA, providerIDs: ["m1", "x"], includeStored: false), [])
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountB, providerIDs: ["b-live"], includeStored: false), ["b-live"],
                       "another account's backfill keeps its marks")
        // The seen mark went too, so a reconcile that now finishes saw nothing.
        XCTAssertEqual(try store.finishBackfill(accountID: accountA, sweepUnseen: true), 2)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all)), [])
    }

    func testEmptyMarkCallsChangeNothing() throws {
        try store.upsertMessages([message("m1", in: "c1")])
        try store.markLiveChanges(accountID: accountA, upserted: [], deleted: [])
        try store.markBackfillSeen(accountID: accountA, providerIDs: [])
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountA, providerIDs: ["m1"], includeStored: false), [])
        XCTAssertEqual(try store.finishBackfill(accountID: accountA, sweepUnseen: false), 0)
        XCTAssertNotNil(try store.message(id("m1")))
    }

    // MARK: Wipe, delete, observation

    func testWipeAndAccountDeleteDropBackfillMarks() throws {
        try store.markLiveChanges(accountID: accountA, upserted: ["a-live"], deleted: ["a-gone"])
        try store.markBackfillSeen(accountID: accountA, providerIDs: ["m1"])
        try store.markLiveChanges(accountID: accountB, upserted: ["b-live"], deleted: [])

        try store.wipeMailData(for: accountA)
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountA, providerIDs: ["a-live", "a-gone"], includeStored: false), [])
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountB, providerIDs: ["b-live"], includeStored: false), ["b-live"])
        // The seen mark went with the wipe: a reconcile of the re-downloaded mail that never lists m1 sweeps it.
        try store.upsertMessages([message("m1", in: "c1")])
        XCTAssertEqual(try store.finishBackfill(accountID: accountA, sweepUnseen: true), 1)

        try store.deleteAccount(accountB)
        try store.upsertAccount(account(accountB, email: "b@example.com", addedAt: base.addingTimeInterval(60)))
        XCTAssertEqual(try store.backfillSkippableIDs(accountID: accountB, providerIDs: ["b-live"], includeStored: false), [])
    }

    func testBackfillMarksDoNotWakeObservers() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(100))])
        let initial = expectation(description: "initial value")
        let box = ObservedValues()
        let observation = store.observeConversations(ConversationQuery(view: .inbox)) { summaries in
            if box.append(summaries.map(\.id.providerID)) == 1 { initial.fulfill() }
        }
        wait(for: [initial], timeout: 2)

        try store.markLiveChanges(accountID: accountA, upserted: ["m1", "m9"], deleted: ["m8"])
        try store.markBackfillSeen(accountID: accountA, providerIDs: ["m1"])
        XCTAssertEqual(try store.writeBackfillMessages([message("m1", in: "c1", date: date(100))], refreshExisting: true), 0)
        XCTAssertEqual(try store.finishBackfill(accountID: accountA, sweepUnseen: false), 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(box.values, [["c1"]], "nothing the list shows changed")
        observation.cancel()
    }
}
