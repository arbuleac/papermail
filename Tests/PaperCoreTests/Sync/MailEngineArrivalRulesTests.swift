import Foundation
import XCTest
@testable import PaperCore

/// Mute (roadmap Q3.7) and sender rules (Q4.2) through the engine: setting them is one store write with its operations
/// queued; mail a poll brings into a muted conversation is archived in the poll's own write and its operation replayed
/// once, without waiting for the next poll. Sender rules live on the server since v23 and take no mail at arrival (their
/// lane is `MailEngineRulesTests`).
final class MailEngineArrivalRulesTests: XCTestCase {
    private let account = Fixtures.accountID
    private var t1: ConversationID { ConversationID(accountID: account, providerID: "t1") }

    private func id(_ number: Int) -> MessageID { MessageID(accountID: account, providerID: "\(number)") }

    /// Messages 1 to 3 in conversation t1, in the Inbox. Polls every 60 s unless asked, so a test sees which outbox turn
    /// sent what: an arrival's operation goes out because the poll that brought it woke the outbox.
    private func bootstrappedHarness() async throws -> EngineHarness {
        let provider = ScriptedProvider(accountID: account)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider) { tuning in
            tuning.pollInterval = 60
            tuning.activePollInterval = 60
        }
        harness.engine.start()
        try await waitUntil("bootstrap complete") { try harness.store.syncCursor(for: self.account) == "c0" }
        return harness
    }

    private func arrival(_ number: Int, conversation: String = "t1", from: EmailAddress? = nil) -> MessageMetadata {
        var message = Fixtures.message(number, conversation: conversation)
        if let from { message.from = from }
        return message
    }

    private func poll(_ harness: EngineHarness, _ upserts: [MessageMetadata], cursor: String) async throws {
        harness.provider.enqueueChanges(.success(Fixtures.changes(upserts: upserts, cursor: cursor)))
        harness.engine.syncNow(accountID: account)
        try await waitUntil("poll \(cursor) applied") { try harness.store.syncCursor(for: self.account) == cursor }
    }

    private func pending(_ harness: EngineHarness) throws -> [PaperCore.Operation] {
        try harness.store.pendingOperations(accountID: account, limit: 10)
    }

    // MARK: Mute

    func testMutingArchivesTheConversationAndReplaysTheArchiveOnce() async throws {
        let harness = try await bootstrappedHarness()
        try harness.engine.setMuted(true, conversations: [t1],
                                    performing: [MailActionRecord.Step(change: .archive, targets: [id(1), id(2), id(3)])])
        XCTAssertTrue(try harness.store.conversations(ConversationQuery(view: .inbox)).isEmpty, "applied before it returns")
        XCTAssertEqual(try harness.store.conversations(ConversationQuery(view: .all)).first?.isMuted, true)
        try await waitUntil("archive applied") { harness.provider.applyCalls.count == 1 }
        XCTAssertEqual(harness.provider.applyCalls.first?.change, .archive)
        XCTAssertEqual(harness.provider.applyCalls.first?.ids, ["1", "2", "3"])
        await harness.shutdown()
    }

    func testMailArrivingInAMutedConversationIsArchivedAndReplayedWithoutWaitingForThePoll() async throws {
        let harness = try await bootstrappedHarness()
        try harness.engine.setMuted(true, conversations: [t1],
                                    performing: [MailActionRecord.Step(change: .archive, targets: [id(1), id(2), id(3)])])
        try await waitUntil("mute's archive applied") { harness.provider.applyCalls.count == 1 }
        try await waitUntil("mute's archive confirmed") { try self.pending(harness).isEmpty }

        let polledAt = Date()
        try await poll(harness, [arrival(4), arrival(5, conversation: "t2")], cursor: "c1")
        XCTAssertEqual(try harness.store.message(id(4))?.roles, [], "archived in the poll's own write")
        XCTAssertEqual(try harness.store.conversations(ConversationQuery(view: .inbox)).map(\.id.providerID), ["t2"])

        // The outbox goes on the poll's wake, long before the next poll (60 s away).
        try await waitUntil("arrival's archive applied") { harness.provider.applyCalls.count == 2 }
        let call = try XCTUnwrap(harness.provider.applyCalls.last)
        XCTAssertEqual(call.change, .archive)
        XCTAssertEqual(call.ids, ["4"])
        XCTAssertLessThan(call.at.timeIntervalSince(polledAt), 30)
        try await waitUntil("confirmed and gone") { try self.pending(harness).isEmpty }

        // The provider, having applied it, reports it archived; nothing more goes out.
        try await poll(harness, [Fixtures.message(4, roles: [])], cursor: "c2")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.provider.applyCalls.count, 2)
        XCTAssertEqual(try harness.store.message(id(4))?.roles, [])
        await harness.shutdown()
    }

    /// A mute set while an earlier report of the conversation still says Inbox: the provider's stale report never brings
    /// the arrival back before the archive lands.
    func testAStaleReportNeverBringsAMutedArrivalBack() async throws {
        let failures = Array(repeating: Result<Void, Error>.failure(ProviderError.network("offline")), count: 50)
        let provider = ScriptedProvider(accountID: account)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        provider.applyResults = failures
        let harness = try EngineHarness(provider: provider) { $0.backoffBase = 10; $0.backoffCap = 60 }
        harness.engine.start()
        try await waitUntil("bootstrap complete") { try harness.store.syncCursor(for: self.account) == "c0" }
        try harness.engine.setMuted(true, conversations: [t1],
                                    performing: [MailActionRecord.Step(change: .archive, targets: [id(1), id(2), id(3)])])
        try await poll(harness, [arrival(4)], cursor: "c1")
        try await poll(harness, [arrival(4), Fixtures.message(1)], cursor: "c2")
        XCTAssertTrue(try harness.store.conversations(ConversationQuery(view: .inbox)).isEmpty)
        await harness.shutdown()
    }

    // MARK: Sender rules

    /// The server's filter acts on a blocked sender's mail before this Mac sees it, so a poll stores it where the provider
    /// put it and queues nothing for the rule: no request goes out on its account.
    func testABlockedSendersArrivalIsLeftWhereTheServerPutIt() async throws {
        let harness = try await bootstrappedHarness()
        let spammer = EmailAddress(name: "Deals", address: "deals@shop.example")
        try harness.engine.setSenderRule(.trash, for: spammer.address, accountID: account, performing: [])
        XCTAssertEqual(try harness.store.senderRules().map(\.action), [.trash])
        var trashed = arrival(4, conversation: "t4", from: spammer)
        trashed.roles = [.trash]
        try await poll(harness, [trashed, arrival(5, conversation: "t5"), arrival(6, conversation: "t6", from: spammer)], cursor: "c1")
        XCTAssertEqual(try harness.store.message(id(4))?.roles, [.trash], "as the server put it")
        XCTAssertEqual(try harness.store.message(id(6))?.roles, [.inbox], "one the server did not take stays where it is")
        XCTAssertEqual(Set(try harness.store.conversations(ConversationQuery(view: .inbox)).map(\.id.providerID)), ["t1", "t5", "t6"])
        XCTAssertTrue(try pending(harness).isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(harness.provider.applyCalls.isEmpty, "nothing replayed for the rule")
        await harness.shutdown()
    }

    /// Setting a rule from a message takes that sender's mail there in the same write, and the outbox replays it.
    func testSettingARuleQueuesItsStepsAndAnUndoPutsThemBack() async throws {
        let harness = try await bootstrappedHarness()
        let sender = try XCTUnwrap(try harness.store.message(id(2))?.from)
        try harness.engine.setSenderRule(.archive, for: sender.address, accountID: account,
                                         performing: [MailActionRecord.Step(change: .archive, targets: [id(2)])])
        XCTAssertEqual(try harness.store.message(id(2))?.roles, [])
        XCTAssertEqual(try harness.store.senderRules().map(\.address), ["sender2@example.com"])
        try await waitUntil("archive applied") { harness.provider.applyCalls.count == 1 }

        try harness.engine.setSenderRule(nil, for: sender.address, accountID: account,
                                         performing: [MailActionRecord.Step(change: .moveToInbox, targets: [id(2)])])
        XCTAssertEqual(try harness.store.message(id(2))?.roles, [.inbox])
        XCTAssertTrue(try harness.store.senderRules().isEmpty)
        try await waitUntil("move back applied") { harness.provider.applyCalls.count == 2 }
        XCTAssertEqual(harness.provider.applyCalls.last?.change, .moveToInbox)

        // The sender's next message is stored as the provider reports it.
        try await poll(harness, [arrival(6, conversation: "t6", from: sender)], cursor: "c1")
        XCTAssertEqual(try harness.store.message(id(6))?.roles, [.inbox])
        await harness.shutdown()
    }

    /// A rule's steps never reach another account's mail: a rule belongs to one account.
    func testARulesStepsStayInItsAccount() async throws {
        let harness = try await bootstrappedHarness()
        let other = MessageID(accountID: AccountID("other"), providerID: "x")
        try harness.engine.setSenderRule(.trash, for: "deals@shop.example", accountID: account,
                                         performing: [MailActionRecord.Step(change: .trash, targets: [other, id(3)])])
        try await waitUntil("trash applied") { harness.provider.applyCalls.count == 1 }
        XCTAssertEqual(harness.provider.applyCalls.first?.ids, ["3"])
        await harness.shutdown()
    }
}
