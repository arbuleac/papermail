import XCTest
@testable import SSCore

/// The `MailStoring` contract for Mark as spam (roadmap Q2.3): the two changes are applied and queued like any other,
/// spam leaves every view, the undo's steps put the mail back where it was, a give-up restores and marks the row, and a
/// snooze ends once the mail it put away is in Spam. An extension of `MailStoreContractTests`, so both stores are held to it.
extension MailStoreContractTests {
    private func spamID(_ providerID: String) -> MessageID {
        MessageID(accountID: accountA, providerID: providerID)
    }

    private func spamOperation(_ change: MetadataChange, _ providerIDs: [String], at offset: TimeInterval) -> SSCore.Operation {
        SSCore.Operation(accountID: accountA, change: change, targets: providerIDs.map(spamID), createdAt: date(offset))
    }

    /// The steps a record's undo queues, a millisecond apart, as `MailEngine.setSnoozes` queues them.
    private func spamUndo(_ record: MailActionRecord, at offset: TimeInterval) -> [SSCore.Operation] {
        record.inverse.enumerated().map { index, step in
            SSCore.Operation(accountID: accountA, change: step.change, targets: step.targets, createdAt: date(offset + Double(index) / 1_000))
        }
    }

    func testSpamLeavesEveryViewAndSearch() throws {
        try store.upsertMessages([
            message("m1", in: "c1", subject: "Prize claim", date: date(10)),
            message("m2", in: "c2", subject: "Lunch", date: date(20)),
        ])
        try store.enqueue(spamOperation(.markSpam, ["m1"], at: 100))

        XCTAssertEqual(try store.message(spamID("m1"))?.roles, [.spam])
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10).map(\.change), [.markSpam], "queued for the engine")
        for view in [MailboxView.inbox, .all, .starred, .sent, .trash] {
            XCTAssertFalse(try conversationIDs(ConversationQuery(view: view)).contains("c1"), "\(view)")
        }
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .all, searchText: "prize")), [])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c2"])
    }

    /// The user's reply stays in Sent: the conversation lists there, and no longer in the Inbox.
    func testTheUsersOwnReplyKeepsTheConversationInSent() throws {
        try store.upsertMessages([
            message("in", in: "c1", date: date(10)),
            message("reply", in: "c1", date: date(20), roles: [.sent]),
        ])
        let messages = try store.messages(in: ConversationID(accountID: accountA, providerID: "c1"))
        let targets = MailActionRecord.targets(for: .markSpam, in: messages, kind: .gmail)
        try store.enqueue(SSCore.Operation(accountID: accountA, change: .markSpam, targets: targets.map(\.id), createdAt: date(100)))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), [])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .sent)), ["c1"])
        XCTAssertEqual(try store.message(spamID("reply"))?.roles, [.sent])
    }

    /// Undo of a mixed conversation: what was in the Inbox comes back there, what was archived goes back to the archive.
    func testTheUndoStepsPutTheMailBackWhereItWas() throws {
        try store.upsertMessages([
            message("old", in: "c1", date: date(10), roles: []),
            message("new", in: "c1", date: date(20), roles: [.inbox]),
        ])
        let id = ConversationID(accountID: accountA, providerID: "c1")
        let before = try store.messages(in: id)
        let record = try XCTUnwrap(MailActionRecord.make(.markSpam, on: MailActionRecord.targets(for: .markSpam, in: before, kind: .microsoft),
                                                         conversation: id))
        try store.enqueue(SSCore.Operation(accountID: accountA, change: .markSpam, targets: record.targets, createdAt: date(100)))
        XCTAssertTrue(try store.conversations(ConversationQuery(view: .all)).isEmpty)

        try store.enqueue(spamUndo(record, at: 200))
        XCTAssertEqual(try store.messages(in: id).map(\.roles), before.map(\.roles))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c1"])
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10).map(\.change), [.markSpam, .markNotSpam, .archive],
                       "replayed in the order they were applied")
    }

    /// A provider report that still has the message in the Inbox, before the change has landed, does not bring it back.
    func testAPendingMarkAsSpamWinsOverAnOlderReport() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        try store.enqueue(spamOperation(.markSpam, ["m1"], at: 100))
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        XCTAssertEqual(try store.message(spamID("m1"))?.roles, [.spam])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), [])
    }

    func testGivingUpAMarkAsSpamRestoresTheRowWithItsMark() throws {
        try store.upsertMessages([message("m1", in: "c1", date: date(10))])
        let queued = spamOperation(.markSpam, ["m1"], at: 100)
        try store.enqueue(queued)
        var failed = queued
        failed.status = .failed
        failed.attempts = 1
        failed.lastError = "server 400"
        failed.nextAttemptAt = date(1_000_000)
        try store.updateOperation(failed)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["c1"])
        XCTAssertEqual(try summary("c1", view: .inbox).failedOperation, .markSpam)
    }

    /// Marking as spam leaves the user's own copies in Sent and Drafts, so the conversation keeps a summary row; with the
    /// rest of its mail in Spam its snooze ends all the same (here or on another device), and the undo puts both back.
    /// Left standing, its return would move the user's own reply to the Inbox.
    func testSpamOfEverythingButTheUsersOwnCopiesEndsTheSnooze() throws {
        try store.upsertMessages([message("in1", in: "c1", date: date(10)), message("reply1", in: "c1", date: date(20), roles: [.sent]),
                                  message("in2", in: "c2", date: date(10)), message("reply2", in: "c2", date: date(20), roles: [.sent])])
        let c1 = ConversationID(accountID: accountA, providerID: "c1")
        let c2 = ConversationID(accountID: accountA, providerID: "c2")
        try store.setSnoozes([Snooze.Change(conversationID: c1, until: date(9_000)), Snooze.Change(conversationID: c2, until: date(9_000))],
                             enqueueing: [spamOperation(.archive, ["in1", "in2"], at: 100)], at: date(100))
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [c1, c2])

        let record = try XCTUnwrap(MailActionRecord.make(.markSpam, on: MailActionRecord.targets(for: .markSpam, in: try store.messages(in: c1),
                                                                                                    kind: .gmail), conversation: c1))
        XCTAssertEqual(record.targets, [spamID("in1")])
        try store.enqueue(SSCore.Operation(accountID: accountA, change: .markSpam, targets: record.targets, createdAt: date(200)))
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [c2], "c1 leaves Later")
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .later)), ["c2"])
        XCTAssertFalse(Snooze.canHold(try store.messages(in: c1)), "and cannot be snoozed again")

        // The undo restores the mail to the archive and the snooze together.
        try store.setSnoozes([Snooze.Change(conversationID: c1, until: date(9_000))], enqueueing: spamUndo(record, at: 300), at: date(300))
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [c1, c2])
        XCTAssertEqual(try store.message(spamID("in1"))?.roles, [])

        // Another device's Report spam, once the archive has landed, ends c2's the same way.
        for operation in try store.pendingOperations(accountID: accountA, limit: 10) { try store.confirmOperation(id: operation.id) }
        try store.upsertMessages([message("in2", in: "c2", date: date(10), roles: [.spam])])
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [c1])
    }

    /// Spam alone in a conversation whose other mail from others is put away does not end its snooze: that mail still
    /// comes back.
    func testSomeSpamBesideMailPutAwayKeepsTheSnooze() throws {
        try store.upsertMessages([message("a", in: "c1", date: date(10), roles: []), message("b", in: "c1", date: date(20), roles: [.spam]),
                                  message("reply", in: "c1", date: date(30), roles: [.sent])])
        let c1 = ConversationID(accountID: accountA, providerID: "c1")
        XCTAssertTrue(Snooze.canHold(try store.messages(in: c1)))
        try store.setSnoozes([Snooze.Change(conversationID: c1, until: date(9_000))], enqueueing: [], at: date(100))
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [c1])
    }
}
