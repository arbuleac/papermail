import XCTest
import PaperCore

/// The calendar's rows of the budgets in docs/ARCHITECTURE.md, in a real file holding five accounts' calendars for the
/// whole window (CalendarWindow.around) and a year of history before it: a read of an account's calendar writes its 500
/// events within 50 ms (the first time, which also prunes the account's history to 30 days behind the window, again
/// unchanged two minutes later, and with a few changed), and the day column's or the week's read of seven days, about 250
/// events, takes under 5 ms. The file holds the synthetic mailbox too (`PerfMailbox`, 300,000 messages), and the reads
/// and an unchanged write are measured again after a sweep to Keep mail at 1 year. Only with `PAPER_PERF=1`:
///
///     PAPER_PERF=1 swift test --filter CalendarStorePerformanceTests
final class CalendarStorePerformanceTests: XCTestCase {
    private static let accountCount = 5
    private static let eventsPerRead = 500

    func testAReadOf500EventsAndAWeekOnScreenStayWithinBudget() throws {
        guard ProcessInfo.processInfo.environment["PAPER_PERF"] == "1" else {
            throw XCTSkip("set PAPER_PERF=1 to run the calendar store benchmark")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalendarStorePerformanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        defer { try? store.close() }
        let mailbox = PerfMailbox.make()
        _ = try PerfMailbox.load(mailbox, into: store)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let now = Date(timeIntervalSince1970: 1_795_600_000) // a Thursday in November 2026
        let window = CalendarWindow.around(now, calendar: calendar)
        let history = DateInterval(start: window.start.addingTimeInterval(-365 * 86_400), end: window.start)
        let accounts = (0..<Self.accountCount).map { AccountID("acct-\($0)") }
        for (index, id) in accounts.enumerated() {
            try store.upsertAccount(Account(id: id, kind: index.isMultiple(of: 2) ? .gmail : .microsoft, email: "owner\(index)@example.com",
                                            displayName: "Owner", addedAt: now, inkSlot: index))
            try store.replaceCalendarEvents(events(for: id, in: history, count: 2_500), accountID: id, window: history)
            if index > 0 {
                try store.replaceCalendarEvents(events(for: id, in: window, count: Self.eventsPerRead), accountID: id, window: window)
            }
        }

        let read = events(for: accounts[0], in: window, count: Self.eventsPerRead)
        let first = try measure { try store.replaceCalendarEvents(read, accountID: accounts[0], window: window) }
        report("the first read of an account's calendar: 500 events written", first)
        XCTAssertLessThan(first, 50, "calendar budget: a read's store write of 500 events")

        let unchanged = try median(runs: 9) { try store.replaceCalendarEvents(read, accountID: accounts[0], window: window) }
        report("the next read, nothing changed", unchanged.milliseconds)
        XCTAssertLessThan(unchanged.milliseconds, 50, "calendar budget: a read's store write of 500 events")

        // Every other read moves 40 events, renames 40, drops 10 and adds 10, and the next puts them back.
        var changed = read
        for index in stride(from: 0, to: 400, by: 10) { changed[index].start += 1_800; changed[index].end += 1_800 }
        for index in stride(from: 5, to: 405, by: 10) { changed[index].title += " (moved)" }
        changed.removeLast(10)
        changed += events(for: accounts[0], in: window, count: 10, prefix: "new")
        var flip = false
        let churn = try median(runs: 9) {
            flip.toggle()
            try store.replaceCalendarEvents(flip ? changed : read, accountID: accounts[0], window: window)
        }
        report("a read with 100 events changed, removed or added", churn.milliseconds)
        XCTAssertLessThan(churn.milliseconds, 50, "calendar budget: a read's store write of 500 events")

        let week = DateInterval(start: calendar.startOfDay(for: now), duration: 7 * 86_400)
        let all = try median(runs: 15) { try store.calendarEvents(in: week, accountIDs: nil) }
        report("seven days of every account (\(all.value.count) events)", all.milliseconds)
        XCTAssertGreaterThan(all.value.count, 200)
        XCTAssertLessThan(all.milliseconds, 5, "the calendar's share of D or W to the calendar on screen")

        let one = try median(runs: 15) { try store.calendarEvents(in: week, accountIDs: [accounts[0]]) }
        report("seven days of one account (\(one.value.count) events)", one.milliseconds)
        XCTAssertLessThan(one.milliseconds, 5, "the calendar's share of D or W to the calendar on screen")

        let day = DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        let today = try median(runs: 15) { try store.calendarEvents(in: day, accountIDs: nil) }
        report("today, every account (\(today.value.count) events)", today.milliseconds)
        XCTAssertLessThan(today.milliseconds, 5)

        // Keep mail at 1 year: the sweep leaves the calendar alone, and the file it leaves serves the same reads.
        _ = try PerfMailbox.sweep(store, to: PerfMailbox.oneYearCutoff(mailbox))
        let unchangedAfter = try median(runs: 9) { try store.replaceCalendarEvents(read, accountID: accounts[0], window: window) }
        report("1 year: the next read, nothing changed", unchangedAfter.milliseconds)
        XCTAssertLessThan(unchangedAfter.milliseconds, 50, "calendar budget: a read's store write of 500 events")
        let allAfter = try median(runs: 15) { try store.calendarEvents(in: week, accountIDs: nil) }
        report("1 year: seven days of every account (\(allAfter.value.count) events)", allAfter.milliseconds)
        XCTAssertLessThan(allAfter.milliseconds, 5, "the calendar's share of D or W to the calendar on screen")
    }

    // MARK: Fixtures

    /// `count` events of the account spread over `interval`, half an hour to an hour and a half each between 08:00 and
    /// 19:00 UTC, with what a real read carries: links, an invitation UID, now and then a place, an organizer, a call.
    private func events(for accountID: AccountID, in interval: DateInterval, count: Int, prefix: String = "evt") -> [CalendarEvent] {
        let days = max(1, Int(interval.duration / 86_400))
        return (0..<count).map { index in
            let day = interval.start.addingTimeInterval(Double(index % days) * 86_400)
            let start = day.addingTimeInterval(Double(8 * 3_600 + (index * 1_800) % (10 * 3_600)))
            let providerID = "\(prefix)-\(accountID.rawValue)-\(index)-7l8r0ks2q1j3h5g6f"
            return CalendarEvent(
                id: CalendarEvent.localID(accountID: accountID, providerID: providerID), accountID: accountID, providerID: providerID,
                title: "Project sync \(index)", location: index.isMultiple(of: 3) ? "Room \(index % 12), Level 2" : nil,
                start: start, end: start.addingTimeInterval(Double(1_800 * (1 + index % 3))),
                response: index.isMultiple(of: 7) ? .needsAction : .accepted,
                joinURL: index.isMultiple(of: 2) ? "https://meet.google.com/abc-defg-\(index)" : nil,
                webURL: "https://www.google.com/calendar/event?eid=\(providerID)ZXhhbXBsZUBleGFtcGxlLmNvbQ",
                organizer: index.isMultiple(of: 4) ? "Ben Carter" : nil, invitationUID: "\(providerID)@google.com",
                updatedAt: interval.start
            )
        }
    }

    // MARK: Timing

    private func measure(_ work: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now()
        try work()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private func median<T>(runs: Int, _ work: () throws -> T) throws -> (value: T, milliseconds: Double) {
        var last = try work()
        var timings: [Double] = []
        for _ in 0..<runs {
            timings.append(try measure { last = try work() })
        }
        return (last, timings.sorted()[runs / 2])
    }

    private func report(_ label: String, _ milliseconds: Double) {
        print("PAPER_PERF \(label): \(String(format: "%.1f", milliseconds)) ms")
    }
}
