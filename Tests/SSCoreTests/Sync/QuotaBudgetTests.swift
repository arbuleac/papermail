import Foundation
import XCTest
@testable import SSCore

/// The backfill pacing, run on a hand-moved clock: every wait is recorded and moves the clock by its length, so
/// minutes of pacing are checked in simulated seconds without real waiting.
final class QuotaBudgetTests: XCTestCase {
    /// 600 units a minute, all of it for the backfill: 10 units/s at full rate, 5 at the starting half rate, and a
    /// bucket of 150 (15 s at full rate).
    private let quota = ProviderQuota(unitsPerMinute: 600, backfillShare: 1, listCost: 1, metadataCostPerMessage: 1,
                                      bodyCost: 1, changesCost: 1, maxBackfillConcurrency: 2)

    // MARK: Quotas

    func testStandardQuotasCarryTheProvidersNumbers() {
        let gmail = ProviderQuota.standard(for: .gmail)
        XCTAssertEqual(gmail.unitsPerMinute, 6_000)
        XCTAssertEqual(gmail.backfillShare, 2.0 / 3.0)
        XCTAssertEqual(gmail.listCost, 5)
        XCTAssertEqual(gmail.metadataCostPerMessage, 20)
        XCTAssertEqual(gmail.bodyCost, 60)
        XCTAssertEqual(gmail.changesCost, 2)
        XCTAssertEqual(gmail.maxBackfillConcurrency, 2)

        let microsoft = ProviderQuota.standard(for: .microsoft)
        XCTAssertEqual(microsoft.unitsPerMinute, 1_000)
        XCTAssertEqual(microsoft.backfillShare, 2.0 / 3.0)
        XCTAssertEqual(microsoft.listCost, 1)
        XCTAssertEqual(microsoft.metadataCostPerMessage, 1, "each request inside a $batch counts on its own")
        XCTAssertEqual(microsoft.bodyCost, 2)
        XCTAssertEqual(microsoft.changesCost, 1)
        XCTAssertEqual(microsoft.maxBackfillConcurrency, 2)
    }

    // MARK: Pacing

    func testSteadyPacingMatchesTheConfiguredRate() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        // The bucket starts full, so the first 15 s worth goes at once.
        try await budget.acquireBackfill(150)
        XCTAssertEqual(clock.sleeps, [])

        for _ in 0..<20 { try await budget.acquireBackfill(10) }
        // 200 units at half of 10 units/s: 40 s, in even 2 s steps.
        assertSleeps(clock, Array(repeating: 2, count: 20))
        XCTAssertEqual(clock.elapsed, 40, accuracy: 1e-6)
    }

    func testGmailPacesATenPartMetadataBatchAtHalfItsShareAtFirst() async throws {
        let clock = ManualClock()
        let budget = clock.budget(.standard(for: .gmail))
        // A full bucket is 15 s of 4,000 units a minute.
        try await budget.acquireBackfill(1_000)
        XCTAssertEqual(clock.sleeps, [])
        // Ten messages at 20 units each, at 2,000 units a minute.
        try await budget.acquireBackfill(10 * 20)
        assertSleeps(clock, [6])
    }

    func testLiveSpendDelaysTheBackfillWithoutWaitingItself() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        try await budget.acquireBackfill(150)

        await budget.recordLive(50)
        XCTAssertEqual(clock.sleeps, [], "the live lane never waits")
        // 50 owed plus the 10 wanted, at 5 units/s.
        try await budget.acquireBackfill(10)
        assertSleeps(clock, [12])
    }

    func testLiveSpendWhileTheBackfillWaitsExtendsTheWait() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        try await budget.acquireBackfill(150)
        clock.onNextSleep { await budget.recordLive(20) }

        try await budget.acquireBackfill(10)
        // Planned 2 s for 10 units; the 20 the live lane spent meanwhile take 4 s more.
        assertSleeps(clock, [2, 4])
    }

    func testLiveDebtIsFlooredSoABurstCannotStarveTheBackfill() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        try await budget.acquireBackfill(150)

        await budget.recordLive(1_000_000)
        try await budget.acquireBackfill(10)
        // The debt stops at four buckets (600). Paying it and the 10 wanted takes 60 s at 5 units/s, then the
        // rate's first recovery step lifts it to 6 units/s for the remaining 310.
        assertSleeps(clock, [60, 310.0 / 6.0])
    }

    func testCostAboveCapacityWaitsForAFullBucketAndGoesIntoDebt() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        // Five quiet minutes bring the rate to full (10 units/s), so the arithmetic below has no recovery steps.
        clock.advance(300)
        let rateFraction = await budget.rateFraction
        XCTAssertEqual(rateFraction, 1, accuracy: 1e-9)

        try await budget.acquireBackfill(400)
        XCTAssertEqual(clock.sleeps, [], "a full bucket lets an oversized cost through at once")
        try await budget.acquireBackfill(400)
        // 250 owed, then a full bucket of 150 before it may go again.
        assertSleeps(clock, [40])
        try await budget.acquireBackfill(10)
        assertSleeps(clock, [40, 26])
    }

    func testCallersAreServedInArrivalOrderWhateverTheyCost() async throws {
        let clock = ManualClock()
        let budget = clock.budget(.standard(for: .gmail))
        try await budget.acquireBackfill(1_000)
        // The first caller's wait holds until both later callers have queued behind it.
        clock.onNextSleep {
            let deadline = Date().addingTimeInterval(5)
            while await budget.backfillUnitWaiters < 2, Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        }

        let body = Task { try await budget.acquireBackfill(60) }
        await waitUntil { clock.sleeps.count == 1 }
        // A ten-part metadata batch and its listing, then another body.
        let batch = Task { try await budget.acquireBackfill(205) }
        await waitUntil { await budget.backfillUnitWaiters == 1 }
        let laterBody = Task { try await budget.acquireBackfill(60) }
        try await body.value
        try await batch.value
        try await laterBody.value

        // At 2,000 units a minute: the first body, then the batch, and only then the later, cheaper body, which
        // would otherwise have woken first and taken the refill the batch was waiting for.
        assertSleeps(clock, [1.8, 6.15, 1.8])
        let waiting = await budget.backfillUnitWaiters
        XCTAssertEqual(waiting, 0)
    }

    // MARK: Throttles

    func testThrottleHalvesTheRateAndPausesUntilRetryAfter() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        let start = clock.now
        let initialFraction = await budget.rateFraction
        XCTAssertEqual(initialFraction, 0.5)

        let resume = await budget.backfillThrottled(retryAfter: 30)
        XCTAssertEqual(resume, start.addingTimeInterval(30))
        let pausedUntil = await budget.pausedUntil
        XCTAssertEqual(pausedUntil, resume)
        let throttledFraction = await budget.rateFraction
        XCTAssertEqual(throttledFraction, 0.25)

        // The bucket was full, but a throttle drops its credit: after the pause, 10 units at 2.5 units/s.
        try await budget.acquireBackfill(10)
        assertSleeps(clock, [30, 4])
        let pausedAfter = await budget.pausedUntil
        XCTAssertNil(pausedAfter)
    }

    func testRetryAfterIsAtLeastASecondAndBounded() async {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        let zero = await budget.backfillThrottled(retryAfter: 0)
        XCTAssertEqual(zero.timeIntervalSince(clock.now), 1)

        clock.advance(1)
        let huge = await budget.backfillThrottled(retryAfter: 1e12)
        XCTAssertEqual(huge.timeIntervalSince(clock.now), 3_600)
    }

    func testThrottlesWhileAlreadyPausedCountAsTheSameEvent() async {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        let start = clock.now
        let first = await budget.backfillThrottled(retryAfter: nil)
        XCTAssertEqual(first, start.addingTimeInterval(15))

        // The other request that was in flight comes back throttled too.
        clock.advance(2)
        let second = await budget.backfillThrottled(retryAfter: nil)
        XCTAssertEqual(second, first)
        let fraction = await budget.rateFraction
        XCTAssertEqual(fraction, 0.25, "halved once, not twice")

        // A longer retry time still extends the pause.
        let third = await budget.backfillThrottled(retryAfter: 40)
        XCTAssertEqual(third, start.addingTimeInterval(42))

        // The next throttle after the pause is only the second of the run: 30 s, not 60.
        clock.advance(40)
        let next = await budget.backfillThrottled(retryAfter: nil)
        XCTAssertEqual(next.timeIntervalSince(clock.now), 30)
    }

    func testPauseWithoutRetryAfterDoublesUpToTenMinutesAndResetsOnSuccess() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        for expected: TimeInterval in [15, 30, 60, 120, 240, 480, 600, 600] {
            let resume = await budget.backfillThrottled(retryAfter: nil)
            XCTAssertEqual(resume.timeIntervalSince(clock.now), expected)
            // Throttled again the moment the pause ends: no quiet time, so no recovery in between.
            clock.advance(expected)
        }
        let floored = await budget.rateFraction
        XCTAssertEqual(floored, 0.05, accuracy: 1e-12, "halving stops at the floor")

        // A request let through after the pause goes through: the schedule starts again.
        try await budget.acquireBackfill(1)
        await budget.backfillSucceeded()
        let afterSuccess = await budget.backfillThrottled(retryAfter: nil)
        XCTAssertEqual(afterSuccess.timeIntervalSince(clock.now), 15)
    }

    func testASuccessFromBeforeTheThrottleDoesNotRestartThePauseSchedule() async {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        let first = await budget.backfillThrottled(retryAfter: nil)
        XCTAssertEqual(first.timeIntervalSince(clock.now), 15)

        // The other request in flight, sent before the throttle, comes back fine during the pause.
        clock.advance(1)
        await budget.backfillSucceeded()
        // And one more after the pause, before anything new was let through.
        clock.advance(14)
        await budget.backfillSucceeded()

        let second = await budget.backfillThrottled(retryAfter: nil)
        XCTAssertEqual(second.timeIntervalSince(clock.now), 30)
    }

    func testRateRecoversATenthPerQuietMinuteAfterThePause() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        await budget.backfillThrottled(retryAfter: 300)

        // A pause is not quiet time: recovery starts when it ends.
        clock.advance(300)
        var fraction = await budget.rateFraction
        XCTAssertEqual(fraction, 0.25, accuracy: 1e-12)

        clock.advance(59)
        fraction = await budget.rateFraction
        XCTAssertEqual(fraction, 0.25, accuracy: 1e-12)
        clock.advance(1)
        fraction = await budget.rateFraction
        XCTAssertEqual(fraction, 0.35, accuracy: 1e-12)
        clock.advance(60)
        fraction = await budget.rateFraction
        XCTAssertEqual(fraction, 0.45, accuracy: 1e-12)
        clock.advance(600)
        fraction = await budget.rateFraction
        XCTAssertEqual(fraction, 1, accuracy: 1e-12, "recovery stops at full rate")

        // Pacing follows the recovered rate: 10 units/s once the bucket is empty.
        try await budget.acquireBackfill(150)
        XCTAssertEqual(clock.sleeps, [])
        try await budget.acquireBackfill(10)
        assertSleeps(clock, [1])
    }

    // MARK: Live throttles

    /// Both lanes spend one quota, so a throttle on the live lane pauses the backfill exactly as one of its own: the
    /// rate halves, the credit goes, and the backfill's next units wait for the provider's retry time.
    func testALiveThrottlePausesTheBackfillUntilRetryAfter() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        let start = clock.now

        let resume = await budget.liveThrottled(retryAfter: 30)
        XCTAssertEqual(resume, start.addingTimeInterval(30))
        let pausedUntil = await budget.pausedUntil
        XCTAssertEqual(pausedUntil, resume)
        let fraction = await budget.rateFraction
        XCTAssertEqual(fraction, 0.25)

        // The bucket was full; after the pause, 10 units at 2.5 units/s.
        try await budget.acquireBackfill(10)
        assertSleeps(clock, [30, 4])
    }

    /// Without a retry time a live throttle takes the backfill's own schedule, and the two count as one run: 15 s,
    /// then 30 s for the next throttle on either lane.
    func testALiveThrottleWithoutRetryAfterTakesTheBackfillsSchedule() async {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        let first = await budget.liveThrottled(retryAfter: nil)
        XCTAssertEqual(first.timeIntervalSince(clock.now), 15)
        clock.advance(15)
        let second = await budget.backfillThrottled(retryAfter: nil)
        XCTAssertEqual(second.timeIntervalSince(clock.now), 30)
        clock.advance(30)
        let third = await budget.liveThrottled(retryAfter: nil)
        XCTAssertEqual(third.timeIntervalSince(clock.now), 60)
    }

    /// Once the download has finished no backfill request goes through to end a run of throttles, so live throttles
    /// hours apart are separate incidents: ten quiet minutes after a pause start the schedule again, whether or not
    /// a throttle in between named a retry time. Inside those ten minutes the run goes on.
    func testThrottlesTenQuietMinutesApartStartTheScheduleAgain() async {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        var pauses: [TimeInterval] = []
        for retryAfter: TimeInterval? in [nil, 20, nil, nil, 20, nil, nil] {
            let pause = await budget.liveThrottled(retryAfter: retryAfter).timeIntervalSince(clock.now)
            pauses.append(pause)
            clock.advance(pause + 3 * 3_600)
        }
        XCTAssertEqual(pauses, [15, 20, 15, 15, 20, 15, 15])

        let first = await budget.liveThrottled(retryAfter: nil)
        XCTAssertEqual(first.timeIntervalSince(clock.now), 15)
        clock.advance(15 + 599)
        let second = await budget.backfillThrottled(retryAfter: nil)
        XCTAssertEqual(second.timeIntervalSince(clock.now), 30, "under ten quiet minutes: the same run")
        clock.advance(30 + 600)
        let third = await budget.liveThrottled(retryAfter: nil)
        XCTAssertEqual(third.timeIntervalSince(clock.now), 15, "ten quiet minutes: a new run")
    }

    /// One burst throttles both lanes: whichever comes back first, the other lands inside its pause and is the same
    /// event. The rate halves once, and a longer retry time only lengthens the pause.
    func testLiveAndBackfillThrottlesFromOneBurstHalveOnce() async {
        let clock = ManualClock()
        let liveFirst = clock.budget(quota)
        let start = clock.now
        let live = await liveFirst.liveThrottled(retryAfter: nil)
        clock.advance(1)
        let backfill = await liveFirst.backfillThrottled(retryAfter: nil)
        XCTAssertEqual(backfill, live)
        XCTAssertEqual(live, start.addingTimeInterval(15))
        var fraction = await liveFirst.rateFraction
        XCTAssertEqual(fraction, 0.25, "halved once, not twice")

        let backfillFirst = clock.budget(quota)
        let later = clock.now
        await backfillFirst.backfillThrottled(retryAfter: 10)
        clock.advance(2)
        let extended = await backfillFirst.liveThrottled(retryAfter: 20)
        XCTAssertEqual(extended, later.addingTimeInterval(22), "the longer retry time")
        fraction = await backfillFirst.rateFraction
        XCTAssertEqual(fraction, 0.25, "halved once, not twice")
        // The next throttle after that pause is only the second of the run: 30 s, not 60.
        clock.advance(20)
        let next = await backfillFirst.liveThrottled(retryAfter: nil)
        XCTAssertEqual(next.timeIntervalSince(clock.now), 30)
    }

    /// The backfill lane shows a pause only while one of its requests waits through it: a pause no backfill request
    /// meets says nothing, and one that a request meets is heard of when it arrives and ends as it is let through.
    func testAPauseIsHeardOfOnlyWhileABackfillRequestWaitsThroughIt() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        let heard = PauseLog()
        await budget.observePauses { heard.append($0) }

        let first = await budget.liveThrottled(retryAfter: 30)
        clock.advance(40)
        try await budget.acquireBackfill(1)
        XCTAssertEqual(heard.values, [], "over before the backfill asked: nothing to show")

        let second = await budget.liveThrottled(retryAfter: 30)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(heard.values, [], "no backfill request waits yet")
        clock.advance(5)
        try await budget.acquireBackfill(1)
        XCTAssertEqual(heard.values, [second, nil])
    }

    /// A live throttle while a backfill request waits for its units shows at once, before that wait ends; the request
    /// then waits out the pause and goes at the halved rate.
    func testALiveThrottleWhileTheBackfillWaitsForUnitsIsHeardOfAtOnce() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        let heard = PauseLog()
        await budget.observePauses { heard.append($0) }
        try await budget.acquireBackfill(150)
        let start = clock.now
        let heardDuringTheWait = PauseLog()
        clock.onNextSleep {
            await budget.liveThrottled(retryAfter: 30)
            for value in heard.values { heardDuringTheWait.append(value) }
        }

        try await budget.acquireBackfill(10)
        let resume = start.addingTimeInterval(30)
        XCTAssertEqual(heardDuringTheWait.values, [resume])
        XCTAssertEqual(heard.values, [resume, nil])
        // 2 s planned for its units, the rest of the pause, then 10 units at 2.5 units/s.
        assertSleeps(clock, [2, 28, 4])
    }

    func testAClockThatStepsBackNeitherStallsPacingNorStretchesAPause() async throws {
        let clock = ManualClock()
        let budget = clock.budget(.standard(for: .gmail))
        try await budget.acquireBackfill(1_000)
        clock.advance(-3_600)
        // 200 units at 2,000 units a minute, as if the clock had never moved.
        try await budget.acquireBackfill(200)
        assertSleeps(clock, [6])

        await budget.backfillThrottled(retryAfter: 30)
        clock.advance(-3_600)
        let pausedUntil = await budget.pausedUntil
        XCTAssertEqual(pausedUntil, clock.now.addingTimeInterval(30), "the pause still ends 30 s after the throttle")
        // Then 50 units at the halved 1,000 units a minute.
        try await budget.acquireBackfill(50)
        assertSleeps(clock, [6, 30, 3])
    }

    func testAFreshBudgetClimbsFromHalfToFullRate() async {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        var observed: [Double] = []
        for _ in 0...6 {
            observed.append(await budget.rateFraction)
            clock.advance(60)
        }
        for (value, expected) in zip(observed, [0.5, 0.6, 0.7, 0.8, 0.9, 1, 1]) {
            XCTAssertEqual(value, expected, accuracy: 1e-12)
        }
    }

    // MARK: Cancellation

    func testCancellationWhileWaitingForUnitsThrowsAndSpendsNothing() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        try await budget.acquireBackfill(150)

        // The parked sleep swallows the cancellation, so only the budget's own check after the sleep can end it.
        clock.parksSleeps = true
        let waiter = Task { try await budget.acquireBackfill(100) }
        await waitUntil { clock.sleeps.count == 1 }
        waiter.cancel()
        await assertCancelled(waiter)
        clock.parksSleeps = false

        // Nothing was spent: 10 s at 5 units/s buys exactly the 50 below, with no wait.
        clock.advance(10)
        let sleepsBefore = clock.sleeps.count
        try await budget.acquireBackfill(50)
        XCTAssertEqual(clock.sleeps.count, sleepsBefore)
    }

    func testTheDefaultSleepEndsAWaitAsSoonAsTheTaskIsCancelled() async {
        let budget = QuotaBudget(quota: quota)
        try? await budget.acquireBackfill(150)
        // 100 units would take 20 real seconds at 5 units/s.
        let waiter = Task { try await budget.acquireBackfill(100) }
        try? await Task.sleep(for: .milliseconds(50))
        let start = Date()
        waiter.cancel()
        await assertCancelled(waiter)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCancelledCallersSpendNothingAndTheTurnPassesOn() async throws {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        try await budget.acquireBackfill(150)

        clock.parksSleeps = true
        let served = Task { try await budget.acquireBackfill(100) }
        await waitUntil { clock.sleeps.count == 1 }
        let queued = Task { try await budget.acquireBackfill(10) }
        await waitUntil { await budget.backfillUnitWaiters == 1 }
        let last = Task { try await budget.acquireBackfill(20) }
        await waitUntil { await budget.backfillUnitWaiters == 2 }

        queued.cancel()
        await assertCancelled(queued)
        let afterQueued = await budget.backfillUnitWaiters
        XCTAssertEqual(afterQueued, 1, "the cancelled caller left the queue")

        clock.parksSleeps = false
        served.cancel()
        await assertCancelled(served)
        // The caller being served handed its turn on: 20 units at 5 units/s from an empty bucket.
        try await last.value
        assertSleeps(clock, [20, 4])
        let afterAll = await budget.backfillUnitWaiters
        XCTAssertEqual(afterAll, 0)

        // Neither cancelled caller spent anything: 10 s at 5 units/s buys exactly the 50 below, with no wait.
        clock.advance(10)
        try await budget.acquireBackfill(50)
        assertSleeps(clock, [20, 4])
    }

    func testCancellationWhilePausedThrows() async {
        let clock = ManualClock()
        let budget = clock.budget(quota)
        await budget.backfillThrottled(retryAfter: 60)
        clock.parksSleeps = true
        let waiter = Task { try await budget.acquireBackfill(1) }
        await waitUntil { clock.sleeps.count == 1 }
        XCTAssertEqual(clock.sleeps, [60])
        waiter.cancel()
        await assertCancelled(waiter)
    }

    // MARK: Slots

    func testSlotsCapConcurrencyAndHandOverFirstComeFirstServed() async throws {
        let budget = QuotaBudget(quota: quota)
        try await budget.acquireBackfillSlot()
        try await budget.acquireBackfillSlot()
        let held = await budget.backfillSlotsInUse
        XCTAssertEqual(held, 2)

        let log = OrderLog()
        var waiters: [Task<Void, Error>] = []
        for name in ["a", "b", "c"] {
            waiters.append(Task {
                try await budget.acquireBackfillSlot()
                await log.append(name)
            })
            // Queue them one at a time so their order is the order they asked in.
            let queued = waiters.count
            await waitUntil { await budget.backfillSlotWaiters == queued }
        }
        let early = await log.names
        XCTAssertEqual(early, [], "nobody gets past a full set of slots")

        // Slots carry no owner, so the test releases on the waiters' behalf once its own two are handed on.
        for (released, expected) in [["a"], ["a", "b"], ["a", "b", "c"]].enumerated() {
            await budget.releaseBackfillSlot()
            await waitUntil { await log.names.count == released + 1 }
            let names = await log.names
            XCTAssertEqual(names, expected)
            let inUse = await budget.backfillSlotsInUse
            XCTAssertEqual(inUse, 2, "a released slot goes straight to the next waiter")
        }
        for waiter in waiters { try await waiter.value }

        await budget.releaseBackfillSlot()
        await budget.releaseBackfillSlot()
        let idle = await budget.backfillSlotsInUse
        XCTAssertEqual(idle, 0)
    }

    func testNoMoreThanTheCapAreEverInFlight() async throws {
        let budget = QuotaBudget(quota: quota)
        let gauge = ConcurrencyGauge()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await budget.acquireBackfillSlot()
                    await gauge.enter()
                    for _ in 0..<5 { await Task.yield() }
                    await gauge.leave()
                    await budget.releaseBackfillSlot()
                }
            }
            try await group.waitForAll()
        }
        let peak = await gauge.peak
        XCTAssertLessThanOrEqual(peak, 2)
        let idle = await budget.backfillSlotsInUse
        XCTAssertEqual(idle, 0)
    }

    func testACancelledSlotWaiterNeitherLeaksNorTakesASlot() async throws {
        let budget = QuotaBudget(quota: quota)
        try await budget.acquireBackfillSlot()
        try await budget.acquireBackfillSlot()

        let log = OrderLog()
        var waiters: [String: Task<Void, Error>] = [:]
        for name in ["a", "b", "c"] {
            waiters[name] = Task {
                try await budget.acquireBackfillSlot()
                await log.append(name)
            }
            let queued = waiters.count
            await waitUntil { await budget.backfillSlotWaiters == queued }
        }

        waiters["b"]?.cancel()
        if let cancelled = waiters["b"] { await assertCancelled(cancelled) }
        let remaining = await budget.backfillSlotWaiters
        XCTAssertEqual(remaining, 2)
        let inUse = await budget.backfillSlotsInUse
        XCTAssertEqual(inUse, 2, "the cancelled waiter took nothing")

        await budget.releaseBackfillSlot()
        try await waiters["a"]?.value
        await budget.releaseBackfillSlot()
        try await waiters["c"]?.value
        let names = await log.names
        XCTAssertEqual(names, ["a", "c"])

        await budget.releaseBackfillSlot()
        await budget.releaseBackfillSlot()
        let idle = await budget.backfillSlotsInUse
        XCTAssertEqual(idle, 0)
    }

    func testAnAlreadyCancelledTaskGetsNoSlotEvenWhenOneIsFree() async {
        let budget = QuotaBudget(quota: quota)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await budget.acquireBackfillSlot()
        }
        await assertCancelled(task)
        let inUse = await budget.backfillSlotsInUse
        XCTAssertEqual(inUse, 0)
    }

    // MARK: Unlimited

    func testUnlimitedNeverSleeps() async throws {
        let clock = ManualClock()
        let budget = clock.budget(.unlimited)
        for _ in 0..<1_000 { try await budget.acquireBackfill(1_000_000) }
        await budget.recordLive(.greatestFiniteMagnitude)
        try await budget.acquireBackfill(.infinity)
        try await budget.acquireBackfill(1)
        XCTAssertEqual(clock.sleeps, [])
        let paused = await budget.pausedUntil
        XCTAssertNil(paused)

        for _ in 0..<ProviderQuota.unlimited.maxBackfillConcurrency { try await budget.acquireBackfillSlot() }
        let waiting = await budget.backfillSlotWaiters
        XCTAssertEqual(waiting, 0)
    }

    func testUnlimitedDoesNotPauseOnAThrottle() async throws {
        let clock = ManualClock()
        let budget = clock.budget(.unlimited)
        let heard = PauseLog()
        await budget.observePauses { heard.append($0) }
        let resume = await budget.backfillThrottled(retryAfter: 5)
        XCTAssertEqual(resume, clock.now, "resumes at once")
        await budget.backfillThrottled(retryAfter: nil)
        let live = await budget.liveThrottled(retryAfter: 5)
        XCTAssertEqual(live, clock.now, "a live throttle pauses nothing either")
        await budget.liveThrottled(retryAfter: nil)
        let paused = await budget.pausedUntil
        XCTAssertNil(paused)
        try await budget.acquireBackfill(1)
        try await budget.acquireBackfill(1_000_000)
        XCTAssertEqual(clock.sleeps, [])
        XCTAssertEqual(heard.values, [])
    }

    // MARK: The live share

    /// The live lane's own allowance: the third of Gmail's 6,000 units a minute the backfill leaves, holding a
    /// minute of it. It never makes the live lane wait; the lane reads it before what it can put off.
    func testTheLiveShareHoldsAMinuteOfWhatTheBackfillLeaves() async {
        let clock = ManualClock()
        let budget = clock.budget(.standard(for: .gmail))
        var headroom = await budget.liveHeadroom
        XCTAssertEqual(headroom, 2_000, accuracy: 1e-6)
        // A full changes page: the call and 100 messages' metadata.
        await budget.recordLive(2 + 100 * 20)
        headroom = await budget.liveHeadroom
        XCTAssertEqual(headroom, -2, accuracy: 1e-6)
        // Another page like it waits for the share to refill to a whole allowance: 2,002 is more than it holds.
        var wait = await budget.liveWait(for: 2_002)
        XCTAssertEqual(wait, 2_002.0 / (2_000.0 / 60), accuracy: 1e-6)
        // A steady poll needs only to be out of debt.
        wait = await budget.liveWait(for: 2)
        XCTAssertEqual(wait, 4.0 / (2_000.0 / 60), accuracy: 1e-6)
        clock.advance(30)
        headroom = await budget.liveHeadroom
        XCTAssertEqual(headroom, 998, accuracy: 1e-6)
        clock.advance(3_600)
        headroom = await budget.liveHeadroom
        XCTAssertEqual(headroom, 2_000, accuracy: 1e-6, "it holds no more than a minute's worth")
        XCTAssertEqual(clock.sleeps, [], "nothing here waits")
    }

    func testTheLiveShareOwesAtMostOneAllowance() async {
        let clock = ManualClock()
        let budget = clock.budget(.standard(for: .gmail))
        for _ in 0..<10 { await budget.recordLive(2_000) }
        let headroom = await budget.liveHeadroom
        XCTAssertEqual(headroom, -2_000, accuracy: 1e-6)
        let wait = await budget.liveWait(for: 0)
        XCTAssertEqual(wait, 60, accuracy: 1e-6, "a burst holds the live lane back a minute at most")
    }

    /// A single cost beyond the whole allowance is owed in full, so another like it waits as long as it takes to
    /// earn: a Graph page of 1,010 requests against a share of 333 leaves 677 owed, and the next waits about 182 s,
    /// not the 120 s a debt cut at a minute would leave. Only a figure past ten minutes' worth is cut.
    func testASingleCostBeyondTheLiveShareIsOwedInFull() async {
        let clock = ManualClock()
        let budget = clock.budget(.standard(for: .microsoft))
        let share = budget.liveCapacity
        XCTAssertEqual(share, 1_000.0 / 3, accuracy: 1e-6)
        await budget.recordLive(1_010)
        var headroom = await budget.liveHeadroom
        XCTAssertEqual(headroom, share - 1_010, accuracy: 1e-6)
        var wait = await budget.liveWait(for: 1_010)
        XCTAssertEqual(wait, 1_010 / (share / 60), accuracy: 1e-6)
        // An opened body after it neither forgives what the page owes nor takes the debt deeper.
        await budget.recordLive(2)
        headroom = await budget.liveHeadroom
        XCTAssertEqual(headroom, share - 1_010, accuracy: 1e-6)

        // Spread over smaller costs, the debt still stops at a minute.
        let spread = clock.budget(.standard(for: .microsoft))
        for _ in 0..<10 { await spread.recordLive(200) }
        headroom = await spread.liveHeadroom
        XCTAssertEqual(headroom, -share, accuracy: 1e-6)

        let absurd = clock.budget(.standard(for: .microsoft))
        await absurd.recordLive(.greatestFiniteMagnitude)
        headroom = await absurd.liveHeadroom
        XCTAssertEqual(headroom, -10 * share, accuracy: 1e-6)
        wait = await absurd.liveWait(for: .greatestFiniteMagnitude)
        XCTAssertEqual(wait, 11 * 60, accuracy: 1e-6, "ten minutes owed, then a full share")
        XCTAssertEqual(clock.sleeps, [], "nothing here waits")
    }

    func testABackfillThrottleLeavesTheLiveShareAlone() async {
        let clock = ManualClock()
        let budget = clock.budget(.standard(for: .gmail))
        await budget.recordLive(500)
        await budget.backfillThrottled(retryAfter: 300)
        clock.advance(15)
        let headroom = await budget.liveHeadroom
        XCTAssertEqual(headroom, 2_000, accuracy: 1e-6)
    }

    func testAClockSteppingBackDoesNotFreezeTheLiveShare() async {
        let clock = ManualClock()
        let budget = clock.budget(.standard(for: .gmail))
        await budget.recordLive(2_000)
        clock.advance(-3_600)
        var headroom = await budget.liveHeadroom
        XCTAssertEqual(headroom, 0, accuracy: 1e-6, "the step itself refills nothing")
        clock.advance(30)
        headroom = await budget.liveHeadroom
        XCTAssertEqual(headroom, 1_000, accuracy: 1e-6, "and the time after it refills as usual")
    }

    func testUnmeteredOrAllBackfillLeavesTheLiveShareUncounted() async {
        let clock = ManualClock()
        for quota in [ProviderQuota.unlimited, quota] {
            let budget = clock.budget(quota)
            await budget.recordLive(1_000_000)
            let headroom = await budget.liveHeadroom
            let wait = await budget.liveWait(for: 1_000_000)
            XCTAssertEqual(headroom, .infinity)
            XCTAssertEqual(wait, 0)
        }
    }

    // MARK: Helpers

    private func assertSleeps(_ clock: ManualClock, _ expected: [TimeInterval],
                              file: StaticString = #filePath, line: UInt = #line) {
        let actual = clock.sleeps
        XCTAssertEqual(actual.count, expected.count, "sleeps \(actual), expected \(expected)", file: file, line: line)
        for (value, wanted) in zip(actual, expected) {
            XCTAssertEqual(value, wanted, accuracy: 1e-6, "sleeps \(actual), expected \(expected)", file: file, line: line)
        }
    }

    private func assertCancelled<T: Sendable>(_ task: Task<T, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("expected CancellationError", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)", file: file, line: line)
        }
    }

    /// Lets queued tasks reach their suspension point; real time only for scheduling, bounded.
    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while await !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// A clock the test moves by hand, and the sleep the budget is given: it records each wait and moves the clock
/// by it, or, while `parksSleeps` is set, parks until the task is cancelled.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    // An integral start keeps date arithmetic exact, so expected waits compare tightly.
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var recorded: [TimeInterval] = []
    private var hooks: [@Sendable () async -> Void] = []
    private var parking = false

    var now: Date { lock.withLock { current } }
    var sleeps: [TimeInterval] { lock.withLock { recorded } }
    var elapsed: TimeInterval { now.timeIntervalSince(origin) }

    var parksSleeps: Bool {
        get { lock.withLock { parking } }
        set { lock.withLock { parking = newValue } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    /// Runs `hook` inside the next sleep, before the clock moves: something that happens while the budget waits.
    func onNextSleep(_ hook: @escaping @Sendable () async -> Void) {
        lock.withLock { hooks.append(hook) }
    }

    func sleep(_ seconds: TimeInterval) async throws {
        let (hook, parks) = lock.withLock { () -> ((@Sendable () async -> Void)?, Bool) in
            recorded.append(seconds)
            return (hooks.isEmpty ? nil : hooks.removeFirst(), parking)
        }
        if parks {
            try? await Task.sleep(for: .seconds(60))
            return
        }
        await hook?()
        advance(seconds)
    }

    func budget(_ quota: ProviderQuota) -> QuotaBudget {
        QuotaBudget(quota: quota, now: { self.now }, sleep: { try await self.sleep($0) })
    }
}

private actor OrderLog {
    private(set) var names: [String] = []
    func append(_ name: String) { names.append(name) }
}

private actor ConcurrencyGauge {
    private var current = 0
    private(set) var peak = 0
    func enter() {
        current += 1
        peak = max(peak, current)
    }
    func leave() { current -= 1 }
}

/// What a pause observer heard, in order; the observer is called synchronously from inside the budget.
private final class PauseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [Date?] = []

    var values: [Date?] { lock.withLock { heard } }

    func append(_ value: Date?) {
        lock.withLock { heard.append(value) }
    }
}
