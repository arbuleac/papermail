import AppKit
import SSCore
import WebKit
import XCTest
@testable import SuperSparrowApp

/// The reader-window row of the budgets in docs/ARCHITECTURE.md (spec §5.49): ⌘O on a conversation whose bodies are
/// cached puts the window up with its header within 50 ms, and the conversation rendered in it within 200 ms, its own
/// WebContent process starting with it and loading the shell first; the main window's reader has rendered a conversation
/// before, as it has whenever ⌘O is pressed. Each window is a new process, so it only runs with `SS_PERF=1`:
///
///     SS_PERF=1 swift test -c release --filter ReaderWindowPerformanceTests
///
/// The windows open off to the side of the screens, over a throwaway store; nothing reaches the network or the user's mail.
@MainActor
final class ReaderWindowPerformanceTests: XCTestCase {
    private static let windows = 10

    func testOpeningAReaderWindowStaysWithinBudget() throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the reader-window benchmark")
        }
        UserDefaults.standard.removeObject(forKey: "ReaderWindowSize")
        let harness = try MainWindowHarness(threads: Self.windows + 2)
        defer { harness.close() }
        let store = harness.environment.store
        let all = harness.list.conversations.prefix(Self.windows + 1).map(\.id)
        let ids = Array(all.dropFirst())
        XCTAssertEqual(ids.count, Self.windows)
        // Body cached: every message's body is in the store, render-ready, as sync leaves it.
        for id in all {
            for message in try store.messages(in: id) {
                let html = "<p>Just following up on the thread from last week.</p><p>Let me know if Tuesday works for the review; "
                    + "the planning document is attached, with the numbers from the quarter.</p>"
                try store.saveBody(StoredBody(body: MessageBody(html: html, text: "Just following up."), renderedHTML: html,
                                              plainText: "Just following up."), for: message.id)
            }
        }
        // Put up as the app puts them up, ordered in (off to the side, where the harness keeps its windows), not made key.
        harness.controller.bringForward = { $0.window?.orderFrontRegardless() }
        // ⌘O comes after reading in the main window: its reader has rendered a conversation, so WebKit is loaded.
        harness.controller.window?.orderFrontRegardless()
        harness.list.selectedConversationID = all[0]
        harness.list.onSelectionChange?(all[0])
        var warm = false
        harness.reader.whenShownRenderLands(timeout: 10) { _ in warm = true }
        XCTAssertTrue(ListTestSupport.spin(until: { warm }, timeout: 12))
        // ⌘O comes a moment after the reading, the main thread idle, as it is before every later window here. Opened
        // straight after the render, while the core it ran on was still at speed, the first window cost about a quarter less
        // CPU than any other and stood for none of them.
        ListTestSupport.spin(for: 0.2)

        var shown: [Double] = []
        var rendered: [Double] = []
        for id in ids {
            // The app opens and closes a window inside an event, whose autorelease pool drains after it. Without one of
            // its own, each window, its reader, its web view and its WebContent process stayed alive to the end of the
            // test, ten of each by the last window.
            try autoreleasepool {
                let start = DispatchTime.now()
                let reader = try XCTUnwrap(harness.controller.openInNewWindow(id))
                let window = try XCTUnwrap(reader.window)
                window.displayIfNeeded()
                shown.append(milliseconds(since: start))
                XCTAssertNotNil(reader.conversation.header.content.headline, "the header names the conversation")

                var landed: Double?
                var finished = false
                reader.conversation.whenShownRenderLands(timeout: 10) { webView in
                    if webView != nil { landed = self.milliseconds(since: start) }
                    finished = true
                }
                XCTAssertTrue(ListTestSupport.spin(until: { finished }, timeout: 12))
                rendered.append(try XCTUnwrap(landed, "the conversation rendered in its window"))
                reader.close()
                window.orderOut(nil)
            }
            // The window's WebContent process goes with it; the next one starts afresh.
            ListTestSupport.spin(for: 0.2)
        }

        report("window up with its header, first", shown[0])
        report("window up with its header, median", percentile(shown, 0.5))
        report("window up with its header, max", shown.max() ?? 0)
        report("conversation rendered in it, first", rendered[0])
        report("conversation rendered in it, median", percentile(rendered, 0.5))
        report("conversation rendered in it, max", rendered.max() ?? 0)
        XCTAssertLessThan(percentile(shown, 0.5), 50, "reader window budget: up with its header")
        XCTAssertLessThan(percentile(rendered, 0.5), 200, "reader window budget: rendered")
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
        print("SS_PERF reader window \(label): \(String(format: "%.2f", value)) ms")
    }
}
