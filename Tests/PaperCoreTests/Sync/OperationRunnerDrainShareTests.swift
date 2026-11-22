import Foundation
import XCTest
@testable import PaperCore

/// One drain makes at most `SyncTuning.maxApplyCallsPerDrain` provider calls (docs/ARCHITECTURE.md, "Rules"): an
/// operation with thousands of targets, as Always Archive makes for a busy sender, goes out over several cycles, narrowed
/// each time to what is left, so the account's poll and the user's next change never wait behind all of it. Each provider
/// takes as many targets a call as it allows (`MailProvider.maxApplyTargets`): Gmail's `batchModify` 1,000.
final class OperationRunnerDrainShareTests: XCTestCase {
    private func store(messages count: Int) throws -> InMemoryMailStore {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages((1...count).map { Fixtures.message($0, conversation: "t\($0)") })
        return store
    }

    private func targets(_ numbers: ClosedRange<Int>) -> [MessageID] {
        numbers.map { MessageID(accountID: Fixtures.accountID, providerID: "\($0)") }
    }

    private func pending(_ store: InMemoryMailStore) throws -> [PaperCore.Operation] {
        try store.pendingOperations(accountID: Fixtures.accountID, limit: 10)
    }

    func testALargeOperationGoesOutOverSeveralDrainsWithoutSpendingAttempts() async throws {
        let store = try store(messages: 1_000)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        let tuning = SyncTuning()
        XCTAssertEqual(tuning.maxApplyCallsPerDrain, 4)
        let runner = OperationRunner(accountID: Fixtures.accountID, store: store, provider: provider, tuning: tuning)
        let all = targets(1...1_000)
        try store.enqueue(PaperCore.Operation(accountID: Fixtures.accountID, change: .archive, targets: all, createdAt: Date()))

        let first = await runner.drain()
        XCTAssertEqual(provider.applyCalls.map(\.ids.count), [50, 50, 50, 50], "four calls of the provider's 50")
        let due = try XCTUnwrap(first.nextAttemptAt, "the rest is due at once, on the next cycle")
        XCTAssertLessThanOrEqual(due.timeIntervalSinceNow, 0)
        let left = try XCTUnwrap(try pending(store).first)
        XCTAssertEqual(left.targets, Array(all.dropFirst(200)), "narrowed to what was not sent")
        XCTAssertEqual(left.status, .pending)
        XCTAssertEqual(left.attempts, 0, "a drain's share running out is no attempt")
        XCTAssertNil(left.nextAttemptAt)
        XCTAssertTrue(try all.allSatisfy { try store.message($0)?.roles == [] }, "the user's archive stands throughout")
        let summaries = try store.summaries(of: [ConversationID(accountID: Fixtures.accountID, providerID: "t1"),
                                                 ConversationID(accountID: Fixtures.accountID, providerID: "t1000")])
        XCTAssertEqual(summaries.mapValues(\.hasPendingOperations).sorted { $0.key.providerID < $1.key.providerID }.map(\.value),
                       [false, true], "a sent target's conversation settles; the rest stay pending")

        var drains = 1
        while try !pending(store).isEmpty, drains < 20 {
            _ = await runner.drain()
            drains += 1
        }
        XCTAssertEqual(drains, 5)
        XCTAssertEqual(provider.applyCalls.flatMap(\.ids), all.map(\.providerID), "each target once, in order")
    }

    /// A target the provider refuses goes to the end of what is owed and counts one attempt: the next drain sends what
    /// was never sent before trying it again, so it never keeps the others from going out.
    func testARefusedTargetGoesLastAndTheRestStillGoesOut() async throws {
        let store = try store(messages: 300)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.applyResults = [.failure(PartialApplyError(unapplied: ["1"], error: .server(status: 403, message: "denied")))]
        var tuning = SyncTuning()
        tuning.backoffBase = 0.001
        tuning.backoffCap = 0.004
        let runner = OperationRunner(accountID: Fixtures.accountID, store: store, provider: provider, tuning: tuning)
        try store.enqueue(PaperCore.Operation(accountID: Fixtures.accountID, change: .archive, targets: targets(1...300), createdAt: Date()))

        _ = await runner.drain()
        let owed = try XCTUnwrap(try pending(store).first)
        XCTAssertEqual(owed.targets.map(\.providerID), (201...300).map(String.init) + ["1"])
        XCTAssertEqual(owed.attempts, 1, "the refusal counts")
        try await Task.sleep(for: .milliseconds(10))
        _ = await runner.drain()

        XCTAssertEqual(provider.applyCalls.map(\.ids.count), [50, 50, 50, 50, 50, 50, 1])
        XCTAssertEqual(provider.applyCalls.last?.ids, ["1"])
        XCTAssertTrue(try pending(store).isEmpty)
    }

    /// Gmail takes 1,000 ids a call, so 2,345 targets are three calls in one drain, not 47 over twelve.
    func testAProviderThatTakesMoreACallGetsThemInOneCall() async throws {
        let store = try store(messages: 2_345)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.maxApplyTargets = 1_000
        let runner = OperationRunner(accountID: Fixtures.accountID, store: store, provider: provider, tuning: SyncTuning())
        try store.enqueue(PaperCore.Operation(accountID: Fixtures.accountID, change: .archive, targets: targets(1...2_345),
                                              createdAt: Date()))
        _ = await runner.drain()
        XCTAssertEqual(provider.applyCalls.map(\.ids.count), [1_000, 1_000, 345])
        XCTAssertTrue(try pending(store).isEmpty)
    }

    /// Operations queued after a large one wait their turn across the drains: strict order holds, and they go out once it
    /// is done.
    func testLaterOperationsWaitTheirTurnAcrossDrains() async throws {
        let store = try store(messages: 400)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        let runner = OperationRunner(accountID: Fixtures.accountID, store: store, provider: provider, tuning: SyncTuning())
        let now = Date()
        try store.enqueue(PaperCore.Operation(accountID: Fixtures.accountID, change: .archive, targets: targets(1...300), createdAt: now))
        try store.enqueue(PaperCore.Operation(accountID: Fixtures.accountID, change: .setStarred(true), targets: targets(400...400),
                                              createdAt: now.addingTimeInterval(0.01)))
        _ = await runner.drain()
        XCTAssertFalse(provider.applyCalls.contains { $0.change == .setStarred(true) }, "the star waits behind the archive")
        _ = await runner.drain()
        XCTAssertEqual(provider.applyCalls.map(\.change), Array(repeating: .archive, count: 6) + [.setStarred(true)])
        XCTAssertTrue(try pending(store).isEmpty)
    }
}
