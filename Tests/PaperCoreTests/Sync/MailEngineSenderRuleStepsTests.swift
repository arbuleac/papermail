import Foundation
import XCTest
@testable import PaperCore

/// Always Archive Mail from This Sender through the engine (docs/ARCHITECTURE.md, "Rules"): the rule is the one
/// account's, while its steps take the sender's mail in every account, in the rule's one store transaction, one operation
/// per account, and wake each account's outbox, which sends its own share to its own provider. The undo likewise.
final class MailEngineSenderRuleStepsTests: XCTestCase {
    private let first = AccountID("acct-first")
    private let second = AccountID("acct-second")

    private func started() async throws -> (EngineHarness, [AccountID: ScriptedProvider]) {
        let providers = Dictionary(uniqueKeysWithValues: [first, second].map { id -> (AccountID, ScriptedProvider) in
            let provider = ScriptedProvider(accountID: id)
            provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0", account: id))]]
            return (id, provider)
        })
        let harness = try EngineHarness(seedAccount: false) { _ in } factory: { providers[$0.id] ?? ScriptedProvider(accountID: $0.id) }
        for (index, id) in [first, second].enumerated() {
            try harness.store.upsertAccount(Account(id: id, kind: index == 0 ? .gmail : .microsoft, email: "me\(index)@example.com",
                                                    displayName: "Me", addedAt: Fixtures.baseDate.addingTimeInterval(Double(index))))
        }
        harness.engine.start()
        for id in [first, second] {
            try await waitUntil("\(id.rawValue) bootstrapped") { try harness.store.syncCursor(for: id) == "c0" }
        }
        return (harness, providers)
    }

    private func ids(_ account: AccountID, _ numbers: [Int]) -> [MessageID] {
        numbers.map { MessageID(accountID: account, providerID: "\($0)") }
    }

    func testAlwaysArchiveTakesMailInEveryAccountWhileTheRuleStaysOnOne() async throws {
        let (harness, providers) = try await started()
        let mine = ids(first, [1, 2]), theirs = ids(second, [3])
        try harness.engine.setSenderRule(.archive, for: "sender1@example.com", accountID: first,
                                         performing: [MailActionRecord.Step(change: .archive, targets: mine + theirs)])

        // Applied before the call returned, in one transaction: the rule and both accounts' mail.
        XCTAssertEqual(try harness.store.senderRules().map(\.accountID), [first], "never a rule on another account")
        for id in mine + theirs { XCTAssertEqual(try harness.store.message(id)?.roles, [], "\(id) archived") }
        XCTAssertEqual(try harness.store.message(ids(second, [1])[0])?.roles, [.inbox], "nothing else moved")

        // Each account's outbox was woken and sent its own share.
        try await waitUntil("both outboxes sent") {
            providers[self.first]?.applyCalls.contains { $0.change == .archive } == true
                && providers[self.second]?.applyCalls.contains { $0.change == .archive } == true
        }
        XCTAssertEqual(providers[first]?.applyCalls.filter { $0.change == .archive }.map(\.ids), [["1", "2"]])
        XCTAssertEqual(providers[second]?.applyCalls.filter { $0.change == .archive }.map(\.ids), [["3"]])

        // The undo: the rule gone and every message back in its own account, in one transaction again.
        try harness.engine.setSenderRule(nil, for: "sender1@example.com", accountID: first,
                                         performing: [MailActionRecord.Step(change: .moveToInbox, targets: mine + theirs)])
        XCTAssertTrue(try harness.store.senderRules().isEmpty)
        for id in mine + theirs { XCTAssertEqual(try harness.store.message(id)?.roles, [.inbox], "\(id) back") }
        try await waitUntil("both outboxes sent the undo") {
            providers[self.first]?.applyCalls.contains { $0.change == .moveToInbox } == true
                && providers[self.second]?.applyCalls.contains { $0.change == .moveToInbox } == true
        }
        XCTAssertEqual(providers[second]?.applyCalls.filter { $0.change == .moveToInbox }.map(\.ids), [["3"]])
        await harness.shutdown()
    }

    /// A sender with thousands of messages in the Inbox makes one archive operation with thousands of targets: the outbox
    /// sends it in calls of the provider's size (50 here, as Graph's, which Graph cuts again into `$batch` requests of 20;
    /// Gmail's 1,000 ids per `batchModify`, `OperationRunnerDrainShareTests`), each target once, four calls a cycle, and
    /// the account's poll still runs between them.
    func testThousandsOfTargetsGoOutInSlicesWithThePollBetween() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        let count = 2_345
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...count, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider, tune: { $0.pollInterval = 0.05 })
        harness.engine.start()
        try await waitUntil("bootstrapped") { try harness.store.syncCursor(for: Fixtures.accountID) == "c0" }
        provider.applyDelay = 0.005
        let targets = (1...count).map { MessageID(accountID: Fixtures.accountID, providerID: "\($0)") }
        try harness.engine.setSenderRule(.archive, for: "sender1@example.com", accountID: Fixtures.accountID,
                                         performing: [MailActionRecord.Step(change: .archive, targets: targets)])
        XCTAssertEqual(try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).map(\.targets.count), [count],
                       "one operation")
        try await waitUntil("sent", timeout: 20) {
            try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty
        }
        let calls = provider.applyCalls.filter { $0.change == .archive }
        XCTAssertEqual(calls.count, (count + 49) / 50)
        XCTAssertTrue(calls.allSatisfy { $0.ids.count <= 50 })
        XCTAssertEqual(calls.flatMap(\.ids), targets.map(\.providerID), "each target once, in order")
        let (first, last) = (try XCTUnwrap(calls.first).at, try XCTUnwrap(calls.last).at)
        XCTAssertTrue(provider.changesCalls.contains { $0.at > first && $0.at < last }, "the account polled while the archive went out")
        await harness.shutdown()
    }
}
