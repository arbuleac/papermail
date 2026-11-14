import Foundation
import XCTest
@testable import SSCore

/// What Settings › Accounts reads from the engine (spec §5.40): the provider's estimate while older mail
/// downloads behind the live lane (“Up to date · older mail 3 of 9”) and when a failed or throttled account tries
/// again (“Retrying in 30 s”).
final class MailEngineProgressTests: XCTestCase {
    /// The head page is the live lane's (phase bootstrapping, then idle); the rest of the download is counted
    /// in the backfill fields, which start from the head page and clear once the listing completes.
    func testTheBackfillCarriesTheProvidersEstimate() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        let first = BootstrapPage(messages: Fixtures.page(1...3, next: nil).messages, nextPage: "p2", changeCursor: "c0", estimatedTotal: 9)
        provider.bootstrapRuns = [["": .success(first), "p2": .success(Fixtures.page(4...6, next: nil))]]
        provider.gatedBootstrapPages = ["p2"]
        let harness = try EngineHarness(provider: provider)
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("head page counted") { statuses.latest.first?.backfillProgress == 3 }
        XCTAssertEqual(statuses.latest.first?.backfillTotal, 9)
        XCTAssertEqual(try harness.store.bootstrapState(for: Fixtures.accountID)?.estimatedTotal, 9, "kept for a resumed download")
        try await waitUntil("new mail is up to date while older mail downloads") { statuses.latest.first?.phase == .idle }
        XCTAssertTrue(statuses.seen.contains(.bootstrapping), "the head page is the account's first sync")
        XCTAssertEqual(statuses.latest.first?.backfillProgress, 3)
        XCTAssertNil(statuses.latest.first?.bootstrapTotal, "the live lane's figures go with its head page")
        provider.openGate("p2")
        try await waitUntil("downloaded") { statuses.latest.first?.backfillProgress == nil }
        XCTAssertNil(statuses.latest.first?.backfillTotal, "only while downloading")
        XCTAssertEqual(statuses.latest.first?.phase, .idle)
        observation.cancel()
        await harness.shutdown()
    }

    /// Once the listing is done, the bodies still arriving show as `backfillDownloadingBodies` (“Up to date ·
    /// downloading messages…”) until a batch finds none missing. One body per batch, the oldest held, so the flag
    /// can be seen on while a body is still to come.
    func testBodiesStillArrivingAreAnnouncedUntilNoneAreMissing() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        for number in 1...3 {
            provider.bodies["\(number)"] = .success(MessageBody(html: "<p>\(number)</p>", text: "\(number)"))
        }
        provider.heldBodies = ["1"]
        let harness = try EngineHarness(provider: provider) {
            $0.liveHydrationLimit = 0
            $0.hydrationBatchSize = 1
        }
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("bodies announced while the oldest is still to come") {
            statuses.latest.first?.backfillDownloadingBodies == true && provider.bodyCalls.contains("1")
        }
        XCTAssertNil(statuses.latest.first?.backfillProgress, "the listing is done: the head page was the whole mailbox")
        provider.releaseBody("1")
        try await waitUntil("cleared once none are missing") { statuses.latest.first?.backfillDownloadingBodies == false }
        XCTAssertNotNil(try harness.store.body(for: MessageID(accountID: Fixtures.accountID, providerID: "1")))
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

    /// While the polls fail and back off, the user reads and archives mail, and each action runs the outbox on its own.
    /// That cycle set the phase to idle, so the line said "Up to date" between failing polls and lost its countdown.
    /// Only a full cycle, one that polled, moves the phase now.
    func testAnOutboxCycleLeavesAFailingPollsStatusAsItWas() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        provider.changesQueue = [.failure(ProviderError.network("down"))]
        let harness = try EngineHarness(provider: provider) {
            $0.backoffBase = 30
            $0.backoffCap = 60
        }
        let statuses = PhaseRecorder()
        let observation = harness.engine.observeStatus { statuses.record($0) }
        harness.engine.start()
        try await waitUntil("retry announced") { statuses.latest.first?.retryAt != nil }
        let failing = try XCTUnwrap(statuses.latest.first)

        try harness.engine.perform(.setRead(true), on: [MessageID(accountID: Fixtures.accountID, providerID: "1")])
        try await waitUntil("the outbox ran") { provider.applyCalls.count == 1 }
        try await Task.sleep(for: .milliseconds(200))

        let after = try XCTUnwrap(statuses.latest.first)
        XCTAssertEqual(after.phase, .error)
        XCTAssertEqual(after.message, failing.message)
        XCTAssertEqual(after.retryAt, failing.retryAt, "the countdown stays")
        XCTAssertEqual(provider.changesCalls.count, 1, "and the poll keeps its backoff")
        observation.cancel()
        await harness.shutdown()
    }
}
