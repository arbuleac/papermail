import Foundation
import XCTest
@testable import PaperCore

/// The engine's half of attachment byte counts (Q1.7b): a download is charged to the quota as live spend, its
/// progress reaches every caller at most about ten times a second, and a file already cached says nothing.
final class AttachmentDownloadTests: XCTestCase {
    private let id = MessageID(accountID: Fixtures.accountID, providerID: "1")

    // MARK: Quota

    /// Gmail prices messages.attachments.get at 5 units; the download is recorded as live spend, which never waits.
    func testAGmailDownloadIsChargedFiveUnitsOfLiveSpend() async throws {
        let spent = try await liveSpend(kind: .gmail)
        XCTAssertEqual(spent.first, 5, accuracy: 0.000_1)
        XCTAssertEqual(spent.second, 0, accuracy: 0.000_1, "a cached file costs nothing")
    }

    /// Graph counts the `$value` GET as one request.
    func testAGraphDownloadIsChargedOneRequestOfLiveSpend() async throws {
        let spent = try await liveSpend(kind: .microsoft)
        XCTAssertEqual(spent.first, 1, accuracy: 0.000_1)
        XCTAssertEqual(spent.second, 0, accuracy: 0.000_1)
    }

    func testTheStandardQuotasPriceAnAttachment() {
        XCTAssertEqual(ProviderQuota.standard(for: .gmail).attachmentCost, 5)
        XCTAssertEqual(ProviderQuota.standard(for: .microsoft).attachmentCost, 1)
    }

    /// The live share's headroom spent by a first download and by a second one served from the cache. The budget's
    /// clock stands still, so nothing refills in between.
    private func liveSpend(kind: ProviderKind) async throws -> (first: Double, second: Double) {
        let provider = ScriptedProvider(accountID: Fixtures.accountID, kind: kind)
        provider.attachments["1/att-1"] = Data("hello".utf8)
        let budgets = BudgetRecorder()
        let start = Date()
        let harness = try EngineHarness(provider: provider) { tuning in
            tuning.quota = { .standard(for: $0.kind) }
            tuning.makeBudget = { quota in budgets.add(QuotaBudget(quota: quota, now: { start })) }
        }
        _ = try await harness.engine.attachmentData(for: id, attachmentID: "att-1", expectedSize: 5, progress: nil)
        let budget = try XCTUnwrap(budgets.first)
        let afterFirst = await budget.liveHeadroom
        _ = try await harness.engine.attachmentData(for: id, attachmentID: "att-1", expectedSize: 5, progress: nil)
        let afterSecond = await budget.liveHeadroom
        await harness.shutdown()
        XCTAssertEqual(provider.attachmentCalls.count, 1)
        return (budget.liveCapacity - afterFirst, afterFirst - afterSecond)
    }

    // MARK: Progress

    func testProgressReachesTheCallerAndACachedFileSaysNothing() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.attachments["1/att-1"] = Data("hello".utf8)
        provider.attachmentProgressSteps = [0]
        let harness = try EngineHarness(provider: provider)
        let first = FractionRecorder()

        let data = try await harness.engine.attachmentData(for: id, attachmentID: "att-1", expectedSize: 5, progress: first.record)

        XCTAssertEqual(data, Data("hello".utf8))
        XCTAssertEqual(first.values, [0, 1], "the first fraction and the final one always go through")
        XCTAssertEqual(provider.attachmentExpectedSizes, [5], "the listed size reaches the provider")

        let second = FractionRecorder()
        _ = try await harness.engine.attachmentData(for: id, attachmentID: "att-1", expectedSize: 5, progress: second.record)
        XCTAssertEqual(second.values, [], "a file already on this Mac never shows a download")
        await harness.shutdown()
    }

    /// An inline image and the chip can ask for the same file at once: one download, and the second caller hears
    /// where it stands as it joins and everything after.
    func testACallerJoiningADownloadHearsItFromWhereItStands() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.attachments["1/att-1"] = Data("hello".utf8)
        provider.attachmentProgressSteps = [0.25]
        provider.holdAttachmentDownloads = true
        let harness = try EngineHarness(provider: provider)
        let engine = harness.engine
        let message = id
        let first = FractionRecorder()
        let second = FractionRecorder()

        let leader = Task { try await engine.attachmentData(for: message, attachmentID: "att-1", expectedSize: 5, progress: first.record) }
        try await waitUntil("the download reported") { first.values == [0.25] }
        let joiner = Task { try await engine.attachmentData(for: message, attachmentID: "att-1", expectedSize: 5, progress: second.record) }
        try await waitUntil("the joiner heard where it stands") { second.values == [0.25] }
        provider.holdAttachmentDownloads = false

        let results = try await [leader.value, joiner.value]
        XCTAssertEqual(results, [Data("hello".utf8), Data("hello".utf8)])
        XCTAssertEqual(provider.attachmentCalls.count, 1, "one download")
        XCTAssertEqual(first.values, [0.25, 1])
        XCTAssertEqual(second.values, [0.25, 1])
        await harness.shutdown()
    }

    /// A download that fails leaves nothing in the cache, so the next attempt downloads again rather than serving
    /// half a file.
    func testAFailedDownloadLeavesNoFileBehind() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        let harness = try EngineHarness(provider: provider)

        do {
            _ = try await harness.engine.attachmentData(for: id, attachmentID: "att-1", expectedSize: 5, progress: nil)
            XCTFail("expected notFound")
        } catch ProviderError.notFound {
            // expected
        }
        let folder = harness.cacheDirectory.appendingPathComponent(Fixtures.accountID.rawValue).appendingPathComponent("1")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [], [])
        XCTAssertEqual(Self.contents(of: harness.cacheDirectory.appendingPathComponent(".partial")), [])

        provider.attachments["1/att-1"] = Data("hello".utf8)
        let data = try await harness.engine.attachmentData(for: id, attachmentID: "att-1", expectedSize: 5, progress: nil)
        XCTAssertEqual(data, Data("hello".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["att-1"], "no partial file left")
        await harness.shutdown()
    }

    /// Quitting or crashing mid-download leaves the partial file (and Gmail's reply beside it) behind, since the
    /// download never gets to remove it. The next run's first download sweeps them, and only the first: a later one
    /// must not take the file of a download still running.
    func testTheFirstDownloadSweepsWhatAnInterruptedRunLeftAndOnlyThat() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.attachments["1/att-1"] = Data("hello".utf8)
        provider.attachments["1/att-2"] = Data("world".utf8)
        provider.holdAttachmentDownloads = true
        let harness = try EngineHarness(provider: provider)
        let partials = harness.cacheDirectory.appendingPathComponent(".partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partials, withIntermediateDirectories: true)
        let leftover = UUID().uuidString + ".partial"
        try Data(repeating: 7, count: 4_096).write(to: partials.appendingPathComponent(leftover))
        try Data("{}".utf8).write(to: partials.appendingPathComponent(leftover + ".reply"))
        let engine = harness.engine
        let message = id

        let first = Task { try await engine.attachmentData(for: message, attachmentID: "att-1", expectedSize: 5, progress: nil) }
        try await waitUntil("the first download wrote its partial file") {
            Self.contents(of: partials).filter { !$0.hasPrefix(leftover) }.count == 1
        }
        XCTAssertEqual(Self.contents(of: partials).count, 1, "the earlier run's files are swept before the first download")

        let second = Task { try await engine.attachmentData(for: message, attachmentID: "att-2", expectedSize: 5, progress: nil) }
        try await waitUntil("both downloads have their partial files", timeout: 10) { Self.contents(of: partials).count == 2 }

        provider.holdAttachmentDownloads = false
        let results = try await [first.value, second.value]
        XCTAssertEqual(results, [Data("hello".utf8), Data("world".utf8)])
        XCTAssertEqual(Self.contents(of: partials), [])
        await harness.shutdown()
    }

    private static func contents(of folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: Coalescing

    /// Hundreds of chunks a second become about ten reports: the first, then one per tenth of a second, then the 1.
    func testTheRelayHandsOnAboutTenFractionsASecond() {
        let clock = ManualClock()
        let relay = AttachmentProgressRelay(now: clock.now, schedule: clock.schedule)
        let heard = FractionRecorder()
        relay.add(heard.record)

        // A chunk every 2 ms for a second: 500 fractions.
        for step in 1...500 {
            relay.report(Double(step) / 501)
            clock.advance(by: 0.002)
        }
        relay.report(1)

        let values = heard.values
        XCTAssertEqual(values.first, 1.0 / 501, "the first fraction goes at once")
        XCTAssertEqual(values.last, 1, "the end always goes through")
        XCTAssertEqual(values, values.sorted())
        XCTAssertTrue((10...13).contains(values.count), "about ten a second, not 500: \(values.count)")
        XCTAssertLessThanOrEqual(clock.scheduledCount, values.count, "at most one delayed hand-on per interval")
    }

    /// A burst that stops short of the interval is not lost: the latest goes out when the interval is up, with
    /// no further chunk to carry it.
    func testAHeldFractionGoesOutWhenTheIntervalIsUp() {
        let clock = ManualClock()
        let relay = AttachmentProgressRelay(now: clock.now, schedule: clock.schedule)
        let heard = FractionRecorder()
        relay.add(heard.record)

        relay.report(0.1)
        clock.advance(by: 0.01)
        relay.report(0.2)
        relay.report(0.3)
        clock.advance(by: 0.05)
        XCTAssertEqual(heard.values, [0.1], "held while the interval runs")
        clock.advance(by: 0.04)
        XCTAssertEqual(heard.values, [0.1, 0.3], "the latest, once")
        clock.advance(by: 1)
        XCTAssertEqual(heard.values, [0.1, 0.3])
        XCTAssertEqual(clock.scheduledCount, 1)
    }

    func testTheRelayIgnoresFractionsThatDoNotRise() {
        let clock = ManualClock()
        let relay = AttachmentProgressRelay(now: clock.now, schedule: clock.schedule)
        let heard = FractionRecorder()
        relay.add(heard.record)

        relay.report(0.5)
        clock.advance(by: 1)
        relay.report(0.4)
        relay.report(0.5)
        clock.advance(by: 1)
        relay.report(0.6)

        XCTAssertEqual(heard.values, [0.5, 0.6])
    }

    /// A fraction dropped for coming too soon is not lost for good: the next one after the interval carries on.
    func testASlowLinkHearsEveryChunk() {
        let clock = ManualClock()
        let relay = AttachmentProgressRelay(now: clock.now, schedule: clock.schedule)
        let heard = FractionRecorder()
        relay.add(heard.record)

        for fraction in [0.1, 0.2, 0.3] {
            relay.report(fraction)
            clock.advance(by: 0.5)
        }

        XCTAssertEqual(heard.values, [0.1, 0.2, 0.3])
    }

    // MARK: Meter

    func testTheMeterStopsAt99UntilTheFileIsCompleteThenReportsOne() throws {
        let heard = FractionRecorder()
        let meter = DownloadProgressMeter(estimatedLength: 1_000, report: heard.record)
        let response = try XCTUnwrap(Self.response(headers: [:]))

        meter.start()
        meter.received(250, of: response)
        meter.received(250, of: response)
        meter.received(1_000, of: response)
        meter.received(1_400, of: response)
        meter.finish()

        XCTAssertEqual(heard.values, [0, 0.25, DownloadProgressMeter.ceilingBeforeFinish, 1])
    }

    /// The stated length wins, unless the body is compressed: URLSession hands over decoded bytes, which would run
    /// past a compressed length.
    func testTheMeterMeasuresAgainstAnUncompressedContentLength() throws {
        let plain = FractionRecorder()
        let stated = DownloadProgressMeter(estimatedLength: 4_000, report: plain.record)
        stated.received(500, of: try XCTUnwrap(Self.response(headers: ["Content-Length": "1000"])))
        XCTAssertEqual(plain.values, [0.5])

        let gzipped = FractionRecorder()
        let compressed = DownloadProgressMeter(estimatedLength: 4_000, report: gzipped.record)
        compressed.received(500, of: try XCTUnwrap(Self.response(headers: ["Content-Length": "1000", "Content-Encoding": "gzip"])))
        XCTAssertEqual(gzipped.values, [0.125])
    }

    func testAMeterWithoutALengthSaysNothing() throws {
        let heard = FractionRecorder()
        let meter = DownloadProgressMeter(estimatedLength: 0, report: heard.record)
        meter.start()
        meter.received(500, of: try XCTUnwrap(Self.response(headers: [:])))
        meter.finish()
        XCTAssertEqual(heard.values, [])
    }

    private static func response(headers: [String: String]) -> HTTPURLResponse? {
        HTTPURLResponse(url: URL(string: "https://example.com/a")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
    }
}

private final class FractionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var values: [Double] { lock.withLock { recorded } }

    var record: @Sendable (Double) -> Void {
        { [self] fraction in lock.withLock { recorded.append(fraction) } }
    }
}

private final class BudgetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var budgets: [QuotaBudget] = []

    var first: QuotaBudget? { lock.withLock { budgets.first } }

    func add(_ budget: QuotaBudget) -> QuotaBudget {
        lock.withLock { budgets.append(budget) }
        return budget
    }
}

/// A monotonic clock and a scheduler on it: work scheduled for later runs when `advance` passes its time.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_000
    private var pending: [(due: TimeInterval, work: @Sendable () -> Void)] = []
    private var scheduled = 0

    var scheduledCount: Int { lock.withLock { scheduled } }

    var now: @Sendable () -> TimeInterval {
        { [self] in lock.withLock { time } }
    }

    var schedule: AttachmentProgressRelay.Schedule {
        { [self] delay, work in
            lock.withLock {
                scheduled += 1
                pending.append((time + delay, work))
            }
        }
    }

    func advance(by seconds: TimeInterval) {
        let due: [@Sendable () -> Void] = lock.withLock {
            time += seconds
            let ready = pending.filter { $0.due <= time + 0.000_001 }
            pending.removeAll { $0.due <= time + 0.000_001 }
            return ready.map(\.work)
        }
        // Outside the lock: the work reads the clock.
        for work in due { work() }
    }
}
