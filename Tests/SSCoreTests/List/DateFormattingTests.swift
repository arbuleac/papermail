import XCTest
@testable import SSCore

final class DateFormattingTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC") ?? .current
    private let british = Locale(identifier: "en_GB")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = british
        return calendar
    }
    /// en_GB: 24-hour clock, day before month, weeks start on Monday.
    private lazy var formatting = DateFormatting(locale: british, calendar: calendar, timeZone: utc)
    /// Thursday 6 March 2025, 14:05 UTC.
    private lazy var now = date(2025, 3, 6, 14, 5)
    private lazy var reference = formatting.reference(now: now)

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: components) else {
            XCTFail("invalid components \(components)")
            return Date()
        }
        return date
    }

    // MARK: No heads (relative)

    func testTodayShowsTheTimeOfDay() {
        XCTAssertEqual(formatting.string(for: now, now: now), "14:05")
        XCTAssertEqual(formatting.string(for: date(2025, 3, 6, 9, 7), now: now), "09:07")
        XCTAssertEqual(formatting.string(for: date(2025, 3, 6, 0, 0), now: now), "00:00")
        XCTAssertEqual(formatting.string(for: date(2025, 3, 6, 23, 59), now: now), "23:59")
    }

    func testYesterdayIsAWord() {
        XCTAssertEqual(formatting.string(for: date(2025, 3, 5), now: now), "Yesterday")
        XCTAssertEqual(formatting.string(for: date(2025, 3, 5, 0, 0), now: now), "Yesterday")
        XCTAssertEqual(formatting.string(for: date(2025, 3, 5, 23, 59), now: now), "Yesterday")
    }

    func testWithinSixDaysShowsWeekday() {
        XCTAssertEqual(formatting.string(for: date(2025, 3, 4, 23, 59), now: now), "Tue")
        XCTAssertEqual(formatting.string(for: date(2025, 3, 2), now: now), "Sun")
        XCTAssertEqual(formatting.string(for: date(2025, 2, 28, 0, 0), now: now), "Fri")
    }

    func testSevenDaysAgoIsNoLongerThisWeek() {
        // The same weekday as today must not read as "Thu" or it would mean today.
        XCTAssertEqual(formatting.string(for: date(2025, 2, 27, 23, 59), now: now), "27 Feb")
    }

    func testSameYearShowsDayAndMonth() {
        XCTAssertEqual(formatting.string(for: date(2025, 1, 1, 0, 0), now: now), "1 Jan")
        XCTAssertEqual(formatting.string(for: date(2025, 2, 14), now: now), "14 Feb")
    }

    func testOtherYearsShowFullDate() {
        XCTAssertEqual(formatting.string(for: date(2024, 12, 31, 23, 59), now: now), "31 Dec 2024")
        XCTAssertEqual(formatting.string(for: date(2019, 7, 4), now: now), "4 Jul 2019")
    }

    func testFutureDatesFallBackToDateShapes() {
        XCTAssertEqual(formatting.string(for: date(2025, 3, 7, 0, 0), now: now), "7 Mar")
        XCTAssertEqual(formatting.string(for: date(2026, 3, 3), now: now), "3 Mar 2026")
    }

    // MARK: Under heads

    func testStylesUnderHeadsLeaveOutWhatTheHeadSays() {
        let lastTuesday = date(2025, 2, 25, 8, 30)
        XCTAssertEqual(formatting.string(for: date(2025, 3, 5, 23, 39), reference: reference, style: .timeOfDay), "23:39")
        XCTAssertEqual(formatting.string(for: date(2025, 3, 4), reference: reference, style: .weekday), "Tue")
        XCTAssertEqual(formatting.string(for: lastTuesday, reference: reference, style: .dayMonth), "25 Feb")
        // Day and month even in an earlier year: the year is in the head ("October 2024").
        XCTAssertEqual(formatting.string(for: date(2024, 10, 30), reference: reference, style: .dayMonth), "30 Oct")
    }

    func testTheLocaleDecidesTheClockAndTheDayOrder() {
        let american = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let us = DateFormatting(locale: american, calendar: calendar, timeZone: utc)
        XCTAssertEqual(us.string(for: date(2025, 3, 6, 14, 5), now: now).replacingOccurrences(of: "\u{202F}", with: " "), "2:05 PM")
        XCTAssertEqual(us.string(for: date(2025, 2, 14), now: now), "Feb 14")
        XCTAssertEqual(us.string(for: date(2019, 7, 4), now: now), "Jul 4, 2019")
    }

    // MARK: Running heads

    func testRunningHeadsByDay() {
        // Thursday 6 March; the en_GB week starts on Monday 3 March.
        XCTAssertEqual(formatting.runningHead(for: date(2025, 3, 6, 0, 1), reference: reference), .today)
        XCTAssertEqual(formatting.runningHead(for: date(2025, 3, 7), reference: reference), .today, "a future date sits under Today")
        XCTAssertEqual(formatting.runningHead(for: date(2025, 3, 5, 23, 59), reference: reference), .yesterday)
        XCTAssertEqual(formatting.runningHead(for: date(2025, 3, 4), reference: reference), .earlierThisWeek)
        XCTAssertEqual(formatting.runningHead(for: date(2025, 3, 3, 0, 0), reference: reference), .earlierThisWeek)
        XCTAssertEqual(formatting.runningHead(for: date(2025, 3, 2, 23, 59), reference: reference), .lastWeek)
        XCTAssertEqual(formatting.runningHead(for: date(2025, 2, 24, 0, 0), reference: reference), .lastWeek)
        XCTAssertEqual(formatting.runningHead(for: date(2025, 2, 23, 23, 59), reference: reference), .month(year: 2025, month: 2))
        XCTAssertEqual(formatting.runningHead(for: date(2024, 10, 9), reference: reference), .month(year: 2024, month: 10))
    }

    func testOnTheFirstDayOfTheWeekYesterdayWinsOverLastWeek() {
        // Monday 3 March: yesterday (Sunday) is in last week by the calendar but reads "Yesterday".
        let monday = formatting.reference(now: date(2025, 3, 3, 10, 0))
        XCTAssertEqual(formatting.runningHead(for: date(2025, 3, 2, 18, 0), reference: monday), .yesterday)
        XCTAssertEqual(formatting.runningHead(for: date(2025, 3, 1, 18, 0), reference: monday), .lastWeek)
        XCTAssertEqual(formatting.runningHead(for: date(2025, 2, 23, 18, 0), reference: monday), .month(year: 2025, month: 2))
    }

    func testHeadTitles() {
        XCTAssertEqual(formatting.title(for: .today, reference: reference), "Today")
        XCTAssertEqual(formatting.title(for: .yesterday, reference: reference), "Yesterday")
        XCTAssertEqual(formatting.title(for: .earlierThisWeek, reference: reference), "Earlier this week")
        XCTAssertEqual(formatting.title(for: .lastWeek, reference: reference), "Last week")
        XCTAssertEqual(formatting.title(for: .month(year: 2025, month: 2), reference: reference), "February")
        XCTAssertEqual(formatting.title(for: .month(year: 2024, month: 10), reference: reference), "October 2024")
    }

    func testHeadsSetTheirRowsTimeStyle() {
        XCTAssertEqual(RunningHead.today.timeStyle, .timeOfDay)
        XCTAssertEqual(RunningHead.yesterday.timeStyle, .timeOfDay)
        XCTAssertEqual(RunningHead.earlierThisWeek.timeStyle, .weekday)
        XCTAssertEqual(RunningHead.lastWeek.timeStyle, .dayMonth)
        XCTAssertEqual(RunningHead.month(year: 2024, month: 1).timeStyle, .dayMonth)
    }

    // MARK: Reference

    func testReferenceBoundaries() {
        XCTAssertEqual(reference.startOfToday, date(2025, 3, 6, 0, 0))
        XCTAssertEqual(reference.startOfTomorrow, date(2025, 3, 7, 0, 0))
        XCTAssertEqual(reference.startOfYesterday, date(2025, 3, 5, 0, 0))
        XCTAssertEqual(reference.startOfWeekWindow, date(2025, 2, 28, 0, 0))
        XCTAssertEqual(reference.startOfThisWeek, date(2025, 3, 3, 0, 0))
        XCTAssertEqual(reference.startOfLastWeek, date(2025, 2, 24, 0, 0))
        XCTAssertEqual(reference.startOfYear, date(2025, 1, 1, 0, 0))
        XCTAssertEqual(reference.startOfNextYear, date(2026, 1, 1, 0, 0))
        XCTAssertEqual(reference.year, 2025)
    }

    func testDayStampChangesAtMidnightOnly() {
        let before = formatting.reference(now: date(2025, 3, 6, 23, 59)).dayStamp
        let sameDay = formatting.reference(now: date(2025, 3, 6, 0, 1)).dayStamp
        let after = formatting.reference(now: date(2025, 3, 7, 0, 0)).dayStamp
        XCTAssertEqual(before, sameDay)
        XCTAssertNotEqual(before, after)
    }

    func testTimeZoneMovesTheDayBoundary() {
        guard let tokyo = TimeZone(identifier: "Asia/Tokyo") else { return XCTFail("missing time zone") }
        let local = DateFormatting(locale: british, calendar: Calendar(identifier: .gregorian), timeZone: tokyo)
        // 23:30 UTC on 4 March is already 08:30 on 5 March in Tokyo: yesterday there, two days back in UTC.
        let lateEvening = date(2025, 3, 4, 23, 30)
        XCTAssertEqual(local.string(for: date(2025, 3, 5, 23, 30), now: now), "08:30")
        XCTAssertEqual(local.string(for: lateEvening, now: now), "Yesterday")
        XCTAssertEqual(formatting.string(for: lateEvening, now: now), "Tue")
    }
}
