import Foundation
import XCTest
@testable import SSCore

final class MailEngineBootstrapTests: XCTestCase {
    func testBootstrapAcrossThreePagesSetsCursorOnlyAtTheEnd() async throws {
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

        try await waitUntil("two pages stored") { try store.bootstrapState(for: id)?.pagesDone == 2 }
        XCTAssertNil(try store.syncCursor(for: id))
        XCTAssertEqual(try allMessages(store).count, 6)
        let midway = try XCTUnwrap(try store.bootstrapState(for: id))
        XCTAssertFalse(midway.isComplete)
        XCTAssertEqual(midway.checkpoint.providerPage, "p3")
        XCTAssertEqual(midway.checkpoint.changeCursor, "c0")

        provider.openGate("p3")
        try await waitUntil("cursor set") { try store.syncCursor(for: id) == "c0" }
        XCTAssertEqual(try allMessages(store).count, 9)
        let final = try XCTUnwrap(try store.bootstrapState(for: id))
        XCTAssertTrue(final.isComplete)
        XCTAssertNil(final.nextPage)
        XCTAssertEqual(final.messagesSeen, 9)
        XCTAssertEqual(final.pagesDone, 3)
        XCTAssertEqual(provider.bootstrapCalls, [nil, "p2", "p3"])
        await harness.shutdown()
    }

    func testRestartResumesFromPageTwoOnTheSameStore() async throws {
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
        try await waitUntil("page one stored") { try store.bootstrapState(for: id)?.pagesDone == 1 }
        await harness1.shutdown()
        XCTAssertNil(try store.syncCursor(for: id))
        XCTAssertEqual(try allMessages(store).count, 3)

        // The second provider cannot serve a first page: resuming must ask for page two directly.
        let second = ScriptedProvider(accountID: id)
        second.bootstrapRuns = [[
            "p2": .success(Fixtures.page(4...6, next: "p3")),
            "p3": .success(Fixtures.page(7...9, next: nil)),
        ]]
        let harness2 = try EngineHarness(store: store, provider: second)
        harness2.engine.start()
        try await waitUntil("cursor set by the resumed bootstrap") { try store.syncCursor(for: id) == "c0" }
        XCTAssertEqual(second.bootstrapCalls, ["p2", "p3"])
        XCTAssertEqual(first.bootstrapCalls, [nil, "p2"])
        XCTAssertEqual(try allMessages(store).count, 9)
        XCTAssertEqual(try store.bootstrapState(for: id)?.isComplete, true)
        await harness2.shutdown()
    }

    /// A resume token the provider no longer honours (Gmail answers a stale pageToken with 400) must not
    /// wedge the account in bootstrap forever: the enumeration starts over instead.
    func testRejectedResumeTokenRestartsTheBootstrap() async throws {
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
        try await waitUntil("restarted bootstrap completes") { try store.syncCursor(for: id) == "c-new" }
        XCTAssertEqual(provider.bootstrapCalls, ["stale", nil])
        XCTAssertEqual(try allMessages(store).count, 2)
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

    func testResetRequiredWipesAndBootstrapsAgain() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [
            ["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))],
            ["": .success(Fixtures.page(11...13, next: nil, cursor: "c9"))],
        ]
        provider.changesQueue = [.failure(ProviderError.resetRequired)]
        let harness = try EngineHarness(provider: provider)
        harness.engine.start()
        try await waitUntil("second bootstrap complete") { try harness.store.syncCursor(for: Fixtures.accountID) == "c9" }
        XCTAssertEqual(Set(try allMessages(harness.store).map(\.id.providerID)), ["11", "12", "13"])
        XCTAssertEqual(provider.bootstrapCalls, [nil, nil])
        XCTAssertEqual(try harness.store.bootstrapState(for: Fixtures.accountID)?.messagesSeen, 3)
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

    func testHydrationFetchesBodiesWithBoundedConcurrency() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...10, next: nil, cursor: "c0"))]]
        for number in 1...10 {
            provider.bodies["\(number)"] = .success(MessageBody(html: "<p>\(number)</p>", text: "\(number)"))
        }
        provider.bodyDelay = 0.05
        let harness = try EngineHarness(provider: provider)
        harness.engine.start()
        try await waitUntil("all bodies stored", timeout: 10) {
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
}
