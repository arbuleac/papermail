import XCTest
import SSCore

/// The `MailStoring` contract for the data the Quire design needs (docs/DESIGN-LANGUAGE.md §8.5): account
/// ink slots and monograms, the body design facts and the failed-operation mark. Written as an extension so
/// `SQLiteMailStoreContractTests` inherits every case and both stores are held to the same semantics.
extension MailStoreContractTests {
    // MARK: Helpers

    func conversationID(_ providerID: String, account: AccountID? = nil) -> ConversationID {
        ConversationID(accountID: account ?? accountA, providerID: providerID)
    }

    /// The conversation's mark; fails (rather than skips) when the conversation has no summary row.
    func failedMark(_ conversation: String, file: StaticString = #filePath, line: UInt = #line) throws -> OperationKind? {
        let id = conversationID(conversation)
        let all = try store.conversations(ConversationQuery(view: .all, limit: 10_000))
        let summary = try XCTUnwrap(all.first { $0.id == id }, "conversation \(conversation) has no summary", file: file, line: line)
        return summary.failedOperation
    }

    func operation(_ id: String, _ change: MetadataChange, _ targets: [String], at offset: TimeInterval) -> Operation {
        Operation(
            id: id, accountID: accountA, change: change,
            targets: targets.map { MessageID(accountID: accountA, providerID: $0) }, createdAt: date(offset)
        )
    }

    /// The operation as the runner records a give-up: failed, with its expiry in `nextAttemptAt`.
    func failed(_ operation: Operation, expiresAt offset: TimeInterval = 1_000_000) -> Operation {
        var copy = operation
        copy.status = .failed
        copy.attempts = 25
        copy.lastError = "server 500"
        copy.nextAttemptAt = date(offset)
        return copy
    }

    // MARK: Accounts

    func testInkSlotAndMonogramRoundTrip() throws {
        XCTAssertEqual(try store.accounts().map(\.inkSlot), [0, 0])
        XCTAssertEqual(try store.accounts().map(\.monogram), [nil, nil])

        try store.setInkSlot(7, for: accountB)
        try store.setMonogram("  Fa ", for: accountA)
        var accounts = try store.accounts()
        XCTAssertEqual(accounts.map(\.inkSlot), [0, 7])
        XCTAssertEqual(accounts.map(\.monogram), ["Fa", nil])

        try store.setMonogram("abc", for: accountA)
        XCTAssertEqual(try store.accounts().first?.monogram, "ab", "Settings allows two characters and so does the store")
        // The cut can leave whitespace at the end, which is trimmed like the rest.
        try store.setMonogram("A B", for: accountA)
        XCTAssertEqual(try store.accounts().first?.monogram, "A")
        try store.setMonogram(" A\nB", for: accountA)
        XCTAssertEqual(try store.accounts().first?.monogram, "A")
        try store.setMonogram("   ", for: accountA)
        XCTAssertNil(try store.accounts().first?.monogram, "blank means derived")
        try store.setMonogram("G", for: accountA)
        try store.setMonogram(nil, for: accountA)
        XCTAssertNil(try store.accounts().first?.monogram)

        // An upsert carries both fields, normalized like the setters.
        accounts = try store.accounts()
        var updated = accounts[1]
        updated.inkSlot = 3
        updated.monogram = "Cx1"
        try store.upsertAccount(updated)
        let reread = try XCTUnwrap(try store.accounts().last)
        XCTAssertEqual(reread.inkSlot, 3)
        XCTAssertEqual(reread.monogram, "Cx")
        updated.monogram = "D E"
        try store.upsertAccount(updated)
        XCTAssertEqual(try store.accounts().last?.monogram, "D")
    }

    func testInkSlotAndMonogramRejectUnknownAccountsAndSlots() throws {
        let nobody = AccountID("nobody")
        for slot in [-1, AccountInkSlot.count, 42] {
            XCTAssertThrowsError(try store.setInkSlot(slot, for: accountA), "slot \(slot)") { error in
                guard case StoreError.conflict = error else { return XCTFail("expected conflict, got \(error)") }
            }
        }
        XCTAssertThrowsError(try store.setInkSlot(1, for: nobody)) { error in
            guard case StoreError.notFound = error else { return XCTFail("expected notFound, got \(error)") }
        }
        XCTAssertThrowsError(try store.setMonogram("X", for: nobody)) { error in
            guard case StoreError.notFound = error else { return XCTFail("expected notFound, got \(error)") }
        }
        var invalid = try XCTUnwrap(try store.accounts().first)
        invalid.inkSlot = 12
        XCTAssertThrowsError(try store.upsertAccount(invalid))
        XCTAssertEqual(try store.accounts().map(\.inkSlot), [0, 0], "a refused write changes nothing")
        XCTAssertEqual(try store.accounts().count, 2)
    }

    /// The face choice (Quire §5.55): automatic until chosen, any choice round-trips through the setter and an upsert,
    /// and a paper face with no id is automatic, the one representation of "nothing chosen".
    func testFaceRoundTrip() throws {
        XCTAssertEqual(try store.accounts().map(\.face), [.automatic, .automatic])

        try store.setFace(.paper("fox"), for: accountA)
        try store.setFace(.monogram, for: accountB)
        XCTAssertEqual(try store.accounts().map(\.face), [.paper("fox"), .monogram])
        XCTAssertEqual(try store.accounts().map(\.inkSlot), [0, 0], "a face leaves the ink alone")
        XCTAssertEqual(try store.accounts().map(\.monogram), [nil, nil], "and the monogram")

        try store.setFace(.paper("owl"), for: accountA)
        XCTAssertEqual(try store.accounts().first?.face, .paper("owl"))
        try store.setFace(.paper(""), for: accountA)
        XCTAssertEqual(try store.accounts().first?.face, .automatic, "no id means nothing chosen")
        try store.setFace(.monogram, for: accountA)
        try store.setFace(.automatic, for: accountA)
        XCTAssertEqual(try store.accounts().first?.face, .automatic)

        // An upsert carries the face as the setters do; a profile refresh re-saving the account it read keeps it.
        var updated = try XCTUnwrap(try store.accounts().last)
        updated.face = .paper("black-cat")
        try store.upsertAccount(updated)
        XCTAssertEqual(try store.accounts().last?.face, .paper("black-cat"))
        var refreshed = try XCTUnwrap(try store.accounts().last)
        refreshed.displayName = "Renamed"
        try store.upsertAccount(refreshed)
        XCTAssertEqual(try store.accounts().last?.face, .paper("black-cat"))
        updated.face = .paper("")
        try store.upsertAccount(updated)
        XCTAssertEqual(try store.accounts().last?.face, .automatic)
    }

    /// An unknown account is refused, and removing an account takes its choice with it: an account added again later
    /// starts automatic.
    func testFaceRejectsUnknownAccountsAndGoesWithTheAccount() throws {
        XCTAssertThrowsError(try store.setFace(.paper("fox"), for: AccountID("nobody"))) { error in
            guard case StoreError.notFound = error else { return XCTFail("expected notFound, got \(error)") }
        }
        XCTAssertEqual(try store.accounts().map(\.face), [.automatic, .automatic], "a refused write changes nothing")

        let account = try XCTUnwrap(try store.accounts().first { $0.id == accountB })
        try store.setFace(.paper("frog"), for: accountB)
        try store.deleteAccount(accountB)
        XCTAssertEqual(try store.accounts().map(\.id), [accountA])
        try store.upsertAccount(account)
        XCTAssertEqual(try store.accounts().first { $0.id == accountB }?.face, .automatic, "the choice went with the row")
    }

    // MARK: Bodies

    func testBodyDesignFactsRoundTrip() throws {
        try store.upsertMessages([
            message("m1", in: "c", date: date(100)),
            message("m2", in: "c", date: date(200)),
            message("m3", in: "c", date: date(300)),
        ])
        for (index, typesetting) in BodyTypesetting.allCases.enumerated() {
            let id = MessageID(accountID: accountA, providerID: "m\(index + 1)")
            var stored = body("body \(index)")
            stored.typesetting = typesetting
            stored.declaresColors = typesetting == .styled
            stored.coveredByNewYork = typesetting != .unstyled
            try store.saveBody(stored, for: id)
            let reread = try XCTUnwrap(try store.body(for: id))
            XCTAssertEqual(reread.typesetting, typesetting)
            XCTAssertEqual(reread.declaresColors, typesetting == .styled)
            XCTAssertEqual(reread.coveredByNewYork, typesetting != .unstyled)
        }

        // A body saved without the facts (an older sanitizer) keeps them unknown rather than guessing.
        let legacy = MessageID(accountID: accountA, providerID: "m1")
        try store.saveBody(body("legacy"), for: legacy)
        let reread = try XCTUnwrap(try store.body(for: legacy))
        XCTAssertNil(reread.typesetting)
        XCTAssertNil(reread.declaresColors)
        XCTAssertNil(reread.coveredByNewYork)
    }

    /// The engine's backfill (M1): bodies without facts are listed per account, and writing facts changes
    /// only the facts.
    func testBodiesWithoutFactsAreListedUntilTheirFactsAreWritten() throws {
        try store.upsertMessages([
            message("m1", in: "c", date: date(100)),
            message("m2", in: "c", date: date(200)),
        ])
        let legacy = MessageID(accountID: accountA, providerID: "m1")
        let current = MessageID(accountID: accountA, providerID: "m2")
        try store.saveBody(body("legacy"), for: legacy)
        var known = body("current")
        known.typesetting = .unstyled
        known.declaresColors = false
        known.coveredByNewYork = true
        try store.saveBody(known, for: current)
        XCTAssertEqual(try store.messageIDsMissingDesignFacts(accountID: accountA, limit: 10), [legacy])
        XCTAssertEqual(try store.messageIDsMissingDesignFacts(accountID: accountB, limit: 10), [])
        XCTAssertEqual(try store.messageIDsMissingDesignFacts(accountID: accountA, limit: 0), [])

        let nowhere = MessageID(accountID: accountA, providerID: "gone")
        try store.saveDesignFacts([
            legacy: BodyDesignFacts(typesetting: .plain, declaresColors: false, coveredByNewYork: true),
            nowhere: .unknown,
        ])
        let reread = try XCTUnwrap(try store.body(for: legacy))
        XCTAssertEqual(reread.typesetting, .plain)
        XCTAssertEqual(reread.declaresColors, false)
        XCTAssertEqual(reread.coveredByNewYork, true)
        XCTAssertEqual(reread.renderedHTML, body("legacy").renderedHTML, "the rest of the body is untouched")
        XCTAssertNil(try store.body(for: nowhere), "facts never create a body")
        XCTAssertEqual(try store.messageIDsMissingDesignFacts(accountID: accountA, limit: 10), [])
    }

    // MARK: Failed-operation mark

    func testFailedOperationMarkLifecycle() throws {
        try store.upsertMessages([
            message("m1", in: "c", date: date(100)),
            message("m2", in: "c", date: date(200)),
            message("n1", in: "d", date: date(300)),
        ])
        XCTAssertNil(try failedMark("c"))

        // Set in the transaction that records the failure, on every conversation the operation targets.
        let archive = operation("op-archive", .archive, ["m1", "n1"], at: 1_000)
        try store.enqueue(archive)
        XCTAssertNil(try failedMark("c"), "a queued operation is not a failure")
        try store.updateOperation(failed(archive))
        XCTAssertEqual(try failedMark("c"), .archive)
        XCTAssertEqual(try failedMark("d"), .archive)
        XCTAssertFalse(try summary("c").hasPendingOperations)

        // Acknowledging clears one conversation and keeps the failed row; writing that row again as failed
        // (a retry of the write, not a new failure) does not bring the mark back.
        try store.acknowledgeFailedOperation(conversationID: conversationID("c"))
        XCTAssertNil(try failedMark("c"))
        XCTAssertEqual(try failedMark("d"), .archive)
        try store.updateOperation(failed(archive))
        XCTAssertNil(try failedMark("c"))
        try store.acknowledgeFailedOperation(conversationID: conversationID("c"))
        try store.acknowledgeFailedOperation(conversationID: conversationID("nowhere"))
        XCTAssertNil(try failedMark("c"))

        // A new failure marks again, with its own kind.
        let unstar = operation("op-unstar", .setStarred(false), ["m2"], at: 2_000)
        try store.enqueue(unstar)
        try store.updateOperation(failed(unstar))
        XCTAssertEqual(try failedMark("c"), .unstar)

        // An operation created before the failure being confirmed does not clear it...
        let earlier = operation("op-earlier", .setRead(true), ["m1"], at: 1_500)
        try store.enqueue(earlier)
        try store.confirmOperation(id: earlier.id)
        XCTAssertEqual(try failedMark("c"), .unstar)

        // ...a later one does, once it is confirmed rather than merely queued, and only where it landed.
        let later = operation("op-later", .setRead(false), ["m2"], at: 3_000)
        try store.enqueue(later)
        var inFlight = later
        inFlight.status = .uncertain
        try store.updateOperation(inFlight)
        XCTAssertEqual(try failedMark("c"), .unstar, "queued or uncertain is not confirmed")
        try store.confirmOperation(id: later.id)
        XCTAssertNil(try failedMark("c"))
        XCTAssertEqual(try failedMark("d"), .archive)

        // Pruning: nothing before the expiry, the expired row at it, and the mark it held goes with it.
        try store.updateOperation(failed(archive, expiresAt: 5_000))
        XCTAssertEqual(try store.pruneFailedOperations(accountID: accountA, now: date(4_999)), 0)
        XCTAssertEqual(try failedMark("d"), .archive)
        XCTAssertEqual(try store.pruneFailedOperations(accountID: accountB, now: date(5_000)), 0, "other accounts are not pruned")
        XCTAssertEqual(try failedMark("d"), .archive)
        XCTAssertEqual(try store.pruneFailedOperations(accountID: accountA, now: date(5_000)), 1)
        XCTAssertNil(try failedMark("d"))
        XCTAssertNil(try failedMark("c"))
    }

    func testFailedMarkNamesTheNewestFailure() throws {
        try store.upsertMessages([message("m1", in: "c", date: date(100)), message("m2", in: "c", date: date(200))])
        let trash = operation("op-trash", .trash, ["m1"], at: 1_000)
        let star = operation("op-star", .setStarred(true), ["m2"], at: 2_000)
        try store.enqueue(trash)
        try store.enqueue(star)

        try store.updateOperation(failed(star))
        XCTAssertEqual(try failedMark("c"), .star)
        // An older operation failing afterwards does not displace the newer failure the row already names.
        try store.updateOperation(failed(trash))
        XCTAssertEqual(try failedMark("c"), .star)

        // Pruning the older failure leaves the mark: the newer failed row still targets the conversation.
        try store.updateOperation(failed(trash, expiresAt: 10))
        XCTAssertEqual(try store.pruneFailedOperations(accountID: accountA, now: date(10)), 1)
        XCTAssertEqual(try failedMark("c"), .star)

        // Once acknowledged, any new failure shows, even one older than the failure acknowledged.
        try store.acknowledgeFailedOperation(conversationID: conversationID("c"))
        let restore = operation("op-restore", .restoreFromTrash, ["m1"], at: 500)
        try store.enqueue(restore)
        try store.updateOperation(failed(restore))
        XCTAssertEqual(try failedMark("c"), .restoreFromTrash)

        // Every expired row goes in one call, oldest first, and the last of them clears the mark.
        try store.updateOperation(failed(restore, expiresAt: 20))
        try store.updateOperation(failed(star, expiresAt: 20))
        XCTAssertEqual(try store.pruneFailedOperations(accountID: accountA, now: date(20)), 2)
        XCTAssertNil(try failedMark("c"))
    }

    func testDroppingALaterOperationIsNotAConfirmation() throws {
        try store.upsertMessages([message("m1", in: "c", date: date(100))])
        let read = operation("op-read", .setRead(true), ["m1"], at: 1_000)
        try store.enqueue(read)
        try store.updateOperation(failed(read))
        XCTAssertEqual(try failedMark("c"), .markRead)

        // A later operation the poll settles as uncertain (the provider's report decides, landed or not) is
        // deleted without being confirmed, so it says nothing about the failure.
        let star = operation("op-star", .setStarred(true), ["m1"], at: 2_000)
        try store.enqueue(star)
        var uncertain = star
        uncertain.status = .uncertain
        uncertain.attempts = 1
        try store.updateOperation(uncertain)
        try store.deleteOperation(id: star.id)
        XCTAssertEqual(try failedMark("c"), .markRead)

        // Deleting the failed row itself (what pruning does) settles it.
        try store.deleteOperation(id: read.id)
        XCTAssertNil(try failedMark("c"))
    }

    func testPruningKeepsTheMarkWhileAnotherFailureStands() throws {
        // Operations on different messages of one conversation are not ordered by the runner, so the newer
        // one can give up first.
        try store.upsertMessages([message("m1", in: "c", date: date(100)), message("m2", in: "c", date: date(200))])
        let older = operation("op-older", .archive, ["m1"], at: 1_000)
        let newer = operation("op-newer", .setStarred(true), ["m2"], at: 2_000)
        try store.enqueue(older)
        try store.enqueue(newer)
        try store.updateOperation(failed(newer, expiresAt: 10))
        try store.updateOperation(failed(older, expiresAt: 20))
        XCTAssertEqual(try failedMark("c"), .star, "the mark names the newest operation")

        // The newer failure expires first; the older one gave up later, is unacknowledged and still stands.
        XCTAssertEqual(try store.pruneFailedOperations(accountID: accountA, now: date(10)), 1)
        XCTAssertNotNil(try failedMark("c"))
        XCTAssertEqual(try store.pruneFailedOperations(accountID: accountA, now: date(20)), 1)
        XCTAssertNil(try failedMark("c"))
    }

    func testPruningKeepsTheMarkOfAFailureAfterTheAcknowledgement() throws {
        try store.upsertMessages([message("m1", in: "c", date: date(100)), message("m2", in: "c", date: date(200))])
        let older = operation("op-older", .archive, ["m1"], at: 1_000)
        let newer = operation("op-newer", .setStarred(true), ["m2"], at: 2_000)
        try store.enqueue(older)
        try store.enqueue(newer)
        try store.updateOperation(failed(newer, expiresAt: 10))
        try store.acknowledgeFailedOperation(conversationID: conversationID("c"))
        try store.updateOperation(failed(older, expiresAt: 20))
        XCTAssertEqual(try failedMark("c"), .archive)

        // Pruning the acknowledged, newer failure must not take the mark the older, unseen one set.
        XCTAssertEqual(try store.pruneFailedOperations(accountID: accountA, now: date(10)), 1)
        XCTAssertEqual(try failedMark("c"), .archive)
        XCTAssertEqual(try store.pruneFailedOperations(accountID: accountA, now: date(20)), 1)
        XCTAssertNil(try failedMark("c"))
    }

    func testFailedMarkSettlesWhenAnOperationLeavesFailedOrIsConfirmed() throws {
        try store.upsertMessages([message("m1", in: "c", date: date(100))])
        let read = operation("op-read", .setRead(true), ["m1"], at: 1_000)
        try store.enqueue(read)
        try store.updateOperation(failed(read))
        XCTAssertEqual(try failedMark("c"), .markRead)

        // Put back in the outbox (a retry): the failure no longer stands.
        var retry = failed(read)
        retry.status = .pending
        retry.nextAttemptAt = nil
        try store.updateOperation(retry)
        XCTAssertNil(try failedMark("c"))
        XCTAssertTrue(try summary("c").hasPendingOperations)

        try store.updateOperation(failed(read))
        XCTAssertEqual(try failedMark("c"), .markRead)
        let archive = operation("op-archive", .archive, ["m1"], at: 2_000)
        try store.enqueue(archive)
        var confirmed = archive
        confirmed.status = .confirmed
        try store.updateOperation(confirmed)
        XCTAssertNil(try failedMark("c"), "a later operation written as confirmed settles like a deleted one")
    }

    func testFailedMarkLivesOnTheSummaryRow() throws {
        try store.upsertMessages([message("m1", in: "c", date: date(100)), message("n1", in: "d", date: date(200))])
        let archive = operation("op-archive", .archive, ["m1", "n1"], at: 1_000)
        try store.enqueue(archive)
        try store.updateOperation(failed(archive))
        XCTAssertEqual(try failedMark("c"), .archive)

        // Ordinary summary refreshes (new mail, flag changes, body saves) keep the mark.
        try store.upsertMessages([message("m2", in: "c", date: date(300), isRead: false)])
        try store.saveBody(body("hello"), for: MessageID(accountID: accountA, providerID: "m2"))
        XCTAssertEqual(try failedMark("c"), .archive)
        XCTAssertEqual(try summary("c").unreadCount, 1)

        // A conversation that loses its last message loses its row and the mark with it; when mail for it
        // arrives again it starts unmarked.
        try store.deleteMessages([MessageID(accountID: accountA, providerID: "n1")])
        XCTAssertFalse(try store.conversations(ConversationQuery(view: .all)).contains { $0.id == conversationID("d") })
        try store.upsertMessages([message("n1", in: "d", date: date(200))])
        XCTAssertNil(try failedMark("d"))

        // Spam has no summary row either.
        try store.upsertMessages([message("s1", in: "s", date: date(400), roles: [.spam])])
        let spam = operation("op-spam", .setRead(true), ["s1"], at: 2_000)
        try store.enqueue(spam)
        try store.updateOperation(failed(spam))
        try store.upsertMessages([message("s1", in: "s", date: date(400), roles: [.inbox])])
        XCTAssertNil(try failedMark("s"))

        // Wiping the account's mail drops its marks.
        try store.wipeMailData(for: accountA)
        try store.upsertMessages([message("m1", in: "c", date: date(100))])
        XCTAssertNil(try failedMark("c"))
    }

    func testObservedRowsCarryTheFailedMark() throws {
        try store.upsertMessages([message("m1", in: "c", date: date(100))])
        let marked = expectation(description: "mark delivered")
        let cleared = expectation(description: "acknowledgement delivered")
        marked.assertForOverFulfill = false
        cleared.assertForOverFulfill = false
        let box = ObservedValues()
        let observation = store.observeConversations(ConversationQuery(view: .all)) { summaries in
            let marks = summaries.map { $0.failedOperation?.rawValue ?? "-" }
            let count = box.append(marks)
            if marks == ["markUnread"] { marked.fulfill() }
            if count > 1, marks == ["-"], box.values.contains(["markUnread"]) { cleared.fulfill() }
        }
        let unread = operation("op-unread", .setRead(false), ["m1"], at: 1_000)
        try store.enqueue(unread)
        try store.updateOperation(failed(unread))
        wait(for: [marked], timeout: 2)
        try store.acknowledgeFailedOperation(conversationID: conversationID("c"))
        wait(for: [cleared], timeout: 2)
        observation.cancel()
    }
}
