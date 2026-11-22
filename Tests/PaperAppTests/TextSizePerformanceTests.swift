import AppKit
import PaperCore
import PaperDesign
import WebKit
import XCTest
@testable import PaperApp

/// The Text size row of the budgets in docs/ARCHITECTURE.md (spec §4.15), on the synthetic mailbox in a real SQLite
/// file: a change in Settings re-measures and draws the list within 50 ms (`list.remeasure`), and it and ⌘+ / ⌘− have
/// every pooled reader shell measure every open body again within 100 ms (`conversation.textSize`). The conversation
/// open and its pre-rendered neighbours hold 30 messages each, every sheet expanded, plain and styled bodies mixed.
/// Loading the mailbox takes a while, so it only runs with `PAPER_PERF=1`:
///
///     PAPER_PERF=1 swift test -c release --filter TextSizePerformanceTests
///
/// The mailbox is `PerfMailboxSupport`'s (300,000 messages; `PAPER_PERF_MESSAGES` sets another size, `PAPER_PERF_RETENTION=1year` Keep mail).
@MainActor
final class TextSizePerformanceTests: XCTestCase {
    private typealias Support = ListTestSupport

    override func tearDown() {
        MainActor.assumeIsolated { QuireEnvironment.shared.setTextSize(.default) }
        super.tearDown()
    }

    func testATextSizeChangeStaysWithinBudget() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PAPER_PERF"] == "1" else {
            throw XCTSkip("set PAPER_PERF=1 to run the Text size benchmark")
        }
        let harness = try MainWindowHarness(threads: 1, perfMailbox: true)
        defer { harness.close() }
        let store = harness.environment.store
        print("PAPER_PERF textSize mailbox: \(PerfMailboxSupport.label)")
        // The first three conversations, the one opened and the two pre-rendered beside it, grow to 30 messages each.
        for thread in 0..<3 {
            try lengthen(thread: thread, to: 30, in: store)
        }
        Support.spin(until: { harness.list.conversations.count >= 3 && harness.list.conversations[2].id.providerID == "thread-2" }, timeout: 30)
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1_280, height: 800))
        window.layoutIfNeeded()

        // The middle one of the three, so both pre-rendered neighbours are long too.
        XCTAssertEqual(harness.list.conversations.prefix(3).map(\.id.providerID), ["thread-0", "thread-1", "thread-2"])
        let middle = harness.list.conversations[1].id
        harness.list.selectedConversationID = middle
        harness.list.onSelectionChange?(middle)
        var landed: WKWebView??
        harness.controller.whenReaderSettles(timeout: 20) { landed = .some($0) }
        Support.spin(until: { landed != nil }, timeout: 20)
        XCTAssertGreaterThanOrEqual(harness.reader.currentMessages.count, 30)
        let reader = harness.reader
        // Let the neighbours pre-render, then open every sheet in every ready shell so each body is in a frame.
        Support.spin(until: { reader.pool.slots.filter { $0.isReady && $0.renderedID != nil }.count == 3 }, timeout: 10)
        for slot in reader.pool.slots where slot.isReady {
            slot.webView.evaluateJavaScript("window.ss && window.ss.expandAll()") { _, _ in }
        }
        Support.spin(for: 2)
        let frames = framedCards(in: reader)
        print("PAPER_PERF textSize body frames across the shells: \(frames)")
        XCTAssertGreaterThanOrEqual(frames, 60, "every sheet open, in the open conversation and its neighbours")

        var measured: [QuireFont.TextSize] = []
        reader.onTextSizeEvent = { event in
            if case .measured(let size) = event { measured.append(size) }
        }
        defer { reader.onTextSizeEvent = nil }

        // Settings › Text size: the list re-measured and drawn, then every shell measured again.
        var lists: [Double] = []
        var readers: [Double] = []
        let sizes: [QuireFont.TextSize] = [.larger, .small, .large, .default]
        for round in 0..<12 {
            let size = sizes[round % sizes.count]
            let start = DispatchTime.now()
            harness.settings.textSize = size
            window.displayIfNeeded()
            lists.append(milliseconds(since: start))
            XCTAssertTrue(Support.spin(until: { measured.last == size }, timeout: 5), "\(size): the shells measured again")
            readers.append(milliseconds(since: start))
            XCTAssertEqual(harness.list.rowMetrics.height, QuireRowMetrics(textSize: size, compact: false).height)
            // The follow-up measure 50 ms on lands before the next change, as it would between two clicks.
            Support.spin(for: 0.1)
        }

        // ⌘+ and ⌘−: the reader alone, from Default up to Larger, down to Small and back, twice.
        XCTAssertEqual(harness.settings.textSize, .default)
        var keys: [Double] = []
        let steps = [true, true, false, false, false, true]
        for round in 0..<12 {
            let larger = steps[round % steps.count]
            let start = DispatchTime.now()
            let before = measured.count
            XCTAssertTrue(harness.settings.stepReaderTextSize(larger: larger))
            XCTAssertTrue(Support.spin(until: { measured.count > before }, timeout: 5))
            keys.append(milliseconds(since: start))
            Support.spin(for: 0.1)
        }

        report("list re-measured and drawn, median", percentile(lists, 0.5))
        report("list re-measured and drawn, max", lists.max() ?? 0)
        report("Settings change, every shell measured again, median", percentile(readers, 0.5))
        report("Settings change, every shell measured again, max", readers.max() ?? 0)
        report("⌘+ / ⌘−, every shell measured again, median", percentile(keys, 0.5))
        report("⌘+ / ⌘−, every shell measured again, max", keys.max() ?? 0)
        XCTAssertLessThan(percentile(lists, 0.5), 50, "Text size budget: the list")
        XCTAssertLessThan(percentile(readers, 0.5), 100, "Text size budget: the reader after a Settings change")
        XCTAssertLessThan(percentile(keys, 0.5), 100, "Text size budget: ⌘+ / ⌘−")
    }

    /// `thread`'s conversation (as `ListTestSupport.messages` numbers them) holds `count` messages, every other body
    /// plain (set in the reader's type) and the rest styled HTML, each a few paragraphs long.
    private func lengthen(thread: Int, to count: Int, in store: MailStoring) throws {
        let account = thread % 2 == 0 ? Support.accountA : Support.accountB
        let conversation = ConversationID(accountID: account.id, providerID: "thread-\(thread)")
        let now = Date()
        var added: [MessageMetadata] = []
        for part in 0..<count {
            added.append(MessageMetadata(
                id: MessageID(accountID: account.id, providerID: "long-\(thread)-\(part)"),
                conversationID: conversation,
                subject: "Project update \(thread) and the quarterly planning document",
                snippet: "Just following up on the thread from last week.",
                from: Support.senders[(thread + part) % Support.senders.count],
                to: [EmailAddress(name: account.displayName, address: account.email)],
                date: now.addingTimeInterval(-Double(count - part) * 60 + Double(thread) * -7_200 + 3_600),
                roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
            ))
        }
        try store.upsertMessages(added)
        let paragraph = "Just following up on the thread from last week: the review moved, the numbers are in the sheet, and "
            + "the draft needs one more pass before Tuesday. Let me know which of the two times works for you."
        for (part, message) in added.enumerated() {
            let plain = part % 2 == 0
            let html = (0..<4).map { _ in plain ? "<p>\(paragraph)</p>" : "<p style=\"font-size:13px;color:#333\">\(paragraph)</p>" }.joined()
            try store.saveBody(StoredBody(body: MessageBody(html: html, text: paragraph), renderedHTML: html, plainText: paragraph,
                                          hasQuotedContent: false, blockedRemoteImageCount: 0,
                                          typesetting: plain ? .unstyled : .styled, declaresColors: !plain, coveredByNewYork: true),
                               for: message.id)
        }
    }

    /// Body frames across every ready shell.
    private func framedCards(in reader: ConversationViewController) -> Int {
        var total = 0
        var answered = 0
        let ready = reader.pool.slots.filter(\.isReady)
        for slot in ready {
            slot.webView.evaluateJavaScript("document.querySelectorAll('.ss-card iframe').length") { value, _ in
                total += (value as? Int) ?? 0
                answered += 1
            }
        }
        Support.spin(until: { answered == ready.count }, timeout: 5)
        return total
    }

    private func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    private func report(_ label: String, _ value: Double) {
        print("PAPER_PERF textSize \(label): \(String(format: "%.2f", value)) ms")
    }
}
