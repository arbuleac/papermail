import XCTest
@testable import SSCore

/// Repeat rules in words, never expanded (spec §5.14): every shape the card names, and the parts it cannot.
final class RecurrenceRuleTests: XCTestCase {
    private let locale = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!

    /// Tuesday 10 November 2026, 15:00 UTC.
    private let tuesday = ISO8601DateFormatter().date(from: "2026-11-10T15:00:00Z")!

    private func words(_ rrule: String, start: Date? = nil, zone: TimeZone? = nil) throws -> String {
        let rule = try XCTUnwrap(RecurrenceRule(rrule: rrule), rrule)
        return rule.words(start: start ?? tuesday, timeZone: zone ?? utc, locale: locale)
    }

    func testDaily() throws {
        XCTAssertEqual(try words("FREQ=DAILY"), "Every day")
        XCTAssertEqual(try words("FREQ=DAILY;INTERVAL=2"), "Every 2 days")
        XCTAssertEqual(try words("FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR"), "Every weekday")
        XCTAssertEqual(try words("FREQ=DAILY;COUNT=5"), "Every day, 5 times")
    }

    func testWeekly() throws {
        XCTAssertEqual(try words("FREQ=WEEKLY"), "Every week on Tuesday", "the start's weekday when BYDAY is absent")
        XCTAssertEqual(try words("FREQ=WEEKLY;BYDAY=TH,MO;INTERVAL=2"), "Every 2 weeks on Monday and Thursday")
        XCTAssertEqual(try words("FREQ=WEEKLY;BYDAY=MO,WE,FR"), "Every week on Monday, Wednesday and Friday")
        XCTAssertEqual(try words("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"), "Every weekday")
        XCTAssertEqual(try words("FREQ=WEEKLY;BYDAY=SU"), "Every week on Sunday")
    }

    func testMonthly() throws {
        XCTAssertEqual(try words("FREQ=MONTHLY;BYMONTHDAY=3;UNTIL=20270303"), "Every month on the 3rd, until 3 March 2027")
        XCTAssertEqual(try words("FREQ=MONTHLY"), "Every month on the 10th")
        XCTAssertEqual(try words("FREQ=MONTHLY;BYDAY=2TU"), "Every month on the second Tuesday")
        XCTAssertEqual(try words("FREQ=MONTHLY;BYDAY=-1FR"), "Every month on the last Friday")
        XCTAssertEqual(try words("FREQ=MONTHLY;BYDAY=TU;BYSETPOS=3"), "Every month on the third Tuesday")
        XCTAssertEqual(try words("FREQ=MONTHLY;BYMONTHDAY=-1"), "Every month on the last day")
        XCTAssertEqual(try words("FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1"), "Every 3 months on the 1st")
    }

    func testYearly() throws {
        XCTAssertEqual(try words("FREQ=YEARLY"), "Every year on 10 November")
        XCTAssertEqual(try words("FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=3"), "Every year on 3 March")
        XCTAssertEqual(try words("FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU"), "Every year on the last Sunday of October")
        XCTAssertEqual(try words("FREQ=YEARLY;COUNT=1"), "Every year on 10 November, once")
    }

    func testUntilIsTheLastDayInTheEventsZone() throws {
        // 01:00 UTC on 4 March is still 3 March in New York.
        let newYork = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(try words("FREQ=WEEKLY;UNTIL=20270304T010000Z", zone: newYork), "Every week on Tuesday, until 3 March 2027")
    }

    func testPartsTheWordsCannotSay() throws {
        XCTAssertEqual(try words("FREQ=WEEKLY;BYHOUR=9"), "Repeats")
        XCTAssertEqual(try words("FREQ=MONTHLY;BYDAY=MO,TU;BYSETPOS=1,-1;COUNT=4"), "Repeats, 4 times")
        XCTAssertEqual(try words("FREQ=MONTHLY;BYMONTHDAY=1,15"), "Repeats")
    }

    func testRulesThatAreNotRules() {
        XCTAssertNil(RecurrenceRule(rrule: "BYDAY=MO"), "no FREQ")
        XCTAssertNil(RecurrenceRule(rrule: "FREQ=HOURLY"), "finer than a day")
        XCTAssertNil(RecurrenceRule(rrule: "FREQ=WEEKLY;BYDAY=XX"))
        XCTAssertNil(RecurrenceRule(rrule: "FREQ=WEEKLY;INTERVAL=0"))
        XCTAssertNil(RecurrenceRule(rrule: "FREQ=WEEKLY;UNTIL=tomorrow"))
        XCTAssertNil(RecurrenceRule(rrule: "FREQ=MONTHLY;BYMONTHDAY=40"))
    }

    func testTheRuleWritesBackAsAnRRULE() throws {
        let rule = try XCTUnwrap(RecurrenceRule(rrule: "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;UNTIL=20270303T235959Z"))
        XCTAssertEqual(rule.rruleText, "FREQ=MONTHLY;INTERVAL=2;BYDAY=-1FR;UNTIL=20270303T235959Z")
        XCTAssertEqual(RecurrenceRule(rrule: rule.rruleText), rule)
    }
}
