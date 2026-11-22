import Foundation
import XCTest
@testable import PaperCore

final class SyncSupportTests: XCTestCase {
    func testBootstrapCheckpointRoundTripsThroughNextPage() {
        var state = BootstrapState(startedAt: Date())
        XCTAssertEqual(state.checkpoint, BootstrapCheckpoint())

        state.checkpoint = BootstrapCheckpoint(providerPage: "p2", changeCursor: "c0")
        XCTAssertNotNil(state.nextPage)
        XCTAssertEqual(state.checkpoint.providerPage, "p2")
        XCTAssertEqual(state.checkpoint.changeCursor, "c0")

        state.checkpoint = BootstrapCheckpoint()
        XCTAssertNil(state.nextPage)

        // A bare provider token written by something else carries no cursor and reads as "start over".
        state.nextPage = "raw-token"
        XCTAssertEqual(state.checkpoint, BootstrapCheckpoint())
    }

    func testBackoffDoublesAndCaps() {
        XCTAssertEqual(Backoff.delay(attempt: 1, base: 2, cap: 300), 2)
        XCTAssertEqual(Backoff.delay(attempt: 2, base: 2, cap: 300), 4)
        XCTAssertEqual(Backoff.delay(attempt: 5, base: 2, cap: 300), 32)
        XCTAssertEqual(Backoff.delay(attempt: 9, base: 2, cap: 300), 300)
        XCTAssertEqual(Backoff.delay(attempt: 100, base: 2, cap: 300), 300)
        XCTAssertEqual(Backoff.delay(attempt: 0, base: 2, cap: 300), 2)
    }

    func testThrottleDelayFloorsRetryAfterAtTheBase() {
        XCTAssertEqual(Backoff.throttleDelay(retryAfter: 0, attempt: 1, base: 2, cap: 300), 2)
        XCTAssertEqual(Backoff.throttleDelay(retryAfter: 1, attempt: 3, base: 2, cap: 300), 2)
        XCTAssertEqual(Backoff.throttleDelay(retryAfter: 45, attempt: 3, base: 2, cap: 300), 45)
        XCTAssertEqual(Backoff.throttleDelay(retryAfter: 630, attempt: 1, base: 2, cap: 60), 60, "a skewed clock's time is capped")
        XCTAssertEqual(Backoff.throttleDelay(retryAfter: 30, attempt: 1, base: 2, cap: 1), 2, "never under the base")
        XCTAssertEqual(Backoff.throttleDelay(retryAfter: nil, attempt: 3, base: 2, cap: 300), 8)
    }

    /// An account's two lanes publish from different threads. Each writer below only raises its own field, so in
    /// the order the snapshots were taken both fields only grow; one reaching the main thread after a newer one
    /// would show a field going back.
    func testStatusesReachTheMainThreadInTheOrderTheyWereTaken() {
        final class Seen: @unchecked Sendable {
            var last = (0, 0)
            var regressions = 0
            var finished = false
        }
        let center = SyncStatusCenter()
        let account = Fixtures.accountID
        center.register(account)
        let rounds = 4_000
        let seen = Seen()
        let done = expectation(description: "both writers' last values delivered")
        let observation = center.observe { statuses in
            guard let status = statuses.first else { return }
            let current = (status.backfillProgress ?? 0, status.bootstrapProgress ?? 0)
            if current.0 < seen.last.0 || current.1 < seen.last.1 { seen.regressions += 1 }
            seen.last = current
            if current == (rounds, rounds), !seen.finished {
                seen.finished = true
                done.fulfill()
            }
        }
        for writer in 0..<2 {
            DispatchQueue.global().async {
                for round in 1...rounds {
                    center.update(account) { status in
                        if writer == 0 { status.backfillProgress = round } else { status.bootstrapProgress = round }
                    }
                }
            }
        }
        wait(for: [done], timeout: 60)
        XCTAssertEqual(seen.regressions, 0, "a snapshot older than one already shown reached the observer")
        observation.cancel()
    }

    func testWakerReturnsPendingSignalImmediately() async {
        let waker = SyncWaker()
        await waker.deliver(.operations)
        let start = Date()
        let reasons = await waker.wait(timeout: 5)
        XCTAssertEqual(reasons, [.operations])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testWakerTimesOut() async {
        let waker = SyncWaker()
        let start = Date()
        let reasons = await waker.wait(timeout: 0.1)
        XCTAssertEqual(reasons, [])
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.09)
    }

    func testWakerSignalInterruptsWaitAndMergesReasons() async {
        let waker = SyncWaker()
        let start = Date()
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            waker.signal(.operations)
            waker.signal(.poll)
        }
        let reasons = await waker.wait(timeout: 5)
        XCTAssertFalse(reasons.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        // Whatever arrived after the first wake is still there for the next wait.
        let remaining = await waker.wait(timeout: 0.2)
        XCTAssertEqual(reasons.union(remaining), [.operations, .poll])
    }

    func testWakerWaitReturnsWhenTaskIsCancelled() async {
        let waker = SyncWaker()
        let task = Task { await waker.wait(timeout: nil) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let start = Date()
        let reasons = await task.value
        XCTAssertEqual(reasons, [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testStatusCenterDedupesAndOrdersByRegistration() async throws {
        let center = SyncStatusCenter()
        let a = AccountID("a")
        let b = AccountID("b")
        center.register(a)
        center.register(b)
        let recorder = PhaseRecorder()
        let observation = center.observe { recorder.record($0) }
        try await waitUntil("initial delivery") { recorder.deliveries == 1 }
        XCTAssertEqual(recorder.latest.map(\.accountID), [a, b])

        center.update(b) { $0.phase = .syncing }
        center.update(b) { $0.phase = .syncing }
        try await waitUntil("one change delivered") { recorder.deliveries == 2 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.deliveries, 2)
        XCTAssertEqual(recorder.latest.map(\.phase), [.idle, .syncing])

        center.remove(a)
        try await waitUntil("removal delivered") { recorder.latest.map(\.accountID) == [b] }
        observation.cancel()
    }
}
