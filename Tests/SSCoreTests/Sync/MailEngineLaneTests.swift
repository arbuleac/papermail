import Foundation
import XCTest
@testable import SSCore

/// The two lanes: the live lane keeps new mail and the outbox moving whatever the backfill lane is doing, and
/// the backfill lane's writes never undo what the live lane wrote.
final class MailEngineLaneTests: XCTestCase {
    private func id(_ number: Int) -> MessageID {
        MessageID(accountID: Fixtures.accountID, providerID: "\(number)")
    }

    // MARK: Live lane independence

    func testNewMailArrivesWhileEveryBackfillRequestIsThrottled() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [[
            "": .success(Fixtures.page(1...3, next: "p2", cursor: "c0")),
            "p2": .failure(ProviderError.throttled(retryAfter: 0.05)),
        ]]
        provider.bodies["20"] = .success(MessageBody(html: nil, text: "new"))
        let harness = try EngineHarness(provider: provider)
        let store = harness.store
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("head page stored") { try store.syncCursor(for: Fixtures.accountID) == "c0" }
        try await waitUntil("the backfill is throttled again and again") { provider.backfillListingCalls.count >= 2 }
        try await waitUntil("paused older mail under an idle live lane") {
            statuses.latest.first.map { $0.backfillPausedUntil != nil && $0.phase == .idle } ?? false
        }

        // Every backfill request is throttled for good, so a live lane that waited on the backfill would never get here.
        provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(20, conversation: "t9")], cursor: "c1")))
        try harness.engine.perform(.archive, on: ConversationID(accountID: Fixtures.accountID, providerID: "t1"))
        try await waitUntil("new mail landed") { try store.message(self.id(20)) != nil }
        // Only the live lane can fetch it: the backfill's body batches follow listing pages, and none gets through.
        try await waitUntil("its body fetched by the live lane") { try store.body(for: self.id(20)) != nil }
        try await waitUntil("the archive reached the provider") { provider.applyCalls.count == 1 }
        XCTAssertEqual(provider.applyCalls.first?.change, .archive)
        XCTAssertEqual(provider.applyCalls.first?.ids, ["1", "2", "3"])
        XCTAssertEqual(try store.bootstrapState(for: Fixtures.accountID)?.isComplete, false)
        XCTAssertTrue(provider.backfillListingCalls.allSatisfy { $0.page == "p2" })
        observation.cancel()
        await harness.shutdown()
    }

    /// A live throttle backs off on the regular schedule, but never past `liveBackoffCap`, however high
    /// `backoffCap` (which still bounds the backfill and the outbox) is.
    func testALiveThrottleBacksOffNoLongerThanTheLiveCap() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        provider.changesQueue = Array(repeating: .failure(ProviderError.throttled(retryAfter: nil)), count: 5)
            + [.success(Fixtures.changes(cursor: "c1"))]
        let harness = try EngineHarness(provider: provider) {
            $0.backoffBase = 0.1
            $0.backoffCap = 10
            $0.liveBackoffCap = 0.3
        }
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("recovered") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }
        let times = provider.changesCalls.prefix(6).map(\.at)
        guard times.count == 6 else { return XCTFail("expected six change calls, saw \(times.count)") }
        let gaps = intervals(between: times)
        XCTAssertGreaterThanOrEqual(gaps[1], 0.15, "the schedule doubles")
        // Uncapped, the fourth and fifth waits would be 0.8 s and 1.6 s. A stalled machine can stretch one gap,
        // never shorten it, so the shorter of the two shows the cap.
        XCTAssertLessThan(min(gaps[3], gaps[4]), 0.7)
        XCTAssertGreaterThanOrEqual(gaps[4], 0.25, "still backing off, at the cap")
        XCTAssertTrue(statuses.seen.contains(.paused), "the Slow state reads the live lane's throttle")
        observation.cancel()
        await harness.shutdown()
    }

    /// A provider's retry time is honoured only up to `liveBackoffCap`: one an hour away (a skewed Mac clock, a
    /// misread error body) must not stop new mail for an hour.
    func testALiveRetryAfterIsHonouredOnlyUpToTheLiveCap() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        provider.changesQueue = [.failure(ProviderError.throttled(retryAfter: 3_600)), .success(Fixtures.changes(cursor: "c1"))]
        let harness = try EngineHarness(provider: provider) {
            $0.backoffCap = 10
            $0.liveBackoffCap = 0.3
        }
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("polled again within the cap, not in an hour") {
            try harness.store.syncCursor(for: Fixtures.accountID) == "c1"
        }
        let calls = provider.changesCalls
        XCTAssertGreaterThanOrEqual(calls[1].at.timeIntervalSince(calls[0].at), 0.25, "it still waited, up to the cap")
        XCTAssertTrue(statuses.seen.contains(.paused))
        observation.cancel()
        await harness.shutdown()
    }

    /// Only a check someone asked for shows `.syncing`; the routine one every few seconds leaves the phase alone,
    /// or the status would flicker (and clear an error or a Slow state) on every poll.
    func testOnlyARequestedCheckShowsSyncing() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        // Long enough for every phase a poll publishes to reach the observer.
        provider.changesDelay = 0.05
        let harness = try EngineHarness(provider: provider)
        harness.engine.start()
        // The first cycle is a requested one; the second call starts only after it.
        try await waitUntil("the first check done") { provider.changesCalls.count >= 2 }
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        let before = provider.changesCalls.count
        try await waitUntil("routine checks") { provider.changesCalls.count >= before + 4 }
        XCTAssertFalse(statuses.seen.contains(.syncing), "a routine check leaves the phase alone")
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("a requested check shows syncing") { statuses.seen.contains(.syncing) }
        observation.cancel()
        await harness.shutdown()
    }

    /// Frontmost, the live lane checks every `activePollInterval`; in the background every `pollInterval`; coming
    /// to the front checks at once instead of waiting out the background interval.
    func testPollsFollowWhetherTheAppIsActive() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider) {
            $0.pollInterval = 0.6
            $0.activePollInterval = 0.05
        }
        // A stalled machine stretches gaps and never shortens them: upper bounds look at the shortest of several
        // gaps, lower bounds at every one.
        harness.engine.start()
        try await waitUntil("active polling") { provider.changesCalls.count >= 5 }
        let active = intervals(between: provider.changesCalls.suffix(4).map(\.at))
        XCTAssertLessThan(active.min() ?? .infinity, 0.3)

        harness.engine.setAppActive(false)
        // The wait booked while active ends first; every check after it is a background interval from the next.
        try await Task.sleep(for: .milliseconds(200))
        let mark = provider.changesCalls.count
        try await waitUntil("background checks") { provider.changesCalls.count >= mark + 3 }
        let background = intervals(between: Array(provider.changesCalls.map(\.at)[mark...]))
        for gap in background {
            XCTAssertGreaterThanOrEqual(gap, 0.5)
        }

        // Activation right after a background check, when the next one is 0.6 s away; twice, so that one stall
        // cannot fail it.
        var latencies: [TimeInterval] = []
        for _ in 0..<2 {
            let count = provider.changesCalls.count
            try await waitUntil("a background check") { provider.changesCalls.count > count }
            let before = provider.changesCalls.count
            let activatedAt = Date()
            harness.engine.setAppActive(true)
            try await waitUntil("checked on activation") { provider.changesCalls.count > before }
            latencies.append(provider.changesCalls[before].at.timeIntervalSince(activatedAt))
            harness.engine.setAppActive(false)
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertLessThan(latencies.min() ?? .infinity, 0.3)

        harness.engine.setAppActive(true)
        let resumed = provider.changesCalls.count
        try await waitUntil("active polling again") { provider.changesCalls.count >= resumed + 4 }
        let again = intervals(between: provider.changesCalls.suffix(3).map(\.at))
        XCTAssertLessThan(again.min() ?? .infinity, 0.3)
        await harness.shutdown()
    }

    // MARK: Backfill writes

    /// A backfill page fetched before a live change and written after it must neither bring back what the live
    /// lane deleted nor overwrite what it wrote.
    func testABackfillPageFetchedBeforeALiveChangeCannotUndoIt() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [[
            "": .success(Fixtures.page(1...3, next: "p2", cursor: "c0")),
            "p2": .success(Fixtures.page(4...6, next: nil)),
        ]]
        provider.gatedBootstrapPages = ["p2"]
        let harness = try EngineHarness(provider: provider)
        let store = harness.store
        harness.engine.start()
        // The page is fetched (with 5 unread and 6 present) and held until the live lane has moved on.
        try await waitUntil("page two in flight") { provider.backfillListingCalls.count == 1 }
        provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(5, isRead: true)], deleted: ["6"], cursor: "c1")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("live change applied") { try store.syncCursor(for: Fixtures.accountID) == "c1" }
        XCTAssertEqual(try store.message(id(5))?.isRead, true)

        provider.openGate("p2")
        try await waitUntil("backfill complete") { try store.bootstrapState(for: Fixtures.accountID)?.isComplete == true }
        XCTAssertNil(try store.message(id(6)), "the deleted message stays deleted")
        XCTAssertEqual(try store.message(id(5))?.isRead, true, "the live state stays")
        XCTAssertNotNil(try store.message(id(4)), "the rest of the page lands")
        await harness.shutdown()
    }

    /// An ids-only listing (Gmail's) is followed by metadata requests for the ids the store lacks, ten at a time,
    /// each written as it arrives. A throttle mid-page keeps the chunks already written, and the page's retry
    /// asks only for the rest.
    func testIDsOnlyListingsFetchMetadataForUnknownIDsInChunks() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.backfillIDsOnly = true
        provider.bootstrapRuns = [[
            "": .success(Fixtures.page(1...5, next: "p2", cursor: "c0")),
            // The listing overlaps the head page, as a Gmail listing does when new mail shifts it.
            "p2": .success(Fixtures.page(1...30, next: nil)),
        ]]
        provider.metadataResults = [.success(()), .failure(ProviderError.throttled(retryAfter: nil))]
        let harness = try EngineHarness(provider: provider)
        let store = harness.store
        harness.engine.start()
        try await waitUntil("backfill complete") { try store.bootstrapState(for: Fixtures.accountID)?.isComplete == true }
        func ids(_ range: ClosedRange<Int>) -> [String] { range.map(String.init) }
        XCTAssertEqual(provider.metadataCalls, [ids(6...15), ids(16...25), ids(16...25), ids(26...30)])
        XCTAssertEqual(provider.backfillListingCalls.map(\.page), ["p2", "p2"])
        XCTAssertEqual(try allMessages(store).count, 30)
        XCTAssertEqual(try store.bootstrapState(for: Fixtures.accountID)?.pagesDone, 2)
        XCTAssertFalse(provider.bootstrapCalls.contains("p2"), "an ids-only listing does not go through bootstrap")
        await harness.shutdown()
    }

    /// Bodies stored before v3 get their design facts after every backfill body batch, while the listing is still
    /// under way too (docs/DATA-MODEL.md), not only once every body of the mailbox has arrived.
    func testDesignFactsCatchUpWhileTheListingIsUnderWay() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [[
            "": .success(Fixtures.page(1...2, next: "p2", cursor: "c0")),
            "p2": .success(Fixtures.page(3...4, next: "p3")),
            "p3": .success(Fixtures.page(5...6, next: nil)),
        ]]
        provider.gatedBootstrapPages = ["p3"]
        let harness = try EngineHarness(provider: provider)
        let store = harness.store
        try store.upsertMessages([Fixtures.message(50)])
        // Stored before v3: no design facts.
        try store.saveBody(StoredBody(body: MessageBody(html: nil, text: "old"), renderedHTML: "", plainText: "old"), for: id(50))
        harness.engine.start()
        try await waitUntil("page two listed") { try store.bootstrapState(for: Fixtures.accountID)?.pagesDone == 2 }
        try await waitUntil("the old body's design facts") { try store.body(for: self.id(50))?.typesetting != nil }
        XCTAssertEqual(try store.bootstrapState(for: Fixtures.accountID)?.isComplete, false, "the listing still under way")
        provider.openGate("p3")
        await harness.shutdown()
    }

    // MARK: Adopting and reconciling

    /// The download the single-loop engine left in progress (the user's account: page 119, a cursor saved with
    /// the first page, no sync cursor) is adopted: the saved cursor becomes the sync cursor before any backfill
    /// request, the first poll brings in what arrived since, and the backfill resumes at the saved page. Its
    /// progress shows at launch, before the backfill lane (which waits for the live lane's first cycle) runs.
    func testAnOldDownloadInProgressIsAdopted() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages((1...6).map { Fixtures.message($0) })
        var state = BootstrapState(startedAt: Date(timeIntervalSinceNow: -5 * 86_400), pagesDone: 2, messagesSeen: 6, estimatedTotal: 9)
        state.checkpoint = BootstrapCheckpoint(providerPage: "p3", changeCursor: "c-old")
        try store.setBootstrapState(state, for: account)
        XCTAssertNil(try store.syncCursor(for: account))

        let provider = ScriptedProvider(accountID: account)
        provider.bootstrapRuns = [["p3": .success(Fixtures.page(7...9, next: nil))]]
        provider.gatedBootstrapPages = ["p3"]
        provider.changesQueue = [.success(Fixtures.changes(upserts: [Fixtures.message(100, conversation: "new")], cursor: "c1"))]
        // The first poll is held, so the live lane's first cycle cannot end yet.
        provider.holdChanges = true
        let cursorsAtListing = Recorded<String?>()
        provider.onBackfillListing = { _ in cursorsAtListing.append(try? store.syncCursor(for: account)) }
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false)
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()

        try await waitUntil("the old download's progress shows at launch") {
            statuses.latest.first.map { $0.backfillProgress == 6 && $0.backfillTotal == 9 } ?? false
        }
        try await waitUntil("the first poll under way") { !provider.changesCalls.isEmpty }
        XCTAssertTrue(provider.backfillListingCalls.isEmpty, "the backfill waits for the live lane's first cycle")
        provider.releaseChanges()
        try await waitUntil("missing mail polled in") { try store.message(self.id(100)) != nil }
        XCTAssertEqual(provider.changesCalls.first?.cursor, "c-old")
        provider.openGate("p3")
        try await waitUntil("backfill complete") { try store.bootstrapState(for: account)?.isComplete == true }
        XCTAssertFalse(cursorsAtListing.values.isEmpty)
        XCTAssertTrue(cursorsAtListing.values.allSatisfy { $0 != nil }, "the cursor was in place before any backfill request")
        XCTAssertFalse(provider.bootstrapCalls.contains(nil), "no head page: the saved cursor already covers it")
        XCTAssertEqual(provider.backfillListingCalls.map(\.page), ["p3"])
        let final = try XCTUnwrap(try store.bootstrapState(for: account))
        XCTAssertEqual(final.pagesDone, 3)
        XCTAssertEqual(final.messagesSeen, 9)
        XCTAssertEqual(try allMessages(store).count, 10)
        XCTAssertEqual(try store.syncCursor(for: account), "c1")
        try await waitUntil("backfill fields cleared") { statuses.latest.first?.backfillProgress == nil }
        observation.cancel()
        await harness.shutdown()
    }

    /// A rejected cursor keeps the stored mail: a fresh head page brings a new cursor, and a reconciling backfill
    /// lists the rest behind the live lane. It refreshes stale rows, leaves alone what the live lane changed
    /// meanwhile, and at the end removes what the provider no longer lists, except a message a live operation
    /// still targets.
    func testAResetKeepsStoredMailAndReconcilesBehindTheLiveLane() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [[
            "": .success(Fixtures.page(1...2, next: "p2", cursor: "c9")),
            // Fetched before the live lane stars 6: 3 is fresher than the stored row, 6 staler.
            "p2": .success(BootstrapPage(messages: [Fixtures.message(3, isRead: true), Fixtures.message(6)], nextPage: nil, changeCursor: nil)),
        ]]
        provider.gatedBootstrapPages = ["p2"]
        provider.changesQueue = [.failure(ProviderError.resetRequired)]
        // The star on 5 cannot reach the provider, so it stays a live operation. The provider still has 5 (in
        // Trash, which the listing leaves out), so the check before the sweep keeps it.
        provider.applyResults = Array(repeating: .failure(ProviderError.network("offline")), count: 20)
        provider.metadataByID["5"] = Fixtures.message(5, roles: [.trash])
        let harness = try EngineHarness(provider: provider) { $0.backoffBase = 10; $0.backoffCap = 60 }
        let store = harness.store
        let account = Fixtures.accountID
        try store.upsertMessages((1...6).map { Fixtures.message($0) })
        try store.saveBody(StoredBody(body: MessageBody(html: nil, text: "kept"), renderedHTML: "", plainText: "kept"), for: id(1))
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 6, isComplete: true), for: account)
        try store.enqueue(Operation(accountID: account, change: .setStarred(true), targets: [id(5)]))
        harness.engine.start()

        try await waitUntil("fresh cursor") { try store.syncCursor(for: account) == "c9" }
        try await waitUntil("the reconcile's page two in flight") { provider.backfillListingCalls.count == 1 }
        let midway = try XCTUnwrap(try store.bootstrapState(for: account))
        XCTAssertEqual(midway.reconciling, true)
        XCTAssertFalse(midway.isComplete)
        XCTAssertEqual(try allMessages(store).count, 6, "nothing wiped")
        provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(6, isStarred: true)], cursor: "c10")))
        harness.engine.syncNow(accountID: account)
        try await waitUntil("live change applied") { try store.syncCursor(for: account) == "c10" }

        provider.openGate("p2")
        try await waitUntil("reconcile complete") { try store.bootstrapState(for: account)?.isComplete == true }
        XCTAssertEqual(Set(try allMessages(store).map(\.id.providerID)), ["1", "2", "3", "5", "6"])
        XCTAssertEqual(try store.message(id(3))?.isRead, true, "a stale row is refreshed")
        XCTAssertEqual(try store.message(id(6))?.isStarred, true, "the live change is not overwritten")
        XCTAssertEqual(try store.message(id(5))?.isStarred, true, "kept for its operation")
        XCTAssertEqual(try store.body(for: id(1))?.plainText, "kept")
        XCTAssertEqual(provider.bootstrapCalls, [nil, "p2"])
        let final = try XCTUnwrap(try store.bootstrapState(for: account))
        XCTAssertEqual(final.reconciling, true)
        XCTAssertEqual(final.messagesSeen, 4)
        await harness.shutdown()
    }

    /// A reset that cannot get its head page (offline, throttled, a quit) leaves the reconcile already running as
    /// it was, marks and all. Had it cleared the marks first, that reconcile would resume at its saved page and
    /// sweep everything it listed before, though the provider still lists it.
    func testAFailedResetLeavesTheRunningReconcileItsMarks() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [
            // The first reset's head lists 1 and 2; its reconcile lists 3 and 4 on page two.
            ["": .success(Fixtures.page(1...2, next: "p2", cursor: "c9")), "p2": .success(Fixtures.page(3...4, next: nil))],
            // The provider rejects the fresh cursor too, and the second reset's head fails.
            ["": .failure(ProviderError.network("offline")), "p2": .success(Fixtures.page(3...4, next: nil))],
        ]
        provider.gatedBootstrapPages = ["p2"]
        provider.changesQueue = [.failure(ProviderError.resetRequired), .failure(ProviderError.resetRequired)]
        let harness = try EngineHarness(provider: provider)
        let store = harness.store
        let account = Fixtures.accountID
        try store.upsertMessages((1...4).map { Fixtures.message($0) })
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 4, isComplete: true), for: account)
        harness.engine.start()

        try await waitUntil("the second reset's head failed") { provider.bootstrapCalls.filter { $0 == nil }.count == 2 }
        provider.openGate("p2")
        try await waitUntil("the first reconcile completes") { try store.bootstrapState(for: account)?.isComplete == true }
        XCTAssertEqual(Set(try allMessages(store).map(\.id.providerID)), ["1", "2", "3", "4"], "nothing the provider lists is swept")
        XCTAssertEqual(try store.bootstrapState(for: account)?.messagesSeen, 4)
        await harness.shutdown()
    }

    /// A reset whose writes fail after the head page (or a crash there) leaves a reconcile with nowhere to resume
    /// from: the backfill lists everything again from the top before it sweeps, rather than resuming the old
    /// reconcile at its saved page with its marks gone.
    func testAResetWhoseWritesFailListsEverythingAgainBeforeItSweeps() async throws {
        let base = InMemoryMailStore()
        let store = FaultyStore(base: base)
        let account = Fixtures.accountID
        try base.upsertAccount(Fixtures.account())
        try base.upsertMessages((1...6).map { Fixtures.message($0) })
        try base.setSyncCursor("c0", for: account)
        // A reconcile under way: 1 to 4 listed, page three next.
        var state = BootstrapState(startedAt: Date(), pagesDone: 2, messagesSeen: 4, reconciling: true)
        state.checkpoint = BootstrapCheckpoint(providerPage: "p3", changeCursor: "c0")
        try base.setBootstrapState(state, for: account)
        try base.markBackfillSeen(accountID: account, providerIDs: ["1", "2", "3", "4"])

        let provider = ScriptedProvider(accountID: account)
        provider.bootstrapRuns = [
            ["": .success(Fixtures.page(1...2, next: "p2", cursor: "c9")), "p3": .success(Fixtures.page(5...6, next: nil))],
            // The listing from the top, which still lists everything.
            ["": .success(Fixtures.page(1...6, next: nil, cursor: "c-unused"))],
        ]
        provider.changesQueue = [.failure(ProviderError.resetRequired)]
        // The head page is fetched and written, then recording what it listed fails.
        store.fail(.markBackfillSeen)
        let harness = try EngineHarness(store: base, provider: provider, seedAccount: false, engineStore: store)
        harness.engine.start()

        try await waitUntil("the reconcile completes") { try base.bootstrapState(for: account)?.isComplete == true }
        XCTAssertEqual(store.fired, [.markBackfillSeen])
        XCTAssertEqual(Set(try allMessages(base).map(\.id.providerID)), Set((1...6).map(String.init)), "nothing swept")
        XCTAssertTrue(provider.backfillListingCalls.isEmpty, "the old reconcile never resumed at its saved page")
        XCTAssertEqual(provider.bootstrapCalls, [nil, nil])
        let final = try XCTUnwrap(try base.bootstrapState(for: account))
        XCTAssertEqual(final.reconciling, true)
        XCTAssertEqual(final.messagesSeen, 6)
        await harness.shutdown()
    }

    /// The provider deleted 3 while the history covering it expired, and an operation on 3 is still live when the
    /// reconcile sweeps. The sweep keeps an operation's targets, and no later poll would mention 3; the check
    /// before the sweep finds the provider no longer has it. The backfill's sweep, after its listing:
    func testAReconcileRemovesAMessageTheProviderLostThoughAnOperationTargetsIt() async throws {
        try await assertReconcileRemovesALostTarget(wholeMailboxInTheHead: false)
    }

    /// The same for the live lane's sweep, when the head page is the whole mailbox.
    func testAResetWhoseHeadIsTheWholeMailboxRemovesALostTarget() async throws {
        try await assertReconcileRemovesALostTarget(wholeMailboxInTheHead: true)
    }

    private func assertReconcileRemovesALostTarget(wholeMailboxInTheHead: Bool) async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = wholeMailboxInTheHead
            ? [["": .success(Fixtures.page(1...2, next: nil, cursor: "c9"))]]
            : [["": .success(Fixtures.page(1...1, next: "p2", cursor: "c9")), "p2": .success(Fixtures.page(2...2, next: nil))]]
        provider.changesQueue = [.failure(ProviderError.resetRequired)]
        // The archive never gets through, so its operation stays live throughout.
        provider.applyResults = Array(repeating: .failure(ProviderError.network("offline")), count: 20)
        let harness = try EngineHarness(provider: provider) { $0.backoffBase = 10; $0.backoffCap = 60 }
        let store = harness.store
        let account = Fixtures.accountID
        try store.upsertMessages((1...3).map { Fixtures.message($0) })
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 3, isComplete: true), for: account)
        try harness.engine.perform(.archive, on: [id(3)])
        harness.engine.start()

        try await waitUntil("reconcile complete") {
            try store.syncCursor(for: account) == "c9" && store.bootstrapState(for: account)?.isComplete == true
        }
        XCTAssertNil(try store.message(id(3)), "gone from the provider, so gone here")
        XCTAssertEqual(Set(try allMessages(store).map(\.id.providerID)), ["1", "2"])
        XCTAssertEqual(provider.metadataCalls, [["3"]], "only the live operation's target is asked about")
        XCTAssertEqual(try store.pendingOperations(accountID: account, limit: 10).count, 1, "the operation was still live")
        await harness.shutdown()
    }

    /// A target the provider will not return on its own (Graph's 403 for one message) is no proof it is gone: the
    /// reconcile keeps it, as it keeps every live operation's target, and completes rather than failing on it.
    func testAReconcileKeepsALiveTargetTheProviderWillNotReturn() async throws {
        try await assertReconcileKeepsAnUnreadableTarget(wholeMailboxInTheHead: false)
    }

    func testAResetWhoseHeadIsTheWholeMailboxKeepsALiveTargetTheProviderWillNotReturn() async throws {
        try await assertReconcileKeepsAnUnreadableTarget(wholeMailboxInTheHead: true)
    }

    private func assertReconcileKeepsAnUnreadableTarget(wholeMailboxInTheHead: Bool) async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = wholeMailboxInTheHead
            ? [["": .success(Fixtures.page(1...2, next: nil, cursor: "c9"))]]
            : [["": .success(Fixtures.page(1...1, next: "p2", cursor: "c9")), "p2": .success(Fixtures.page(2...2, next: nil))]]
        provider.changesQueue = [.failure(ProviderError.resetRequired)]
        provider.applyResults = Array(repeating: .failure(ProviderError.network("offline")), count: 20)
        provider.unreadableIDs = ["3"]
        let harness = try EngineHarness(provider: provider) { $0.backoffBase = 10; $0.backoffCap = 60 }
        let store = harness.store
        let account = Fixtures.accountID
        try store.upsertMessages((1...3).map { Fixtures.message($0) })
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 3, isComplete: true), for: account)
        try harness.engine.perform(.archive, on: [id(3)])
        harness.engine.start()

        try await waitUntil("reconcile complete") {
            try store.syncCursor(for: account) == "c9" && store.bootstrapState(for: account)?.isComplete == true
        }
        XCTAssertNotNil(try store.message(id(3)), "unreadable is not gone")
        XCTAssertEqual(Set(try allMessages(store).map(\.id.providerID)), ["1", "2", "3"])
        await harness.shutdown()
    }

    /// Gmail's enumeration leaves out Trash and Spam, so a reconcile after an expired history took every stored trashed
    /// message though Gmail keeps its Trash for 30 days, and no later poll brings one back. Their ids are listed apart
    /// now and kept; one Gmail purged in the gap still goes. The backfill's sweep:
    func testAReconcileKeepsTheTrashAndSpamTheEnumerationLeavesOut() async throws {
        try await assertReconcileKeepsMailOutsideTheEnumeration(wholeMailboxInTheHead: false)
    }

    /// The same for the live lane's sweep, when the head page is the whole mailbox.
    func testAResetWhoseHeadIsTheWholeMailboxKeepsTheTrashAndSpam() async throws {
        try await assertReconcileKeepsMailOutsideTheEnumeration(wholeMailboxInTheHead: true)
    }

    private func assertReconcileKeepsMailOutsideTheEnumeration(wholeMailboxInTheHead: Bool) async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = wholeMailboxInTheHead
            ? [["": .success(Fixtures.page(1...2, next: nil, cursor: "c9"))]]
            : [["": .success(Fixtures.page(1...1, next: "p2", cursor: "c9")), "p2": .success(Fixtures.page(2...2, next: nil))]]
        provider.changesQueue = [.failure(ProviderError.resetRequired)]
        provider.outsideEnumerationPages = [["8"], ["10"]]
        let harness = try EngineHarness(provider: provider)
        let store = harness.store
        let account = Fixtures.accountID
        try store.upsertMessages((1...2).map { Fixtures.message($0) } + [
            Fixtures.message(8, conversation: "t8", roles: [.trash]),
            Fixtures.message(9, conversation: "t9", roles: [.trash]),
            Fixtures.message(10, conversation: "t10", roles: [.spam]),
        ])
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 5, isComplete: true), for: account)
        harness.engine.start()

        try await waitUntil("reconcile complete") {
            try store.syncCursor(for: account) == "c9" && store.bootstrapState(for: account)?.isComplete == true
        }
        XCTAssertNotNil(try store.message(id(8)), "Gmail keeps its Trash")
        XCTAssertNotNil(try store.message(id(10)), "and its Spam")
        XCTAssertNil(try store.message(id(9)), "one purged in the gap is gone")
        XCTAssertNotNil(try store.message(id(1)))
        XCTAssertEqual(provider.outsideEnumerationCalls, [nil, "1"])
        await harness.shutdown()
    }

    /// A folder purged in Outlook (emptied out of Deleted Items) answers 404 and leaves the polls, and no delta ever
    /// reports its mail; it stayed here for good, in All Mail and search. Its stored messages are looked up: the ones
    /// the provider no longer has go, one moved out before the purge takes its new folder, and one the provider will
    /// not return is left as it is.
    func testTheMailOfAFolderThatIsGoneIsCheckedAndWhatIsGoneGoes() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID, kind: .microsoft)
        var moved = Fixtures.message(2)
        moved.folderID = "F-ARCHIVE"
        provider.metadataByID = ["2": moved]
        provider.unreadableIDs = ["3"]
        var page = Fixtures.changes(cursor: "c1")
        page.goneFolders = ["F-GONE"]
        provider.changesQueue = [.success(page)]
        let harness = try EngineHarness(provider: provider)
        let store = harness.store
        let account = Fixtures.accountID
        var stored = (1...4).map { Fixtures.message($0) }
        for index in 0..<3 { stored[index].folderID = "F-GONE" }
        stored[3].folderID = "F-INBOX"
        try store.upsertMessages(stored)
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 4, isComplete: true), for: account)
        harness.engine.start()

        try await waitUntil("polled") { try store.syncCursor(for: account) == "c1" }
        XCTAssertNil(try store.message(id(1)), "gone with its folder")
        XCTAssertEqual(try store.message(id(2))?.folderID, "F-ARCHIVE")
        XCTAssertNotNil(try store.message(id(3)), "unreadable is not gone")
        XCTAssertNotNil(try store.message(id(4)), "another folder's mail is not asked about")
        XCTAssertEqual(provider.metadataCalls.map { Set($0) }, [["1", "2", "3"]])
        await harness.shutdown()
    }

    // MARK: Parking and pacing

    /// A token the provider refuses on a backfill request parks both lanes: the live lane shows Sign in required
    /// and stops polling, the backfill sends nothing more, and both resume once a requested check succeeds.
    func testARefusedTokenOnTheBackfillParksBothLanes() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.backfillIDsOnly = true
        provider.bootstrapRuns = [[
            "": .success(Fixtures.page(1...2, next: "p2", cursor: "c0")),
            "p2": .success(Fixtures.page(3...4, next: nil)),
        ]]
        provider.metadataResults = [.failure(ProviderError.unauthorized)]
        let harness = try EngineHarness(provider: provider)
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("parked") { statuses.latest.first?.phase == .needsReauth }
        let polls = provider.changesCalls.count
        let listings = provider.backfillListingCalls.count
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(provider.changesCalls.count, polls, "the live lane waits for the user")
        XCTAssertEqual(provider.backfillListingCalls.count, listings, "and so does the backfill")
        XCTAssertEqual(provider.metadataCalls.count, 1)

        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("backfill complete after the check") {
            try harness.store.bootstrapState(for: Fixtures.accountID)?.isComplete == true
        }
        XCTAssertEqual(statuses.latest.first?.phase, .idle)
        XCTAssertEqual(try allMessages(harness.store).count, 4)
        observation.cancel()
        await harness.shutdown()
    }

    /// A park lands while a backfill turn is under way (its listing in flight): the turn sends nothing more, not
    /// even the metadata for the page it already has, until the account works again.
    func testAParkStopsABackfillTurnBeforeItsNextRequest() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.backfillIDsOnly = true
        provider.bootstrapRuns = [[
            "": .success(Fixtures.page(1...2, next: "p2", cursor: "c0")),
            "p2": .success(Fixtures.page(3...30, next: nil)),
        ]]
        provider.gatedBootstrapPages = ["p2"]
        let harness = try EngineHarness(provider: provider)
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("page two in flight") { provider.backfillListingCalls.count == 1 }
        provider.enqueueChanges(.failure(ProviderError.unauthorized))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("parked") { statuses.latest.first?.phase == .needsReauth }
        let bodies = provider.bodyCalls.count
        provider.openGate("p2")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(provider.metadataCalls.count, 0, "no metadata request once parked")
        XCTAssertEqual(provider.bodyCalls.count, bodies, "and no body")

        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("backfill complete after the check") {
            try harness.store.bootstrapState(for: Fixtures.accountID)?.isComplete == true
        }
        func ids(_ range: ClosedRange<Int>) -> [String] { range.map(String.init) }
        XCTAssertEqual(provider.metadataCalls, [ids(3...12), ids(13...22), ids(23...30)])
        XCTAssertEqual(try allMessages(harness.store).count, 30)
        observation.cancel()
        await harness.shutdown()
    }

    /// The same for a paced body batch: once the account is parked, no further body is fetched.
    func testAParkStopsAPacedBodyBatchUnderWay() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...20, next: nil, cursor: "c0"))]]
        for number in 1...20 {
            provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)"))
        }
        provider.bodyDelay = 0.1
        let harness = try EngineHarness(provider: provider) {
            // Every body goes through the paced path, one at a time.
            $0.liveHydrationLimit = 0
            $0.hydrationConcurrency = 1
        }
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("the paced batch under way") { !provider.bodyCalls.isEmpty }
        provider.enqueueChanges(.failure(ProviderError.unauthorized))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("parked") { statuses.latest.first?.phase == .needsReauth }
        let atPark = provider.bodyCalls.count
        try await Task.sleep(for: .milliseconds(500))
        // At most the fetch that had already passed its last check; unparked, the batch would fetch about five more.
        XCTAssertLessThanOrEqual(provider.bodyCalls.count, atPark + 1)
        observation.cancel()
        await harness.shutdown()
    }

    /// At launch the backfill waits for the live lane's first cycle, so a keychain the user refuses is asked for
    /// once, by the live lane, and not a second time by a backfill request racing it.
    func testADeniedKeychainAtLaunchIsAskedForOnce() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages((1...3).map { Fixtures.message($0) })
        try store.setSyncCursor("c0", for: account)
        var state = BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 3)
        state.checkpoint = BootstrapCheckpoint(providerPage: "p2", changeCursor: "c0")
        try store.setBootstrapState(state, for: account)
        let provider = ScriptedProvider(accountID: account)
        provider.bootstrapRuns = [["p2": .success(Fixtures.page(4...6, next: nil))]]
        provider.changesQueue = [.failure(AuthError.keychain(status: errSecAuthFailed))]
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false)
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("parked") { statuses.latest.first?.phase == .needsReauth }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(provider.changesCalls.count, 1)
        XCTAssertTrue(provider.backfillListingCalls.isEmpty, "no backfill request raced the live lane")
        XCTAssertTrue(provider.bodyCalls.isEmpty)
        observation.cancel()
        await harness.shutdown()
    }

    /// A keychain refused while the outbox replays (actions queued at launch, or Sync Now on a parked account) was taken
    /// for an uncertain provider failure: no park, an attempt counted though nothing was sent, and the poll asked the
    /// keychain again in the same cycle. The account parks at once now, with the keychain's message, and nothing more
    /// is asked of it.
    func testADeniedKeychainInTheOutboxParksTheAccountAtOnce() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages([Fixtures.message(1)])
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 1, isComplete: true), for: account)
        let provider = ScriptedProvider(accountID: account)
        provider.applyResults = [.failure(AuthError.keychain(status: errSecAuthFailed))]
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false)
        try harness.engine.perform(.archive, on: [id(1)])
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()

        try await waitUntil("parked", timeout: 5) { statuses.latest.first?.phase == .needsReauth }
        XCTAssertEqual(statuses.latest.first?.message, LiveLane.keychainMessage)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(provider.changesCalls.isEmpty, "the poll did not ask the keychain a second time")
        let operation = try XCTUnwrap(try store.pendingOperations(accountID: account, limit: 1).first)
        XCTAssertEqual(operation.status, .pending)
        XCTAssertEqual(operation.attempts, 0, "nothing was sent")
        XCTAssertEqual(try store.message(id(1))?.roles, [])
        observation.cancel()
        await harness.shutdown()
    }

    /// A parked account waits for the user. Waking from sleep, the network coming back and coming to the front
    /// (`checkForMail`, `setAppActive`) check the other accounts but never try its token again, which would bring
    /// a refused keychain's prompt back with nobody asking; Sync Now does.
    func testAutomaticChecksLeaveAParkedAccountParked() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages([Fixtures.message(1)])
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 1, isComplete: true), for: account)
        let provider = ScriptedProvider(accountID: account)
        provider.changesQueue = [.failure(AuthError.keychain(status: errSecAuthFailed))]
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false)
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("parked") { statuses.latest.first?.phase == .needsReauth }

        harness.engine.checkForMail()
        harness.engine.setAppActive(false)
        harness.engine.setAppActive(true)
        harness.engine.checkForMail()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(provider.changesCalls.count, 1, "no automatic check tried the token again")
        XCTAssertEqual(harness.tokenProvider.invalidations, [])
        XCTAssertEqual(statuses.latest.first?.phase, .needsReauth)

        harness.engine.syncNow(accountID: account)
        try await waitUntil("Sync Now tries again") { provider.changesCalls.count == 2 }
        XCTAssertEqual(harness.tokenProvider.invalidations, [account])
        try await waitUntil("working again") { statuses.latest.first?.phase == .idle }
        observation.cancel()
        await harness.shutdown()
    }

    /// What the live lane spends comes out of the bucket the backfill draws on, so an opened message, the head
    /// page and each changes page all hold back the backfill's first request by what they cost. Gmail's metadata
    /// costs per message; Graph's pages carry it inline, so they cost the call alone.
    func testLiveSpendComesOutOfTheBackfillsBudget() async throws {
        // A bucket of 15 at 0.5 units a second: the opened body (5), the head page (5 + 5 for its message) and the
        // poll's new message (5) leave -5, and the listing's 5 then takes 20 s.
        let gmail = try await virtualWaitForTheFirstBackfillListing(inlineMetadata: false)
        XCTAssertEqual(gmail, 20, accuracy: 0.5)
        // The body (5) and the head call (5) leave exactly the listing's 5: no wait.
        let graph = try await virtualWaitForTheFirstBackfillListing(inlineMetadata: true)
        XCTAssertEqual(graph, 0, accuracy: 0.5)
    }

    /// A head page that says what its call sent is charged for every request, not as one listing call: Graph's also
    /// looks up the system folders and lists the top of the folder tree.
    func testAHeadPageIsChargedForEveryRequestItReports() async throws {
        // The body (5) and three requests at 5 apiece leave -5 of the bucket's 15, so the listing's 5 takes 20 s.
        let waited = try await virtualWaitForTheFirstBackfillListing(inlineMetadata: true, headRequests: 3)
        XCTAssertEqual(waited, 20, accuracy: 0.5)
    }

    /// The backfill's listing from the top takes one listing page's units before it goes out. A first page that says
    /// its call sent more has the rest taken after, so the backfill's next request waits for it.
    func testAListingFromTheTopIsChargedForEveryRequestItReports() async throws {
        // A bucket of 15 at 0.5 units a second: the listing takes 5 before it goes, and four requests at 5 apiece
        // take 15 more, leaving -5, so the next page's 5 waits 20 s. A page that says nothing costs the 5 alone.
        let counted = try await virtualWaitForTheBackfillAfterAListingFromTheTop(headRequests: 4)
        XCTAssertEqual(counted, 20, accuracy: 0.5)
        let uncounted = try await virtualWaitForTheBackfillAfterAListingFromTheTop(headRequests: nil)
        XCTAssertEqual(uncounted, 0, accuracy: 0.5)
    }

    private func virtualWaitForTheBackfillAfterAListingFromTheTop(headRequests: Int?) async throws -> TimeInterval {
        let clock = TestClock(realSleepCap: 0.01, followsRealTime: false)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        var head = Fixtures.page(1...1, next: "p2", cursor: "c-ignored")
        head.requestCount = headRequests
        provider.bootstrapRuns = [["": .success(head), "p2": .success(Fixtures.page(2...2, next: nil))]]
        let waited = Recorded<TimeInterval>()
        provider.onBackfillListing = { _ in waited.append(clock.advanced) }
        let harness = try EngineHarness(provider: provider) { tuning in
            tuning.quota = { _ in
                ProviderQuota(unitsPerMinute: 90, listCost: 5, metadataCostPerMessage: 5, bodyCost: 5, changesCost: 0,
                              maxBackfillConcurrency: 2, inlineMetadata: true)
            }
            tuning.makeBudget = { quota in QuotaBudget(quota: quota, now: clock.now, sleep: clock.sleep) }
            // Only the backfill's listings spend units.
            tuning.liveHydrationLimit = 0
            tuning.hydrationBatchSize = 0
        }
        // A download with nowhere to resume from: the backfill lists from the top, the live lane polls its cursor.
        try harness.store.setSyncCursor("c0", for: Fixtures.accountID)
        var state = BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 1, isComplete: false)
        state.checkpoint = BootstrapCheckpoint(providerPage: nil, changeCursor: "c0")
        try harness.store.setBootstrapState(state, for: Fixtures.accountID)
        harness.engine.start()
        try await waitUntil("the backfill's next page") { !waited.values.isEmpty }
        await harness.shutdown()
        XCTAssertEqual(provider.bootstrapCalls.filter { $0 == nil }.count, 1, "listed from the top once")
        return try XCTUnwrap(waited.values.first)
    }

    private func virtualWaitForTheFirstBackfillListing(inlineMetadata: Bool, headRequests: Int? = nil) async throws -> TimeInterval {
        // Time moves only when the budget sleeps, so nothing refills on its own and the wait is exact.
        let clock = TestClock(realSleepCap: 0.01, followsRealTime: false)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        var head = Fixtures.page(1...1, next: "p2", cursor: "c0")
        head.requestCount = headRequests
        provider.bootstrapRuns = [[
            "": .success(head),
            "p2": .success(Fixtures.page(2...2, next: nil)),
        ]]
        provider.changesQueue = [.success(Fixtures.changes(upserts: [Fixtures.message(3)], cursor: "c1"))]
        provider.bodies["50"] = .success(MessageBody(html: nil, text: "opened"))
        let waited = Recorded<TimeInterval>()
        provider.onBackfillListing = { _ in waited.append(clock.advanced) }
        let harness = try EngineHarness(provider: provider) { tuning in
            // 90 units a minute: 1 a second for the backfill at full rate, half that at first, and a bucket of 15.
            tuning.quota = { _ in
                ProviderQuota(unitsPerMinute: 90, listCost: 5, metadataCostPerMessage: 5, bodyCost: 5, changesCost: 0,
                              maxBackfillConcurrency: 2, inlineMetadata: inlineMetadata)
            }
            tuning.makeBudget = { quota in QuotaBudget(quota: quota, now: clock.now, sleep: clock.sleep) }
            // Only the opened message, the head page and the poll spend live units.
            tuning.liveHydrationLimit = 0
        }
        try harness.store.upsertMessages([Fixtures.message(50)])
        _ = try await harness.engine.ensureBody(for: id(50))
        harness.engine.start()
        try await waitUntil("the first backfill listing") { !waited.values.isEmpty }
        await harness.shutdown()
        return try XCTUnwrap(waited.values.first)
    }

    /// A poll whose later page fails has already written its earlier pages. Their bodies are not left for the
    /// backfill's idle timer: the backfill lane is woken for them at once.
    func testBodiesFromAPollThatFailsPartWayAreLeftToTheBackfillAtOnce() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        provider.bodies["1"] = .success(MessageBody(html: nil, text: "1"))
        provider.bodies["20"] = .success(MessageBody(html: nil, text: "20"))
        let harness = try EngineHarness(provider: provider)
        let store = harness.store
        harness.engine.start()
        try await waitUntil("the head body stored") { try store.body(for: self.id(1)) != nil }
        // The backfill has nothing left and sleeps for its idle interval (5 minutes).
        try await Task.sleep(for: .milliseconds(200))

        provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(20, conversation: "t9")], cursor: "c1", hasMore: true)))
        provider.enqueueChanges(.failure(ProviderError.throttled(retryAfter: nil)))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("the first page written") { try store.message(self.id(20)) != nil }
        try await waitUntil("its body fetched without waiting out the idle timer") { try store.body(for: self.id(20)) != nil }
        await harness.shutdown()
    }

    /// Under a metered quota a backfill throttle is the budget's to hold: the lane shows when it resumes, the live
    /// lane stays idle and keeps polling, and the pause clears as soon as the lane resumes.
    func testABackfillThrottlePausesOnlyTheBackfill() async throws {
        let clock = TestClock(realSleepCap: 0.6)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.backfillIDsOnly = true
        provider.bootstrapRuns = [[
            "": .success(Fixtures.page(1...2, next: "p2", cursor: "c0")),
            "p2": .success(Fixtures.page(3...4, next: nil)),
        ]]
        provider.metadataResults = [.failure(ProviderError.throttled(retryAfter: 30))]
        let harness = try EngineHarness(provider: provider) { tuning in
            // Gmail's costs over an allowance so large that only the throttle makes anything wait.
            tuning.quota = { _ in
                ProviderQuota(unitsPerMinute: 6_000_000, listCost: 5, metadataCostPerMessage: 20, bodyCost: 60, changesCost: 2,
                              maxBackfillConcurrency: 2)
            }
            tuning.makeBudget = { quota in QuotaBudget(quota: quota, now: clock.now, sleep: clock.sleep) }
        }
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("older mail paused") { statuses.latest.first?.backfillPausedUntil != nil }
        let paused = try XCTUnwrap(statuses.latest.first)
        XCTAssertEqual(paused.phase, .idle, "the live lane is not touched")
        XCTAssertNil(paused.message)
        // The budget's clock runs ahead of the real one, never behind it.
        XCTAssertGreaterThan(try XCTUnwrap(paused.backfillPausedUntil).timeIntervalSinceNow, 20, "the provider's retry time")
        XCTAssertEqual(paused.backfillProgress, 2, "progress stays while paused")
        let polls = provider.changesCalls.count
        try await waitUntil("the live lane polls during the pause") { provider.changesCalls.count > polls }

        try await waitUntil("backfill complete") { try harness.store.bootstrapState(for: Fixtures.accountID)?.isComplete == true }
        try await waitUntil("pause cleared") { statuses.latest.first?.backfillPausedUntil == nil }
        XCTAssertEqual(provider.metadataCalls, [["3", "4"], ["3", "4"]])
        XCTAssertNil(statuses.latest.first?.backfillProgress)
        observation.cancel()
        await harness.shutdown()
    }

    // MARK: Live throttles pause the backfill

    /// Gmail's costs over an allowance so large that only a throttle makes the backfill wait, on `clock`.
    private func throttleHarness(_ provider: ScriptedProvider, clock: TestClock, budgets: Recorded<QuotaBudget>? = nil,
                                 store: InMemoryMailStore? = nil) throws -> EngineHarness {
        try EngineHarness(store: store ?? InMemoryMailStore(), provider: provider, seedAccount: store == nil) { tuning in
            tuning.quota = { _ in
                ProviderQuota(unitsPerMinute: 6_000_000, listCost: 5, metadataCostPerMessage: 20, bodyCost: 60, changesCost: 2,
                              maxBackfillConcurrency: 2)
            }
            tuning.makeBudget = { quota in
                let budget = QuotaBudget(quota: quota, now: clock.now, sleep: clock.sleep)
                budgets?.append(budget)
                return budget
            }
            // Only listings go out on the backfill, and the live lane fetches no bodies.
            tuning.hydrationBatchSize = 0
            tuning.liveHydrationLimit = 0
            // The live lane retries its throttled poll within a fifth of a second, well inside the backfill's pause.
            tuning.backoffBase = 0.05
            tuning.liveBackoffCap = 0.2
        }
    }

    /// Both lanes spend one per-user quota, so a throttle on the live lane's poll pauses the backfill until the
    /// provider's retry time: its next request waits that long, the pause shows as `backfillPausedUntil` while it
    /// waits, and then the backfill goes on and finishes. The live lane keeps its own short backoff and is back to
    /// polling while older mail is still paused.
    func testAThrottledLivePollPausesTheBackfillUntilRetryAfter() async throws {
        let clock = TestClock(realSleepCap: 2)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [[
            "": .success(Fixtures.page(1...2, next: "p2", cursor: "c0")),
            "p2": .success(Fixtures.page(3...4, next: "p3")),
            "p3": .success(Fixtures.page(5...6, next: nil)),
        ]]
        provider.gatedBootstrapPages = ["p2"]
        let listed = Recorded<(page: String, at: TimeInterval)>()
        provider.onBackfillListing = { page in listed.append((page, clock.advanced)) }
        let harness = try throttleHarness(provider, clock: clock)
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        // The backfill's request for p2 is out (the provider holds it) when the live lane's poll is throttled.
        try await waitUntil("the backfill asked for p2") { listed.values.contains { $0.page == "p2" } }
        provider.enqueueChanges(.failure(ProviderError.throttled(retryAfter: 30)))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("the live lane throttled") { statuses.seen.contains(.paused) }
        provider.openGate("p2")

        try await waitUntil("older mail paused", timeout: 10) { statuses.latest.first?.backfillPausedUntil != nil }
        let paused = try XCTUnwrap(statuses.latest.first?.backfillPausedUntil)
        // The budget's clock runs ahead of the real one, never behind it.
        XCTAssertGreaterThan(paused.timeIntervalSinceNow, 20, "the provider's retry time")
        try await waitUntil("new mail flows while older mail is paused") {
            statuses.latest.first.map { $0.phase == .idle && $0.backfillPausedUntil != nil } ?? false
        }
        try await waitUntil("backfill complete") { try harness.store.bootstrapState(for: Fixtures.accountID)?.isComplete == true }
        try await waitUntil("pause cleared") { statuses.latest.first?.backfillPausedUntil == nil }
        XCTAssertEqual(listed.values.map(\.page), ["p2", "p3"], "no other backfill request")
        let resumed = try XCTUnwrap(listed.values.last?.at)
        XCTAssertGreaterThanOrEqual(resumed, 25, "the next backfill request waited for the retry time")
        XCTAssertEqual(try allMessages(harness.store).count, 6)
        observation.cancel()
        await harness.shutdown()
    }

    /// One burst throttles both lanes: the live lane's poll, then the backfill's request that was already out. The
    /// backfill's throttle lands inside the live one's pause and is the same event: the rate halves once and the
    /// pause keeps the live lane's longer retry time.
    func testALiveAndABackfillThrottleFromOneBurstHalveTheRateOnce() async throws {
        let clock = TestClock(realSleepCap: 2)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [[
            "": .success(Fixtures.page(1...2, next: "p2", cursor: "c0")),
            "p2": .failure(ProviderError.throttled(retryAfter: 5)),
        ]]
        provider.gatedBootstrapPages = ["p2"]
        let listed = Recorded<(page: String, at: TimeInterval)>()
        provider.onBackfillListing = { page in listed.append((page, clock.advanced)) }
        let budgets = Recorded<QuotaBudget>()
        let harness = try throttleHarness(provider, clock: clock, budgets: budgets)
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("the backfill asked for p2") { listed.values.contains { $0.page == "p2" } }
        provider.enqueueChanges(.failure(ProviderError.throttled(retryAfter: 30)))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("the live lane throttled") { statuses.seen.contains(.paused) }
        provider.openGate("p2")

        try await waitUntil("older mail paused", timeout: 10) { statuses.latest.first?.backfillPausedUntil != nil }
        let budget = try XCTUnwrap(budgets.values.first)
        let fraction = await budget.rateFraction
        XCTAssertEqual(fraction, 0.25, accuracy: 1e-9, "half the starting rate: halved once, not twice")
        let paused = try XCTUnwrap(statuses.latest.first?.backfillPausedUntil)
        XCTAssertGreaterThan(paused.timeIntervalSinceNow, 20, "the live lane's 30 s, not the backfill's own 5 s")

        // The retry after the pause goes through.
        provider.locked { provider.bootstrapRuns[0]["p2"] = .success(Fixtures.page(3...4, next: nil)) }
        try await waitUntil("backfill complete") { try harness.store.bootstrapState(for: Fixtures.accountID)?.isComplete == true }
        XCTAssertEqual(listed.values.map(\.page), ["p2", "p2"])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(listed.values.last?.at), 25)
        observation.cancel()
        await harness.shutdown()
    }

    /// One burst throttles the live poll and a paced body fetch that was out while the batch's other fetch waited for
    /// its units. That fetch stops rather than wait out the pause and go, so the batch comes back while the pause runs
    /// and its throttle is the same event. Had it gone, the batch would have held the throttle until after the pause,
    /// where it would count as a second event: the rate halved again and a second pause.
    func testAPacedBatchThrottledInTheLiveLanesBurstHalvesTheRateOnce() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages([Fixtures.message(1), Fixtures.message(2)])
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 2, isComplete: true), for: account)
        let provider = ScriptedProvider(accountID: account)
        provider.bodies["1"] = .success(MessageBody(html: nil, text: "1"))
        provider.bodies["2"] = .failure(ProviderError.throttled(retryAfter: 5))
        provider.heldBodies = ["2"]
        // Time moves only when the budget sleeps, and every sleep holds until the test lets it go.
        let clock = TestClock(realSleepCap: 0.01, followsRealTime: false)
        clock.holdsSleeps = true
        let budgets = Recorded<QuotaBudget>()
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false) { tuning in
            // A bucket of 15 units refilling at 0.5 a second; a body costs 10, so the second waits for its units.
            tuning.quota = { _ in
                ProviderQuota(unitsPerMinute: 90, listCost: 5, metadataCostPerMessage: 5, bodyCost: 10, changesCost: 0,
                              maxBackfillConcurrency: 2)
            }
            tuning.makeBudget = { quota in
                let budget = QuotaBudget(quota: quota, now: clock.now, sleep: clock.sleep)
                budgets.append(budget)
                return budget
            }
            tuning.hydrationBatchSize = 2
            tuning.hydrationConcurrency = 2
            tuning.liveHydrationLimit = 0
            tuning.backoffBase = 0.05
            tuning.liveBackoffCap = 0.2
        }
        let pauses = Recorded<Date>()
        let observation = harness.engine.observeStatus { snapshot in
            if let paused = snapshot.first?.backfillPausedUntil { pauses.append(paused) }
        }
        harness.engine.start()
        try await waitUntil("body 2 out and body 1 waiting for its units") {
            provider.bodyCalls == ["2"] && clock.sleepsBegun == 1
        }
        provider.enqueueChanges(.failure(ProviderError.throttled(retryAfter: 30)))
        // Body 1 waits in the budget, so the pause shows at once.
        try await waitUntil("the live throttle paused the backfill") { !pauses.values.isEmpty }
        let budget = try XCTUnwrap(budgets.values.first)
        let afterLive = await budget.rateFraction
        XCTAssertEqual(afterLive, 0.25, accuracy: 1e-9)

        // Body 2 comes back refused by the same burst. The batch returns without body 1, and the lane's next turn
        // waits out the pause.
        provider.releaseBody("2")
        // Not a hard wait: a batch held by body 1 never comes back while sleeps hold, and the checks below say why.
        let deadline = Date().addingTimeInterval(10)
        while clock.sleepsBegun < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(clock.sleepsBegun, 2, "the batch came back while the pause runs, and the lane waits it out")
        XCTAssertEqual(provider.bodyCalls, ["2"], "body 1 did not go out into the pause")
        let reported = await budget.rateFraction
        XCTAssertEqual(reported, 0.25, accuracy: 1e-9, "the backfill's throttle is the live one's event")

        provider.locked { provider.bodies["2"] = .success(MessageBody(html: nil, text: "2")) }
        clock.holdsSleeps = false
        try await waitUntil("both bodies stored") { try (1...2).allSatisfy { try store.body(for: self.id($0)) != nil } }
        let final = await budget.rateFraction
        XCTAssertGreaterThanOrEqual(final, 0.25, "halved once, not again when the batch came back")
        XCTAssertEqual(Set(pauses.values).count, 1, "one pause, not a second after it: \(pauses.values)")
        observation.cancel()
        await harness.shutdown()
    }

    /// The demo's unmetered budget pauses nothing: a throttle on the live lane leaves the backfill going and shows no
    /// paused older mail.
    func testUnderAnUnmeteredQuotaALiveThrottlePausesNothing() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [[
            "": .success(Fixtures.page(1...2, next: "p2", cursor: "c0")),
            "p2": .success(Fixtures.page(3...4, next: "p3")),
            "p3": .success(Fixtures.page(5...6, next: nil)),
        ]]
        provider.gatedBootstrapPages = ["p2"]
        let harness = try EngineHarness(provider: provider)
        let statuses = PhaseRecorder()
        let pauses = Recorded<Date>()
        let observation = harness.engine.observeStatus { snapshot in
            statuses.record(snapshot)
            if let paused = snapshot.first?.backfillPausedUntil { pauses.append(paused) }
        }
        harness.engine.start()
        try await waitUntil("the backfill asked for p2") { provider.backfillListingCalls.contains { $0.page == "p2" } }
        provider.enqueueChanges(.failure(ProviderError.throttled(retryAfter: 30)))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("the live lane throttled") { statuses.seen.contains(.paused) }
        provider.openGate("p2")
        try await waitUntil("backfill complete well inside the retry time", timeout: 10) {
            try harness.store.bootstrapState(for: Fixtures.accountID)?.isComplete == true
        }
        XCTAssertEqual(pauses.values, [])
        observation.cancel()
        await harness.shutdown()
    }

    /// With the download finished there is no older mail to pause. A live throttle still pauses the budget, so a
    /// backfill that starts meanwhile waits too, but nothing shows `backfillPausedUntil` and the line never reads
    /// "older mail paused".
    func testALiveThrottleAfterTheBackfillFinishedShowsNoPause() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 0, isComplete: true), for: account)
        let provider = ScriptedProvider(accountID: account)
        provider.changesQueue = [.failure(ProviderError.throttled(retryAfter: 30))]
        // Time moves only when the budget sleeps, so the pause is still running when the test looks.
        let clock = TestClock(realSleepCap: 0.01, followsRealTime: false)
        let budgets = Recorded<QuotaBudget>()
        let harness = try throttleHarness(provider, clock: clock, budgets: budgets, store: store)
        let statuses = PhaseRecorder()
        let pauses = Recorded<Date>()
        let observation = harness.engine.observeStatus { snapshot in
            statuses.record(snapshot)
            if let paused = snapshot.first?.backfillPausedUntil { pauses.append(paused) }
        }
        harness.engine.start()
        try await waitUntil("the live lane throttled") { statuses.seen.contains(.paused) }
        try await waitUntil("and polling again") { provider.changesCalls.count >= 3 && statuses.latest.first?.phase == .idle }
        let budget = try XCTUnwrap(budgets.values.first)
        let pausedUntil = await budget.pausedUntil
        XCTAssertNotNil(pausedUntil, "the budget holds the pause for any backfill that starts")

        let latest = try XCTUnwrap(statuses.latest.first)
        XCTAssertEqual(pauses.values, [], "nothing to show: no older mail is waiting")
        XCTAssertNil(SyncLineSummary.olderMailWords(latest))
        XCTAssertEqual(SyncLineSummary.accountWords(latest), "Up to date")
        let line = SyncLineSummary.make(SyncLineSummary.Input(statuses: [latest], accounts: [Fixtures.account()]))
        XCTAssertFalse(line.spokenText.contains("paused"), line.spokenText)
        observation.cancel()
        await harness.shutdown()
    }

    /// Every request that spends the live share pauses the backfill when the provider throttles it, not only the
    /// live lane's pages: the outbox, a message the user opens and an attachment download.
    func testEveryThrottleOnTheLiveSharePausesTheBackfill() async throws {
        try await assertAThrottlePausesTheBackfill("an archive in the outbox") { harness, provider in
            provider.applyResults = [.failure(ProviderError.throttled(retryAfter: 30))]
            harness.engine.start()
            try await waitUntil("head page stored") { try harness.store.message(self.id(1)) != nil }
            try harness.engine.perform(.archive, on: [self.id(1)])
        }
        try await assertAThrottlePausesTheBackfill("an opened message") { harness, provider in
            try harness.store.upsertMessages([Fixtures.message(50)])
            provider.bodies["50"] = .failure(ProviderError.throttled(retryAfter: 30))
            do {
                _ = try await harness.engine.ensureBody(for: self.id(50))
                XCTFail("the body was throttled")
            } catch ProviderError.throttled {}
        }
        try await assertAThrottlePausesTheBackfill("an attachment") { harness, provider in
            provider.attachmentErrors["1/att-1"] = ProviderError.throttled(retryAfter: 30)
            do {
                _ = try await harness.engine.attachmentData(for: self.id(1), attachmentID: "att-1", expectedSize: 5, progress: nil)
                XCTFail("the download was throttled")
            } catch ProviderError.throttled {}
        }
    }

    private func assertAThrottlePausesTheBackfill(
        _ description: String, file: StaticString = #filePath, line: UInt = #line,
        _ trigger: (EngineHarness, ScriptedProvider) async throws -> Void
    ) async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        let start = Date()
        let budgets = Recorded<QuotaBudget>()
        let harness = try EngineHarness(provider: provider) { tuning in
            tuning.quota = { _ in .standard(for: .gmail) }
            // The budget's clock stands still, so the pause ends exactly at the retry time.
            tuning.makeBudget = { quota in
                let budget = QuotaBudget(quota: quota, now: { start })
                budgets.append(budget)
                return budget
            }
        }
        try await trigger(harness, provider)
        let deadline = Date().addingTimeInterval(10)
        var pausedUntil: Date?
        while pausedUntil == nil, Date() < deadline {
            if let budget = budgets.values.first { pausedUntil = await budget.pausedUntil }
            if pausedUntil == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(pausedUntil, start.addingTimeInterval(30), "\(description) pauses the backfill until its retry time",
                       file: file, line: line)
        await harness.shutdown()
    }

    /// A paced batch picks its bodies before their slots and units come free. One stored meanwhile (by the live
    /// lane, or opened by the user) is skipped without spending the backfill's units on it.
    func testAPacedFetchSkipsABodyStoredMeanwhileWithoutSpendingUnits() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages([Fixtures.message(1), Fixtures.message(2)])
        let provider = ScriptedProvider(accountID: account)
        provider.bodies["2"] = .success(MessageBody(html: nil, text: "2"))
        provider.heldBodies = ["2"]
        let clock = TestClock(realSleepCap: 0.01, followsRealTime: false)
        // A bucket of 15 at 0.5 units a second; a body costs 10, so a second body would wait 10 s.
        let quota = ProviderQuota(unitsPerMinute: 90, listCost: 5, metadataCostPerMessage: 5, bodyCost: 10, changesCost: 0,
                                  maxBackfillConcurrency: 1)
        var tuning = SyncTuning()
        tuning.hydrationConcurrency = 1
        let hydrator = Hydrator(accountID: account, store: store, provider: provider, sanitizer: RecordingSanitizer(), tuning: tuning,
                                budget: QuotaBudget(quota: quota, now: clock.now, sleep: clock.sleep))
        let batch = Task { await hydrator.hydratePaced() }
        // The newest first: 2 is in flight, 1 waits for the slot.
        try await waitUntil("the first fetch under way") { provider.bodyCalls == ["2"] }
        try store.saveBody(StoredBody(body: MessageBody(html: nil, text: "opened"), renderedHTML: "", plainText: "opened"), for: id(1))
        provider.releaseBody("2")
        let outcome = await batch.value
        XCTAssertEqual(outcome.fetched, 1)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(provider.bodyCalls, ["2"])
        XCTAssertEqual(clock.advanced, 0, "the skipped body spent no units, so nothing waited for them")
    }

    // MARK: The live lane's share

    /// A Gmail-like quota whose live share is 400 units a minute (6.7 a second): a page costs 20 units per message
    /// it names (the bare call nothing, so the routine polls between steps spend nothing), a body 60. Paced bodies
    /// are off, so only the live lane spends, and the budget's clock moves only when the test moves it.
    private func liveShareHarness(_ provider: ScriptedProvider, clock: TestClock,
                                  tune: (inout SyncTuning) -> Void = { _ in }) throws -> EngineHarness {
        try EngineHarness(provider: provider) { tuning in
            tuning.quota = { _ in
                ProviderQuota(unitsPerMinute: 1_200, listCost: 5, metadataCostPerMessage: 20, bodyCost: 60, changesCost: 0,
                              maxBackfillConcurrency: 2)
            }
            tuning.makeBudget = { quota in QuotaBudget(quota: quota, now: clock.now, sleep: clock.sleep) }
            tuning.hydrationBatchSize = 0
            tune(&tuning)
        }
    }

    /// A run of changes pages that spends past the live lane's share waits for the share to cover another page like
    /// the last before it fetches the next, so a large catch-up never bursts past the provider's limit. Meanwhile
    /// the outbox moves, and once the share is back the run goes on where it stopped.
    func testARunOfChangesPagesKeepsToTheLiveShare() async throws {
        let clock = TestClock(realSleepCap: 0.01, followsRealTime: false)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        let harness = try liveShareHarness(provider, clock: clock) { $0.liveHydrationLimit = 0 }
        let store = harness.store
        harness.engine.start()
        try await waitUntil("head page stored") { try store.syncCursor(for: Fixtures.accountID) == "c0" }
        // The head cost 25 of 400. A page naming 19 messages costs 380 and leaves -5: the next page, expected to
        // cost as much, waits about 58 s.
        provider.enqueueChanges(.success(Fixtures.changes(upserts: (10...28).map { Fixtures.message($0, conversation: "t\($0)") },
                                                          cursor: "c1", hasMore: true)))
        provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(40, conversation: "t40")], cursor: "c2")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("the first page written") { try store.message(self.id(28)) != nil }
        try harness.engine.perform(.archive, on: [id(1)])
        try await waitUntil("the archive goes out while the run waits") { provider.applyCalls.count == 1 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(provider.changesCalls.contains { $0.cursor == "c1" }, "the next page waits for the share")
        XCTAssertNil(try store.message(id(40)))

        // Past a full share; it holds no more than that.
        clock.skip(120)
        try await waitUntil("the run goes on once the share is back") { try store.message(self.id(40)) != nil }
        XCTAssertEqual(try store.syncCursor(for: Fixtures.accountID), "c2")
        await harness.shutdown()
    }

    /// After a page that spent most of the share, the live lane prefetches only the bodies the rest pays for, newest
    /// first, and leaves the others to the backfill.
    func testNewBodiesArePrefetchedOnlyWithinTheLiveShare() async throws {
        let clock = TestClock(realSleepCap: 0.01, followsRealTime: false)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        for number in [1] + Array(20...24) { provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)")) }
        let harness = try liveShareHarness(provider, clock: clock)
        let store = harness.store
        harness.engine.start()
        // The head (25) and its body (60) leave 315.
        try await waitUntil("head body stored") { try store.body(for: self.id(1)) != nil }
        // Five new messages cost 100 and leave 215: room for three bodies.
        provider.enqueueChanges(.success(Fixtures.changes(upserts: (20...24).map { Fixtures.message($0, conversation: "t\($0)") },
                                                          cursor: "c1")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("bodies prefetched") { provider.bodyCalls.count >= 4 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(Set(provider.bodyCalls), ["1", "24", "23", "22"], "the newest three")
        XCTAssertNil(try store.body(for: id(20)))
        await harness.shutdown()
    }

    /// Opening a long conversation the backfill has not reached puts the live share deep in debt (40 Gmail bodies,
    /// 2,400 units against 2,000). After light pages (no run of changes, no heavy page), the polls still go and a
    /// single new message arrives within an interval instead of after the minute the share needs.
    func testOpenedBodiesNeverHoldBackTheFirstPageOfAPoll() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages((1...40).map { Fixtures.message($0, conversation: "t1") })
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 40, isComplete: true), for: account)
        let provider = ScriptedProvider(accountID: account)
        for number in 1...40 { provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)")) }
        let clock = TestClock(realSleepCap: 0.01, followsRealTime: false)
        let budgets = Recorded<QuotaBudget>()
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false) { tuning in
            tuning.quota = { _ in .standard(for: .gmail) }
            tuning.makeBudget = { quota in
                let budget = QuotaBudget(quota: quota, now: clock.now, sleep: clock.sleep)
                budgets.append(budget)
                return budget
            }
            tuning.hydrationBatchSize = 0
        }
        harness.engine.start()
        try await waitUntil("polling") { provider.changesCalls.count >= 2 }
        for number in 1...40 { _ = try await harness.engine.ensureBody(for: id(number)) }
        let budget = try XCTUnwrap(budgets.values.first)
        let headroom = await budget.liveHeadroom
        XCTAssertLessThan(headroom, 0, "the opened bodies spent past the share, and the clock stands still")

        let polls = provider.changesCalls.count
        try await waitUntil("the routine polls go on") { provider.changesCalls.count >= polls + 2 }
        provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(99, conversation: "t99")], cursor: "c1")))
        try await waitUntil("the new message arrives") { try store.message(self.id(99)) != nil }
        await harness.shutdown()
    }

    /// A busy mailbox (a bulk action elsewhere, applied in stages) brings a heavy page on every poll, each saying
    /// there is no more. Such a page makes the next poll wait for the share like the next page of a run, instead of
    /// every poll going at once and spending several times the share: 80 Gmail messages cost 1,602 of the 2,000, so
    /// the next poll waits until the share covers that much again. A light page ends it, and the polls go on.
    func testPollsThatEachBringAHeavyPageKeepToTheLiveShare() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages([Fixtures.message(1)])
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 1, isComplete: true), for: account)
        let provider = ScriptedProvider(accountID: account)
        func heavyPage(from first: Int, cursor: String) -> Result<ChangesPage, Error> {
            .success(Fixtures.changes(upserts: (first..<first + 80).map { Fixtures.message($0, conversation: "t\($0)") },
                                      cursor: cursor))
        }
        provider.changesQueue = [
            heavyPage(from: 100, cursor: "c1"),
            heavyPage(from: 200, cursor: "c2"),
            .success(Fixtures.changes(upserts: [Fixtures.message(300, conversation: "t300")], cursor: "c3")),
        ]
        let clock = TestClock(realSleepCap: 0.01, followsRealTime: false)
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false) { tuning in
            tuning.quota = { _ in .standard(for: .gmail) }
            tuning.makeBudget = { quota in QuotaBudget(quota: quota, now: clock.now, sleep: clock.sleep) }
            tuning.hydrationBatchSize = 0
            tuning.liveHydrationLimit = 0
        }
        harness.engine.start()
        // 2,000 - 1,602 leaves 398: another 1,602 takes about 36 s.
        try await waitUntil("the first heavy page written") { try store.syncCursor(for: account) == "c1" }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(provider.changesCalls.map(\.cursor), ["c0"], "the next poll waits for the share")

        // 398 + 40 s of share leaves 129 after the second page: the poll after it waits too.
        clock.skip(40)
        try await waitUntil("the second heavy page written") { try store.syncCursor(for: account) == "c2" }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(provider.changesCalls.map(\.cursor), ["c0", "c1"], "and so does the one after it")

        // A light page (22 units) after it, and the polls go on with the clock standing still.
        clock.skip(45)
        try await waitUntil("the light page written") { try store.syncCursor(for: account) == "c3" }
        try await waitUntil("the polls go on") { provider.changesCalls.filter { $0.cursor == "c3" }.count >= 3 }
        await harness.shutdown()
    }

    /// Graph charges every request a `changes` call sends (a delta GET per folder, a `$batch` part per removal it
    /// looks up), and the call reports how many. A run whose pages sent 100 each keeps to the live share like a
    /// Gmail run: a third of 1,000 requests a minute is 333, so three pages go, the fourth waits for the share, and
    /// once it is back the run goes on.
    func testAGraphRunKeepsToTheLiveShareByTheRequestsItsPagesSent() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Account(id: account, kind: .microsoft, email: "me@example.com", displayName: "Me", addedAt: Fixtures.baseDate))
        try store.upsertMessages([Fixtures.message(1)])
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 1, isComplete: true), for: account)
        let provider = ScriptedProvider(accountID: account, kind: .microsoft)
        provider.changesQueue = (1...10).map { page in
            .success(Fixtures.changes(cursor: "c\(page)", hasMore: page < 10, requestCount: 100))
        }
        let clock = TestClock(realSleepCap: 0.01, followsRealTime: false)
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false) { tuning in
            tuning.quota = { _ in .standard(for: .microsoft) }
            tuning.makeBudget = { quota in QuotaBudget(quota: quota, now: clock.now, sleep: clock.sleep) }
            tuning.hydrationBatchSize = 0
        }
        harness.engine.start()
        try await waitUntil("three pages asked for") { provider.changesCalls.count >= 3 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(provider.changesCalls.map(\.cursor), ["c0", "c1", "c2"], "the fourth page waits for the share")
        XCTAssertEqual(try store.syncCursor(for: account), "c3")

        // A full share: three more pages.
        clock.skip(60)
        try await waitUntil("the run goes on once the share is back") { try store.syncCursor(for: account) == "c6" }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try store.syncCursor(for: account), "c6")
        await harness.shutdown()
    }

    /// One Graph call can send far more requests than the live share holds: ten folders on their nextLinks with a
    /// hundred removals each to look up is 1,010 against 333. The share owes all of it, so the run's next page waits
    /// the three minutes such a page takes to earn, not the two that a debt cut at a minute would leave.
    func testAGraphPageDearerThanTheWholeShareIsPacedByAllItCost() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Account(id: account, kind: .microsoft, email: "me@example.com", displayName: "Me", addedAt: Fixtures.baseDate))
        try store.upsertMessages([Fixtures.message(1)])
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 1, isComplete: true), for: account)
        let provider = ScriptedProvider(accountID: account, kind: .microsoft)
        provider.changesQueue = (1...4).map { page in
            .success(Fixtures.changes(cursor: "c\(page)", hasMore: page < 4, requestCount: 1_010))
        }
        let clock = TestClock(realSleepCap: 0.01, followsRealTime: false)
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false) { tuning in
            tuning.quota = { _ in .standard(for: .microsoft) }
            tuning.makeBudget = { quota in QuotaBudget(quota: quota, now: clock.now, sleep: clock.sleep) }
            tuning.hydrationBatchSize = 0
        }
        harness.engine.start()
        try await waitUntil("the first page written") { try store.syncCursor(for: account) == "c1" }
        // 333 - 1,010 leaves 677 owed: a full share again is (677 + 333) / 5.56 s, about 182 s.
        clock.skip(150)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(provider.changesCalls.map(\.cursor), ["c0"], "two and a half minutes do not pay for that page")

        clock.skip(35)
        try await waitUntil("the run goes on once the page is paid for") { try store.syncCursor(for: account) == "c2" }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(provider.changesCalls.map(\.cursor), ["c0", "c1"], "and the page after it waits as long")
        await harness.shutdown()
    }

    /// A new Gmail account's head page (100 messages, 2,005 units) spends the whole live share (2,000), yet the
    /// newest bodies after it are fetched: they are what a new account opens first.
    func testTheNewestBodiesAfterAHeadPageAreFetchedWhateverTheShareHolds() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...100, next: nil, cursor: "c0"))]]
        let calls = try await liveBodyCallsAfterAHead(provider)
        XCTAssertEqual(Set(calls), Set((81...100).map(String.init)), "the newest twenty")
    }

    /// The same after a rejected cursor: the reconcile's fresh head is followed by its newest bodies.
    func testTheNewestBodiesAfterAResetsHeadAreFetchedWhateverTheShareHolds() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...100, next: nil, cursor: "c1"))]]
        provider.changesQueue = [.failure(ProviderError.resetRequired)]
        let calls = try await liveBodyCallsAfterAHead(provider) { store in
            try store.setSyncCursor("c-old", for: Fixtures.accountID)
            try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 0, isComplete: true),
                                        for: Fixtures.accountID)
        }
        XCTAssertEqual(Set(calls), Set((81...100).map(String.init)), "the newest twenty")
    }

    /// The bodies the live lane fetched after `provider`'s head page under Gmail's real quota, on a budget clock that
    /// stands still so nothing refills, with paced bodies off.
    private func liveBodyCallsAfterAHead(_ provider: ScriptedProvider,
                                         prepare: (InMemoryMailStore) throws -> Void = { _ in }) async throws -> [String] {
        for number in 1...100 { provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)")) }
        let clock = TestClock(realSleepCap: 0.01, followsRealTime: false)
        let harness = try EngineHarness(provider: provider) { tuning in
            tuning.quota = { _ in .standard(for: .gmail) }
            tuning.makeBudget = { quota in QuotaBudget(quota: quota, now: clock.now, sleep: clock.sleep) }
            tuning.hydrationBatchSize = 0
        }
        try prepare(harness.store)
        harness.engine.start()
        try await waitUntil("the head's bodies") { provider.bodyCalls.count >= 20 }
        try await Task.sleep(for: .milliseconds(300))
        let calls = provider.bodyCalls
        await harness.shutdown()
        return calls
    }

    /// A poll names stored messages whose labels changed (another device marked them read, a filter moved them)
    /// and mail new to the store; only the new mail's bodies are prefetched, and not spam's, which the backfill
    /// skips too. The rest are the paced path's.
    func testOnlyMailNewToTheStoreIsPrefetched() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages((1...3).map { Fixtures.message($0, conversation: "t\($0)") })
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 3, isComplete: true), for: account)
        let provider = ScriptedProvider(accountID: account)
        for number in [1, 2, 3, 20, 21] { provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)")) }
        provider.changesQueue = [.success(Fixtures.changes(upserts: [
            Fixtures.message(2, conversation: "t2", isRead: true),
            Fixtures.message(3, conversation: "t3", roles: [.spam]),
            Fixtures.message(20, conversation: "t20"),
            Fixtures.message(21, conversation: "t21", roles: [.spam]),
        ], cursor: "c1"))]
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false) { $0.hydrationBatchSize = 0 }
        harness.engine.start()
        try await waitUntil("the new message's body") { try store.body(for: self.id(20)) != nil }
        let polls = provider.changesCalls.count
        try await waitUntil("two more polls") { provider.changesCalls.count >= polls + 2 }
        XCTAssertEqual(provider.bodyCalls, ["20"])
        await harness.shutdown()
    }

    /// A message marked Not spam on another device comes back without a body, since neither lane fetches spam's, and
    /// the idle backfill would leave it for minutes: it counts as arrived and its body is prefetched like new mail's.
    /// A stored message whose labels merely changed still is not.
    func testAMessageLeavingSpamHasItsBodyPrefetched() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages([Fixtures.message(1, conversation: "t1"), Fixtures.message(3, conversation: "t3", roles: [.spam])])
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 2, isComplete: true), for: account)
        let provider = ScriptedProvider(accountID: account)
        for number in [1, 3] { provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)")) }
        provider.changesQueue = [.success(Fixtures.changes(upserts: [
            Fixtures.message(1, conversation: "t1", isRead: true),
            Fixtures.message(3, conversation: "t3", roles: [.inbox]),
        ], cursor: "c1"))]
        // Paced bodies are off, so only the live lane fetches.
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false) { $0.hydrationBatchSize = 0 }
        harness.engine.start()
        try await waitUntil("the body of the message back from Spam") { try store.body(for: self.id(3)) != nil }
        let polls = provider.changesCalls.count
        try await waitUntil("two more polls") { provider.changesCalls.count >= polls + 2 }
        XCTAssertEqual(provider.bodyCalls, ["3"])
        await harness.shutdown()
    }

    /// Bodies the live lane leaves to the backfill (beyond its limit) reach a backfill with nothing else to do at
    /// once, not after its 5-minute idle interval.
    func testBodiesBeyondTheLiveLimitWakeTheIdleBackfill() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        for number in [1, 20, 21, 22] { provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)")) }
        let harness = try EngineHarness(provider: provider) { $0.liveHydrationLimit = 1 }
        let store = harness.store
        harness.engine.start()
        try await waitUntil("the head body stored") { try store.body(for: self.id(1)) != nil }
        // The backfill has nothing left and sleeps for its idle interval (5 minutes).
        try await Task.sleep(for: .milliseconds(300))
        provider.enqueueChanges(.success(Fixtures.changes(upserts: (20...22).map { Fixtures.message($0, conversation: "t\($0)") },
                                                          cursor: "c1")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("every new body, the live lane's one and the backfill's two", timeout: 10) {
            try (20...22).allSatisfy { try store.body(for: self.id($0)) != nil }
        }
        await harness.shutdown()
    }

    /// A backfill sitting out a failure backoff (the network was down) starts again when the live lane hands it
    /// bodies of new mail after a poll that went through: the network is back, and that mail should open offline.
    func testBodiesHandedOverEndABackfillFailureBackoff() async throws {
        let store = InMemoryMailStore()
        let account = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages((1...2).map { Fixtures.message($0, conversation: "t\($0)") })
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 2, isComplete: true), for: account)
        let provider = ScriptedProvider(accountID: account)
        // Older bodies fail on the network, so every paced batch stalls and the lane backs off for 60 s.
        for number in 1...2 { provider.bodies["\(number)"] = .failure(ProviderError.network("offline")) }
        for number in 20...22 { provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)")) }
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false) {
            $0.liveHydrationLimit = 1
            $0.backoffBase = 60
            $0.backoffCap = 300
        }
        harness.engine.start()
        try await waitUntil("a paced batch failed") { Set(provider.bodyCalls).isSuperset(of: ["1", "2"]) }
        try await Task.sleep(for: .milliseconds(300))
        let failedCalls = provider.bodyCalls.count
        provider.enqueueChanges(.success(Fixtures.changes(upserts: (20...22).map { Fixtures.message($0, conversation: "t\($0)") },
                                                          cursor: "c1")))
        harness.engine.syncNow(accountID: account)
        try await waitUntil("the handed-over bodies arrive well inside the backoff", timeout: 15) {
            try (20...22).allSatisfy { try store.body(for: self.id($0)) != nil }
        }
        XCTAssertGreaterThan(provider.bodyCalls.count, failedCalls + 1)
        await harness.shutdown()
    }

    func testTheDemoProviderIsUnmetered() {
        let tuning = SyncTuning()
        let account = Account(id: AccountID("demo"), kind: .gmail, email: "", displayName: "", addedAt: Fixtures.baseDate)
        let demo = DemoMailService(liveInterval: 3_600).provider(for: account)
        XCTAssertEqual(tuning.quota(demo), .unlimited)
        XCTAssertEqual(tuning.quota(ScriptedProvider(accountID: Fixtures.accountID, kind: .gmail)), .standard(for: .gmail))
        XCTAssertEqual(tuning.quota(ScriptedProvider(accountID: Fixtures.accountID, kind: .microsoft)), .standard(for: .microsoft))
    }

    func testTuningDefaults() {
        let tuning = SyncTuning()
        XCTAssertEqual(tuning.pollInterval, 30, "the background interval")
        XCTAssertEqual(tuning.activePollInterval, 5)
        XCTAssertEqual(tuning.liveBackoffCap, 60)
        XCTAssertEqual(tuning.bootstrapPageSize, 100)
        XCTAssertEqual(tuning.changesPageSize, 100)
        XCTAssertEqual(tuning.liveHydrationLimit, 20)
        XCTAssertEqual(tuning.liveHydrationConcurrency, 2)
        XCTAssertEqual(tuning.backfillMetadataChunk, 10)
        XCTAssertEqual(tuning.backfillIdleInterval, 300)
        XCTAssertEqual(SyncTuning(pollInterval: 15).activePollInterval, 5)
        XCTAssertEqual(SyncTuning(pollInterval: 2).activePollInterval, 2, "never above the background interval")
        var custom = SyncTuning(pollInterval: 2)
        custom.activePollInterval = 1
        custom.pollInterval = 10
        XCTAssertEqual(custom.activePollInterval, 1, "an explicit value stays")
    }
}

/// Values appended from any thread, read by the test.
private final class Recorded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }
}

/// A clock for `QuotaBudget` whose sleeps move time forward at once and really wait only up to `realSleepCap`,
/// so a 30-second pause takes a fraction of a second. Without `followsRealTime` it stands still between sleeps.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    private var begun = 0
    private var holding = false
    private let realSleepCap: TimeInterval
    private let start: Date?

    init(realSleepCap: TimeInterval, followsRealTime: Bool = true) {
        self.realSleepCap = realSleepCap
        start = followsRealTime ? nil : Date()
    }

    /// How far the sleeps have moved the clock.
    var advanced: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return offset
    }

    /// Sleeps begun so far.
    var sleepsBegun: Int {
        lock.lock(); defer { lock.unlock() }
        return begun
    }

    /// While set, a sleep that has moved the clock goes on waiting until this is cleared or its task is cancelled,
    /// so what a test does while the budget waits lands at a known point however slow the machine is.
    var holdsSleeps: Bool {
        get { lock.lock(); defer { lock.unlock() }; return holding }
        set { lock.lock(); holding = newValue; lock.unlock() }
    }

    var now: @Sendable () -> Date {
        { [self] in current() }
    }

    var sleep: @Sendable (TimeInterval) async throws -> Void {
        { [self] seconds in
            advance(by: seconds, countingASleep: true)
            while holdsSleeps { try await Task.sleep(for: .milliseconds(5)) }
            try await Task.sleep(for: .seconds(min(max(0, seconds), realSleepCap)))
        }
    }

    private func current() -> Date {
        lock.lock(); defer { lock.unlock() }
        return (start ?? Date()).addingTimeInterval(offset)
    }

    private func advance(by seconds: TimeInterval, countingASleep: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        offset += max(0, seconds)
        if countingASleep { begun += 1 }
    }

    /// Moves the clock on as if `seconds` had passed, without sleeping.
    func skip(_ seconds: TimeInterval) {
        advance(by: seconds)
    }
}
