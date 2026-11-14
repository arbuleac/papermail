import Foundation
import XCTest
@testable import SSCore

final class MailEngineOperationTests: XCTestCase {
    private func bootstrappedHarness(
        applyResults: [Result<Void, Error>] = [],
        tune: (inout SyncTuning) -> Void = { _ in }
    ) async throws -> EngineHarness {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        provider.applyResults = applyResults
        let harness = try EngineHarness(provider: provider, tune: tune)
        harness.engine.start()
        try await waitUntil("bootstrap complete") { try harness.store.syncCursor(for: Fixtures.accountID) == "c0" }
        return harness
    }

    private func pendingOperations(_ harness: EngineHarness) throws -> [Operation] {
        try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10)
    }

    private func failedMark(_ harness: EngineHarness, _ conversation: ConversationID) throws -> OperationKind? {
        let summaries = try harness.store.conversations(ConversationQuery(view: .all, limit: 100))
        return try XCTUnwrap(summaries.first { $0.id == conversation }).failedOperation
    }

    func testGivenUpOperationMarksItsConversationUntilItIsPruned() async throws {
        let harness = try await bootstrappedHarness(
            applyResults: [.failure(ProviderError.server(status: 500, message: "boom"))]
        ) { tuning in
            tuning.maxOperationAttempts = 1
            tuning.failedOperationRetention = 0.6
        }
        let conversation = ConversationID(accountID: Fixtures.accountID, providerID: "t1")
        let target = MessageID(accountID: Fixtures.accountID, providerID: "2")
        let queuedAt = Date()
        try harness.engine.perform(.setStarred(true), on: [target])
        XCTAssertEqual(try harness.store.message(target)?.isStarred, true)
        try await waitUntil("failure marked") { try self.failedMark(harness, conversation) == .star }
        XCTAssertEqual(try harness.store.message(target)?.isStarred, false, "the change the provider refused is given back")
        XCTAssertTrue(try pendingOperations(harness).isEmpty, "a failed operation is not replayed")
        XCTAssertFalse(try XCTUnwrap(try harness.store.conversations(ConversationQuery(view: .all)).first).hasPendingOperations)

        // The outbox prunes it once its retention has passed, which clears the mark, and not before.
        try await waitUntil("expired failure pruned") { try self.failedMark(harness, conversation) == nil }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(queuedAt), 0.6)
        XCTAssertEqual(harness.provider.applyCalls.count, 1)
        await harness.shutdown()
    }

    func testArchiveConversationUpdatesLocallyAndAppliesOnce() async throws {
        let harness = try await bootstrappedHarness()
        let conversation = ConversationID(accountID: Fixtures.accountID, providerID: "t1")
        try harness.engine.perform(.archive, on: conversation)

        // Local state changed before `perform` returned.
        let messages = try harness.store.messages(in: conversation)
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages.allSatisfy { !$0.roles.contains(.inbox) })
        XCTAssertTrue(try harness.store.conversations(ConversationQuery(view: .inbox)).isEmpty)
        // The runner may already have replayed and deleted the operation on a loaded machine.
        let queued = try pendingOperations(harness).count
        XCTAssertTrue(queued == 1 || harness.provider.applyCalls.count == 1, "operation neither queued nor applied")

        try await waitUntil("apply called") { harness.provider.applyCalls.count == 1 }
        let call = try XCTUnwrap(harness.provider.applyCalls.first)
        XCTAssertEqual(call.change, .archive)
        XCTAssertEqual(call.ids, ["1", "2", "3"])
        try await waitUntil("operation deleted") { try self.pendingOperations(harness).isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.provider.applyCalls.count, 1)
        XCTAssertTrue(try harness.store.messages(in: conversation).allSatisfy { !$0.roles.contains(.inbox) })
        await harness.shutdown()
    }

    /// Mark as spam (roadmap Q2.3): the conversation leaves every view before `perform` returns, the provider is asked
    /// once, and the undo's inverse reaches it after, in the order it was applied.
    func testMarkSpamIsLocalFirstAndItsUndoReplaysAfterIt() async throws {
        let harness = try await bootstrappedHarness()
        let conversation = ConversationID(accountID: Fixtures.accountID, providerID: "t1")
        let messages = try harness.store.messages(in: conversation)
        let record = try XCTUnwrap(MailActionRecord.make(.markSpam, on: MailActionRecord.targets(for: .markSpam, in: messages, kind: .gmail),
                                                         conversation: conversation))
        try harness.engine.perform(.markSpam, on: record.targets)

        XCTAssertTrue(try harness.store.messages(in: conversation).allSatisfy { $0.roles == [.spam] })
        XCTAssertTrue(try harness.store.conversations(ConversationQuery(view: .all)).isEmpty)
        try await waitUntil("spam applied") { harness.provider.applyCalls.count == 1 }
        XCTAssertEqual(harness.provider.applyCalls.first?.change, .markSpam)
        XCTAssertEqual(harness.provider.applyCalls.first?.ids, ["1", "2", "3"])

        XCTAssertEqual(record.inverse.map(\.change), [.markNotSpam], "all three were in the Inbox")
        for step in record.inverse { try harness.engine.perform(step.change, on: step.targets) }
        XCTAssertEqual(try harness.store.conversations(ConversationQuery(view: .inbox)).map(\.id), [conversation])
        try await waitUntil("undo applied") { harness.provider.applyCalls.count == 2 }
        XCTAssertEqual(harness.provider.applyCalls.map(\.change), [.markSpam, .markNotSpam])
        try await waitUntil("outbox drained") { try self.pendingOperations(harness).isEmpty }
        await harness.shutdown()
    }

    func testNetworkFailureLeavesOperationPendingWithFutureRetry() async throws {
        let failures = Array(repeating: Result<Void, Error>.failure(ProviderError.network("offline")), count: 20)
        // The harness caps backoff at one second for speed; this test needs a retry that stays in the future.
        let harness = try await bootstrappedHarness(applyResults: failures) { $0.backoffBase = 10; $0.backoffCap = 60 }
        let target = MessageID(accountID: Fixtures.accountID, providerID: "1")
        try harness.engine.perform(.setStarred(true), on: [target])
        try await waitUntil("apply attempted") { harness.provider.applyCalls.count == 1 }
        try await waitUntil("failure recorded") {
            try self.pendingOperations(harness).first.map { $0.status == .pending && $0.attempts == 1 } ?? false
        }

        let operation = try XCTUnwrap(try pendingOperations(harness).first)
        XCTAssertEqual(operation.status, .pending)
        XCTAssertEqual(operation.attempts, 1)
        XCTAssertEqual(operation.lastError, "network: offline")
        let nextAttemptAt = try XCTUnwrap(operation.nextAttemptAt)
        XCTAssertGreaterThan(nextAttemptAt, Date())
        XCTAssertGreaterThan(nextAttemptAt.timeIntervalSinceNow, 5)
        XCTAssertEqual(try harness.store.message(target)?.isStarred, true)

        // No retry sneaks in before the scheduled attempt.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(harness.provider.applyCalls.count, 1)
        await harness.shutdown()
    }

    func testPollWithStaleProviderStateDoesNotUndoPendingChange() async throws {
        let failures = Array(repeating: Result<Void, Error>.failure(ProviderError.network("offline")), count: 50)
        let harness = try await bootstrappedHarness(applyResults: failures) { $0.backoffBase = 10; $0.backoffCap = 60 }
        let conversation = ConversationID(accountID: Fixtures.accountID, providerID: "t1")
        try harness.engine.perform(.archive, on: conversation)
        try await waitUntil("apply attempted") { harness.provider.applyCalls.count == 1 }

        // The provider never received the archive, so it still reports every message in the inbox.
        harness.provider.enqueueChanges(.success(Fixtures.changes(upserts: (1...3).map { Fixtures.message($0) }, cursor: "c1")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("stale poll applied") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }

        let messages = try harness.store.messages(in: conversation)
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages.allSatisfy { !$0.roles.contains(.inbox) })
        XCTAssertTrue(try harness.store.conversations(ConversationQuery(view: .inbox)).isEmpty)
        XCTAssertEqual(try pendingOperations(harness).count, 1)
        await harness.shutdown()
    }

    func testUnknownOutcomeMarksOperationUncertainAndRetries() async throws {
        let harness = try await bootstrappedHarness(
            applyResults: [.failure(ProviderError.server(status: 503, message: "timeout"))]
        ) { $0.backoffBase = 0.1 }
        let target = MessageID(accountID: Fixtures.accountID, providerID: "2")
        try harness.engine.perform(.setRead(true), on: [target])
        try await waitUntil("uncertain recorded") {
            try self.pendingOperations(harness).first.map { $0.status == .uncertain && $0.lastError != nil } ?? false
        }
        let uncertain = try XCTUnwrap(try pendingOperations(harness).first)
        XCTAssertEqual(uncertain.lastError, "server 503: timeout")
        XCTAssertNotNil(uncertain.nextAttemptAt)
        // The second attempt succeeds (apply is idempotent) and clears the row.
        try await waitUntil("retried and confirmed") { try self.pendingOperations(harness).isEmpty }
        XCTAssertEqual(harness.provider.applyCalls.count, 2)
        XCTAssertEqual(try harness.store.message(target)?.isRead, true)
        await harness.shutdown()
    }

    /// Long backoffs, so an uncertain row's retry lies well ahead of its last attempt (`nextAttemptAt` less the backoff
    /// the attempt took), as it does in use, without the drain sending it again during the test.
    private func longBackoff(_ tuning: inout SyncTuning) {
        tuning.backoffBase = 3000
        tuning.backoffCap = 3600
    }

    /// An uncertain row last tried `ago` seconds ago, its retry one backoff after that.
    private func uncertain(_ change: MetadataChange, _ targets: [MessageID], createdAgo: TimeInterval,
                           triedAgo: TimeInterval) -> Operation {
        Operation(accountID: Fixtures.accountID, change: change, targets: targets,
                  createdAt: Date().addingTimeInterval(-createdAgo), status: .uncertain, attempts: 1,
                  nextAttemptAt: Date().addingTimeInterval(3000 - triedAgo))
    }

    func testPollSettlesOldUncertainOperations() async throws {
        let harness = try await bootstrappedHarness(tune: longBackoff)
        let target = MessageID(accountID: Fixtures.accountID, providerID: "1")
        let old = uncertain(.setRead(true), [target], createdAgo: 700, triedAgo: 700)
        let young = uncertain(.setStarred(true), [target], createdAgo: 0, triedAgo: 0)
        try harness.store.updateOperation(old)
        try harness.store.updateOperation(young)

        // The provider reports message 1 unread and unstarred: it never applied either operation.
        harness.provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(1)], cursor: "c1")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("poll applied") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }
        XCTAssertEqual(try pendingOperations(harness).map(\.id), [young.id])
        // The settled operation must not have been re-applied on top of the provider's state on its way out,
        // while the young one still wins.
        let message = try XCTUnwrap(try harness.store.message(target))
        XCTAssertEqual(message.isRead, false)
        XCTAssertEqual(message.isStarred, true)
        await harness.shutdown()
    }

    /// Measured from the last attempt, an age of 600 s could never pass under the default tuning: the outbox retries a
    /// due operation just before each poll and the backoff stops at 300 s, so an operation whose change landed while
    /// the provider kept answering 500 was never settled, and was given up 88 minutes later with a false failure mark.
    /// The settle age sits below the backoff cap: a poll between two retries settles it.
    func testAnUncertainOperationSettlesUnderTheDefaultTuning() async throws {
        let defaults = SyncTuning()
        XCTAssertLessThan(defaults.uncertainSettleAge, defaults.backoffCap, "a poll between two retries can settle")
        let harness = try await bootstrappedHarness { tuning in
            tuning.backoffBase = defaults.backoffBase
            tuning.backoffCap = defaults.backoffCap
            tuning.uncertainSettleAge = defaults.uncertainSettleAge
        }
        let target = MessageID(accountID: Fixtures.accountID, providerID: "1")
        // Its ninth attempt, 200 s ago, waits out the capped backoff: the retry is 100 s ahead.
        let landed = Operation(accountID: Fixtures.accountID, change: .archive, targets: [target],
                               createdAt: Date().addingTimeInterval(-3_600), status: .uncertain, attempts: 9,
                               nextAttemptAt: Date().addingTimeInterval(defaults.backoffCap - 200))
        try harness.store.updateOperation(landed)

        harness.provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(1, roles: [])], cursor: "c1")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("poll applied") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }
        XCTAssertTrue(try pendingOperations(harness).isEmpty, "the provider's report settles it")
        XCTAssertEqual(try harness.store.message(target)?.roles, [])
        await harness.shutdown()
    }

    /// An operation queued offline archived a conversation's two messages; its first attempt moved one and failed on
    /// the other. Settled because the poll reported the one that moved, it was deleted whole, and the other stayed
    /// archived here and in the Inbox on the server for good. It is settled only once every target is reported.
    func testAnUncertainOperationIsSettledOnlyOnceThePollHasSeenEveryTarget() async throws {
        let harness = try await bootstrappedHarness(tune: longBackoff)
        let targets = ["1", "2"].map { MessageID(accountID: Fixtures.accountID, providerID: $0) }
        let archive = uncertain(.archive, targets, createdAgo: 700, triedAgo: 700)
        try harness.store.updateOperation(archive)

        harness.provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(1, roles: [])], cursor: "c1")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("first poll") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }
        XCTAssertEqual(try pendingOperations(harness).map(\.id), [archive.id], "message 2 has not been reported")
        XCTAssertEqual(try harness.store.message(targets[0])?.roles, [])

        harness.provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(1, roles: []), Fixtures.message(2, roles: [])], cursor: "c2")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("second poll") { try harness.store.syncCursor(for: Fixtures.accountID) == "c2" }
        XCTAssertTrue(try pendingOperations(harness).isEmpty)
        await harness.shutdown()
    }

    /// Old enough means old enough since its last attempt, not since it was queued: an operation queued offline an hour
    /// ago and tried just now may still be landing, and a poll reporting its target for another reason must not drop it.
    func testAnUncertainOperationTriedJustNowIsNotSettledHoweverOldItIs() async throws {
        let harness = try await bootstrappedHarness(tune: longBackoff)
        let target = MessageID(accountID: Fixtures.accountID, providerID: "1")
        let archive = uncertain(.archive, [target], createdAgo: 3600, triedAgo: 0)
        try harness.store.updateOperation(archive)

        harness.provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(1, isStarred: true)], cursor: "c1")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("poll applied") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }
        XCTAssertEqual(try pendingOperations(harness).map(\.id), [archive.id])
        XCTAssertEqual(try harness.store.message(target)?.roles, [], "still archived here while it may be landing")
        await harness.shutdown()
    }

    /// An operation tried while offline (the network failing every request) kept counting attempts, so after about an
    /// hour and a half the first server error once the network was back gave it up and put the user's change back. Only
    /// failures that reached the provider count towards the give-up; offline the backoff still grows to its cap.
    func testNetworkFailuresDoNotUseUpTheAttemptsAServerErrorGivesUpOn() async throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages([Fixtures.message(1)])
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.applyResults = Array(repeating: .failure(ProviderError.network("offline")), count: 30)
            + [.failure(ProviderError.server(status: 500, message: "backend"))]
        var tuning = SyncTuning()
        tuning.backoffBase = 0.001
        tuning.backoffCap = 0.004
        let runner = OperationRunner(accountID: Fixtures.accountID, store: store, provider: provider, tuning: tuning)
        let target = MessageID(accountID: Fixtures.accountID, providerID: "1")
        try store.enqueue(Operation(accountID: Fixtures.accountID, change: .archive, targets: [target], createdAt: Date()))

        var backoffs: [TimeInterval] = []
        for _ in 0..<31 {
            _ = await runner.drain()
            if let operation = try store.pendingOperations(accountID: Fixtures.accountID, limit: 1).first,
               let next = operation.nextAttemptAt {
                backoffs.append(next.timeIntervalSinceNow)
            }
            try await Task.sleep(for: .milliseconds(8))
        }

        XCTAssertEqual(provider.applyCalls.count, 31)
        let operation = try XCTUnwrap(try store.pendingOperations(accountID: Fixtures.accountID, limit: 1).first,
                                      "a server error after a long offline spell is retried, not given up")
        XCTAssertEqual(operation.status, .uncertain)
        XCTAssertLessThan(operation.attempts, tuning.maxOperationAttempts)
        XCTAssertEqual(try store.message(target)?.roles, [], "the user's archive stands")
        XCTAssertGreaterThan(backoffs[29], 0.002, "offline, the backoff still reached its cap")
    }

    /// A token refresh that fails (the token endpoint down, an OAuth client changed in Settings) means nothing left this
    /// Mac: it is retried on the backoff and never gives the user's change up.
    func testATokenRefreshThatKeepsFailingNeverGivesTheChangeUp() async throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages([Fixtures.message(1)])
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.applyResults = Array(repeating: .failure(AuthError.refreshFailed("unauthorized_client")), count: 30)
        var tuning = SyncTuning()
        tuning.backoffBase = 0.001
        tuning.backoffCap = 0.004
        let runner = OperationRunner(accountID: Fixtures.accountID, store: store, provider: provider, tuning: tuning)
        let target = MessageID(accountID: Fixtures.accountID, providerID: "1")
        try store.enqueue(Operation(accountID: Fixtures.accountID, change: .archive, targets: [target], createdAt: Date()))

        for _ in 0..<30 {
            _ = await runner.drain()
            try await Task.sleep(for: .milliseconds(8))
        }

        let operation = try XCTUnwrap(try store.pendingOperations(accountID: Fixtures.accountID, limit: 1).first)
        XCTAssertEqual(operation.status, .pending, "nothing was sent, so nothing may have landed")
        XCTAssertEqual(try store.message(target)?.roles, [])
    }

    func testGivenUpArchiveReturnsTheConversationToTheInbox() async throws {
        let harness = try await bootstrappedHarness(
            applyResults: [.failure(ProviderError.server(status: 500, message: "boom"))]
        ) { $0.maxOperationAttempts = 1 }
        let conversation = ConversationID(accountID: Fixtures.accountID, providerID: "t1")
        try harness.engine.perform(.archive, on: conversation)
        XCTAssertTrue(try harness.store.conversations(ConversationQuery(view: .inbox)).isEmpty)

        try await waitUntil("restored") {
            try harness.store.conversations(ConversationQuery(view: .inbox)).first?.failedOperation == .archive
        }
        XCTAssertTrue(try harness.store.messages(in: conversation).allSatisfy { $0.roles == [.inbox] })
        XCTAssertEqual(harness.provider.applyCalls.count, 1)
        await harness.shutdown()
    }

    /// One target the provider refused stopped the rest of an operation: the later slices never went out, every retry
    /// failed at the same place, and the give-up put back every target, the ones never sent included. The later slices
    /// go now, and the give-up puts back only what the provider did not take.
    func testATargetTheProviderRefusesNoLongerHoldsBackTheRest() async throws {
        let harness = try await bootstrappedHarness(
            applyResults: [.failure(ProviderError.server(status: 403, message: "ErrorAccessDenied")), .success(())]
        ) { tuning in
            tuning.maxApplyTargets = 2
            tuning.maxOperationAttempts = 1
        }
        let conversation = ConversationID(accountID: Fixtures.accountID, providerID: "t1")
        let targets = (1...3).map { MessageID(accountID: Fixtures.accountID, providerID: String($0)) }
        try harness.engine.perform(.archive, on: targets)

        try await waitUntil("given up") { try self.failedMark(harness, conversation) == .archive }
        XCTAssertEqual(harness.provider.applyCalls.map(\.ids), [["1", "2"], ["3"]])
        XCTAssertEqual(try harness.store.message(targets[0])?.roles, [.inbox])
        XCTAssertEqual(try harness.store.message(targets[1])?.roles, [.inbox])
        XCTAssertEqual(try harness.store.message(targets[2])?.roles, [], "the slice that went out stays archived")
        await harness.shutdown()
    }

    /// A provider that changed some targets of a call and not others says which (`PartialApplyError`): the operation
    /// keeps only those, so its retry sends them alone rather than all of them again.
    func testAnOperationIsNarrowedToTheTargetsTheProviderDidNotChange() async throws {
        let harness = try await bootstrappedHarness(
            applyResults: [.failure(PartialApplyError(unapplied: ["2"], error: .server(status: 500, message: "boom")))]
        )
        let targets = (1...3).map { MessageID(accountID: Fixtures.accountID, providerID: String($0)) }
        try harness.engine.perform(.archive, on: targets)

        try await waitUntil("retried") { harness.provider.applyCalls.count == 2 }
        XCTAssertEqual(harness.provider.applyCalls.map(\.ids), [["1", "2", "3"], ["2"]])
        try await waitUntil("confirmed") { try self.pendingOperations(harness).isEmpty }
        XCTAssertTrue(try targets.allSatisfy { try harness.store.message($0)?.roles == [] })
        await harness.shutdown()
    }

    func testPollSettlingALaterUncertainOperationKeepsAnEarlierFailureMarked() async throws {
        let harness = try await bootstrappedHarness(tune: longBackoff)
        let conversation = ConversationID(accountID: Fixtures.accountID, providerID: "t1")
        let target = MessageID(accountID: Fixtures.accountID, providerID: "1")
        let farFuture = Date().addingTimeInterval(3600)
        let failed = Operation(
            accountID: Fixtures.accountID, change: .archive, targets: [target],
            createdAt: Date().addingTimeInterval(-800), status: .failed, attempts: 25, nextAttemptAt: farFuture
        )
        let uncertain = uncertain(.setStarred(true), [target], createdAgo: 700, triedAgo: 700)
        try harness.store.updateOperation(failed)
        try harness.store.updateOperation(uncertain)
        XCTAssertEqual(try failedMark(harness, conversation), .archive)

        // The poll drops the uncertain star because the provider has reported its target, not because the
        // star landed: that is no confirmation, and the archive's failure still stands.
        harness.provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(1)], cursor: "c1")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("poll applied") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }
        XCTAssertTrue(try pendingOperations(harness).isEmpty)
        XCTAssertEqual(try failedMark(harness, conversation), .archive)
        await harness.shutdown()
    }

    func testUserActionsDoNotPostponeTheChangePoll() async throws {
        let harness = try await bootstrappedHarness { $0.pollInterval = 0.3 }
        try await waitUntil("first poll") { harness.provider.changesCalls.count >= 1 }
        let pollsBefore = harness.provider.changesCalls.count
        let target = MessageID(accountID: Fixtures.accountID, providerID: "1")
        // Twelve actions 80 ms apart: a user triaging, never pausing for a whole poll interval.
        for step in 0..<12 {
            try harness.engine.perform(.setRead(step % 2 == 0), on: [target])
            try await Task.sleep(for: .milliseconds(80))
        }
        // Three polls were due in that time; two is the floor that tolerates a slow machine.
        XCTAssertGreaterThanOrEqual(harness.provider.changesCalls.count - pollsBefore, 2)
        await harness.shutdown()
    }

    func testApplyInterruptedByACrashIsReplayedOnTheNextLaunch() async throws {
        let store = InMemoryMailStore()
        let first = ScriptedProvider(accountID: Fixtures.accountID)
        first.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        first.holdApplies = true
        let harness1 = try EngineHarness(store: store, provider: first)
        harness1.engine.start()
        try await waitUntil("bootstrap complete") { try store.syncCursor(for: Fixtures.accountID) == "c0" }
        let conversation = ConversationID(accountID: Fixtures.accountID, providerID: "t1")
        try harness1.engine.perform(.archive, on: conversation)
        try await waitUntil("request in flight") { first.applyCalls.count == 1 }
        // The process dies here: the request never returns and nothing after it runs. `stop` only cancels;
        // the held apply ignores cancellation, so the store is left exactly as the runner wrote it.
        harness1.engine.stop()

        let second = ScriptedProvider(accountID: Fixtures.accountID)
        let harness2 = try EngineHarness(store: store, provider: second)
        harness2.engine.start()
        try await waitUntil("replayed after relaunch") { second.applyCalls.count == 1 }
        XCTAssertEqual(second.applyCalls.first?.change, .archive)
        XCTAssertEqual(second.applyCalls.first?.ids, ["1", "2", "3"])
        try await waitUntil("row cleared") { try store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty }
        XCTAssertTrue(try store.messages(in: conversation).allSatisfy { !$0.roles.contains(.inbox) })
        await harness2.shutdown()
        first.releaseHeldApplies()
        await harness1.shutdown()
    }

    func testFreshOperationMergedWithAnOldOneKeepsItsOwnAttemptCount() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        provider.applyResults = [.failure(ProviderError.server(status: 503, message: "unavailable"))]
        let harness = try EngineHarness(provider: provider) { $0.backoffBase = 10; $0.backoffCap = 60 }
        let m1 = MessageID(accountID: Fixtures.accountID, providerID: "1")
        let m2 = MessageID(accountID: Fixtures.accountID, providerID: "2")
        let old = Operation(
            accountID: Fixtures.accountID, change: .setRead(true), targets: [m1],
            createdAt: Date().addingTimeInterval(-60), status: .uncertain, attempts: 24
        )
        try harness.store.updateOperation(old)
        // Queued before the loop runs, so both operations go out in the same request.
        try harness.engine.perform(.setRead(true), on: [m2])
        harness.engine.start()
        try await waitUntil("merged apply attempted") { provider.applyCalls.count == 1 }
        XCTAssertEqual(provider.applyCalls.first?.ids, ["1", "2"])
        try await waitUntil("old operation given up") {
            try !self.pendingOperations(harness).contains { $0.id == old.id }
        }
        let remaining = try pendingOperations(harness)
        XCTAssertEqual(remaining.map(\.targets), [[m2]])
        let fresh = try XCTUnwrap(remaining.first)
        XCTAssertEqual(fresh.status, .uncertain)
        XCTAssertEqual(fresh.attempts, 1)
        XCTAssertNotNil(fresh.nextAttemptAt)

        // The provider never saw the change; a stale poll must not undo it while the operation is queued.
        provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(2, isRead: false)], cursor: "c1")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("stale poll applied") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }
        XCTAssertEqual(try harness.store.message(m2)?.isRead, true)
        await harness.shutdown()
    }

    func testZeroRetryAfterOnApplyStillBacksOff() async throws {
        let harness = try await bootstrappedHarness(
            applyResults: [.failure(ProviderError.throttled(retryAfter: 0))]
        ) { $0.backoffBase = 0.2 }
        let target = MessageID(accountID: Fixtures.accountID, providerID: "1")
        try harness.engine.perform(.setStarred(true), on: [target])
        try await waitUntil("retried") { harness.provider.applyCalls.count == 2 }
        let calls = harness.provider.applyCalls
        XCTAssertGreaterThanOrEqual(calls[1].at.timeIntervalSince(calls[0].at), 0.15)
        try await waitUntil("confirmed") { try self.pendingOperations(harness).isEmpty }
        await harness.shutdown()
    }

    /// A provider retry time is measured against this Mac's clock, which may be minutes off: a user action waits
    /// no longer than the live lane's cap for it.
    func testALongRetryAfterOnApplyWaitsNoLongerThanTheLiveCap() async throws {
        let harness = try await bootstrappedHarness(
            applyResults: [.failure(ProviderError.throttled(retryAfter: 3_600))]
        ) { $0.backoffCap = 600; $0.liveBackoffCap = 0.3 }
        let target = MessageID(accountID: Fixtures.accountID, providerID: "1")
        try harness.engine.perform(.setStarred(true), on: [target])
        try await waitUntil("retried within the cap", timeout: 10) { harness.provider.applyCalls.count == 2 }
        try await waitUntil("confirmed") { try self.pendingOperations(harness).isEmpty }
        await harness.shutdown()
    }

    func testGroupingMergesConsecutiveSameChangeUpToTargetLimit() {
        func ids(_ range: ClosedRange<Int>) -> [MessageID] {
            range.map { MessageID(accountID: Fixtures.accountID, providerID: "\($0)") }
        }
        let operations = [
            Operation(accountID: Fixtures.accountID, change: .archive, targets: ids(1...2)),
            Operation(accountID: Fixtures.accountID, change: .archive, targets: ids(3...3)),
            Operation(accountID: Fixtures.accountID, change: .setRead(true), targets: ids(1...1)),
            Operation(accountID: Fixtures.accountID, change: .archive, targets: ids(4...4)),
        ]
        XCTAssertEqual(OperationRunner.groups(of: operations, maxTargets: 50).map(\.count), [2, 1, 1])

        let large = [
            Operation(accountID: Fixtures.accountID, change: .archive, targets: ids(1...30)),
            Operation(accountID: Fixtures.accountID, change: .archive, targets: ids(31...60)),
            Operation(accountID: Fixtures.accountID, change: .archive, targets: ids(61...70)),
        ]
        XCTAssertEqual(OperationRunner.groups(of: large, maxTargets: 50).map(\.count), [1, 2])
    }

    func testPerformSplitsTargetsByAccount() async throws {
        let harness = try await bootstrappedHarness()
        let other = AccountID("22222222-2222-2222-2222-222222222222")
        try harness.store.upsertAccount(Fixtures.account(id: other))
        try harness.store.upsertMessages([Fixtures.message(1, account: other)])
        try harness.engine.perform(.setRead(true), on: [
            MessageID(accountID: Fixtures.accountID, providerID: "1"),
            MessageID(accountID: other, providerID: "1"),
            MessageID(accountID: Fixtures.accountID, providerID: "2"),
        ])
        let mine = try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10)
        let theirs = try harness.store.pendingOperations(accountID: other, limit: 10)
        // The first account's operation is confirmed quickly; the other account has no syncer and keeps its row.
        XCTAssertEqual(theirs.count, 1)
        XCTAssertEqual(theirs.first?.targets.map(\.providerID), ["1"])
        XCTAssertTrue(mine.count <= 1)
        XCTAssertEqual(try harness.store.message(MessageID(accountID: other, providerID: "1"))?.isRead, true)
        await harness.shutdown()
    }
}
