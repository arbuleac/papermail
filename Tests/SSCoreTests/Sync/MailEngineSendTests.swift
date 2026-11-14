import Foundation
import XCTest
@testable import SSCore

final class MailEngineSendTests: XCTestCase {
    private func startedHarness() throws -> EngineHarness {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider)
        harness.engine.start()
        return harness
    }

    func testSendIsCancellableDuringUndoWindowAndSentAfterIt() async throws {
        let harness = try startedHarness()
        let message = Fixtures.outgoing()

        let cancelled = try harness.engine.send(message, undoWindow: 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(try harness.engine.cancelSend(id: cancelled))
        XCTAssertFalse(try harness.engine.cancelSend(id: cancelled))
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertTrue(harness.provider.sendCalls.isEmpty)
        XCTAssertTrue(try harness.store.pendingSends().isEmpty)

        let queuedAt = Date()
        let kept = try harness.engine.send(message, undoWindow: 1)
        XCTAssertEqual(try harness.store.pendingSends().first?.status, .scheduled)
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(harness.provider.sendCalls.count, 1)
        XCTAssertEqual(harness.provider.sendCalls.first?.subject, "Hello")
        XCTAssertFalse(try harness.engine.cancelSend(id: kept))
        XCTAssertTrue(try harness.store.pendingSends().isEmpty)
        let sentAt = try XCTUnwrap(harness.provider.sendTimes.first)
        XCTAssertGreaterThanOrEqual(sentAt.timeIntervalSince(queuedAt), 0.95)
        await harness.shutdown()
    }

    func testFailedSendIsKeptWithItsError() async throws {
        let harness = try startedHarness()
        harness.provider.sendResults = [.failure(ProviderError.server(status: 500, message: "boom"))]
        let id = try harness.engine.send(Fixtures.outgoing(), undoWindow: 0)
        try await waitUntil("send failed") { try harness.store.pendingSends().first?.status == .failed }
        let failed = try XCTUnwrap(try harness.store.pendingSends().first)
        XCTAssertEqual(failed.id, id)
        XCTAssertEqual(failed.attempts, 1)
        XCTAssertEqual(failed.lastError, "server 500: boom")
        XCTAssertFalse(try harness.engine.cancelSend(id: id))
        // A failed send is never retried on its own: the message may already have gone out.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.provider.sendCalls.count, 1)
        await harness.shutdown()
    }

    /// A send that failed before any request left this Mac (no network at wake, Wi-Fi not back yet; a token refresh
    /// that could not reach the token endpoint) was marked failed for good, though nothing reached the provider and a
    /// retry cannot send it twice. It waits and is sent again, as a throttled one is; one whose request may have gone
    /// out still fails.
    func testASendThatNeverLeftThisMacIsSentAgain() async throws {
        let harness = try startedHarness()
        harness.provider.sendResults = [
            .failure(ProviderError.transport(URLError(.notConnectedToInternet))),
            .failure(ProviderError.notSent("token endpoint unreachable")),
        ]
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 0)
        try await waitUntil("sent on the third attempt") { harness.provider.sendCalls.count == 3 }
        try await waitUntil("outbox empty") { try harness.store.pendingSends().isEmpty }
        await harness.shutdown()
    }

    func testAConnectionLostMidSendStillFails() async throws {
        let harness = try startedHarness()
        harness.provider.sendResults = [.failure(ProviderError.transport(URLError(.networkConnectionLost)))]
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 0)
        try await waitUntil("send failed") { try harness.store.pendingSends().first?.status == .failed }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.provider.sendCalls.count, 1, "it may have gone out")
        await harness.shutdown()
    }

    func testThrottledSendIsRescheduledAndEventuallySent() async throws {
        let harness = try startedHarness()
        harness.provider.sendResults = [.failure(ProviderError.throttled(retryAfter: 0.2))]
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 0)
        try await waitUntil("sent on the second attempt") { harness.provider.sendCalls.count == 2 }
        try await waitUntil("outbox empty") { try harness.store.pendingSends().isEmpty }
        let times = harness.provider.sendTimes
        guard times.count >= 2 else { return XCTFail("expected two send attempts") }
        XCTAssertGreaterThanOrEqual(times[1].timeIntervalSince(times[0]), 0.15)
        await harness.shutdown()
    }

    /// Like a user action, a send waits no longer than the live lane's cap on a provider's retry time.
    func testALongRetryAfterOnSendWaitsNoLongerThanTheLiveCap() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        provider.sendResults = [.failure(ProviderError.throttled(retryAfter: 3_600))]
        let harness = try EngineHarness(provider: provider) {
            $0.backoffCap = 600
            $0.liveBackoffCap = 0.3
        }
        harness.engine.start()
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 0)
        try await waitUntil("sent on the second attempt", timeout: 10) { provider.sendCalls.count == 2 }
        try await waitUntil("outbox empty") { try harness.store.pendingSends().isEmpty }
        await harness.shutdown()
    }

    func testZeroRetryAfterOnSendStillBacksOff() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        provider.sendResults = [.failure(ProviderError.throttled(retryAfter: 0))]
        // The runner waits exactly for the retry time, so a retry scheduled for "now" would show as two quick sends.
        let harness = try EngineHarness(provider: provider) { $0.backoffBase = 0.2 }
        harness.engine.start()
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 0)
        try await waitUntil("sent on the second attempt") { provider.sendCalls.count == 2 }
        let times = provider.sendTimes
        guard times.count >= 2 else { return XCTFail("expected two send attempts") }
        XCTAssertGreaterThanOrEqual(times[1].timeIntervalSince(times[0]), 0.15)
        try await waitUntil("outbox empty") { try harness.store.pendingSends().isEmpty }
        await harness.shutdown()
    }

    func testSendWithoutRunningEngineStaysScheduled() async throws {
        let harness = try EngineHarness()
        let id = try harness.engine.send(Fixtures.outgoing(), undoWindow: 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try harness.store.pendingSends().first?.status, .scheduled)
        XCTAssertTrue(harness.provider.sendCalls.isEmpty)
        XCTAssertTrue(try harness.engine.cancelSend(id: id))
        await harness.shutdown()
    }
}
