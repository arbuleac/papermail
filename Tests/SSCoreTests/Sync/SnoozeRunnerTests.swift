import Foundation
import XCTest
@testable import SSCore

/// When snoozed mail comes back (Later, docs/ARCHITECTURE.md "Later"), on a clock the test moves by hand: at its time,
/// at launch for a time missed while the app was closed, on waking after the Mac slept through it, and when the wall
/// clock is set past it, each once its account has checked for mail since the time (or has waited a minute for that);
/// each return queues the ordinary move-to-inbox and mark-unread operations and marks the conversation returned, and
/// mail that came meanwhile ends the snooze instead. The runner keeps one wait for the soonest snooze and none at all
/// with nothing snoozed.
final class SnoozeRunnerTests: XCTestCase {
    private let account = Fixtures.accountID

    private func harness(_ clock: HandClock, start: Bool = true, prepare: (InMemoryMailStore) throws -> Void = { _ in }) throws -> EngineHarness {
        let provider = ScriptedProvider(accountID: account)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider) {
            $0.pollInterval = 30
            $0.snoozeClock = clock.sendClock
        }
        try prepare(harness.store)
        if start { harness.engine.start() }
        return harness
    }

    private func conversation(_ id: String) -> ConversationID {
        ConversationID(accountID: account, providerID: id)
    }

    /// An older conversation, read, in the Inbox: what L is pressed on.
    private func seed(_ store: InMemoryMailStore, _ id: String = "later") throws {
        try store.upsertMessages([
            Fixtures.message(201, conversation: id, isRead: true),
            Fixtures.message(202, conversation: id, isRead: true),
        ])
    }

    /// Snoozes it as the window does: through the engine, archiving what is in the Inbox.
    private func snooze(_ harness: EngineHarness, _ id: String = "later", until due: Date) throws {
        let targets = try harness.store.messages(in: conversation(id)).filter(\.isInInbox).map(\.id)
        try harness.engine.setSnoozes([Snooze.Change(conversationID: conversation(id), until: due)],
                                      performing: [MailActionRecord.Step(change: .archive, targets: targets)])
    }

    private func isBack(_ harness: EngineHarness, _ id: String = "later") throws -> Bool {
        try isBack(harness.store, id)
    }

    private func isBack(_ store: MailStoring, _ id: String = "later") throws -> Bool {
        try store.conversations(ConversationQuery(view: .inbox)).contains { $0.id.providerID == id && $0.returnedAt != nil }
    }

    /// A runner on its own, over `store`, whose checks the test reports by hand.
    private func bareRunner(_ store: MailStoring, _ clock: HandClock, _ requests: CheckRequests) -> SnoozeRunner {
        SnoozeRunner(store: store, clock: clock.sendClock, onReturn: { _ in }, requestCheck: { requests.append($0) })
    }

    /// Snoozes `id` straight in the store, archiving what is in the Inbox, as the engine writes it.
    private func snoozeInStore(_ store: MailStoring, _ id: ConversationID, until due: Date, at now: Date) throws {
        let targets = try store.messages(in: id).filter(\.isInInbox).map(\.id)
        try store.setSnoozes([Snooze.Change(conversationID: id, until: due)],
                             enqueueing: [SSCore.Operation(accountID: id.accountID, change: .archive, targets: targets, createdAt: now)], at: now)
    }

    /// The account's live lane checked for mail: a full cycle began now and its poll caught up.
    private func checked(_ runner: SnoozeRunner, _ account: AccountID) {
        runner.liveCheckStarted(account)
        runner.liveCheckCaughtUp(account)
    }

    private func pendingChanges(_ store: MailStoring, _ account: AccountID? = nil) throws -> [MetadataChange] {
        try store.pendingOperations(accountID: account ?? self.account, limit: 10).map(\.change)
    }

    /// Lets the runner's actor run whatever a wake handed it.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: Timers

    func testWithNothingSnoozedTheRunnerKeepsNoTimer() async throws {
        let clock = HandClock()
        let harness = try harness(clock)
        await settle()
        XCTAssertTrue(clock.sleeps.isEmpty, "no snooze, no wait: not even the poll's")
        // Two minutes on, still none.
        clock.advance(120)
        await settle()
        XCTAssertTrue(clock.sleeps.isEmpty)
        await harness.shutdown()
    }

    /// One wait, to the snooze's time: no tick in between, however far away it is.
    func testASnoozeWaitsOnceForItsTimeAndComesBackThen() async throws {
        let clock = HandClock()
        let harness = try harness(clock) { try self.seed($0) }
        try snooze(harness, until: clock.now.addingTimeInterval(3 * 3_600))
        try await waitUntil("the runner waits for the snooze") { clock.sleeps.count == 1 }
        XCTAssertEqual(clock.sleeps, [3 * 3_600])
        XCTAssertEqual(clock.advance(3 * 3_600 - 2), 0)
        XCTAssertFalse(try isBack(harness))
        XCTAssertEqual(try harness.store.conversations(ConversationQuery(view: .later)).map(\.id), [conversation("later")])

        XCTAssertEqual(clock.advance(2), 1)
        try await waitUntil("back in the Inbox") { try self.isBack(harness) }
        let row = try XCTUnwrap(try harness.store.conversations(ConversationQuery(view: .inbox)).first { $0.id == conversation("later") })
        XCTAssertEqual(row.unreadCount, 1, "its latest message is unread")
        XCTAssertEqual(try harness.store.message(MessageID(accountID: account, providerID: "202"))?.isRead, false)
        XCTAssertEqual(try harness.store.message(MessageID(accountID: account, providerID: "201"))?.isRead, true)
        XCTAssertEqual(row.returnedAt.map { $0.timeIntervalSince(clock.now) } ?? 99, 0, accuracy: 0.002)
        XCTAssertTrue(try harness.store.snoozes().isEmpty)
        // Nothing left snoozed: no further wait was asked for, beyond the one for its account's check.
        await settle()
        let waits = clock.sleeps
        XCTAssertEqual(waits.first, 3 * 3_600)
        XCTAssertTrue(waits.dropFirst().allSatisfy { $0 <= SnoozeRunner.checkWait }, "\(waits)")
        await settle()
        XCTAssertEqual(clock.sleeps.count, waits.count)
        await harness.shutdown()
    }

    func testTheReturnQueuesTheOrdinaryOperations() async throws {
        let clock = HandClock()
        let store = InMemoryMailStore()
        try seed(store)
        let runner = bareRunner(store, clock, CheckRequests())
        try snoozeInStore(store, conversation("later"), until: clock.now.addingTimeInterval(60), at: clock.now)
        clock.advance(61)
        checked(runner, account)
        _ = await runner.returnDue()
        let pending = try store.pendingOperations(accountID: account, limit: 10)
        XCTAssertEqual(pending.map(\.change), [.archive, .moveToInbox, .setRead(false)], "replayed in this order")
        XCTAssertEqual(pending[1].targets.map(\.providerID), ["201", "202"])
        XCTAssertEqual(pending[2].targets.map(\.providerID), ["202"], "only the latest message")
        XCTAssertTrue(try isBack(store))
    }

    /// The return brings back what the snooze put away: never a message in the Trash or Spam (Move to Inbox's “from the
    /// Trash” rule would bring only that back), and on Microsoft not the user's own reply in Sent Items, so the message
    /// marked unread is the one that lands in the Inbox.
    func testTheReturnBringsBackOnlyWhatWasPutAway() {
        let now = Fixtures.baseDate
        let partlyTrashed = [
            Fixtures.message(1, conversation: "c", roles: [], isRead: true),
            Fixtures.message(2, conversation: "c", roles: [.trash], isRead: true),
            Fixtures.message(3, conversation: "c", roles: [.spam], isRead: true),
        ]
        let gmail = SnoozeRunner.operations(returning: partlyTrashed, of: conversation("c"), kind: .gmail, at: now)
        XCTAssertEqual(gmail.map(\.change), [.moveToInbox, .setRead(false)])
        XCTAssertEqual(gmail.map { $0.targets.map(\.providerID) }, [["1"], ["1"]])

        let replied = [Fixtures.message(1, conversation: "c", roles: [], isRead: true),
                       Fixtures.message(2, conversation: "c", roles: [.sent], isRead: true)]
        let microsoft = SnoozeRunner.operations(returning: replied, of: conversation("c"), kind: .microsoft, at: now)
        XCTAssertEqual(microsoft.map { $0.targets.map(\.providerID) }, [["1"], ["1"]], "the reply stays in Sent Items, read")
        // A conversation of the user's own mail alone comes back whole, as Move to Inbox moves it.
        let own = [Fixtures.message(1, conversation: "c", roles: [.sent], isRead: true)]
        XCTAssertEqual(SnoozeRunner.operations(returning: own, of: conversation("c"), kind: .microsoft, at: now).map { $0.targets.map(\.providerID) },
                       [["1"], ["1"]])
    }

    /// A snooze moved earlier, or a second one sooner, takes the wait: the runner is woken by the write.
    func testASoonerSnoozeTakesTheWait() async throws {
        let clock = HandClock()
        let harness = try harness(clock) {
            try self.seed($0, "a")
            try $0.upsertMessages([Fixtures.message(301, conversation: "b", isRead: true)])
        }
        try snooze(harness, "a", until: clock.now.addingTimeInterval(7_200))
        try await waitUntil("the first wait") { clock.sleeps.count == 1 }
        try snooze(harness, "b", until: clock.now.addingTimeInterval(600))
        try await waitUntil("the second wait") { clock.sleeps.count == 2 }
        XCTAssertEqual(clock.sleeps, [7_200, 600])
        clock.advance(600)
        try await waitUntil("b back") { try self.isBack(harness, "b") }
        // After the wait for b's account to check, if the check was not in already.
        try await waitUntil("waiting for a again") { abs((clock.sleeps.last ?? 0) - 6_600) < 0.001 }
        XCTAssertFalse(try isBack(harness, "a"))
        await harness.shutdown()
    }

    // MARK: Missed times

    func testATimeMissedWhileTheAppWasClosedReturnsAtLaunch() async throws {
        let clock = HandClock()
        let harness = try harness(clock, start: false) { try self.seed($0) }
        try snooze(harness, until: clock.now.addingTimeInterval(3_600))
        // The app quits; a day passes before the next launch.
        clock.sleepThrough(86_400)
        harness.engine.start()
        try await waitUntil("back at launch") { try self.isBack(harness) }
        await settle()
        XCTAssertTrue(clock.sleeps.allSatisfy { $0 <= SnoozeRunner.checkWait }, "nothing else snoozed: no wait but the one for the account's first check")
        await harness.shutdown()
    }

    /// The finding this guards: the outbox replays before each poll, so a return queued at launch from what the store
    /// held when the app quit would mark yesterday's message unread on every device before the reply that came overnight
    /// was even seen, and keep the Back tag on the conversation the reply is about.
    func testAtLaunchMailThatCameWhileTheAppWasClosedEndsTheSnoozeFirst() async throws {
        let clock = HandClock()
        let harness = try harness(clock, start: false) { try self.seed($0) }
        let due = clock.now.addingTimeInterval(3_600)
        try snooze(harness, until: due)
        clock.sleepThrough(86_400)
        var reply = Fixtures.message(203, conversation: "later")
        reply.date = due.addingTimeInterval(-1_800)
        harness.provider.enqueueChanges(.success(Fixtures.changes(upserts: [reply], cursor: "c1")))
        harness.engine.start()
        try await waitUntil("the reply is in") { try harness.store.message(MessageID(accountID: self.account, providerID: "203")) != nil }
        try await waitUntil("the snooze ended") { try harness.store.snoozes().isEmpty }
        await settle()
        XCTAssertFalse(try isBack(harness), "a reply ended it: no return, no Back tag")
        XCTAssertEqual(try harness.store.message(MessageID(accountID: account, providerID: "202"))?.isRead, true, "nothing old marked unread")
        XCTAssertFalse(harness.provider.applyCalls.contains { $0.change == .setRead(false) || $0.change == .moveToInbox })
        await harness.shutdown()
    }

    /// The Mac slept through the time and the timer has not fired: waking (`checkForMail`) brings it back.
    func testASnoozeDueWhileTheMacSleptReturnsOnWake() async throws {
        let clock = HandClock()
        let harness = try harness(clock) { try self.seed($0) }
        try snooze(harness, until: clock.now.addingTimeInterval(600))
        try await waitUntil("waiting") { clock.sleeps.count == 1 }
        clock.sleepThrough(3_600)
        await settle()
        XCTAssertFalse(try isBack(harness), "the timer has not fired")
        // What `AppWakeups` calls on `NSWorkspace.didWakeNotification`, on activation and when the network returns.
        harness.engine.checkForMail()
        try await waitUntil("back on waking") { try self.isBack(harness) }
        await harness.shutdown()
    }

    /// Overnight with the lid closed, a reply comes to one snoozed conversation and the other is put back in the Inbox and
    /// read on the phone. At wake the runner waits for the account's check, which brings both in and ends both snoozes:
    /// nothing is returned over them, nothing is marked unread on any device.
    func testMailThatCameWhileTheMacSleptEndsTheSnoozesRatherThanBeingReturnedOver() async throws {
        let clock = HandClock()
        let harness = try harness(clock) {
            try self.seed($0, "reply")
            try $0.upsertMessages([Fixtures.message(301, conversation: "moved", isRead: true)])
        }
        let due = clock.now.addingTimeInterval(7_200)
        try snooze(harness, "reply", until: due)
        try snooze(harness, "moved", until: due)
        try await waitUntil("the archives reached the provider") {
            try harness.store.pendingOperations(accountID: self.account, limit: 10).isEmpty && !harness.provider.applyCalls.isEmpty
        }
        harness.provider.locked { harness.provider.holdChanges = true }
        clock.sleepThrough(10_800)
        var reply = Fixtures.message(203, conversation: "reply")
        reply.date = due.addingTimeInterval(-3_600)
        let moved = Fixtures.message(301, conversation: "moved", roles: [.inbox], isRead: true)
        harness.provider.enqueueChanges(.success(Fixtures.changes(upserts: [reply, moved], cursor: "c1")))

        // The lid opens: `AppWakeups` calls this. The check has not got through yet.
        harness.engine.checkForMail()
        await settle()
        XCTAssertFalse(try isBack(harness, "reply"), "held until the account has checked")
        XCTAssertFalse(try isBack(harness, "moved"))
        XCTAssertEqual(try harness.store.snoozes().count, 2)

        harness.provider.releaseChanges()
        try await waitUntil("both snoozes ended") { try harness.store.snoozes().isEmpty }
        await settle()
        XCTAssertNotNil(try harness.store.message(MessageID(accountID: account, providerID: "203")))
        XCTAssertFalse(try isBack(harness, "reply"), "no Back tag: the reply is what the conversation is about")
        XCTAssertFalse(try isBack(harness, "moved"))
        XCTAssertEqual(try harness.store.message(MessageID(accountID: account, providerID: "202"))?.isRead, true)
        XCTAssertEqual(try harness.store.message(MessageID(accountID: account, providerID: "301"))?.isRead, true, "read on the phone, it stays read")
        XCTAssertFalse(harness.provider.applyCalls.contains { $0.change == .setRead(false) || $0.change == .moveToInbox })
        XCTAssertTrue(try pendingChanges(harness.store).isEmpty)
        await harness.shutdown()
    }

    // MARK: Waiting for the account's check

    /// A check already under way at the time began before it, so it may have missed a reply sent just before: the runner
    /// asks for another and returns once one that began after the time has caught up.
    func testADueSnoozeWaitsForACheckThatBeganAfterItsTime() async throws {
        let clock = HandClock()
        let store = InMemoryMailStore()
        try seed(store)
        let requests = CheckRequests()
        let runner = bareRunner(store, clock, requests)
        try snoozeInStore(store, conversation("later"), until: clock.now.addingTimeInterval(600), at: clock.now)
        runner.liveCheckStarted(account)
        clock.advance(600)
        runner.liveCheckCaughtUp(account)

        let next = await runner.returnDue()
        XCTAssertFalse(try isBack(store))
        XCTAssertEqual(try pendingChanges(store), [.archive], "nothing queued yet")
        XCTAssertEqual(requests.all, [[account]], "its account is asked to check")
        XCTAssertEqual(next, clock.now.addingTimeInterval(SnoozeRunner.checkWait), "and waited on for a minute at most")
        _ = await runner.returnDue()
        XCTAssertEqual(requests.all.count, 1, "asked once")

        checked(runner, account)
        let after = await runner.returnDue()
        XCTAssertNil(after, "nothing else snoozed: no wait")
        XCTAssertTrue(try isBack(store))
        XCTAssertEqual(try pendingChanges(store), [.archive, .moveToInbox, .setRead(false)])
    }

    /// Offline, signed out or failing, the account never checks: what is due comes back after a minute of awake time,
    /// which a sleep in between does not use up (the wait would otherwise run out at wake, before the network is back).
    func testAnAccountThatCannotCheckReturnsAfterAMinuteAwake() async throws {
        let clock = HandClock()
        let store = InMemoryMailStore()
        try seed(store)
        let runner = bareRunner(store, clock, CheckRequests())
        try snoozeInStore(store, conversation("later"), until: clock.now.addingTimeInterval(600), at: clock.now)
        clock.advance(600)
        _ = await runner.returnDue()
        clock.sleepThrough(3_600)
        _ = await runner.returnDue()
        XCTAssertFalse(try isBack(store), "the Mac slept: the minute has not run")
        clock.advance(SnoozeRunner.checkWait - 1)
        let waiting = await runner.returnDue()
        let next = try XCTUnwrap(waiting)
        XCTAssertEqual(next.timeIntervalSince(clock.now), 1, accuracy: 0.001)
        XCTAssertFalse(try isBack(store))
        clock.advance(1)
        let after = await runner.returnDue()
        XCTAssertNil(after)
        XCTAssertTrue(try isBack(store), "back without the check rather than not at all")
    }

    /// The wait is per account: one that has checked since the time returns at once beside one that has not.
    func testOnlyTheAccountThatHasNotCheckedWaits() async throws {
        let clock = HandClock()
        let store = InMemoryMailStore()
        let other = AccountID("other")
        try store.upsertAccount(Fixtures.account(id: other))
        try seed(store)
        try store.upsertMessages([Fixtures.message(301, account: other, conversation: "elsewhere", isRead: true)])
        let requests = CheckRequests()
        let runner = bareRunner(store, clock, requests)
        let due = clock.now.addingTimeInterval(600)
        try snoozeInStore(store, conversation("later"), until: due, at: clock.now)
        try snoozeInStore(store, ConversationID(accountID: other, providerID: "elsewhere"), until: due, at: clock.now)
        clock.advance(600)
        checked(runner, other)
        _ = await runner.returnDue()
        XCTAssertTrue(try isBack(store, "elsewhere"))
        XCTAssertFalse(try isBack(store, "later"))
        XCTAssertEqual(requests.all, [[account]])
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [conversation("later")])
    }

    /// Setting the Mac's clock past the time cannot be seen by a wait on the continuous clock; the engine hears of it.
    func testSettingTheClockPastTheTimeBringsItBack() async throws {
        let clock = HandClock()
        let harness = try harness(clock) { try self.seed($0) }
        try snooze(harness, until: clock.now.addingTimeInterval(3_600))
        try await waitUntil("waiting") { clock.sleeps.count == 1 }
        clock.setWallClock(by: 7_200)
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        try await waitUntil("back once the clock is set") { try self.isBack(harness) }
        await harness.shutdown()
    }

    /// Set back, the clock makes the wait end early; the snooze waits again for what is left rather than coming back.
    func testSettingTheClockBackKeepsItSnoozed() async throws {
        let clock = HandClock()
        let harness = try harness(clock) { try self.seed($0) }
        try snooze(harness, until: clock.now.addingTimeInterval(600))
        try await waitUntil("waiting") { clock.sleeps.count == 1 }
        clock.setWallClock(by: -3_600)
        clock.advance(600)
        try await waitUntil("waiting again") { clock.sleeps.count == 2 }
        XCTAssertEqual(clock.sleeps.last ?? 0, 3_600, accuracy: 0.001)
        XCTAssertFalse(try isBack(harness))
        await harness.shutdown()
    }

    func testAStoppedEngineReturnsNothing() async throws {
        let clock = HandClock()
        let harness = try harness(clock) { try self.seed($0) }
        try snooze(harness, until: clock.now.addingTimeInterval(60))
        try await waitUntil("waiting") { clock.sleeps.count == 1 }
        await harness.engine.stopAndWait()
        clock.advance(120)
        await settle()
        XCTAssertFalse(try isBack(harness))
        XCTAssertEqual(try harness.store.snoozes().count, 1, "it waits for the next launch")
        await harness.shutdown()
    }
}

/// The accounts a runner asked to check, in order.
private final class CheckRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [[AccountID]] = []

    func append(_ accounts: [AccountID]) {
        lock.withLock { asked.append(accounts) }
    }

    var all: [[AccountID]] { lock.withLock { asked } }
}
