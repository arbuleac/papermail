import AppKit
import SSCore
import WebKit
import XCTest
@testable import SuperSparrowApp

/// The rows of the budgets in docs/ARCHITECTURE.md that the main window answers and no other benchmark measured before
/// roadmap Q4.3, on the benchmarks' mailbox (`PerfMailboxSupport`: 300,000 messages, every body stored; Keep mail by
/// `SS_PERF_RETENTION`): launch to a usable inbox (500 ms), a conversation opened pre-rendered (50 ms) and with its
/// bodies cached (100 ms), every local action from its key or its menu (16 ms), and ↩ to search the server (16 ms).
/// Loading the mailbox takes a while, so it only runs with `SS_PERF=1`:
///
///     SS_PERF=1 swift test -c release --filter MainWindowPerformanceTests
///
/// The windows stay off to the side of the screens, over throwaway stores; nothing reaches the network or the user's mail.
@MainActor
final class MainWindowPerformanceTests: XCTestCase {
    private typealias Support = ListTestSupport

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the main window benchmark")
        }
    }

    /// From opening the store file to the inbox's first page drawn: the database opened (its migrations checked), the
    /// engine and the window built, the list's first read and its rows drawn. What comes before (the process, AppKit and
    /// the menu bar) does not grow with the mailbox, and the engine's start, which the app makes after, reads nothing on
    /// the main thread. Each launch opens its own copy of the file, so the first read of every page comes from the disk.
    func testLaunchToAUsableInboxStaysWithinBudget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MainWindowLaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = folder.appendingPathComponent("template.sqlite")
        try PerfMailboxSupport.install(at: template.path)
        print("SS_PERF launch mailbox: \(PerfMailboxSupport.label)")

        var launches: [Double] = []
        for run in 0..<7 {
            let directory = folder.appendingPathComponent("launch-\(run)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: template, to: directory.appendingPathComponent("scratch.sqlite"))
            let settings = Support.settings()
            let start = DispatchTime.now()
            let environment = try AppEnvironment.makeScratch(in: directory)
            let controller = MainWindowController(environment: environment, settings: settings, remembersScope: false)
            let window = try XCTUnwrap(controller.window)
            window.setFrameAutosaveName("")
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.setContentSize(NSSize(width: 1_280, height: 800))
            spin(until: { !controller.list.conversations.isEmpty }, timeout: 10)
            window.displayIfNeeded()
            launches.append(milliseconds(since: start))
            XCTAssertEqual(controller.list.conversations.count, 200, "the inbox's first page")
            controller.tearDown()
            controller.close()
            var finished = false
            Task { @MainActor in
                await environment.shutdown()
                finished = true
            }
            spin(until: { finished }, timeout: 10)
        }
        report("launch to the inbox drawn, first", launches[0])
        report("launch to the inbox drawn, median", percentile(launches, 0.5))
        report("launch to the inbox drawn, max", launches.max() ?? 0)
        XCTAssertLessThan(percentile(launches, 0.5), 500, "launch budget")
    }

    /// J onto a conversation the reader pre-rendered, as it pre-renders the neighbours of the one open once the selection
    /// rests: the key to the conversation on screen. Then a conversation further down chosen as a click chooses it, its
    /// bodies stored but nothing rendered: the click to the render landed.
    func testOpeningAConversationStaysWithinBudget() throws {
        let harness = try MainWindowHarness(perfMailbox: true)
        defer { harness.close() }
        print("SS_PERF open mailbox: \(PerfMailboxSupport.label)")
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1_280, height: 800))
        window.layoutIfNeeded()
        // Reading in the main window, so WebKit is loaded, as it is whenever a conversation is opened after the first.
        harness.controller.window?.orderFrontRegardless()
        let reader = harness.reader
        let rows = harness.list.conversations
        harness.list.selectedConversationID = rows[0].id
        harness.list.onSelectionChange?(rows[0].id)
        XCTAssertTrue(waitForRender(reader, timeout: 15))

        var prerendered: [Double] = []
        var skipped = 0
        for _ in 0..<12 {
            let current = try XCTUnwrap(harness.list.selectedConversationID)
            let next = try XCTUnwrap(harness.list.neighbors(of: current).next)
            // The selection rests and the neighbours render into the pool.
            spin(until: { reader.pool.slot(rendering: next).map { !$0.renderInFlight } ?? false }, timeout: 5)
            spin(for: 0.1)
            guard reader.pool.slot(rendering: next) != nil else {
                // Not pre-rendered this time (the pool gave its slot to another neighbour): J would be a render, not
                // this row's case, so it moves on unmeasured.
                skipped += 1
                XCTAssertTrue(harness.controller.perform(.next))
                XCTAssertTrue(waitForRender(reader, timeout: 5))
                continue
            }
            let start = DispatchTime.now()
            XCTAssertTrue(harness.controller.perform(.next))
            XCTAssertEqual(harness.list.selectedConversationID, next)
            XCTAssertTrue(waitForRender(reader, timeout: 5))
            window.displayIfNeeded()
            prerendered.append(milliseconds(since: start))
        }

        var cached: [Double] = []
        for index in stride(from: 40, to: 160, by: 10) {
            let id = rows[index].id
            spin(for: 0.3)
            XCTAssertNil(reader.pool.slot(rendering: id), "not pre-rendered")
            let start = DispatchTime.now()
            harness.list.selectedConversationID = id
            harness.list.onSelectionChange?(id)
            XCTAssertTrue(waitForRender(reader, timeout: 5))
            window.displayIfNeeded()
            cached.append(milliseconds(since: start))
        }
        XCTAssertLessThanOrEqual(skipped, 3, "most neighbours are pre-rendered")
        report("open pre-rendered (J), \(prerendered.count) of 12, median", percentile(prerendered, 0.5))
        report("open pre-rendered (J), max", prerendered.max() ?? 0)
        report("open with its bodies cached, median", percentile(cached, 0.5))
        report("open with its bodies cached, max", cached.max() ?? 0)
        XCTAssertLessThan(percentile(prerendered, 0.5), 50, "open conversation, pre-rendered")
        XCTAssertLessThan(percentile(cached, 0.5), 100, "open conversation, body cached")
    }

    /// Each local action of the budget row from its key or its menu item, on the conversation open: the store written
    /// and queued in one transaction, the toast and the window drawn. Seven times each, on seven conversations.
    func testEveryLocalActionStaysWithinBudget() throws {
        let harness = try MainWindowHarness(perfMailbox: true)
        defer { harness.close() }
        print("SS_PERF actions mailbox: \(PerfMailboxSupport.label)")
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1_280, height: 800))
        window.layoutIfNeeded()
        let store = harness.environment.store
        // Newsletters to unsubscribe from: a one-click request, queued with the archive.
        let account = Support.accountA
        for issue in 0..<8 {
            let conversation = ConversationID(accountID: account.id, providerID: "news-\(issue)")
            try store.upsertMessages([MessageMetadata(
                id: MessageID(accountID: account.id, providerID: "news-\(issue)-1"), conversationID: conversation,
                subject: "Frontend Weekly #\(issue)", snippet: "This week", from: EmailAddress(name: "Frontend Weekly", address: "hello@news\(issue).test"),
                to: [EmailAddress(name: account.displayName, address: account.email)], date: Date().addingTimeInterval(Double(issue)),
                roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false,
                listUnsubscribe: "<https://news\(issue).test/u/42>", listUnsubscribePost: "List-Unsubscribe=One-Click"
            )])
        }

        func open(_ index: Int) {
            spin(until: { harness.list.conversations.count > index }, timeout: 5)
            let id = harness.list.conversations[index].id
            harness.list.selectedConversationID = id
            harness.list.onSelectionChange?(id)
            spin(until: { harness.reader.currentConversationID == id && !harness.reader.currentMessages.isEmpty }, timeout: 5)
            spin(for: 0.2)
        }
        func measure(_ label: String, opening index: (Int) -> Int, runs: Int = 7, _ action: () -> Void) -> Double {
            var timings: [Double] = []
            for run in 0..<runs {
                open(index(run))
                let start = DispatchTime.now()
                action()
                window.displayIfNeeded()
                timings.append(milliseconds(since: start))
            }
            report("\(label), median", percentile(timings, 0.5))
            report("\(label), max", timings.max() ?? 0)
            return percentile(timings, 0.5)
        }

        var medians: [String: Double] = [:]
        medians["unsubscribe"] = measure("unsubscribe, one-click (⇧⌘U)", opening: { _ in 0 }) {
            harness.controller.unsubscribeFromConversation(nil)
        }
        medians["archive"] = measure("archive (E)", opening: { _ in 0 }) { XCTAssertTrue(harness.controller.perform(.archive)) }
        medians["star"] = measure("star (S)", opening: { _ in 1 }) { XCTAssertTrue(harness.controller.perform(.toggleStar)) }
        medians["read"] = measure("mark read or unread (⇧U)", opening: { _ in 2 }) { XCTAssertTrue(harness.controller.perform(.toggleRead)) }
        medians["spam"] = measure("mark as spam (!)", opening: { _ in 0 }) { XCTAssertTrue(harness.controller.perform(.markSpam)) }
        medians["mute"] = measure("mute (M)", opening: { _ in 0 }) { XCTAssertTrue(harness.controller.perform(.toggleMute)) }
        medians["snooze"] = measure("snooze until tomorrow (L, a preset)", opening: { _ in 0 }) {
            guard let id = harness.list.selectedConversationID else { return XCTFail("nothing selected") }
            harness.controller.snooze([id], until: Date().addingTimeInterval(86_400))
        }
        // A conversation whose sender has no rule yet, each time: a later row for each run.
        let rulesBefore = try store.senderRules().count
        medians["block"] = measure("block sender (context menu)", opening: { run in 10 + run * 3 }) { harness.controller.blockSender(nil) }
        XCTAssertEqual(try store.senderRules().count, rulesBefore + 7, "each run blocked a sender")
        for (label, median) in medians {
            XCTAssertLessThan(median, 16, "local action budget: \(label)")
        }
    }

    /// ↩ in the search field once every local result is listed: the row reading “Searching Gmail…” drawn. The search
    /// itself is the engine's, off the main thread; here it never answers.
    func testSearchingTheServerStaysWithinBudget() throws {
        let harness = try MainWindowHarness(perfMailbox: true)
        defer { harness.close() }
        print("SS_PERF server search mailbox: \(PerfMailboxSupport.label)")
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1_280, height: 800))
        window.layoutIfNeeded()
        let list = harness.list
        let pane = harness.controller.listPane
        list.serverSearch.search = { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return ServerSearchResult()
        }
        var timings: [Double] = []
        // Thread numbers: each word is in the subjects of a few dozen threads, so the local results end on the first page.
        for (run, words) in ["update 777", "update 1234", "update 4321", "update 2468", "update 1357", "update 9876", "update 5555"].enumerated() {
            pane.header.search.query = words
            pane.header.search.onQueryChange?(words)
            pane.sendPendingSearch()
            spin(until: { list.query.searchText == words && list.hasReceivedFirstPage && list.serverSearchRow?.phase == .offer }, timeout: 10)
            XCTAssertEqual(list.serverSearchRow?.phase, .offer, "run \(run): the offer ends the results")
            window.displayIfNeeded()
            let start = DispatchTime.now()
            harness.controller.searchServer(nil)
            window.displayIfNeeded()
            timings.append(milliseconds(since: start))
            XCTAssertEqual(list.serverSearchRow?.phase, .searching, "run \(run)")
        }
        report("↩ to search the server, the row drawn, median", percentile(timings, 0.5))
        report("↩ to search the server, the row drawn, max", timings.max() ?? 0)
        XCTAssertLessThan(percentile(timings, 0.5), 16, "search the server budget")
    }

    // MARK: Support

    private func waitForRender(_ reader: ConversationViewController, timeout: TimeInterval) -> Bool {
        var landed = false
        var finished = false
        reader.whenShownRenderLands(timeout: timeout) { webView in
            landed = webView != nil
            finished = true
        }
        spin(until: { finished }, timeout: timeout + 1)
        return landed
    }

    /// A fine-grained spin, so a wait for the main queue is measured rather than the test's polling.
    private func spin(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.0005))
        }
    }

    private func spin(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
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
        print("SS_PERF main window \(label): \(String(format: "%.2f", value)) ms")
    }
}
