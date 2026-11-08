import Foundation
import XCTest
@testable import SSCore

/// When the send runner wakes, on a clock the test moves by hand: it waits for the next held send rather than on a
/// one-second tick, falls back to the background poll interval with nothing held, and keeps a send to its undo window
/// across sleep and changes to the wall clock. Nothing here sleeps for real beyond the moments the runner takes to act.
final class SendRunnerScheduleTests: XCTestCase {
    /// The live lane's background poll interval, which the runner falls back to with nothing held.
    private let fallback: TimeInterval = 30

    /// `engineStore` runs the engine on another store (the SQLite one), which then needs the account too.
    private func startedHarness(_ clock: HandClock, engineStore: MailStoring? = nil,
                                tune: (inout SyncTuning) -> Void = { _ in }) throws -> EngineHarness {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        try engineStore?.upsertAccount(Fixtures.account(id: provider.accountID))
        let harness = try EngineHarness(provider: provider, engineStore: engineStore) {
            $0.pollInterval = self.fallback
            $0.sendClock = clock.sendClock
            tune(&$0)
        }
        harness.engine.start()
        return harness
    }

    /// The `index`th timed wait the runner asks for (0-based), once it has asked.
    private func sleep(_ index: Int, of clock: HandClock, file: StaticString = #filePath, line: UInt = #line) async throws -> TimeInterval {
        try await waitUntil("wait \(index + 1) of the send runner", file: file, line: line) { clock.sleeps.count > index }
        return clock.sleeps[index]
    }

    func testAnEmptyOutboxWaitsForTheBackgroundPollIntervalNotASecond() async throws {
        let clock = HandClock()
        let harness = try startedHarness(clock)
        let first = try await sleep(0, of: clock)
        XCTAssertEqual(first, fallback, accuracy: 0.001)
        // Two minutes of idle, a second at a time: the runner looks at the outbox once per fallback, not per second.
        for _ in 0..<120 {
            let begun = clock.sleeps.count
            if clock.advance(1) > 0 { _ = try await sleep(begun, of: clock) }
        }
        XCTAssertEqual(clock.sleeps.count, 5, "one look at launch and one every 30 s")
        XCTAssertTrue(clock.sleeps.allSatisfy { abs($0 - fallback) < 0.001 }, "\(clock.sleeps)")
        XCTAssertTrue(harness.provider.sendCalls.isEmpty)
        await harness.shutdown()
    }

    func testAQueuedSendWakesTheRunnerAndGoesAtItsTime() async throws {
        let clock = HandClock()
        let harness = try startedHarness(clock)
        _ = try await sleep(0, of: clock)
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 5)
        // No time has passed: the runner read the send because queueing it woke the runner.
        let held = try await sleep(1, of: clock)
        XCTAssertEqual(held, 5, accuracy: 0.001)
        XCTAssertEqual(clock.advance(4.5), 0)
        XCTAssertTrue(harness.provider.sendCalls.isEmpty, "inside the undo window")
        XCTAssertEqual(clock.advance(0.5), 1)
        try await waitUntil("sent at the end of the window") { harness.provider.sendCalls.count == 1 }
        let idle = try await sleep(2, of: clock)
        XCTAssertEqual(idle, fallback, accuracy: 0.001)
        XCTAssertTrue(try harness.store.pendingSends().isEmpty)
        await harness.shutdown()
    }

    /// No undo window, as a send that should go now: it goes without the clock moving at all.
    func testASendWithoutAnUndoWindowGoesAtOnce() async throws {
        let clock = HandClock()
        let harness = try startedHarness(clock)
        _ = try await sleep(0, of: clock)
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 0)
        try await waitUntil("sent at once") { harness.provider.sendCalls.count == 1 }
        await harness.shutdown()
    }

    func testAThrottledSendIsRetriedAtItsRescheduledTime() async throws {
        let clock = HandClock()
        let harness = try startedHarness(clock) {
            $0.backoffCap = 600
            $0.liveBackoffCap = 60
        }
        harness.provider.sendResults = [.failure(ProviderError.throttled(retryAfter: 7))]
        _ = try await sleep(0, of: clock)
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 0)
        // The retry time is counted although the read that claimed the send came before the throttle.
        let retry = try await sleep(1, of: clock)
        XCTAssertEqual(retry, 7, accuracy: 0.001)
        XCTAssertEqual(harness.provider.sendCalls.count, 1)
        XCTAssertEqual(try harness.store.pendingSends().first?.status, .scheduled)
        XCTAssertEqual(clock.advance(6), 0)
        XCTAssertEqual(harness.provider.sendCalls.count, 1)
        XCTAssertEqual(clock.advance(1), 1)
        try await waitUntil("sent on the retry") { harness.provider.sendCalls.count == 2 }
        try await waitUntil("outbox empty") { try harness.store.pendingSends().isEmpty }
        await harness.shutdown()
    }

    /// The Mac slept through the end of the undo window and the timer has not fired: waking sends it.
    func testWakingFromSleepSendsWhatFellDueMeanwhile() async throws {
        let clock = HandClock()
        let harness = try startedHarness(clock)
        _ = try await sleep(0, of: clock)
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 5)
        _ = try await sleep(1, of: clock)
        clock.sleepThrough(60)
        XCTAssertTrue(harness.provider.sendCalls.isEmpty)
        // What `AppWakeups` calls on `NSWorkspace.didWakeNotification`.
        harness.engine.checkForMail()
        try await waitUntil("sent on waking") { harness.provider.sendCalls.count == 1 }
        await harness.shutdown()
    }

    func testSettingTheClockForwardDoesNotCutTheUndoWindowShort() async throws {
        let clock = HandClock()
        let harness = try startedHarness(clock)
        _ = try await sleep(0, of: clock)
        let id = try harness.engine.send(Fixtures.outgoing(), undoWindow: 5)
        _ = try await sleep(1, of: clock)
        clock.setWallClock(by: 3_600)
        // Anything that makes the runner look (here the app coming to the front) finds the send still held.
        harness.engine.checkForMail()
        let held = try await sleep(2, of: clock)
        XCTAssertEqual(held, 5, accuracy: 0.001)
        XCTAssertTrue(harness.provider.sendCalls.isEmpty)
        XCTAssertEqual(try harness.store.pendingSends().first?.status, .scheduled)
        XCTAssertEqual(clock.advance(5), 1)
        try await waitUntil("sent at the end of the window") { harness.provider.sendCalls.count == 1 }
        XCTAssertFalse(try harness.engine.cancelSend(id: id))
        await harness.shutdown()
    }

    func testSettingTheClockBackDoesNotHoldASendPastItsTime() async throws {
        let clock = HandClock()
        let harness = try startedHarness(clock)
        _ = try await sleep(0, of: clock)
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 5)
        _ = try await sleep(1, of: clock)
        clock.setWallClock(by: -3_600)
        XCTAssertEqual(clock.advance(5), 1)
        try await waitUntil("sent at the end of the window") { harness.provider.sendCalls.count == 1 }
        await harness.shutdown()
    }

    /// A send stored without waking the runner is still picked up, at the fallback at the latest.
    func testASendStoredWithoutAWakeGoesWithinTheFallback() async throws {
        let clock = HandClock()
        let harness = try startedHarness(clock)
        _ = try await sleep(0, of: clock)
        try harness.store.enqueueSend(PendingSend(message: Fixtures.outgoing(), sendAfter: clock.now))
        XCTAssertEqual(clock.advance(fallback - 1), 0)
        XCTAssertTrue(harness.provider.sendCalls.isEmpty)
        XCTAssertEqual(clock.advance(1), 1)
        try await waitUntil("sent at the fallback") { harness.provider.sendCalls.count == 1 }
        await harness.shutdown()
    }

    /// A held send the last run left in the outbox is timed from launch.
    func testAHeldSendFromThePreviousRunIsTimedFromLaunch() async throws {
        let clock = HandClock()
        let harness = try harnessWithSendFromThePreviousRun(clock, dueIn: 10)
        let first = try await sleep(0, of: clock)
        XCTAssertEqual(first, 10, accuracy: 0.001)
        XCTAssertEqual(clock.advance(10), 1)
        try await waitUntil("sent at its time") { harness.provider.sendCalls.count == 1 }
        await harness.shutdown()
    }

    /// An engine started on an outbox that holds a send due `dueIn` seconds from now by the wall clock, as a previous
    /// run left it. The retry caps are production's, since they bound how long such a send is held.
    private func harnessWithSendFromThePreviousRun(_ clock: HandClock, dueIn: TimeInterval) throws -> EngineHarness {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        let defaults = SyncTuning()
        let harness = try EngineHarness(provider: provider) {
            $0.pollInterval = self.fallback
            $0.backoffCap = defaults.backoffCap
            $0.liveBackoffCap = defaults.liveBackoffCap
            $0.sendClock = clock.sendClock
        }
        try harness.store.enqueueSend(PendingSend(message: Fixtures.outgoing(), sendAfter: clock.now.addingTimeInterval(dueIn)))
        harness.engine.start()
        return harness
    }

    /// The clock moved while the runner was busy delivering another send, before it first read this one: the window
    /// still runs from when the send was queued. Also on the SQLite store, which keeps `sendAfter` to the millisecond,
    /// with a wall clock that has digits below it as `Date()` does, so the time read back differs from the one queued.
    private func checkWindowSurvivesClockSetDuringAnotherDelivery(by jump: TimeInterval, file: StaticString = #filePath,
                                                                 line: UInt = #line) async throws {
        try await checkWindowSurvivesClockSetDuringAnotherDelivery(by: jump, clock: HandClock(), engineStore: nil,
                                                                   file: file, line: line)
        try await checkWindowSurvivesClockSetDuringAnotherDelivery(
            by: jump, clock: HandClock(wallStart: Date(timeIntervalSinceReferenceDate: 800_000_000.123_456_7)),
            engineStore: try SQLiteMailStore.inMemory(), file: file, line: line
        )
    }

    private func checkWindowSurvivesClockSetDuringAnotherDelivery(by jump: TimeInterval, clock: HandClock,
                                                                 engineStore: MailStoring?, file: StaticString,
                                                                 line: UInt) async throws {
        let harness = try startedHarness(clock, engineStore: engineStore)
        _ = try await sleep(0, of: clock)
        harness.provider.holdSends = true
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 0)
        try await waitUntil("the first send in flight") { harness.provider.sendCalls.count == 1 }
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 20)
        clock.setWallClock(by: jump)
        let begun = clock.sleeps.count
        harness.provider.holdSends = false
        let held = try await sleep(begun, of: clock, file: file, line: line)
        XCTAssertEqual(held, 20, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(harness.provider.sendCalls.count, 1, "inside the undo window", file: file, line: line)
        XCTAssertEqual(clock.advance(19.5), 0, file: file, line: line)
        XCTAssertEqual(harness.provider.sendCalls.count, 1, file: file, line: line)
        XCTAssertEqual(clock.advance(0.5), 1, file: file, line: line)
        try await waitUntil("sent at the end of the window", file: file, line: line) { harness.provider.sendCalls.count == 2 }
        await harness.shutdown()
    }

    func testSettingTheClockBackDuringAnotherDeliveryDoesNotHoldASendPastItsWindow() async throws {
        try await checkWindowSurvivesClockSetDuringAnotherDelivery(by: -300)
    }

    func testSettingTheClockForwardDuringAnotherDeliveryDoesNotCutTheWindowShort() async throws {
        try await checkWindowSurvivesClockSetDuringAnotherDelivery(by: 300)
    }

    /// The clock was set back an hour between runs, so the stored send time is an hour off: the send waits no longer
    /// than the runner ever holds one itself, a throttle's retry.
    func testAHeldSendFromThePreviousRunWaitsNoLongerThanTheRetryCap() async throws {
        let clock = HandClock()
        let harness = try harnessWithSendFromThePreviousRun(clock, dueIn: 3_600)
        let provider = harness.provider
        let cap = SyncTuning().userRetryAfterCap
        _ = try await sleep(0, of: clock)
        var waited: TimeInterval = 0
        while waited + fallback < cap {
            let begun = clock.sleeps.count
            XCTAssertEqual(clock.advance(fallback), 1)
            waited += fallback
            _ = try await sleep(begun, of: clock)
            XCTAssertTrue(provider.sendCalls.isEmpty, "held at \(waited) s")
        }
        XCTAssertEqual(clock.advance(cap - waited), 1)
        try await waitUntil("sent at the cap") { provider.sendCalls.count == 1 }
        await harness.shutdown()
    }

    /// Quitting while a send uploads stops the runner there: a send that fell due meanwhile is not claimed under the
    /// cancelled task (where it would fail as "cancelled") but stays held for the next launch.
    func testStoppingMidDeliveryLeavesASendThatFellDueMeanwhileForTheNextRun() async throws {
        let clock = HandClock()
        let harness = try startedHarness(clock)
        _ = try await sleep(0, of: clock)
        harness.provider.holdSends = true
        let first = try harness.engine.send(Fixtures.outgoing(), undoWindow: 0)
        try await waitUntil("the first send in flight") { harness.provider.sendCalls.count == 1 }
        let second = try harness.engine.send(Fixtures.outgoing(), undoWindow: 0)
        await harness.engine.stopAndWait()
        let sends = try harness.store.pendingSends()
        XCTAssertEqual(sends.first { $0.id == first }?.status, .failed, "the upload the quit cut off")
        let left = try XCTUnwrap(sends.first { $0.id == second })
        XCTAssertEqual(left.status, .scheduled)
        XCTAssertEqual(left.attempts, 0)
        XCTAssertEqual(harness.provider.sendCalls.count, 1, "the second send never reached the provider")
        await harness.shutdown()
    }

    /// Two sends fall due in the same read and the quit lands while the first uploads: the second, claimed with it but
    /// never handed to the provider, goes back to the outbox as it was rather than failing as "cancelled".
    func testStoppingMidDeliveryLeavesASendClaimedWithItForTheNextRun() async throws {
        let clock = HandClock()
        let harness = try startedHarness(clock)
        _ = try await sleep(0, of: clock)
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 5)
        _ = try await sleep(1, of: clock)
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 5)
        _ = try await sleep(2, of: clock)
        harness.provider.holdSends = true
        XCTAssertEqual(clock.advance(5), 1)
        try await waitUntil("the first send in flight") { harness.provider.sendCalls.count == 1 }
        await harness.engine.stopAndWait()
        let sends = try harness.store.pendingSends()
        XCTAssertEqual(sends.filter { $0.status == .failed }.count, 1, "the upload the quit cut off")
        let left = sends.filter { $0.status == .scheduled }
        XCTAssertEqual(left.count, 1, "\(sends.map(\.status))")
        XCTAssertEqual(left.first?.attempts, 0)
        XCTAssertEqual(harness.provider.sendCalls.count, 1, "the second send never reached the provider")
        await harness.shutdown()
    }

    /// Undo needs no wake: the runner looks at the cancelled send's time, finds nothing, and goes back to idle.
    func testACancelledSendLeavesTheRunnerIdle() async throws {
        let clock = HandClock()
        let harness = try startedHarness(clock)
        _ = try await sleep(0, of: clock)
        let id = try harness.engine.send(Fixtures.outgoing(), undoWindow: 5)
        _ = try await sleep(1, of: clock)
        XCTAssertTrue(try harness.engine.cancelSend(id: id))
        XCTAssertEqual(clock.advance(5), 1)
        let idle = try await sleep(2, of: clock)
        XCTAssertEqual(idle, fallback, accuracy: 0.001)
        XCTAssertTrue(harness.provider.sendCalls.isEmpty)
        await harness.shutdown()
    }
}

/// Time the test moves by hand, for the send runner: the wall clock, the continuous clock beside it, and sleeps that
/// end only when `advance` carries the continuous clock past them, or their task is cancelled.
private final class HandClock: @unchecked Sendable {
    private struct Sleeper {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var wall: Date
    private var continuous: TimeInterval = 1_000
    private var sleepers: [UUID: Sleeper] = [:]
    private var requested: [TimeInterval] = []

    // Integral starts keep the arithmetic exact, so expected waits compare tightly.
    init(wallStart: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) {
        wall = wallStart
    }

    var sendClock: SendClock {
        SendClock(now: { self.now }, uptime: { self.uptime }, sleep: { try await self.sleep($0) })
    }

    var now: Date { lock.withLock { wall } }
    var uptime: TimeInterval { lock.withLock { continuous } }
    /// Every timed wait the runner has begun, in order.
    var sleeps: [TimeInterval] { lock.withLock { requested } }

    /// Moves both clocks and ends the sleeps now due. Returns how many it ended.
    @discardableResult
    func advance(_ seconds: TimeInterval) -> Int {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            continuous += seconds
            wall = wall.addingTimeInterval(seconds)
            let ids = sleepers.filter { $0.value.deadline <= continuous }.map(\.key)
            return ids.compactMap { sleepers.removeValue(forKey: $0)?.continuation }
        }
        due.forEach { $0.resume() }
        return due.count
    }

    /// The Mac slept: both clocks moved on, and no timer has fired yet.
    func sleepThrough(_ seconds: TimeInterval) {
        lock.withLock {
            continuous += seconds
            wall = wall.addingTimeInterval(seconds)
        }
    }

    /// Someone set the Mac's clock: the wall clock moves alone.
    func setWallClock(by seconds: TimeInterval) {
        lock.withLock { wall = wall.addingTimeInterval(seconds) }
    }

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Checked under the lock the cancellation handler takes, so a cancel cannot slip in between.
                let outcome: Result<Void, Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    requested.append(seconds)
                    if seconds <= 0 { return .success(()) }
                    sleepers[id] = Sleeper(deadline: continuous + seconds, continuation: continuation)
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let continuation = lock.withLock { sleepers.removeValue(forKey: id)?.continuation }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
