import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// The calendar's budgets in the main window (docs/ARCHITECTURE.md, Performance budgets; spec §5.54): W to the week on
/// screen in 50 ms with 300 events in it, and J and K with the day column following the selection inside the 16 ms of
/// moving it. The conversation's context is read off the main thread, so the column follows one hop after the list; what
/// the calendar adds to a step on the main thread (the selection handed over, the context landing, the column turning,
/// refitting and drawing, measured as the main thread's CPU time) is added to the key's own work (the list's move and the
/// reader's part of it) for the budget. The whole window, over its SQLite store holding the benchmarks' mailbox
/// (`PerfMailboxSupport`, 300,000 messages), with a few thousand events around the shown weeks. Gated, as the list's
/// benchmark is; every build prints what it measured, and the budgets are asserted in release builds:
///
///     PAPER_PERF=1 swift test -c release --filter MainWindowCalendarPerformanceTests
@MainActor
final class MainWindowCalendarPerformanceTests: XCTestCase {
    private typealias Support = CalendarTestSupport

    func testTheWeekAndTheColumnFollowingTheSelectionStayWithinBudget() throws {
        guard ProcessInfo.processInfo.environment["PAPER_PERF"] == "1" else {
            throw XCTSkip("set PAPER_PERF=1 to run the main window's calendar benchmark")
        }
        let clock = Support.Clock()
        let harness = try MainWindowHarness(calendar: Support.calendar, now: { clock.now }, perfMailbox: true)
        print("PAPER_PERF main window calendar mailbox: \(PerfMailboxSupport.label)")
        defer { harness.close() }
        let controller = harness.controller
        let store = harness.environment.store
        controller.splitView.layoutSubtreeIfNeeded()

        // 300 events in the week of the 19th and about 3,000 more in the months around it.
        var seed: UInt64 = 11
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        var events: [CalendarEvent] = []
        func add(_ count: Int, from first: Date, days: Int, prefix: String) {
            for index in 0..<count {
                let day = Support.calendar.date(byAdding: .day, value: next(days), to: first)!
                let start = Support.at(7 + next(13), [0, 15, 30, 45][next(4)], on: day)
                events.append(Support.event("\(prefix)-\(index)", account: index % 2 == 0 ? Support.accountA : Support.accountB,
                                            title: "Meeting \(index)", start: start,
                                            end: start.addingTimeInterval(Double(15 * (1 + next(8))) * 60),
                                            response: [.accepted, .organizer, .tentative, .needsAction][next(4)],
                                            location: index % 3 == 0 ? "Room \(index % 7)" : nil))
            }
        }
        add(300, from: Support.day(16), days: 7, prefix: "week")
        add(3_000, from: Support.day(1, month: 9), days: 120, prefix: "history")
        let window = DateInterval(start: Support.day(1, month: 9), end: Support.day(31, month: 12))
        for account in [Support.accountA, Support.accountB] {
            try store.replaceCalendarEvents(events.filter { $0.accountID == account.id }, accountID: account.id, window: window)
        }
        // Every other conversation is about a time: an invitation, or a time its mail names, on days around the 19th.
        let rows = harness.list.conversations
        for (index, row) in rows.enumerated() where index % 2 == 1 {
            guard let message = try store.messages(in: row.id).max(by: { $0.date < $1.date }) else { continue }
            let day = Support.day(17 + index % 9)
            if index % 4 == 1 {
                let account = row.id.accountID == Support.accountA.id ? Support.accountA : Support.accountB
                let invitation = CalendarInvitation(method: .request, uid: "perf-\(index)", title: "Invite \(index)",
                                                    start: Support.at(10, on: day), end: Support.at(11, on: day),
                                                    organizer: .init(address: "o@example.com"), userAddress: account.email,
                                                    userResponse: .needsAction)
                try store.saveBody(StoredBody(body: MessageBody(html: nil, text: ""), renderedHTML: "", plainText: "",
                                              invitation: invitation), for: message.id)
            } else {
                try store.saveMailTimes([MailTime(messageID: message.id, start: Support.at(15, on: day), phrase: "3pm")], for: message.id)
            }
        }

        let desk = controller.desk
        let state = controller.calendarState
        // The writes reach the state's observation on the main queue.
        harness.spin { state.events.count >= 300 }
        let week = desk.week
        let column = desk.column
        let weekBitmap = { try XCTUnwrap(week.bitmapImageRepForCachingDisplay(in: week.bounds)) }
        let columnBitmap = try XCTUnwrap(column.bitmapImageRepForCachingDisplay(in: column.bounds))

        // W: from the column on a day whose week is out of the observed range (a store read) to the week drawn.
        var opens: [Double] = []
        for round in 0..<12 {
            controller.selectDay(round % 2 == 0 ? Support.today : Support.day(10, month: 9))
            column.displayIfNeeded()
            let start = DispatchTime.now()
            XCTAssertTrue(controller.perform(.toggleWeek))
            week.layoutSubtreeIfNeeded()
            let bitmap = try weekBitmap()
            week.cacheDisplay(in: week.bounds, to: bitmap)
            opens.append(milliseconds(since: start))
            if round == 0 { XCTAssertGreaterThan(week.timeline.placed.count, 150, "the week lays its events out") }
            XCTAssertTrue(controller.perform(.toggleWeek))
        }

        // J and K: the list moves, the calendar reads the conversation's context off the main thread, the column follows.
        controller.selectDay(Support.today)
        harness.selectFirst(1)
        var follows: [Double] = []
        var keys: [Double] = []
        for step in 0..<36 {
            let forward = (step / 12) % 2 == 0
            let start = DispatchTime.now()
            XCTAssertTrue(controller.perform(forward ? .next : .previous))
            keys.append(milliseconds(since: start))
            let target = harness.list.selectedConversationID
            spin(until: { state.selection?.conversationID == target })
            column.cacheDisplay(in: column.bounds, to: columnBitmap)
            follows.append(milliseconds(since: start))
        }
        // The calendar's own share of a step, without the reader's: the selection handed to the state, its context landing,
        // the column turning to its day, refitting and drawing, as main-thread CPU time.
        var shares: [Double] = []
        for step in 0..<36 {
            let id = rows[(step % 12) + 1].id
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            state.select(id)
            spin(until: { state.selection?.conversationID == id })
            column.cacheDisplay(in: column.bounds, to: columnBitmap)
            shares.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1_000_000)
            state.select(nil)
        }

        // B and its undo: the block stored, toasted and drawn; the removal stored and drawn.
        var blocks: [Double] = []
        var removals: [Double] = []
        let plain = rows[0].id
        state.select(plain)
        spin(until: { state.selection?.conversationID == plain })
        harness.list.selectedConversationID = plain
        // Each measured to the column drawn with the change, which the store's observation hands over on the main queue.
        let isSetAside = { state.events.contains { $0.sync == .creating } }
        for _ in 0..<12 {
            let start = DispatchTime.now()
            XCTAssertTrue(controller.perform(.blockTime))
            spin(until: isSetAside)
            column.cacheDisplay(in: column.bounds, to: columnBitmap)
            blocks.append(milliseconds(since: start))
            let removing = DispatchTime.now()
            XCTAssertTrue(controller.perform(.undo))
            spin(until: { !isSetAside() })
            column.cacheDisplay(in: column.bounds, to: columnBitmap)
            removals.append(milliseconds(since: removing))
        }

        let open = percentile(Array(opens.dropFirst(2)), 0.95)
        let block = percentile(Array(blocks.dropFirst(2)), 0.95)
        let removal = percentile(Array(removals.dropFirst(2)), 0.95)
        let follow = percentile(Array(follows.dropFirst(2)), 0.95)
        let key = percentile(Array(keys.dropFirst(2)), 0.95)
        let share = percentile(Array(shares.dropFirst(2)), 0.95)
        print("MainWindowCalendarPerformance: W to the week drawn p95 \(format(open)) ms; J/K: the key p95 \(format(key)) ms "
              + "and the calendar's main-thread share p95 \(format(share)) ms (sum \(format(key + share)) ms); the column drawn "
              + "after a key, wall clock with the reader's work and the read off the main thread, p95 \(format(follow)) ms; "
              + "300 events in the week, \(events.count) stored; B to the block drawn p95 \(format(block)) ms, its undo "
              + "\(format(removal)) ms")
        #if !DEBUG
        XCTAssertLessThan(open, 50, "W budget")
        XCTAssertLessThan(key + share, 16, "J/K budget")
        XCTAssertLessThan(block, 16, "B budget")
        XCTAssertLessThan(removal, 16, "undo of B budget")
        #endif
    }

    /// A fine-grained spin, so the wait for the reading queue is measured rather than the test's polling.
    private func spin(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.0005))
        }
    }

    private func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    private func format(_ value: Double) -> String { String(format: "%.2f", value) }
}
