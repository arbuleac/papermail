import XCTest
import SSCore

/// What happens to local state when the runner gives up on an operation: the change it applied at enqueue is
/// given back, so a failed archive puts the conversation back in the inbox (docs/DESIGN-LANGUAGE.md §5.7, "the
/// row is restored locally"). An extension of `MailStoreContractTests`, so both stores are held to it.
extension MailStoreContractTests {
    private func messageID(_ providerID: String) -> MessageID {
        MessageID(accountID: accountA, providerID: providerID)
    }

    private func flags(_ providerID: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> (roles: Set<MailboxRole>, isRead: Bool, isStarred: Bool) {
        let stored = try XCTUnwrap(try store.message(messageID(providerID)), "no message \(providerID)", file: file, line: line)
        return (stored.roles, stored.isRead, stored.isStarred)
    }

    func testGivingUpPutsBackWhatTheOperationChanged() throws {
        try store.upsertMessages([
            message("m1", in: "c", date: date(100), roles: [.inbox], isRead: false),
            // Archiving a conversation targets every message, including one that was never in the inbox: giving
            // up must not invent an inbox role for it, which an inverse change would.
            message("m2", in: "c", date: date(200), roles: [.sent]),
            message("n1", in: "d", date: date(300), roles: [.inbox]),
        ])
        let archive = operation("op-archive", .archive, ["m1", "m2"], at: 1_000)
        try store.enqueue(archive)
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["d"])

        try store.updateOperation(failed(archive))
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), ["d", "c"])
        XCTAssertEqual(try summary("c", view: .inbox).failedOperation, .archive, "restored and marked in one write")
        XCTAssertFalse(try summary("c").hasPendingOperations)
        XCTAssertEqual(try flags("m1").roles, [.inbox])
        XCTAssertEqual(try flags("m1").isRead, false)
        XCTAssertEqual(try flags("m2").roles, [.sent])
        XCTAssertEqual(try store.message(messageID("n1"))?.roles, [.inbox], "messages it did not target are untouched")

        // Writing the failed row again (or pruning it) gives nothing back a second time.
        try store.upsertMessages([message("m1", in: "c", date: date(100), roles: [], isRead: false)])
        try store.updateOperation(failed(archive, expiresAt: 10))
        XCTAssertEqual(try flags("m1").roles, [], "a failed row no longer wins, and does not undo provider state")
        XCTAssertEqual(try store.pruneFailedOperations(accountID: accountA, now: date(10)), 1)
        XCTAssertEqual(try flags("m1").roles, [])
    }

    /// The outbox narrows an operation to the targets the provider did not take; giving it up then puts back only
    /// those, never a message the provider has.
    func testGivingUpANarrowedOperationPutsBackOnlyItsRemainingTargets() throws {
        try store.upsertMessages([
            message("m1", in: "c", date: date(100), roles: [.inbox]),
            message("m2", in: "c", date: date(200), roles: [.inbox]),
            message("m3", in: "e", date: date(300), roles: [.inbox]),
        ])
        var archive = operation("op-archive", .archive, ["m1", "m2", "m3"], at: 1_000)
        try store.enqueue(archive)
        archive.status = .uncertain
        archive.targets = [messageID("m2")]
        try store.updateOperation(archive)

        try store.updateOperation(failed(archive))
        XCTAssertEqual(try flags("m2").roles, [.inbox], "the target still owed is put back")
        XCTAssertEqual(try flags("m1").roles, [], "the provider took this one")
        XCTAssertEqual(try flags("m3").roles, [])
        XCTAssertNil(try summary("e").failedOperation, "only the conversation still owed is marked")
    }

    /// An undo's steps are separate `perform` calls, often within one millisecond, so their rows share `created_at`;
    /// ordered then by their random ids, an undone trash could replay its archive before its restore and land in the
    /// Inbox, on the server and here. Rows of one millisecond keep the order they were queued in.
    func testOperationsQueuedInOneMillisecondKeepTheirOrder() throws {
        try store.upsertMessages([message("m1", in: "c", date: date(100), roles: [.trash])])
        let restore = operation("op-z", .restoreFromTrash, ["m1"], at: 1_000)
        let archive = operation("op-a", .archive, ["m1"], at: 1_000)
        try store.enqueue(restore)
        try store.enqueue(archive)
        XCTAssertEqual(try store.pendingOperations(accountID: accountA, limit: 10).map(\.id), ["op-z", "op-a"])
        XCTAssertEqual(try flags("m1").roles, [], "restored from the Trash, then archived")

        // A poll's report replays them in the same order.
        try store.upsertMessages([message("m1", in: "c", date: date(100), roles: [.trash])])
        XCTAssertEqual(try flags("m1").roles, [])

        // And a give-up of the first replays the second on top of what it puts back.
        try store.updateOperation(failed(restore))
        XCTAssertEqual(try flags("m1").roles, [.trash], "the restore given back, the archive (no Inbox to leave) on top")
    }

    func testGivingUpEachKindOfChange() throws {
        let cases: [(MetadataChange, Set<MailboxRole>, Bool, Bool)] = [
            (.archive, [.inbox], true, false),
            (.moveToInbox, [.spam], true, false),
            (.setRead(true), [.inbox], false, false),
            (.setRead(false), [.inbox], true, false),
            (.setStarred(true), [.inbox], true, false),
            (.setStarred(false), [.inbox], true, true),
            (.trash, [.inbox, .sent], true, false),
            (.restoreFromTrash, [.trash], true, false),
            (.markSpam, [.inbox], true, false),
            (.markNotSpam, [.spam], true, false),
        ]
        for (index, (change, roles, isRead, isStarred)) in cases.enumerated() {
            let before = message("x\(index)", in: "c\(index)", date: date(100), roles: roles, isRead: isRead, isStarred: isStarred)
            try store.upsertMessages([before])
            let queued = operation("op-\(index)", change, ["x\(index)"], at: 1_000 + TimeInterval(index))
            try store.enqueue(queued)
            XCTAssertNotEqual(try store.message(before.id), before, "\(change) changed nothing to give back")
            try store.updateOperation(failed(queued))
            XCTAssertEqual(try store.message(before.id), before, "\(change)")
        }
    }

    func testGivingUpKeepsNewerQueuedChangesAndTheLatestProviderReport() throws {
        try store.upsertMessages([message("m1", in: "c", date: date(100), roles: [.inbox], isRead: false)])
        let archive = operation("op-archive", .archive, ["m1"], at: 1_000)
        let star = operation("op-star", .setStarred(true), ["m1"], at: 2_000)
        try store.enqueue(archive)
        try store.enqueue(star)

        // The user read the message on their phone: the poll's report is the state the archive replaced now.
        try store.upsertMessages([message("m1", in: "c", date: date(100), roles: [.inbox], isRead: true)])
        XCTAssertEqual(try flags("m1").roles, [])
        XCTAssertTrue(try flags("m1").isRead)

        // The archive gives up; the star, queued after it and still live, keeps its effect.
        try store.updateOperation(failed(archive))
        XCTAssertEqual(try flags("m1").roles, [.inbox])
        XCTAssertTrue(try flags("m1").isRead, "the provider's later report, not the state at enqueue")
        XCTAssertTrue(try flags("m1").isStarred)
        XCTAssertTrue(try summary("c", view: .inbox).hasPendingOperations)

        // When the star gives up too, it goes back to the state without the archive it was queued behind.
        try store.updateOperation(failed(star))
        XCTAssertEqual(try flags("m1").roles, [.inbox])
        XCTAssertFalse(try flags("m1").isStarred)
        XCTAssertEqual(try summary("c", view: .inbox).failedOperation, .star)
    }

    func testGivingUpANewerOperationKeepsAnOlderOneThatIsStillQueued() throws {
        try store.upsertMessages([message("m1", in: "c", date: date(100), roles: [.inbox])])
        let archive = operation("op-archive", .archive, ["m1"], at: 1_000)
        let star = operation("op-star", .setStarred(true), ["m1"], at: 2_000)
        try store.enqueue(archive)
        try store.enqueue(star)

        try store.updateOperation(failed(star))
        XCTAssertEqual(try flags("m1").roles, [], "the older archive is still queued and still wins")
        XCTAssertFalse(try flags("m1").isStarred)

        try store.confirmOperation(id: archive.id)
        XCTAssertEqual(try flags("m1").roles, [])
    }

    func testGivingUpAfterTheProviderReportedTheChangeKeepsIt() throws {
        // The request timed out but landed: the next poll reports the message archived, then the runner gives up.
        try store.upsertMessages([message("m1", in: "c", date: date(100), roles: [.inbox])])
        let archive = operation("op-archive", .archive, ["m1"], at: 1_000)
        try store.enqueue(archive)
        try store.upsertMessages([message("m1", in: "c", date: date(100), roles: [])])
        try store.updateOperation(failed(archive))
        XCTAssertEqual(try flags("m1").roles, [])
        XCTAssertEqual(try conversationIDs(ConversationQuery(view: .inbox)), [])
    }

    func testOperationsThatNeverAppliedAChangeGiveNothingBack() throws {
        try store.upsertMessages([message("m1", in: "c", date: date(100), roles: [.inbox])])
        // Written straight to the outbox (as an older build left it) rather than enqueued: nothing was recorded
        // about the state it replaced, so a give-up cannot know what to put back and leaves the row alone.
        var stray = operation("op-stray", .archive, ["m1"], at: 1_000)
        stray.status = .uncertain
        try store.updateOperation(stray)
        try store.updateOperation(failed(stray))
        XCTAssertEqual(try flags("m1").roles, [.inbox])

        // A target that arrives only after its operation was queued is recorded by the poll that brings it.
        let read = operation("op-read", .setRead(true), ["m2"], at: 2_000)
        try store.enqueue(read)
        try store.upsertMessages([message("m2", in: "c", date: date(200), isRead: false)])
        XCTAssertTrue(try flags("m2").isRead)
        try store.updateOperation(failed(read))
        XCTAssertFalse(try flags("m2").isRead)

        // A target deleted before the give-up is simply gone.
        let star = operation("op-star", .setStarred(true), ["m1"], at: 3_000)
        try store.enqueue(star)
        try store.deleteMessages([messageID("m1")])
        try store.updateOperation(failed(star))
        XCTAssertNil(try store.message(messageID("m1")))
    }

    func testConfirmingOrDroppingAnOperationKeepsItsChange() throws {
        try store.upsertMessages([message("m1", in: "c", date: date(100), roles: [.inbox])])
        let archive = operation("op-archive", .archive, ["m1"], at: 1_000)
        try store.enqueue(archive)
        try store.confirmOperation(id: archive.id)
        XCTAssertEqual(try flags("m1").roles, [])

        let star = operation("op-star", .setStarred(true), ["m1"], at: 2_000)
        try store.enqueue(star)
        var uncertain = star
        uncertain.status = .uncertain
        try store.updateOperation(uncertain)
        try store.deleteOperation(id: star.id)
        XCTAssertTrue(try flags("m1").isStarred, "a poll settles it next, with the provider's state")
    }
}
