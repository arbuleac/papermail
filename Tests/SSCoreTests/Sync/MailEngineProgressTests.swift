import Foundation
import XCTest
@testable import SSCore

/// What Settings › Accounts reads from the engine (spec §5.40): the provider's estimate during the first
/// download (“Downloading · 3,412 of 8,120”) and when a failed or throttled account tries again (“Retrying in
/// 30 s”).
final class MailEngineProgressTests: XCTestCase {
    func testTheFirstDownloadCarriesTheProvidersEstimate() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        let first = BootstrapPage(messages: Fixtures.page(1...3, next: nil).messages, nextPage: "p2", changeCursor: "c0", estimatedTotal: 9)
        provider.bootstrapRuns = [["": .success(first), "p2": .success(Fixtures.page(4...6, next: nil))]]
        provider.gatedBootstrapPages = ["p2"]
        let harness = try EngineHarness(provider: provider)
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("page one counted") { statuses.latest.first?.bootstrapProgress == 3 }
        XCTAssertEqual(statuses.latest.first?.bootstrapTotal, 9)
        XCTAssertEqual(try harness.store.bootstrapState(for: Fixtures.accountID)?.estimatedTotal, 9, "kept for a resumed download")
        provider.openGate("p2")
        try await waitUntil("downloaded") { statuses.latest.first?.phase == .idle }
        XCTAssertNil(statuses.latest.first?.bootstrapTotal, "only while downloading")
        observation.cancel()
        await harness.shutdown()
    }

    func testAFailedCycleSaysWhenItTriesAgain() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        provider.changesQueue = [.failure(ProviderError.network("down"))]
        let harness = try EngineHarness(provider: provider) {
            $0.backoffBase = 30
            $0.backoffCap = 60
        }
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        let started = Date()
        harness.engine.start()
        try await waitUntil("retry announced") { statuses.latest.first?.retryAt != nil }
        let status = try XCTUnwrap(statuses.latest.first)
        XCTAssertEqual(status.phase, .error)
        let wait = try XCTUnwrap(status.retryAt).timeIntervalSince(started)
        XCTAssertGreaterThan(wait, 20, "the backoff's own delay")
        XCTAssertLessThan(wait, 70)
        observation.cancel()
        await harness.shutdown()
    }
}
