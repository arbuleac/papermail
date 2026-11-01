import XCTest
@testable import SSCore

final class DateFormattingTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC") ?? .current
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }
    private lazy var formatting = DateFormatting(locale: Locale(identifier: "en_US"), calendar: calendar, timeZone: utc)
    /// Thursday 6 March 2025, 14:05 UTC.
    private lazy var now = date(2025, 3, 6, 14, 5)

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: components) else {
            XCTFail("invalid components \(components)")
            return Date()
        }
        return date
    }

    func testTodayShowsTwentyFourHourTime() {
        XCTAssertEqual(formatting.string(for: now, now: now), "14:05")
        XCTAssertEqual(formatting.string(for: date(2025, 3, 6, 9, 7), now: now), "09:07")
        XCTAssertEqual(formatting.string(for: date(2025, 3, 6, 0, 0), now: now), "00:00")
        XCTAssertEqual(formatting.string(for: date(2025, 3, 6, 23, 59), now: now), "23:59")
    }

    func testWithinSixDaysShowsWeekday() {
        XCTAssertEqual(formatting.string(for: date(2025, 3, 5), now: now), "Wed")
        XCTAssertEqual(formatting.string(for: date(2025, 3, 5, 23, 59), now: now), "Wed")
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

    func testReferenceBoundaries() {
        let reference = formatting.reference(now: now)
        XCTAssertEqual(reference.startOfToday, date(2025, 3, 6, 0, 0))
        XCTAssertEqual(reference.startOfTomorrow, date(2025, 3, 7, 0, 0))
        XCTAssertEqual(reference.startOfWeekWindow, date(2025, 2, 28, 0, 0))
        XCTAssertEqual(reference.startOfYear, date(2025, 1, 1, 0, 0))
        XCTAssertEqual(reference.startOfNextYear, date(2026, 1, 1, 0, 0))
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
        let local = DateFormatting(locale: Locale(identifier: "en_US"), calendar: Calendar(identifier: .gregorian), timeZone: tokyo)
        // 23:30 UTC on 5 March is already 08:30 on 6 March in Tokyo, so it is "today" there.
        let lateEvening = date(2025, 3, 5, 23, 30)
        XCTAssertEqual(local.string(for: lateEvening, now: now), "08:30")
        XCTAssertEqual(formatting.string(for: lateEvening, now: now), "Wed")
    }
}
