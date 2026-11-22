import AppKit
import PaperCore
import WebKit
import XCTest
@testable import PaperApp

/// Reader mode on the open path (spec §5.59, docs/ARCHITECTURE.md "Performance budgets"): a conversation whose message
/// carries a 200 KB text, opened in reader mode with its body stored, stays inside "Open conversation, body cached"
/// (100 ms, click to the render landed). Its text part and its extracted text (with quoted history to fold) are both
/// measured; the payload's share, the text chosen and set as a plain body, is reported apart, and the same bodies opened
/// with their design are reported beside it (not held to it: setting the text is work the design's stored page never
/// does). Pre-rendered, such a conversation opens inside "Open conversation, pre-rendered" (50 ms), and the longest the
/// main thread is held while the neighbours pre-render, one per turn of the run loop, is reported. A text part of 4 MB is
/// set once and then found in the reader's cache. Runs only with `PAPER_PERF=1`:
///
///     PAPER_PERF=1 swift test --filter ReaderModePerformanceTests
@MainActor
final class ReaderModePerformanceTests: XCTestCase {
    private var folder: URL!
    private var environment: AppEnvironment?
    private var window: NSWindow?
    private let account = ListTestSupport.accountA

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["PAPER_PERF"] == "1" else {
            throw XCTSkip("set PAPER_PERF=1 to run the reader mode benchmark")
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderModePerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.orderOut(nil)
        if let environment {
            var finished = false
            Task { @MainActor in
                await environment.shutdown()
                finished = true
            }
            ListTestSupport.spin(until: { finished }, timeout: 5)
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// About 200 KB of letter, paragraph by paragraph, with a link now and then.
    private static func letter(_ index: Int) -> String {
        let paragraph = "The quarterly figures for the northern region are in, and the plan for the offsite holds; the notes from "
            + "Tuesday's review follow, with the open questions on the venue at the end. See https://wiki.contoso.test/plan/\(index).\n\n"
        return String(repeating: paragraph, count: 200 * 1024 / paragraph.utf8.count)
    }

    private static let history = "\n\nFrom: Ada Lovelace <ada@contoso.test>\nSent: Tuesday, 17 November 2026 09:12\nTo: Alex Morgan\n"
        + "Subject: Quarterly plan\n\n" + String(repeating: "The earlier message, quoted whole.\n", count: 200)

    func testOpeningA200KBTextStaysWithinTheCachedOpenBudget() throws {
        let environment = try AppEnvironment.makeScratch(in: folder.appendingPathComponent("env"))
        self.environment = environment
        try environment.store.upsertAccount(account)
        var ids: [ConversationID] = []
        for index in 0..<24 {
            let conversation = ConversationID(accountID: account.id, providerID: "thread-\(index)")
            let id = MessageID(accountID: account.id, providerID: "msg-\(index)")
            let text = Self.letter(index)
            let design = "<div class=\"ss-body\">" + text.split(separator: "\n").map { "<p style=\"color:#223344\">\($0)</p>" }.joined() + "</div>"
            // Even messages carry a text part; odd ones are HTML alone, their extracted text ending in quoted history.
            let stored = index.isMultiple(of: 2)
                ? StoredBody(body: MessageBody(html: "<p>source</p>", text: text), renderedHTML: design, plainText: text,
                             hasQuotedContent: false, blockedRemoteImageCount: 0, typesetting: .styled, declaresColors: true, coveredByNewYork: true)
                : StoredBody(body: MessageBody(html: "<p>source</p>", text: nil), renderedHTML: design, plainText: text + Self.history,
                             hasQuotedContent: false, blockedRemoteImageCount: 0, typesetting: .styled, declaresColors: true, coveredByNewYork: true)
            try environment.store.upsertMessages([MessageMetadata(
                id: id, conversationID: conversation, subject: "Quarterly plan \(index)", snippet: "The quarterly figures",
                from: EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test"), to: [EmailAddress(address: account.email)],
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60), roles: [.inbox], isRead: true, isStarred: false,
                hasAttachments: false
            )])
            try environment.store.saveBody(stored, for: id)
            ids.append(conversation)
        }
        XCTAssertGreaterThanOrEqual(Self.letter(0).utf8.count, 195 * 1024)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PaperAppTests.ReaderModePerf.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let reader = ConversationViewController(client: environment.engine, settings: settings)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 840, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = reader
        window.orderFrontRegardless()
        self.window = window

        func open(_ id: ConversationID) -> Double {
            ListTestSupport.spin(for: 0.3)
            XCTAssertNil(reader.pool.slot(rendering: id), "not pre-rendered")
            let start = DispatchTime.now()
            reader.show(id)
            XCTAssertTrue(ListTestSupport.spin(until: {
                guard let slot = reader.pool.current else { return false }
                return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == id
            }, timeout: 5))
            window.displayIfNeeded()
            return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        }

        // Warm WebKit with one open of each, as every open after the first in a session is.
        _ = open(ids[22])
        settings.offersReaderMode = true
        _ = open(ids[23])

        var reading: [Double] = []
        for id in ids[0..<12] { reading.append(open(id)) }

        // Pre-rendered: J onto a neighbour the reader rendered while the selection rested. Meanwhile a 1 ms timer measures
        // the longest the main thread was held, which is what a J pressed during the pre-render would wait for.
        var prerendered: [Double] = []
        let hold = HoldProbe()
        for pair in stride(from: 12, to: 20, by: 2) {
            let neighbours = [ids[pair], ids[pair + 1]]
            reader.prerender(neighbours)
            hold.start()
            XCTAssertTrue(ListTestSupport.spin(until: {
                neighbours.allSatisfy { id in reader.pool.slot(rendering: id).map { !$0.renderInFlight } ?? false }
            }, timeout: 5), "both neighbours pre-rendered")
            hold.stop()
            let start = DispatchTime.now()
            reader.show(neighbours[0])
            XCTAssertTrue(ListTestSupport.spin(until: {
                guard let slot = reader.pool.current else { return false }
                return slot.renderedID == neighbours[0] && !slot.renderInFlight
            }, timeout: 5))
            window.displayIfNeeded()
            prerendered.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }
        settings.readerModeOn = false
        var design: [Double] = []
        for id in ids[20..<22] + ids[0..<8] { design.append(open(id)) }

        // The payload's share in reader mode: the text chosen and set as the plain body, for one 200 KB message.
        let builder = RenderPayloadBuilder()
        let message = try XCTUnwrap(try environment.store.messages(in: ids[1]).first)
        let body = try XCTUnwrap(try environment.store.body(for: message.id))
        var builds: [Double] = []
        for _ in 0..<10 {
            let start = DispatchTime.now()
            let payload = builder.build(messages: [message], bodies: [message.id: body], accounts: [account.id: account],
                                        readerMode: ReaderModeRender())
            builds.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            XCTAssertEqual(payload.messages.first?.reader, .extracted)
            XCTAssertEqual(payload.messages.first?.hasQuotedContent, true, "the history folds")
        }

        // A text part of 4 MB beside the HTML (a digest, a log): set once, then found in the reader's cache, held beside
        // its limit.
        let line = "2026-11-22 09:14:03 build 4412 step 17 finished in 0.82 s, cache hit, see https://ci.contoso.test/4412\n"
        let log = String(repeating: line, count: 4 * 1024 * 1024 / line.utf8.count)
        let digest = StoredBody(body: MessageBody(html: "<p>source</p>", text: log), renderedHTML: "<div class=\"ss-body\"><p>Digest</p></div>",
                                plainText: String(log.prefix(200 * 1024)), hasQuotedContent: false, blockedRemoteImageCount: 0,
                                typesetting: .styled, declaresColors: true, coveredByNewYork: true)
        let cache = ReaderTextCache()
        var digestBuilds: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now()
            let payload = builder.build(messages: [message], bodies: [message.id: digest], accounts: [account.id: account],
                                        readerMode: ReaderModeRender(cache: cache))
            digestBuilds.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            XCTAssertEqual(payload.messages.first?.reader, .text)
        }
        XCTAssertTrue(cache.holdsLongText)

        print("PAPER_PERF reader mode open, 200 KB text, median \(String(format: "%.1f", median(reading))) ms, max \(String(format: "%.1f", reading.max() ?? 0)) ms")
        print("PAPER_PERF reader mode open pre-rendered, 200 KB text, median \(String(format: "%.1f", median(prerendered))) ms, max \(String(format: "%.1f", prerendered.max() ?? 0)) ms")
        print("PAPER_PERF reader mode pre-render, longest main-thread hold \(String(format: "%.1f", hold.longest)) ms")
        print("PAPER_PERF design open, same bodies, median \(String(format: "%.1f", median(design))) ms")
        print("PAPER_PERF reader mode payload, 200 KB extracted text, median \(String(format: "%.1f", median(builds))) ms")
        print("PAPER_PERF reader mode payload, 4 MB text part, first \(String(format: "%.1f", digestBuilds[0])) ms, then median \(String(format: "%.1f", median(Array(digestBuilds.dropFirst())))) ms")
        XCTAssertLessThan(median(reading), 100, "open conversation, body cached, in reader mode")
        XCTAssertLessThan(median(prerendered), 50, "open conversation, pre-rendered, in reader mode")
        XCTAssertLessThan(median(Array(digestBuilds.dropFirst())), digestBuilds[0] / 4, "a long text is set once, then looked up")
    }

    /// The longest gap between the ticks of a 1 ms timer on the main run loop: how long the main thread was held.
    private final class HoldProbe {
        private(set) var longest: Double = 0
        private var last = DispatchTime.now()
        private var timer: Timer?

        func start() {
            last = DispatchTime.now()
            let timer = Timer(timeInterval: 0.001, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        @objc private func tick() {
            let now = DispatchTime.now()
            longest = max(longest, Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000)
            last = now
        }
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}
