import Foundation
import XCTest
@testable import SSCore

final class MailEngineBootstrapTests: XCTestCase {
    /// The head page sets the cursor at once, so new mail does not wait for the whole mailbox; the backfill lane
    /// lists the older pages behind it and the state completes when it reaches the end.
    func testHeadPageSetsTheCursorAndTheBackfillListsTheRest() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [[
            "": .success(Fixtures.page(1...3, next: "p2", cursor: "c0")),
            "p2": .success(Fixtures.page(4...6, next: "p3")),
            "p3": .success(Fixtures.page(7...9, next: nil)),
        ]]
        provider.gatedBootstrapPages = ["p3"]
        let harness = try EngineHarness(provider: provider)
        let store = harness.store
        let id = Fixtures.accountID
        harness.engine.start()

        try await waitUntil("cursor set by the head page") { try store.syncCursor(for: id) == "c0" }
        try await waitUntil("two pages stored") { try store.bootstrapState(for: id)?.pagesDone == 2 }
        XCTAssertEqual(try store.syncCursor(for: id), "c0")
        XCTAssertEqual(try allMessages(store).count, 6)
        let midway = try XCTUnwrap(try store.bootstrapState(for: id))
        XCTAssertFalse(midway.isComplete)
        XCTAssertEqual(midway.checkpoint.providerPage, "p3")
        XCTAssertEqual(midway.checkpoint.changeCursor, "c0")
        try await waitUntil("the live lane polls while the backfill is under way") { !provider.changesCalls.isEmpty }
        XCTAssertEqual(provider.changesCalls.first?.cursor, "c0")

        provider.openGate("p3")
        try await waitUntil("backfill complete") { try store.bootstrapState(for: id)?.isComplete == true }
        XCTAssertEqual(try allMessages(store).count, 9)
        let final = try XCTUnwrap(try store.bootstrapState(for: id))
        XCTAssertNil(final.nextPage)
        XCTAssertEqual(final.messagesSeen, 9)
        XCTAssertEqual(final.pagesDone, 3)
        XCTAssertEqual(provider.bootstrapCalls, [nil, "p2", "p3"])
        XCTAssertEqual(provider.backfillListingCalls.map(\.page), ["p2", "p3"])
        XCTAssertEqual(try store.syncCursor(for: id), "c0")
        await harness.shutdown()
    }

    /// A quit mid-backfill keeps the cursor and the saved page: the next launch polls at once and the backfill
    /// carries on from that page, never fetching the head again.
    func testRestartResumesTheBackfillFromTheStoredPage() async throws {
        let store = InMemoryMailStore()
        let id = Fixtures.accountID
        let first = ScriptedProvider(accountID: id)
        first.bootstrapRuns = [[
            "": .success(Fixtures.page(1...3, next: "p2", cursor: "c0")),
            "p2": .success(Fixtures.page(4...6, next: "p3")),
        ]]
        first.gatedBootstrapPages = ["p2"]
        let harness1 = try EngineHarness(store: store, provider: first)
        harness1.engine.start()
        try await waitUntil("backfill asked for page two") { first.bootstrapCalls.count == 2 }
        await harness1.shutdown()
        XCTAssertEqual(try store.syncCursor(for: id), "c0")
        XCTAssertEqual(try allMessages(store).count, 3)
        XCTAssertEqual(try store.bootstrapState(for: id)?.checkpoint.providerPage, "p2")

        // The second provider cannot serve a first page: resuming must ask for page two directly.
        let second = ScriptedProvider(accountID: id)
        second.bootstrapRuns = [[
            "p2": .success(Fixtures.page(4...6, next: "p3")),
            "p3": .success(Fixtures.page(7...9, next: nil)),
        ]]
        let harness2 = try EngineHarness(store: store, provider: second)
        harness2.engine.start()
        try await waitUntil("resumed backfill completes") { try store.bootstrapState(for: id)?.isComplete == true }
        XCTAssertEqual(second.bootstrapCalls, ["p2", "p3"])
        XCTAssertEqual(first.bootstrapCalls, [nil, "p2"])
        XCTAssertEqual(try allMessages(store).count, 9)
        XCTAssertEqual(try store.syncCursor(for: id), "c0")
        XCTAssertEqual(second.changesCalls.first?.cursor, "c0")
        await harness2.shutdown()
    }

    /// A resume token the provider no longer honours (Gmail answers a stale pageToken with 400) must not
    /// wedge the backfill forever: the listing starts over from the top. The cursor saved with the old download
    /// is kept (adopted), since the restarted listing's cursor belongs to the live lane alone.
    func testRejectedResumeTokenRestartsTheListing() async throws {
        let store = InMemoryMailStore()
        let id = Fixtures.accountID
        try store.upsertAccount(Fixtures.account())
        var state = BootstrapState(startedAt: Date())
        state.pagesDone = 1
        state.checkpoint = BootstrapCheckpoint(providerPage: "stale", changeCursor: "c-old")
        try store.setBootstrapState(state, for: id)
        let provider = ScriptedProvider(accountID: id)
        provider.bootstrapRuns = [[
            "stale": .failure(ProviderError.server(status: 400, message: "Invalid pageToken")),
            "": .success(Fixtures.page(1...2, next: nil, cursor: "c-new")),
        ]]
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false)
        harness.engine.start()
        try await waitUntil("restarted listing completes") { try store.bootstrapState(for: id)?.isComplete == true }
        XCTAssertEqual(provider.bootstrapCalls, ["stale", nil])
        XCTAssertEqual(try allMessages(store).count, 2)
        XCTAssertEqual(try store.syncCursor(for: id), "c-old")
        XCTAssertEqual(try store.bootstrapState(for: id)?.messagesSeen, 2, "the count starts over with the listing")
        await harness.shutdown()
    }

    /// A head page whose state cannot be written after its rows (a full disk, or the process dying there) leaves a
    /// state carrying that head's own cursor. The next cycle adopts it rather than fetching a newer head, so polling
    /// covers every row of the first head, even one newer mail has pushed off the next, and the backfill lists the
    /// mailbox from the top.
    func testAHeadWhoseStateCannotBeWrittenIsCoveredByItsOwnCursor() async throws {
        let base = InMemoryMailStore()
        let store = FaultyStore(base: base)
        let id = Fixtures.accountID
        let provider = ScriptedProvider(accountID: id)
        provider.bootstrapRuns = [
            ["": .success(Fixtures.page(1...3, next: "p2", cursor: "c0"))],
            // What the backfill's listing from the top finds; a head fetched again would take its cursor.
            ["": .success(Fixtures.page(1...4, next: nil, cursor: "c-newer"))],
        ]
        // The head's own state, written after its rows, fails.
        store.failBootstrapState { $0?.pagesDone == 1 && $0?.checkpoint.providerPage == "p2" }
        let harness = try EngineHarness(store: base, provider: provider, engineStore: store)
        harness.engine.start()
        try await waitUntil("the listing from the top completes") { try base.bootstrapState(for: id)?.isComplete == true }
        XCTAssertEqual(store.fired, [.setBootstrapState])
        XCTAssertEqual(try base.syncCursor(for: id), "c0")
        XCTAssertEqual(provider.changesCalls.first?.cursor, "c0", "polling starts before the first head's rows")
        XCTAssertEqual(provider.bootstrapCalls, [nil, nil])
        XCTAssertEqual(try allMessages(base).count, 4)
        XCTAssertEqual(try base.bootstrapState(for: id)?.messagesSeen, 4)
        await harness.shutdown()
    }

    func testChangePageAppliesUpsertsAndDeletes() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        provider.changesQueue = [.success(Fixtures.changes(
            upserts: [Fixtures.message(2, isRead: true), Fixtures.message(10, conversation: "t2")],
            deleted: ["3"],
            cursor: "c1"
        ))]
        let harness = try EngineHarness(provider: provider)
        let store = harness.store
        harness.engine.start()
        try await waitUntil("poll applied") { try store.syncCursor(for: Fixtures.accountID) == "c1" }
        XCTAssertNil(try store.message(MessageID(accountID: Fixtures.accountID, providerID: "3")))
        XCTAssertEqual(try store.message(MessageID(accountID: Fixtures.accountID, providerID: "2"))?.isRead, true)
        XCTAssertNotNil(try store.message(MessageID(accountID: Fixtures.accountID, providerID: "10")))
        XCTAssertEqual(Set(try allMessages(store).map(\.id.providerID)), ["1", "2", "10"])
        await harness.shutdown()
    }

    func testMultiPageChangesPersistCursorAfterEachPage() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        provider.changesQueue = [
            .success(Fixtures.changes(upserts: [Fixtures.message(2)], cursor: "c1", hasMore: true)),
            .success(Fixtures.changes(upserts: [Fixtures.message(3)], cursor: "c2", hasMore: false)),
        ]
        let harness = try EngineHarness(provider: provider)
        harness.engine.start()
        try await waitUntil("both pages polled") { try harness.store.syncCursor(for: Fixtures.accountID) == "c2" }
        XCTAssertEqual(provider.changesCalls.map(\.cursor).prefix(2), ["c0", "c1"])
        XCTAssertEqual(try allMessages(harness.store).count, 3)
        await harness.shutdown()
    }

    func testThrottledChangesBackOffAndSucceed() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        provider.changesQueue = [
            .failure(ProviderError.throttled(retryAfter: 0.3)),
            .success(Fixtures.changes(cursor: "c1")),
        ]
        let harness = try EngineHarness(provider: provider)
        let phases = PhaseRecorder()
        let observation = harness.engine.observeStatus { phases.record($0) }
        harness.engine.start()
        try await waitUntil("second poll succeeded") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }
        let calls = provider.changesCalls
        guard calls.count >= 2 else { return XCTFail("expected a retry, saw \(calls.count) change calls") }
        XCTAssertGreaterThanOrEqual(calls[1].at.timeIntervalSince(calls[0].at), 0.25)
        try await waitUntil("paused phase observed") { phases.seen.contains(.paused) }
        observation.cancel()
        await harness.shutdown()
    }

    func testZeroRetryAfterOnChangesStillBacksOff() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        provider.changesQueue = [
            .failure(ProviderError.throttled(retryAfter: 0)),
            .failure(ProviderError.throttled(retryAfter: 0)),
            .success(Fixtures.changes(cursor: "c1")),
        ]
        let harness = try EngineHarness(provider: provider) { $0.backoffBase = 0.2 }
        harness.engine.start()
        try await waitUntil("recovered") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }
        let calls = provider.changesCalls
        guard calls.count >= 3 else { return XCTFail("expected two retries, saw \(calls.count) change calls") }
        // "Retry-After: 0" is honored as "soon", never as "now": the base backoff is the floor.
        XCTAssertGreaterThanOrEqual(calls[1].at.timeIntervalSince(calls[0].at), 0.15)
        XCTAssertGreaterThanOrEqual(calls[2].at.timeIntervalSince(calls[1].at), 0.15)
        await harness.shutdown()
    }

    func testNetworkErrorsBackOffExponentially() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        provider.changesQueue = [
            .failure(ProviderError.network("down")),
            .failure(ProviderError.network("down")),
            .success(Fixtures.changes(cursor: "c1")),
        ]
        let harness = try EngineHarness(provider: provider) { $0.backoffBase = 0.1 }
        let phases = PhaseRecorder()
        let observation = harness.engine.observeStatus { phases.record($0) }
        harness.engine.start()
        try await waitUntil("recovered") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }
        let calls = provider.changesCalls
        guard calls.count >= 3 else { return XCTFail("expected two retries, saw \(calls.count) change calls") }
        XCTAssertGreaterThanOrEqual(calls[1].at.timeIntervalSince(calls[0].at), 0.08)
        XCTAssertGreaterThanOrEqual(calls[2].at.timeIntervalSince(calls[1].at), 0.18)
        XCTAssertTrue(phases.seen.contains(.error))
        observation.cancel()
        await harness.shutdown()
    }

    /// A rejected cursor no longer wipes the mailbox: a fresh head page brings a new cursor, and when that page is
    /// the whole mailbox the reconcile finishes at once, keeping what the provider still lists (with its body)
    /// and removing what it no longer does.
    func testResetReconcilesInsteadOfWiping() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [
            ["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))],
            ["": .success(BootstrapPage(messages: [Fixtures.message(1, isRead: true)] + (11...13).map { Fixtures.message($0) },
                                        nextPage: nil, changeCursor: "c9"))],
        ]
        provider.changesQueue = [.failure(ProviderError.resetRequired)]
        let harness = try EngineHarness(provider: provider)
        let store = harness.store
        let one = MessageID(accountID: Fixtures.accountID, providerID: "1")
        // The body is in place before the reset; a wipe would take it.
        try store.upsertMessages([Fixtures.message(1)])
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>kept</p>", text: "kept"), renderedHTML: "<p>kept</p>", plainText: "kept"),
                           for: one)
        harness.engine.start()
        try await waitUntil("reconciled") { try store.syncCursor(for: Fixtures.accountID) == "c9" }
        XCTAssertEqual(Set(try allMessages(store).map(\.id.providerID)), ["1", "11", "12", "13"])
        XCTAssertEqual(try store.message(one)?.isRead, true, "the head page refreshes what is stored")
        XCTAssertEqual(try store.body(for: one)?.plainText, "kept")
        XCTAssertEqual(provider.bootstrapCalls, [nil, nil])
        let state = try XCTUnwrap(try store.bootstrapState(for: Fixtures.accountID))
        XCTAssertEqual(state.messagesSeen, 4)
        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(state.reconciling, true)
        await harness.shutdown()
    }

    func testDeniedKeychainAccessParksAccountInsteadOfRetrying() async throws {
        // Each retry of a denied keychain read brings the macOS password prompt back; the account waits for
        // the user instead, like a revoked token.
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        provider.changesQueue = [.failure(AuthError.keychain(status: errSecAuthFailed)), .success(Fixtures.changes(cursor: "c1"))]
        let harness = try EngineHarness(provider: provider)
        let phases = PhaseRecorder()
        let observation = harness.engine.observeStatus { phases.record($0) }
        harness.engine.start()
        try await waitUntil("needsReauth reported") { phases.latest.first?.phase == .needsReauth }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(provider.changesCalls.count, 1)
        XCTAssertTrue(phases.latest.first?.message?.contains("Keychain") ?? false)
        observation.cancel()
        await harness.shutdown()
    }

    func testUnauthorizedParksAccountUntilSyncNow() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        provider.changesQueue = [.failure(ProviderError.unauthorized), .success(Fixtures.changes(cursor: "c1"))]
        let harness = try EngineHarness(provider: provider)
        let phases = PhaseRecorder()
        let observation = harness.engine.observeStatus { phases.record($0) }
        harness.engine.start()
        try await waitUntil("needsReauth reported") { phases.latest.first?.phase == .needsReauth }
        // Several poll intervals pass without another request.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(provider.changesCalls.count, 1)
        XCTAssertEqual(try harness.store.syncCursor(for: Fixtures.accountID), "c0")

        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("poll after syncNow") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }
        XCTAssertEqual(harness.tokenProvider.invalidations, [Fixtures.accountID])
        try await waitUntil("idle again") { phases.latest.first?.phase == .idle }
        observation.cancel()
        await harness.shutdown()
    }

    /// The backfill lane's paced path keeps to `hydrationConcurrency` (the quota's own cap is higher here).
    /// The live lane is told to fetch nothing so every body goes through the paced path.
    func testHydrationFetchesBodiesWithBoundedConcurrency() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...10, next: nil, cursor: "c0"))]]
        for number in 1...10 {
            provider.bodies["\(number)"] = .success(MessageBody(html: "<p>\(number)</p>", text: "\(number)"))
        }
        provider.bodyDelay = 0.05
        let harness = try EngineHarness(provider: provider) { $0.liveHydrationLimit = 0 }
        harness.engine.start()
        try await waitUntil("all bodies stored") {
            try (1...10).allSatisfy {
                try harness.store.body(for: MessageID(accountID: Fixtures.accountID, providerID: "\($0)")) != nil
            }
        }
        XCTAssertEqual(provider.bodyCalls.count, 10)
        XCTAssertEqual(Set(provider.bodyCalls).count, 10)
        XCTAssertLessThanOrEqual(provider.maxConcurrentBodyCalls, 4)
        XCTAssertGreaterThanOrEqual(provider.maxConcurrentBodyCalls, 2)
        XCTAssertEqual(harness.sanitizer.calls, 10)
        let stored = try XCTUnwrap(try harness.store.body(for: MessageID(accountID: Fixtures.accountID, providerID: "7")))
        XCTAssertEqual(stored.renderedHTML, "<p>7</p>")
        XCTAssertEqual(stored.plainText, "7")
        await harness.shutdown()
    }

    /// The live lane fetches the bodies of the newest mail a head page brought, at most `liveHydrationLimit` of
    /// them and `liveHydrationConcurrency` at a time. The backfill's paced path is switched off (batches of none),
    /// so every body fetched here is the live lane's; `testHydrationFetchesBodiesWithBoundedConcurrency` covers the
    /// paced path that fetches the rest.
    func testLiveLaneFetchesOnlyTheNewestBodiesUpToItsLimit() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...6, next: nil, cursor: "c0"))]]
        for number in 1...6 {
            provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)"))
        }
        provider.bodyDelay = 0.05
        // More bodies than run at once, so the concurrency bound is put to the test.
        let harness = try EngineHarness(provider: provider) {
            $0.liveHydrationLimit = 4
            $0.liveHydrationConcurrency = 2
            $0.hydrationBatchSize = 0
        }
        func id(_ number: Int) -> MessageID { MessageID(accountID: Fixtures.accountID, providerID: "\(number)") }
        harness.engine.start()
        try await waitUntil("the newest four bodies stored") {
            try (3...6).allSatisfy { try harness.store.body(for: id($0)) != nil }
        }
        // Later polls bring nothing new; a fetch beyond the limit would have shown by then.
        let polls = provider.changesCalls.count
        try await waitUntil("two more polls") { provider.changesCalls.count >= polls + 2 }
        XCTAssertEqual(provider.bodyCalls.sorted(), ["3", "4", "5", "6"], "the newest, up to the limit")
        XCTAssertEqual(provider.maxConcurrentBodyCalls, 2, "two at a time, never four")
        XCTAssertNil(try harness.store.body(for: id(2)))
        await harness.shutdown()
    }
}
