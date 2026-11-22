import XCTest
import SSCore

/// The `MailStoring` contract for Keep mail on this Mac (roadmap Q1.6, docs/DATA-MODEL.md `bodies.evicted`): a body
/// outside the window loses its source and rendered HTML and keeps everything the list and search read. Written as an
/// extension so `SQLiteMailStoreContractTests` inherits every case and both stores are held to the same semantics.
extension MailStoreContractTests {
    private var day: TimeInterval { 86_400 }

    /// Received a year and a half before `base`, well outside a three-month window whose cutoff is `cutoff`.
    private var old: Date { date(-540 * day) }
    private var cutoff: Date { date(-90 * day) }

    private func id(_ providerID: String, account: AccountID? = nil) -> MessageID {
        MessageID(accountID: account ?? accountA, providerID: providerID)
    }

    func testEvictionDropsTheSourceAndKeepsTheListAndSearch() throws {
        try store.upsertMessages([
            message("old", in: "c-old", subject: "Quarterly figures", snippet: "The figures you asked for", date: old),
            message("new", in: "c-new", subject: "Lunch", date: date(0)),
        ])
        try store.saveBody(body("zanzibar spreadsheet attached"), for: id("old"))
        try store.saveBody(body("see you at noon"), for: id("new"))
        let summaryBefore = try summary("c-old")

        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 100), 1)

        XCTAssertNil(try store.body(for: id("old")), "an evicted body reads as one to fetch")
        XCTAssertEqual(try store.body(for: id("new"))?.plainText, "see you at noon", "a body inside the window stays")
        XCTAssertEqual(try summary("c-old"), summaryBefore, "the row, its subject and snippet are unchanged")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all, searchText: "zanzibar")), ["c-old"],
                       "the body's text is still searched")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all, searchText: "quarterly")), ["c-old"])
        XCTAssertEqual(try store.messageIDsMissingBodies(accountID: accountA, limit: 10), [],
                       "neither lane is offered an evicted body to fetch back")
        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 100), 0, "nothing is evicted twice")
    }

    /// Bodies saved before v3 have no design facts and wait for the engine to work them out from the source; an evicted
    /// one has no source left, so it leaves that queue and gets its facts when it is fetched again.
    func testAnEvictedBodyLeavesTheDesignFactsQueue() throws {
        try store.upsertMessages([message("old", in: "c1", date: old), message("new", in: "c2", date: date(0))])
        try store.saveBody(body("old text"), for: id("old"))
        try store.saveBody(body("new text"), for: id("new"))
        XCTAssertEqual(Set(try store.messageIDsMissingDesignFacts(accountID: accountA, limit: 10)), [id("old"), id("new")])

        try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 100)
        XCTAssertEqual(try store.messageIDsMissingDesignFacts(accountID: accountA, limit: 10), [id("new")])
    }

    func testEvictionLeavesDraftsLiveOperationsAndExcludedMessagesAlone() throws {
        try store.upsertMessages([
            message("plain", in: "c1", date: old),
            message("draft", in: "c2", date: old, roles: [.drafts]),
            message("queued", in: "c3", date: old),
            message("kept", in: "c4", date: old),
            message("settled", in: "c5", date: old),
            message("gave-up", in: "c6", date: old),
        ])
        for providerID in ["plain", "draft", "queued", "kept", "settled", "gave-up"] {
            try store.saveBody(body("text of \(providerID)"), for: id(providerID))
        }
        try store.enqueue(Operation(id: "op-live", accountID: accountA, change: .setRead(true), targets: [id("queued")], createdAt: date(1)))
        try store.enqueue(Operation(id: "op-done", accountID: accountA, change: .setStarred(true), targets: [id("settled")], createdAt: date(2)))
        try store.confirmOperation(id: "op-done")
        var failed = Operation(id: "op-failed", accountID: accountA, change: .setStarred(true), targets: [id("gave-up")], createdAt: date(3))
        try store.enqueue(failed)
        failed.status = .failed
        try store.updateOperation(failed)
        let send = PendingSend(id: "send-1", message: OutgoingMessage(accountID: accountA, to: [bea], subject: "Old thread",
                                                                     html: "<p>Reply</p>", text: "Reply"),
                               createdAt: old, sendAfter: date(10))
        try store.enqueueSend(send)

        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [id("kept")], limit: 100), 3)

        XCTAssertNil(try store.body(for: id("plain")))
        XCTAssertNil(try store.body(for: id("settled")), "a confirmed operation no longer holds its target")
        XCTAssertNil(try store.body(for: id("gave-up")), "nor does a failed one, which is never replayed")
        XCTAssertNotNil(try store.body(for: id("draft")), "drafts are never evicted")
        XCTAssertNotNil(try store.body(for: id("queued")), "a message a pending operation targets is left as it is")
        XCTAssertNotNil(try store.body(for: id("kept")), "the caller's exclusions are left as they are")
        XCTAssertEqual(try store.pendingSends().map(\.id), ["send-1"], "the outbox is not the store's bodies")
        XCTAssertEqual(try store.pendingSends().first?.message.html, "<p>Reply</p>")
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10).map(\.id), ["op-live"])
    }

    /// One call evicts at most `limit` bodies, the oldest first, so a sweep is many short transactions.
    func testEvictionTakesAtMostTheLimitOldestFirst() throws {
        let messages = (0..<5).map { message("m\($0)", in: "c\($0)", date: date(Double(-600 + $0) * day)) }
        try store.upsertMessages(messages.shuffled())
        for message in messages { try store.saveBody(body("body of \(message.id.providerID)"), for: message.id) }

        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 2), 2)
        XCTAssertNil(try store.body(for: id("m0")))
        XCTAssertNil(try store.body(for: id("m1")))
        XCTAssertNotNil(try store.body(for: id("m2")), "the newest wait for the next batch")
        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 2), 2)
        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 2), 1)
        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 2), 0)
        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 0), 0)
    }

    /// A sweep walks the mailbox once: each batch starts where the last one stopped (`next`), never again from the
    /// oldest message, so a body behind it (here one fetched again meanwhile) waits for the next sweep. Messages sharing
    /// the boundary's date are looked at again, so none is skipped, and `next` is nil once nothing is left to look at.
    func testABatchStartsWhereThePreviousOneStopped() throws {
        var messages = (0..<5).map { message("m\($0)", in: "c\($0)", date: date(Double(-600 + $0) * day)) }
        // Received in the same second as m1.
        messages.append(message("m1-twin", in: "c-twin", date: messages[1].date))
        try store.upsertMessages(messages.shuffled())
        for message in messages { try store.saveBody(body("body of \(message.id.providerID)"), for: message.id) }
        let rules = { () -> (cutoff: Date, excluding: Set<MessageID>)? in (self.cutoff, []) }

        let first = try store.evictBodies(from: nil, limit: 2, rules: rules)
        XCTAssertEqual(first.evicted, 2)
        XCTAssertEqual(first.next, messages[1].date, "the next batch starts at the last date this one reached")
        XCTAssertNil(try store.body(for: id("m0")))
        try store.saveBody(body("m0 fetched again"), for: id("m0"))

        let second = try store.evictBodies(from: first.next, limit: 2, rules: rules)
        XCTAssertEqual(second.evicted, 2)
        XCTAssertNotNil(try store.body(for: id("m0")), "behind the batch's start: left for the next sweep")
        XCTAssertTrue(try ["m1", "m1-twin", "m2"].allSatisfy { try store.body(for: id($0)) == nil }, "the twin is not skipped")
        let third = try store.evictBodies(from: second.next, limit: 2, rules: rules)
        XCTAssertEqual(third.evicted, 2)
        let last = try store.evictBodies(from: third.next, limit: 2, rules: rules)
        XCTAssertEqual(last.evicted, 0)
        XCTAssertNil(last.next, "nothing left to look at")
        XCTAssertEqual(try store.evictBodies(from: nil, limit: 2, rules: rules).evicted, 1, "the next sweep starts from the oldest")
    }

    /// Excluded messages are read past, however many of them there are, and never end a sweep before the cutoff.
    func testExcludedMessagesNeverEndASweepEarly() throws {
        let messages = (0..<7).map { message("m\($0)", in: "c\($0)", date: date(Double(-600 + $0) * day)) }
        try store.upsertMessages(messages)
        for message in messages { try store.saveBody(body("body \(message.id.providerID)"), for: message.id) }
        let excluded: Set<MessageID> = [id("m0"), id("m3")]
        var start: Date?
        var evicted = 0
        var batches = 0
        repeat {
            let batch = try store.evictBodies(from: start, limit: 4) { (self.cutoff, excluded) }
            evicted += batch.evicted
            start = batch.next
            batches += 1
        } while start != nil && batches < 10
        XCTAssertEqual(evicted, 5, "every message but the excluded two")
        XCTAssertTrue(try ["m1", "m2", "m4", "m5", "m6"].allSatisfy { try store.body(for: id($0)) == nil })
        XCTAssertNotNil(try store.body(for: id("m0")))
        XCTAssertNotNil(try store.body(for: id("m3")))
    }

    /// Rules that answer nil (the window became Everything) evict nothing.
    func testNoRulesEvictNothing() throws {
        try store.upsertMessages([message("old", in: "c1", date: old)])
        try store.saveBody(body("old text"), for: id("old"))
        let batch = try store.evictBodies(from: nil, limit: 10) { nil }
        XCTAssertEqual(batch.evicted, 0)
        XCTAssertNil(batch.next)
        XCTAssertNotNil(try store.body(for: id("old")))
    }

    /// An eviction keeps the attachment list, which the reader's chips, Quick Look and scheme handlers read apart from
    /// the body: a page renders from the body it read, so one evicted in that instant still finds its files.
    func testAnEvictedBodyKeepsItsAttachmentList() throws {
        let file = AttachmentInfo(id: "a1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 2_048, isInline: false)
        try store.upsertMessages([message("old", in: "c1", date: old)])
        var stored = body("plan attached")
        stored.body.attachments = [file]
        try store.saveBody(stored, for: id("old"))
        XCTAssertEqual(try store.attachments(of: id("old")), [file])

        try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 10)
        XCTAssertNil(try store.body(for: id("old")))
        XCTAssertEqual(try store.attachments(of: id("old")), [file], "the list outlives the source")
        XCTAssertNil(try store.attachments(of: id("unknown")), "no body, no list")
    }

    /// An exclusion takes no place in the batch: the batch still evicts `limit` bodies.
    func testExcludedBodiesDoNotShortenABatch() throws {
        let messages = (0..<4).map { message("m\($0)", in: "c\($0)", date: date(Double(-600 + $0) * day)) }
        try store.upsertMessages(messages)
        for message in messages { try store.saveBody(body("body \(message.id.providerID)"), for: message.id) }
        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [id("m0"), id("m1")], limit: 2), 2)
        XCTAssertNotNil(try store.body(for: id("m0")))
        XCTAssertNotNil(try store.body(for: id("m1")))
        XCTAssertNil(try store.body(for: id("m2")))
        XCTAssertNil(try store.body(for: id("m3")))
    }

    /// A body fetched again (the user opened the message) is whole and no longer marked; it is evicted again only by a
    /// sweep that does not exclude it.
    func testSavingAnEvictedBodyMakesItWholeAgain() throws {
        try store.upsertMessages([message("old", in: "c1", date: old)])
        try store.saveBody(body("first copy"), for: id("old"))
        try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 10)
        XCTAssertNil(try store.body(for: id("old")))

        try store.saveBody(body("fetched again"), for: id("old"))
        XCTAssertEqual(try store.body(for: id("old")), body("fetched again"))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all, searchText: "fetched")), ["c1"])
        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [id("old")], limit: 10), 0)
        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 10), 1)
    }

    /// The backfill's save: a body outside the window is stored already evicted, under the same rules as a sweep, so the
    /// store never holds it whole; one inside the window, a draft's, or one a live operation targets is stored whole.
    func testABodySavedOutsideTheWindowIsStoredAlreadyEvicted() throws {
        try store.upsertMessages([
            message("old", in: "c1", subject: "Harbour plans", date: old),
            message("new", in: "c2", date: date(0)),
            message("draft", in: "c3", date: old, roles: [.drafts]),
            message("queued", in: "c4", date: old),
        ])
        try store.enqueue(Operation(id: "op-live", accountID: accountA, change: .setRead(true), targets: [id("queued")], createdAt: date(1)))
        let summaryBefore = try summary("c1")

        XCTAssertTrue(try store.saveBody(body("lighthouse drawings"), for: id("old"), evictingIfReceivedBefore: cutoff))
        XCTAssertFalse(try store.saveBody(body("noon"), for: id("new"), evictingIfReceivedBefore: cutoff))
        XCTAssertFalse(try store.saveBody(body("draft text"), for: id("draft"), evictingIfReceivedBefore: cutoff))
        XCTAssertFalse(try store.saveBody(body("queued text"), for: id("queued"), evictingIfReceivedBefore: cutoff))

        XCTAssertNil(try store.body(for: id("old")), "stored evicted: opening it fetches it")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all, searchText: "lighthouse")), ["c1"], "its text is searched")
        XCTAssertEqual(try summary("c1"), summaryBefore)
        XCTAssertEqual(try store.messageIDsMissingBodies(accountID: accountA, limit: 10), [], "and no lane fetches it again")
        XCTAssertEqual(try store.body(for: id("new"))?.plainText, "noon")
        XCTAssertEqual(try store.body(for: id("draft"))?.plainText, "draft text")
        XCTAssertEqual(try store.body(for: id("queued"))?.plainText, "queued text")
        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 10), 0, "a sweep finds it already done")

        // Opened later: saved whole, as any fetched body.
        try store.saveBody(body("lighthouse drawings"), for: id("old"))
        XCTAssertEqual(try store.body(for: id("old")), body("lighthouse drawings"))
    }

    func testDeletingAnEvictedMessageAndWipingTheAccountLeaveNothingBehind() throws {
        try store.upsertMessages([message("a1", in: "c1", date: old), message("b1", in: "c2", account: accountB, date: old)])
        try store.saveBody(body("alpha"), for: id("a1"))
        try store.saveBody(body("bravo"), for: id("b1", account: accountB))
        try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 10)

        try store.deleteMessages([id("a1")])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all, searchText: "alpha")), [])
        try store.wipeMailData(for: accountB)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all, searchText: "bravo")), [])

        // The same ids written again start whole: no mark outlives its message.
        try store.upsertMessages([message("a1", in: "c1", date: old)])
        try store.saveBody(body("alpha again"), for: id("a1"))
        XCTAssertEqual(try store.body(for: id("a1"))?.plainText, "alpha again")
    }
}

/// Reader mode's read of an evicted body (spec §5.59): `keptBody(for:)` answers with what the eviction kept (plain text,
/// attachment list, design facts) where `body(for:)` answers nil, so the reader shows the text without waiting for the
/// download.
extension MailStoreContractTests {
    func testAKeptBodyIsWhatTheEvictionLeft() throws {
        let old = date(-540 * 86_400)
        let file = AttachmentInfo(id: "a1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 2_048, isInline: false)
        let oldID = MessageID(accountID: accountA, providerID: "old")
        let newID = MessageID(accountID: accountA, providerID: "new")
        try store.upsertMessages([message("old", in: "c1", date: old), message("new", in: "c2", date: date(0))])
        let whole = StoredBody(body: MessageBody(html: "<p>Plan <b>attached</b></p>", text: "Plan attached", attachments: [file]),
                               renderedHTML: "<div class=\"ss-body\"><p>Plan <b>attached</b></p></div>", plainText: "Plan attached",
                               hasQuotedContent: false, blockedRemoteImageCount: 2, trackerImageCount: 1, typesetting: .styled,
                               declaresColors: true, coveredByNewYork: true)
        try store.saveBody(whole, for: oldID)
        try store.saveBody(body("noon"), for: newID)
        XCTAssertEqual(try store.keptBody(for: oldID), whole, "a whole body reads whole")

        try store.evictBodies(receivedBefore: date(-90 * 86_400), excluding: [], limit: 10)
        XCTAssertNil(try store.body(for: oldID))
        let kept = try XCTUnwrap(try store.keptBody(for: oldID))
        XCTAssertEqual(kept.plainText, "Plan attached")
        XCTAssertEqual(kept.body.attachments, [file])
        XCTAssertNil(kept.body.html, "no source")
        XCTAssertNil(kept.body.text)
        XCTAssertEqual(kept.renderedHTML, "", "no rendered HTML")
        XCTAssertNil(kept.invitation)
        XCTAssertEqual(kept.typesetting, .styled, "the design facts stay")
        XCTAssertEqual(kept.declaresColors, true)
        XCTAssertEqual(kept.coveredByNewYork, true)
        XCTAssertEqual(kept.blockedRemoteImageCount, 2)
        XCTAssertEqual(kept.trackerImageCount, 1, "the trackers' count is a design fact too (v24)")
        XCTAssertEqual(try store.keptBody(for: newID)?.plainText, "noon")
        XCTAssertNil(try store.keptBody(for: MessageID(accountID: accountA, providerID: "unknown")), "no row, nothing kept")

        try store.saveBody(whole, for: oldID)
        XCTAssertEqual(try store.keptBody(for: oldID), whole, "fetched again, whole again")
    }

    /// The kept bodies of many messages in one read: what `keptBody(for:)` answers for each, the ones without a row left
    /// out, across accounts and past one statement's worth of ids.
    func testKeptBodiesReadsManyAtOnce() throws {
        let old = date(-540 * 86_400)
        var ids: [MessageID] = []
        var messages: [MessageMetadata] = []
        for index in 0..<620 {
            messages.append(message("m\(index)", in: "c\(index % 7)", date: old.addingTimeInterval(Double(index))))
            ids.append(MessageID(accountID: accountA, providerID: "m\(index)"))
        }
        try store.upsertMessages(messages)
        for (index, id) in ids.enumerated() where !index.isMultiple(of: 3) { try store.saveBody(body("words \(index)"), for: id) }
        try store.evictBodies(receivedBefore: date(-90 * 86_400), excluding: [ids[1]], limit: 1_000)
        try store.upsertMessages([message("m1", in: "cb", account: accountB, date: date(0))])
        let otherAccount = MessageID(accountID: accountB, providerID: "m1")
        try store.saveBody(body("other account"), for: otherAccount)
        let unknown = MessageID(accountID: accountA, providerID: "unknown")

        let kept = try store.keptBodies(for: ids + [otherAccount, unknown, ids[2]])
        XCTAssertEqual(kept.count, ids.indices.filter { !$0.isMultiple(of: 3) }.count + 1, "a body for each row, none for the rest")
        XCTAssertEqual(kept[otherAccount]?.plainText, "other account", "each account's own, though the provider ids are the same")
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(kept[id], try store.keptBody(for: id), "as keptBody(for:) reads m\(index)")
        }
        XCTAssertEqual(kept[ids[2]]?.plainText, "words 2")
        XCTAssertEqual(kept[ids[2]]?.renderedHTML, "", "evicted: as the eviction left it")
        XCTAssertEqual(kept[ids[1]]?.renderedHTML.isEmpty, false, "kept whole: read whole")
        XCTAssertEqual(try store.keptBodies(for: []), [:])
    }
}
