import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// The list half of the budgets in docs/ARCHITECTURE.md, on a synthetic mailbox in a real SQLite file:
/// j/k ≤ 16 ms, list refresh after a sync transaction ≤ 50 ms, and no avatar cache miss while hovering during
/// a scroll (spec §8.7). Loading the mailbox takes a while, so it only runs with `SS_PERF=1`:
///
///     SS_PERF=1 swift test -c release --filter MessageListPerformanceTests
///
/// The mailbox is `PerfMailboxSupport`'s (300,000 messages; `SS_PERF_MESSAGES` sets another size, `SS_PERF_RETENTION=1year` Keep mail).
@MainActor
final class MessageListPerformanceTests: XCTestCase {
    private typealias Support = ListTestSupport

    func testListStaysWithinBudget() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the list benchmark")
        }
        let messageCount = PerfMailboxSupport.messageCount
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageListPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("mail.sqlite").path
        try PerfMailboxSupport.install(at: path)
        let store = try SQLiteMailStore(path: path)
        print("SS_PERF list mailbox: \(PerfMailboxSupport.label)")

        let (list, window) = Support.host(store: store, settings: Support.settings(), size: NSSize(width: 380, height: 760))
        XCTAssertEqual(list.conversations.count, 200)
        XCTAssertTrue(list.layout.showsHeads)

        // j/k: the selection move and the frame it draws, every step.
        var steps: [Double] = []
        for step in 0..<300 {
            let start = DispatchTime.now()
            if step < 150 { list.selectNext() } else { list.selectPrevious() }
            window.displayIfNeeded()
            steps.append(milliseconds(since: start))
            // Pages loaded by walking down land between key presses, as they would in the app.
            RunLoop.main.run(until: Date())
        }
        let warmSteps = Array(steps.dropFirst(5))
        report("j/k step median", percentile(warmSteps, 0.5))
        report("j/k step p95", percentile(warmSteps, 0.95))
        report("j/k step max", warmSteps.max() ?? 0)
        XCTAssertLessThan(percentile(warmSteps, 0.95), 16, "j/k budget")

        // Refresh after a sync transaction: 200 new replies move threads to the top; read, diff, apply, draw.
        var refreshes: [Double] = []
        for round in 0..<5 {
            let now = Date().addingTimeInterval(Double(round + 1))
            let replies = (0..<200).map { offset -> MessageMetadata in
                let thread = (round * 200 + offset * 7) % (messageCount / 2)
                let account = thread % 2 == 0 ? Support.accountA : Support.accountB
                return MessageMetadata(
                    id: MessageID(accountID: account.id, providerID: "reply-\(round)-\(offset)"),
                    conversationID: ConversationID(accountID: account.id, providerID: "thread-\(thread)"),
                    subject: "Project update \(thread) and the quarterly planning document",
                    snippet: "A new reply in round \(round).",
                    from: Support.senders[offset % Support.senders.count],
                    date: now.addingTimeInterval(-Double(offset)),
                    roles: [.inbox], isRead: false, isStarred: false, hasAttachments: false
                )
            }
            try store.upsertMessages(replies)
            let start = DispatchTime.now()
            let rows = try store.conversations(list.query)
            list.handleHeadUpdate(rows)
            window.displayIfNeeded()
            refreshes.append(milliseconds(since: start))
        }
        report("refresh after a 200-message transaction, median", percentile(refreshes, 0.5))
        report("refresh after a 200-message transaction, max", refreshes.max() ?? 0)
        XCTAssertLessThan(percentile(refreshes, 0.5), 50, "list refresh budget")

        // Hover while scrolling: after one pass has rendered every face, scrolling with the pointer resting over
        // the list never misses the face cache.
        let clip = list.scrollView.contentView
        // A hundred conversations down: far enough to recycle every row view several times, short of the
        // distance that asks for the next page, so no new faces arrive between the passes.
        let lastRow = list.layout.row(ofConversation: 100) ?? 0
        let limit = max(0, list.tableView.rect(ofRow: lastRow).maxY - clip.bounds.height)
        func scrollThrough(hovering: Bool) {
            var y: CGFloat = 0
            list.tableView.beginScrollHoverSuspension()
            while y < limit {
                y = min(limit, y + 34)
                clip.scroll(to: NSPoint(x: 0, y: y))
                list.scrollView.reflectScrolledClipView(clip)
                if hovering {
                    // A still pointer 300 pt down the pane: the row beneath it changes as rows slide by.
                    list.tableView.setHoveredRow(list.tableView.row(at: NSPoint(x: 100, y: y + 300)))
                }
                window.displayIfNeeded()
            }
            list.tableView.endScrollHoverSuspension()
            clip.scroll(to: .zero)
            list.scrollView.reflectScrolledClipView(clip)
            window.displayIfNeeded()
        }
        scrollThrough(hovering: false)
        Support.spin(for: 0.5)
        scrollThrough(hovering: false)
        let missesBefore = ConversationCellView.faceMisses
        scrollThrough(hovering: true)
        XCTAssertEqual(ConversationCellView.faceMisses, missesBefore, "hovering during a scroll missed the face cache")
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
        print("SS_PERF list \(label): \(String(format: "%.2f", value)) ms")
    }
}
