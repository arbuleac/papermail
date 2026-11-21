import Foundation
import XCTest
@testable import SSCore

/// The rules lane through the engine (docs/ARCHITECTURE.md, "Rules"): the server's rules are the single source of truth,
/// read into the store's mirror after a live cycle that caught up (every half hour in front, every two hours behind), at
/// once when asked or when a write waits; the sender rules set, changed and removed on this Mac sent oldest first, an
/// identical rule on the server adopted rather than made twice; nothing sent without the scope or while the account is
/// parked; each refusal handled as the spec says, and nothing of it reaching the mail.
///
/// The rules' clock is a `HandClock` that moves only when a test moves it, so a read that happens without it moving was
/// asked for, and one that does not happen is not due.
final class MailEngineRulesTests: XCTestCase {
    private let account = Fixtures.accountID
    private let deals = "deals@shop.example"
    private let news = "news@letter.example"

    private func started(
        _ provider: ScriptedRuleProvider, clock: HandClock, tune: (inout SyncTuning) -> Void = { _ in }
    ) async throws -> EngineHarness {
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider) { tuning in
            tuning.rulesClock = clock.sendClock
            tune(&tuning)
        }
        harness.engine.start()
        try await waitUntil("head page stored") { try harness.store.syncCursor(for: Fixtures.accountID) == "c0" }
        return harness
    }

    private func rows(_ harness: EngineHarness) throws -> [String] {
        try harness.store.senderRules().filter { $0.accountID == account }
            .map { "\($0.address) \($0.action.rawValue) \($0.sync.rawValue) \($0.serverIDs.joined(separator: ","))" }
    }

    private func rulesState(_ recorder: PhaseRecorder) -> RulesSyncState? {
        recorder.latest.first { $0.accountID == account }?.rules
    }

    /// Waits for `count` more live polls, so a turn that was due would have had its chance.
    private func waitForPolls(_ count: Int, of provider: ScriptedProvider) async throws {
        let target = provider.changesCalls.count + count
        try await waitUntil("\(count) more polls") { provider.changesCalls.count >= target }
    }

    // MARK: When it reads

    func testTheFirstReadRidesTheFirstLiveCycleAndTheNextWaitsHalfAnHour() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let seeded = provider.seedRule(deals, .trash)
        provider.otherRules = 12
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }

        try await waitUntil("the first read") { provider.reads == 1 }
        try await waitUntil("mirrored") { try self.rows(harness) == ["\(self.deals) trash saved \(seeded)"] }
        try await waitUntil("up to date") { self.rulesState(recorder) == .upToDate(otherCount: 12, readAt: clock.now) }

        // The polls go on every 0.15 s; the rules are not read with each of them.
        try await waitForPolls(5, of: provider)
        XCTAssertEqual(provider.reads, 1)
        clock.advance(30 * 60 - 1)
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.reads, 1, "not before half an hour")
        clock.advance(1)
        try await waitUntil("read again after half an hour") { provider.reads == 2 }
        XCTAssertTrue(provider.writeLog.isEmpty, "a read writes nothing")
        await harness.shutdown()
    }

    func testInTheBackgroundTheRulesAreReadEveryTwoHours() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.reads == 1 }
        harness.engine.setAppActive(false)

        clock.advance(30 * 60)
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.reads, 1, "half an hour is the frontmost interval")
        clock.advance(90 * 60 - 1)
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.reads, 1)
        clock.advance(1)
        try await waitUntil("read after two hours") { provider.reads == 2 }
        await harness.shutdown()
    }

    /// Settings › Senders opening asks for a read at once, for its account or every account.
    func testARefreshReadsAtOnce() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.reads == 1 }

        let seeded = provider.seedRule(news, .archive)
        harness.engine.refreshServerRules(accountID: account)
        try await waitUntil("read for the asking") { provider.reads == 2 }
        try await waitUntil("a rule made elsewhere shown") { try self.rows(harness) == ["\(self.news) archive saved \(seeded)"] }
        harness.engine.refreshServerRules(accountID: nil)
        try await waitUntil("read for every account") { provider.reads == 3 }
        harness.engine.refreshServerRules(accountID: AccountID("nobody"))
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.reads, 3)
        await harness.shutdown()
    }

    /// A slow rules request is nobody's poll: the live lane goes on polling while a read waits for its answer.
    func testASlowRulesReadNeverHoldsBackTheMailPoll() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        provider.holdReads = true
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the read under way") { provider.reads == 1 }
        let pollsBefore = provider.changesCalls.count
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertGreaterThanOrEqual(provider.changesCalls.count - pollsBefore, 2, "the live lane kept polling meanwhile")
        XCTAssertEqual(provider.reads, 1, "and the read is not sent again meanwhile")

        let recorder = PhaseRecorder()
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        provider.releaseReads()
        try await waitUntil("the read answered") { self.rulesState(recorder) == .upToDate(otherCount: 0, readAt: clock.now) }
        await harness.shutdown()
    }

    /// A provider without server rules (a test double here) gets no rules lane: its status stays unknown, a rule set on
    /// it waits in the store, and a reconnect never asks for the rules scope for it.
    func testAProviderWithoutServerRulesKeepsNoRulesLane() async throws {
        let provider = ScriptedProvider(accountID: account)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider)
        let recorder = PhaseRecorder()
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        harness.engine.start()
        try await waitUntil("head page stored") { try harness.store.syncCursor(for: Fixtures.accountID) == "c0" }
        try harness.engine.setSenderRule(.trash, for: deals, accountID: account, performing: [])
        harness.engine.refreshServerRules(accountID: nil)
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(rulesState(recorder), .unknown)
        XCTAssertEqual(try rows(harness), ["\(deals) trash creating "])
        XCTAssertFalse(harness.engine.permissionsToAsk(for: Fixtures.account()).contains(.rules))
        await harness.shutdown()
    }

    // MARK: Permission and parking

    func testWithoutTheRulesScopeNothingIsSentAndAReconnectAsksForIt() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        provider.grantsRules = false
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("not connected") { self.rulesState(recorder) == .notConnected }
        XCTAssertFalse(harness.engine.permissionsToAsk(for: Fixtures.account()).contains(.rules),
                       "nothing waits for the scope yet: a reconnect does not ask for it")

        try harness.engine.setSenderRule(.trash, for: deals, accountID: account, performing: [])
        try await waitUntil("the permission asked of the token after the write") { provider.rulesPermissionChecks >= 2 }
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.reads, 0, "no request")
        XCTAssertTrue(provider.writeLog.isEmpty)
        XCTAssertEqual(try rows(harness), ["\(deals) trash creating "], "the rule waits as it is")
        let status = try XCTUnwrap(recorder.latest.first { $0.accountID == account })
        XCTAssertTrue(status.permissionsNeeded.isEmpty, "the outbox's reconnect ask is the outbox's alone")
        XCTAssertNotEqual(status.phase, .needsReauth)
        XCTAssertTrue(harness.engine.permissionsToAsk(for: Fixtures.account()).contains(.rules), "a reconnect now asks for it")

        // A plain reconnect asks for it while the rule waits, and once granted the next live cycle sends the rule.
        provider.grantsRules = true
        _ = try await harness.engine.reconnect(Fixtures.account())
        XCTAssertEqual(harness.authenticator.permissions.last, [.rules])
        try await waitUntil("created") { provider.createCalls == ["create \(self.deals) trash"] }
        try await waitUntil("saved") { try self.rows(harness) == ["\(self.deals) trash saved rule-1"] }
        try await waitUntil("up to date") { self.rulesState(recorder) == .upToDate(otherCount: 0, readAt: clock.now) }
        XCTAssertFalse(harness.engine.permissionsToAsk(for: Fixtures.account()).contains(.rules),
                       "nothing waits: the scope is asked for again only as one the token holds")
        await harness.shutdown()
    }

    func testConnectRulesAsksForTheScopeAndReadsOnceGranted() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        provider.grantsRules = false
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("not connected") { self.rulesState(recorder) == .notConnected }

        provider.grantsRules = true
        let connected = try await harness.engine.connectRules(Fixtures.account())
        XCTAssertEqual(connected.id, account)
        XCTAssertEqual(harness.authenticator.permissions.last, [.rules], "the rules on top of mail, with nothing queued")
        XCTAssertEqual(harness.tokenProvider.replacements, [account])
        try await waitUntil("read without waiting for the interval") { provider.reads == 1 }
        try await waitUntil("up to date") { self.rulesState(recorder) == .upToDate(otherCount: 0, readAt: clock.now) }
        await harness.shutdown()
    }

    /// Parked for sign-in, the account sends nothing for its rules; what was set meanwhile goes once it works again.
    func testAParkedAccountSendsNoRules() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.reads == 1 }

        provider.enqueueChanges(.failure(ProviderError.unauthorized))
        harness.engine.syncNow(accountID: account)
        try await waitUntil("parked") { recorder.latest.first?.phase == .needsReauth }
        try harness.engine.setSenderRule(.archive, for: news, accountID: account, performing: [])
        harness.engine.refreshServerRules(accountID: account)
        clock.advance(3 * 60 * 60)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(provider.reads, 1, "nothing read while parked")
        XCTAssertTrue(provider.writeLog.isEmpty, "nothing written")
        XCTAssertEqual(try rows(harness), ["\(news) archive creating "])

        harness.engine.syncNow(accountID: account)
        try await waitUntil("sent once the account works") { provider.createCalls == ["create \(self.news) archive"] }
        try await waitUntil("saved") { try self.rows(harness) == ["\(self.news) archive saved rule-1"] }
        await harness.shutdown()
    }

    // MARK: Writes

    func testARuleSetIsCreatedAtOnceAfterAReadAndSaved() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.reads == 1 }

        try harness.engine.setSenderRule(.trash, for: "  Deals@Shop.Example", accountID: account, performing: [])
        XCTAssertEqual(try rows(harness), ["\(deals) trash creating "], "shown before any request")
        try await waitUntil("created") { provider.createCalls.count == 1 }
        XCTAssertEqual(provider.createCalls, ["create \(deals) trash"], "only the address and the action")
        try await waitUntil("saved") { try self.rows(harness) == ["\(self.deals) trash saved rule-1"] }
        XCTAssertEqual(provider.reads, 2, "read before the create")
        XCTAssertEqual(provider.rulesOnServer.count, 1)
        await harness.shutdown()
    }

    /// The server already has the very rule (made on another device, or by a create whose reply was lost): the read before
    /// the create finds it, and it is adopted rather than made twice.
    func testAnIdenticalRuleOnTheServerIsAdoptedNotMadeTwice() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.reads == 1 }

        let elsewhere = provider.seedRule(deals, .trash)
        try harness.engine.setSenderRule(.trash, for: deals, accountID: account, performing: [])
        try await waitUntil("adopted") { try self.rows(harness) == ["\(self.deals) trash saved \(elsewhere)"] }
        try await waitForPolls(3, of: provider)
        XCTAssertTrue(provider.writeLog.isEmpty, "nothing created")
        XCTAssertEqual(provider.rulesOnServer.count, 1)
        await harness.shutdown()
    }

    func testACreateWhoseReplyWasLostIsAdoptedAtTheNextTurn() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        provider.createScripts = [.loseReply(ProviderError.network("connection lost"))]
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.reads == 1 }

        try harness.engine.setSenderRule(.archive, for: news, accountID: account, performing: [])
        try await waitUntil("the reply lost") { self.rulesState(recorder) == .failed(.unreachable, otherCount: 0) }
        XCTAssertEqual(provider.rulesOnServer.count, 1, "the server made it")
        XCTAssertEqual(try rows(harness), ["\(news) archive creating "], "this Mac never heard")

        clock.advance(1)
        try await waitUntil("adopted on the next turn") { try self.rows(harness) == ["\(self.news) archive saved rule-1"] }
        XCTAssertEqual(provider.createCalls.count, 1, "one create")
        XCTAssertEqual(provider.rulesOnServer.count, 1, "one rule")
        try await waitUntil("up to date") { self.rulesState(recorder) == .upToDate(otherCount: 0, readAt: clock.now) }
        await harness.shutdown()
    }

    /// The other action for a rule the server has: the new rule is created, then the old deleted.
    func testChangingARuleCreatesTheNewThenDeletesTheOld() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let old = provider.seedRule(deals, .archive)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("mirrored") { try self.rows(harness) == ["\(self.deals) archive saved \(old)"] }

        try harness.engine.setSenderRule(.trash, for: deals, accountID: account, performing: [])
        XCTAssertEqual(try rows(harness), ["\(deals) trash replacing \(old)"])
        try await waitUntil("replaced") { try self.rows(harness) == ["\(self.deals) trash saved rule-2"] }
        XCTAssertEqual(provider.writeLog, ["create \(deals) trash", "delete \(old)"], "the new rule first: no moment without one")
        XCTAssertEqual(provider.rulesOnServer, [ServerSenderRule(serverID: "rule-2", address: deals, action: .trash)])
        await harness.shutdown()
    }

    /// An undo of a change before it went out: the server's own rule is the one wanted, so nothing is written.
    func testAChangeUndoneBeforeItWentOutWritesNothing() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        provider.grantsRules = false
        let old = provider.seedRule(deals, .archive)
        let harness = try await started(provider, clock: clock)
        try harness.store.replaceServerSenderRules(accountID: account, with: provider.rulesOnServer, readAt: clock.now)
        try harness.engine.setSenderRule(.trash, for: deals, accountID: account, performing: [])
        try harness.engine.setSenderRule(.archive, for: deals, accountID: account, performing: [])
        XCTAssertEqual(try rows(harness), ["\(deals) archive replacing \(old)"])

        provider.grantsRules = true
        harness.engine.refreshServerRules(accountID: account)
        try await waitUntil("back as it was") { try self.rows(harness) == ["\(self.deals) archive saved \(old)"] }
        XCTAssertTrue(provider.writeLog.isEmpty)
        await harness.shutdown()
    }

    /// Removed on this Mac, a rule is deleted on the server (every rule it holds for the sender: Gmail's archive filter
    /// beside its trash filter), and a rule the server no longer has counts as deleted.
    func testRemovingARuleDeletesEveryRuleTheServerHoldsForTheSender() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let archive = provider.seedRule(deals, .archive)
        let trash = provider.seedRule(deals, .trash)
        let gone = provider.seedRule(news, .archive)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("mirrored") {
            try self.rows(harness) == ["\(self.deals) trash saved \(archive),\(trash)", "\(self.news) archive saved \(gone)"]
        }
        provider.grantsRules = false
        try harness.engine.setSenderRule(nil, for: deals, accountID: account, performing: [])
        try harness.engine.setSenderRule(nil, for: news, accountID: account, performing: [])
        provider.removeRule(gone)
        XCTAssertEqual(try rows(harness), ["\(deals) trash deleting \(archive),\(trash)", "\(news) archive deleting \(gone)"])

        provider.grantsRules = true
        harness.engine.refreshServerRules(accountID: account)
        try await waitUntil("deleted") { try self.rows(harness).isEmpty }
        XCTAssertEqual(provider.writeLog, ["delete \(archive)", "delete \(trash)"],
                       "the read found the other already gone: no request for it")
        XCTAssertTrue(provider.rulesOnServer.isEmpty)
        await harness.shutdown()
    }

    /// Whatever the user did while the lane could not send goes out in the order it was done.
    func testPendingWritesAreReplayedOldestFirst() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        provider.grantsRules = false
        let a = provider.seedRule("a@x.example", .archive)
        let b = provider.seedRule("b@x.example", .archive)
        let harness = try await started(provider, clock: clock)
        try harness.store.replaceServerSenderRules(accountID: account, with: provider.rulesOnServer, readAt: clock.now)
        let base = clock.now
        try harness.store.setSenderRule(.trash, for: "z@x.example", accountID: account, enqueueing: [], at: base.addingTimeInterval(2))
        try harness.store.setSenderRule(nil, for: "a@x.example", accountID: account, enqueueing: [], at: base.addingTimeInterval(1))
        try harness.store.setSenderRule(.trash, for: "b@x.example", accountID: account, enqueueing: [], at: base.addingTimeInterval(3))
        try harness.store.setSenderRule(.archive, for: "c@x.example", accountID: account, enqueueing: [], at: base.addingTimeInterval(4))

        provider.grantsRules = true
        harness.engine.refreshServerRules(accountID: account)
        try await waitUntil("all sent") { try harness.store.pendingSenderRules(accountID: self.account).isEmpty }
        XCTAssertEqual(provider.writeLog, [
            "delete \(a)", "create z@x.example trash", "create b@x.example trash", "delete \(b)", "create c@x.example archive",
        ])
        XCTAssertEqual(try rows(harness), ["b@x.example trash saved rule-4", "c@x.example archive saved rule-5",
                                           "z@x.example trash saved rule-3"])
        await harness.shutdown()
    }

    /// The read replaces the mirror's saved rows with the server's (a rule changed or deleted on the web shows here) and
    /// leaves the rows on their way alone.
    func testAReadReplacesTheSavedRowsAndKeepsThePendingOnes() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let kept = provider.seedRule(deals, .archive)
        let deletedElsewhere = provider.seedRule(news, .trash)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("mirrored") { try self.rows(harness).count == 2 }

        provider.removeRule(deletedElsewhere)
        let added = provider.seedRule("new@x.example", .trash)
        provider.createScripts = [.fail(ProviderError.server(status: 500, message: "boom"))]
        try harness.engine.setSenderRule(.archive, for: "pending@x.example", accountID: account, performing: [])
        try await waitUntil("the create failed") { provider.createCalls.count == 1 }
        try await waitUntil("read") {
            try self.rows(harness) == ["\(self.deals) archive saved \(kept)", "new@x.example trash saved \(added)",
                                       "pending@x.example archive creating "]
        }
        clock.advance(1)
        try await waitUntil("sent on the next turn") { try harness.store.pendingSenderRules(accountID: self.account).isEmpty }
        await harness.shutdown()
    }

    func testARuleRemovedWhileItsCreateWasOnItsWayIsDeletedThere() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.reads == 1 }
        provider.holdCreates = true

        try harness.engine.setSenderRule(.trash, for: deals, accountID: account, performing: [])
        try await waitUntil("create under way") { provider.createCalls.count == 1 }
        try harness.engine.setSenderRule(nil, for: deals, accountID: account, performing: [])
        XCTAssertTrue(try rows(harness).isEmpty, "gone from Senders at once")
        provider.holdCreates = false

        try await waitUntil("the rule made meanwhile deleted") { provider.deleteCalls == ["rule-1"] }
        XCTAssertTrue(provider.rulesOnServer.isEmpty)
        try await waitForPolls(3, of: provider)
        XCTAssertTrue(try rows(harness).isEmpty)
        await harness.shutdown()
    }

    // MARK: Failures

    /// Gmail's cap on filters: the rule is given up (gone from Senders) and the failure said, through the reads that follow,
    /// until a later write goes through.
    func testALimitOnACreateGivesTheRuleUpAndSaysSo() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        provider.otherRules = 1_000
        provider.createScripts = [.fail(RuleProviderError.limitReached)]
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.reads == 1 }

        try harness.engine.setSenderRule(.trash, for: deals, accountID: account, performing: [])
        try await waitUntil("said") { self.rulesState(recorder) == .failed(.limitReached, otherCount: 1_000) }
        XCTAssertTrue(try rows(harness).isEmpty, "given up")
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.createCalls.count, 1, "never tried again")

        // A read alone (Settings opening) keeps saying it; the next write that goes through clears it.
        let reads = provider.reads
        harness.engine.refreshServerRules(accountID: account)
        try await waitUntil("read") { provider.reads == reads + 1 }
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(rulesState(recorder), .failed(.limitReached, otherCount: 1_000))
        try harness.engine.setSenderRule(.archive, for: news, accountID: account, performing: [])
        try await waitUntil("the next write clears it") {
            self.rulesState(recorder) == .upToDate(otherCount: 1_000, readAt: clock.now)
        }
        await harness.shutdown()
    }

    func testARefusedCreateIsGivenUpAndARefusedDeleteIsBackAsTheServerHasIt() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let kept = provider.seedRule(news, .archive)
        provider.createScripts = [.fail(RuleProviderError.refused)]
        provider.deleteResults = [RuleProviderError.refused]
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("mirrored") { try self.rows(harness) == ["\(self.news) archive saved \(kept)"] }

        provider.grantsRules = false
        try harness.engine.setSenderRule(.trash, for: deals, accountID: account, performing: [])
        try harness.engine.setSenderRule(nil, for: news, accountID: account, performing: [])
        provider.grantsRules = true
        harness.engine.refreshServerRules(accountID: account)
        try await waitUntil("said") { self.rulesState(recorder) == .failed(.refused, otherCount: 0) }
        try await waitUntil("both settled") { try harness.store.pendingSenderRules(accountID: self.account).isEmpty }
        XCTAssertEqual(try rows(harness), ["\(news) archive saved \(kept)"], "the block given up; the removal undone")
        XCTAssertEqual(provider.rulesOnServer.map(\.serverID), [kept])
        await harness.shutdown()
    }

    /// The token turns out to lack the scope on the write itself (the granted scopes said otherwise): not connected, the
    /// rule waits, and a reconnect asks for the scope.
    func testAPermissionRefusalOnAWriteLeavesItWaiting() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        provider.createScripts = [.fail(RuleProviderError.permissionMissing)]
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.reads == 1 }

        try harness.engine.setSenderRule(.archive, for: news, accountID: account, performing: [])
        try await waitUntil("not connected") { self.rulesState(recorder) == .notConnected }
        XCTAssertEqual(try rows(harness), ["\(news) archive creating "])
        XCTAssertTrue(harness.engine.permissionsToAsk(for: Fixtures.account()).contains(.rules))
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.createCalls.count, 1, "nothing more sent without the scope")

        // Once the scope is granted, the next live cycle sends it.
        provider.grantsRules = true
        try await waitUntil("sent at the next look") { try self.rows(harness) == ["\(self.news) archive saved rule-1"] }
        await harness.shutdown()
    }

    /// A rule the provider keeps failing for a reason of its own (a 500 for that one rule) is given up after its tries, so
    /// it never holds the others back; a failure every request would meet (the network) costs a rule none of its tries.
    func testARuleThatKeepsFailingIsGivenUpAfterItsTries() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.reads == 1 }

        provider.createScripts = [.fail(ProviderError.network("offline"))]
            + Array(repeating: .fail(ProviderError.server(status: 500, message: "boom")), count: 5)
        try harness.engine.setSenderRule(.trash, for: deals, accountID: account, performing: [])
        try await waitUntil("the first try") { provider.createCalls.count == 1 }
        try await waitUntil("failing") { self.rulesState(recorder) == .failed(.unreachable, otherCount: 0) }
        // Each try waits out its backoff on the hand clock, moved on until the next one goes.
        try await waitUntil("given up after five tries of its own") {
            clock.advance(1)
            return provider.createCalls.count == 6
        }
        try await waitUntil("said") { self.rulesState(recorder) == .failed(.refused, otherCount: 0) }
        XCTAssertTrue(try rows(harness).isEmpty)
        await harness.shutdown()
    }

    /// Whatever the rules meet (a refused token, a throttle, the service, the scope), the mail goes on: the phase never
    /// leaves its polls, no reconnect is asked for by the outbox, the token is never thrown away, and the status says it.
    func testRulesFailuresNeverReachTheMail() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        provider.readResults = [
            ProviderError.unauthorized, ProviderError.throttled(retryAfter: 1), ProviderError.server(status: 503, message: "busy"),
            ProviderError.server(status: 400, message: "bad"), RuleProviderError.permissionMissing,
        ]
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }

        let steps: [RulesSyncState] = [
            .failed(.unreachable, otherCount: nil), .failed(.unreachable, otherCount: nil), .failed(.unreachable, otherCount: nil),
            .failed(.refused, otherCount: nil), .notConnected,
        ]
        for (index, state) in steps.enumerated() {
            try await waitUntil("read \(index + 1)") { provider.reads == index + 1 }
            try await waitUntil("state after read \(index + 1)") { self.rulesState(recorder) == state }
            let status = try XCTUnwrap(recorder.latest.first { $0.accountID == account })
            XCTAssertTrue(status.permissionsNeeded.isEmpty, "read \(index + 1)")
            XCTAssertNil(status.message, "read \(index + 1): the sync line says nothing")
            XCTAssertNil(status.retryAt, "read \(index + 1)")
            clock.advance(2)
        }
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.reads, 5, "without the scope, no read")
        provider.grantsRules = true
        try await waitUntil("up to date at last") { provider.reads == 6 }
        try await waitUntil("up to date") { self.rulesState(recorder) == .upToDate(otherCount: 0, readAt: clock.now) }
        XCTAssertFalse(recorder.seen.contains(.error))
        XCTAssertFalse(recorder.seen.contains(.needsReauth))
        XCTAssertTrue(harness.tokenProvider.invalidations.isEmpty, "a rules 401 never throws the token away")
        await harness.shutdown()
    }

    func testRemovingTheAccountStopsItsRules() async throws {
        let clock = HandClock()
        let provider = ScriptedRuleProvider(accountID: account)
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.reads == 1 }

        try await harness.engine.removeAccount(account)
        try await waitUntil("its status gone") { !recorder.latest.contains { $0.accountID == self.account } }
        harness.engine.refreshServerRules(accountID: nil)
        clock.advance(3 * 60 * 60)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(provider.reads, 1, "nothing read for an account that has gone")
        await harness.shutdown()
    }
}

/// The lane alone, for what the engine's harness cannot measure: what each rules request costs on the mail's quota, and
/// which budget a throttle on it pauses.
final class RulesLaneQuotaTests: XCTestCase {
    private let account = Fixtures.accountID

    private func lane(_ provider: ScriptedRuleProvider, quota: ProviderQuota, start: Date)
        throws -> (RulesLane, QuotaBudget, InMemoryMailStore) {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        // The budget's clock stands still, so nothing refills between two readings.
        let budget = QuotaBudget(quota: quota, now: { start })
        let lane = RulesLane(accountID: account, store: store, provider: provider, statusCenter: SyncStatusCenter(),
                             tuning: SyncTuning(), budget: budget, link: LaneLink(), isAppActive: { true })
        return (lane, budget, store)
    }

    func testGmailFiltersAreChargedAsGmailCallsAndAThrottlePausesTheBackfill() async throws {
        let start = Date()
        let provider = ScriptedRuleProvider(accountID: account, kind: .gmail)
        let old = provider.seedRule("deals@shop.example", .archive)
        let (lane, budget, store) = try lane(provider, quota: .standard(for: .gmail), start: start)
        var before = await budget.liveHeadroom
        await lane.turn()
        var after = await budget.liveHeadroom
        XCTAssertEqual(before - after, 1, accuracy: 1e-9, "filters.list")

        try store.setSenderRule(.trash, for: "deals@shop.example", accountID: account, enqueueing: [], at: start)
        before = after
        await lane.turn()
        after = await budget.liveHeadroom
        XCTAssertEqual(before - after, 1 + 5 + 5, accuracy: 1e-9, "the read, the create and the delete of \(old)")

        provider.readResults = [ProviderError.throttled(retryAfter: 30)]
        await lane.turn()
        let paused = await budget.pausedUntil
        XCTAssertEqual(paused, start.addingTimeInterval(30), "Gmail's quota is the mail's: the backfill pauses too")
    }

    func testOutlookRulesSpendTheMailboxsRequests() async throws {
        let start = Date()
        let provider = ScriptedRuleProvider(accountID: account, kind: .microsoft)
        provider.requestsPerRead = 7
        let (lane, budget, store) = try lane(provider, quota: .standard(for: .microsoft), start: start)
        var before = await budget.liveHeadroom
        await lane.turn()
        var after = await budget.liveHeadroom
        XCTAssertEqual(before - after, 7, accuracy: 1e-9, "a read's requests, folder lookups included")

        provider.requestsPerRead = 1
        try store.setSenderRule(.archive, for: "news@letter.example", accountID: account, enqueueing: [], at: start)
        before = after
        await lane.turn()
        after = await budget.liveHeadroom
        XCTAssertEqual(before - after, 1 + 2, accuracy: 1e-9, "the read, then the create, which reads the rules for its order")
    }

    func testTheStandardQuotasSayWhatARulesRequestCosts() {
        let gmail = ProviderQuota.standard(for: .gmail)
        XCTAssertEqual([gmail.ruleReadCost, gmail.ruleCreateCost, gmail.ruleDeleteCost], [1, 5, 5])
        let graph = ProviderQuota.standard(for: .microsoft)
        XCTAssertEqual([graph.ruleReadCost, graph.ruleCreateCost, graph.ruleDeleteCost], [1, 2, 1])
    }
}
