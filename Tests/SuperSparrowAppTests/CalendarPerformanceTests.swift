import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The calendar's budgets (docs/ARCHITECTURE.md; spec §5.54): D or W to the calendar on screen in 50 ms (the store's
/// read of the range and the fit of up to 300 events), and the column following J and K inside the list's 16 ms. On a
/// real SQLite file holding the benchmarks' mailbox, with 300 events in the shown week and a year of history around it. Gated, as the list's benchmark
/// is; the budgets are asserted in release builds, and every build prints what it measured:
///
///     SS_PERF=1 swift test -c release --filter CalendarPerformanceTests
@MainActor
final class CalendarPerformanceTests: XCTestCase {
    private typealias Support = CalendarTestSupport

    func testOpeningTheCalendarAndFollowingTheSelectionStayWithinBudget() throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the calendar benchmark")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalendarPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The calendar beside the benchmarks' mailbox (`PerfMailboxSupport`, 300,000 messages), as it is stored.
        let path = directory.appendingPathComponent("mail.sqlite").path
        try PerfMailboxSupport.install(at: path)
        let store = try SQLiteMailStore(path: path)
        print("SS_PERF calendar mailbox: \(PerfMailboxSupport.label)")

        // 300 events in the week of the 19th, and about 4,000 more across the months around it.
        var events: [CalendarEvent] = []
        var seed: UInt64 = 7
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        func add(_ count: Int, from first: Date, days: Int, prefix: String) {
            for index in 0..<count {
                let day = Support.calendar.date(byAdding: .day, value: next(days), to: first)!
                let start = Support.at(7 + next(13), [0, 15, 30, 45][next(4)], on: day)
                let account = index % 2 == 0 ? Support.accountA : Support.accountB
                let response: CalendarEvent.Response = [.accepted, .accepted, .organizer, .tentative, .needsAction, .declined][next(6)]
                events.append(Support.event("\(prefix)-\(index)", account: account, title: "Meeting \(prefix) \(index)", start: start,
                                            end: start.addingTimeInterval(Double(15 * (1 + next(8))) * 60), response: response,
                                            joinURL: index % 5 == 0 ? "https://meet.google.com/x-\(index)" : nil,
                                            location: index % 3 == 0 ? "Room \(index % 7)" : nil))
            }
        }
        add(300, from: Support.day(16), days: 7, prefix: "week")
        add(4_000, from: Support.day(1, month: 9), days: 120, prefix: "history")
        let window = DateInterval(start: Support.day(1, month: 9), end: Support.day(31, month: 12))
        for account in [Support.accountA, Support.accountB] {
            try store.replaceCalendarEvents(events.filter { $0.accountID == account.id }, accountID: account.id, window: window)
        }

        // Conversations to select: half carry an invitation today and a time they name.
        var conversations: [ConversationID] = []
        for index in 0..<20 {
            let conversation = ConversationID(accountID: Support.accountA.id, providerID: "perf-thread-\(index)")
            conversations.append(conversation)
            let message = MessageID(accountID: Support.accountA.id, providerID: "perf-msg-\(index)")
            try store.upsertMessages([MessageMetadata(id: message, conversationID: conversation, subject: "Perf \(index)", snippet: "",
                                                      from: nil, date: Support.at(8), roles: [.inbox], isRead: true, isStarred: false,
                                                      hasAttachments: false)])
            guard index % 2 == 0 else { continue }
            let invitation = CalendarInvitation(method: .request, uid: "perf-\(index)", title: "Invite \(index)",
                                                start: Support.at(10 + index % 6), end: Support.at(11 + index % 6),
                                                organizer: .init(address: "o@example.com"), userAddress: Support.accountA.email,
                                                userResponse: .needsAction)
            try store.saveBody(StoredBody(body: MessageBody(html: "<p>x</p>", text: "x"), renderedHTML: "<p>x</p>", plainText: "x",
                                          invitation: invitation), for: message)
            try store.saveMailTimes([MailTime(messageID: message, start: Support.at(16), phrase: "4pm")], for: message)
        }

        let state = Support.state(store: store)
        defer { state.tearDown() }
        let column = DayColumnView(state: state)
        let columnWindow = Support.host(column, size: NSSize(width: Quire.Layout.CalendarPane.columnWidth, height: 800))
        defer { columnWindow.close() }
        let week = WeekView(state: state)
        let weekWindow = Support.host(week, size: NSSize(width: 1_064, height: 800))
        defer { weekWindow.close() }
        // Every measured step ends with the whole view drawn, synchronously: an upper bound on the frame it costs.
        let columnBitmap = try XCTUnwrap(column.bitmapImageRepForCachingDisplay(in: column.bounds))
        let weekBitmap = try XCTUnwrap(week.bitmapImageRepForCachingDisplay(in: week.bounds))

        // W: the span moves to a week out of the observed range (a store read), the week refits and draws.
        var opens: [Double] = []
        for round in 0..<12 {
            state.span = .day
            state.shownDay = Support.today
            columnWindow.displayIfNeeded()
            let start = DispatchTime.now()
            state.shownWeek = round % 2 == 0 ? Support.today : Support.day(10, month: 9)
            state.span = .week
            week.layoutSubtreeIfNeeded()
            draw(week, into: weekBitmap)
            opens.append(milliseconds(since: start))
            if round == 0 { XCTAssertGreaterThan(week.timeline.placed.count, 150, "the week lays out its events (not declined, not behind +N)") }
            state.shownWeek = Support.day(10, month: 9)
        }
        // D: the column back on a day out of the range.
        var columns: [Double] = []
        for round in 0..<12 {
            state.span = .day
            state.shownDay = Support.day(10, month: 9)
            columnWindow.displayIfNeeded()
            let start = DispatchTime.now()
            state.shownDay = round % 2 == 0 ? Support.today : Support.day(20)
            column.layoutSubtreeIfNeeded()
            draw(column, into: columnBitmap)
            columns.append(milliseconds(since: start))
        }

        // J and K: the selection moves; its context lands from the reader queue and the column follows.
        state.span = .day
        state.shownDay = Support.today
        var follows: [Double] = []
        for (index, conversation) in (conversations + conversations).enumerated() {
            let start = DispatchTime.now()
            state.select(conversation)
            // A fine-grained spin, so the wait for the reader queue is measured rather than the test's polling.
            let deadline = Date().addingTimeInterval(2)
            while state.selection?.conversationID != conversation, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.0005))
            }
            draw(column, into: columnBitmap)
            follows.append(milliseconds(since: start))
            if index % 2 == 0 { XCTAssertNotNil(state.selection?.invitation) }
        }

        let open = percentile(Array(opens.dropFirst(2)), 0.95)
        let day = percentile(Array(columns.dropFirst(2)), 0.95)
        let follow = percentile(Array(follows.dropFirst(2)), 0.95)
        print("CalendarPerformance: W to the week drawn p95 \(format(open)) ms; D to the column drawn p95 \(format(day)) ms; "
              + "J/K followed p95 \(format(follow)) ms (300 events in the week, \(events.count) stored)")
        #if !DEBUG
        XCTAssertLessThan(open, 50, "W budget")
        XCTAssertLessThan(day, 50, "D budget")
        XCTAssertLessThan(follow, 16, "J/K budget")
        #endif
    }

    private func draw(_ view: NSView, into bitmap: NSBitmapImageRep) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
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
