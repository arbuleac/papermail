import XCTest
@testable import PaperCore

/// Later's presets (spec §5.45) and the times written beside them, on fixed clocks in fixed time zones: the morning,
/// the afternoon, after 17:00, late at night, a Monday, a Sunday, month and year ends, and both daylight-saving changes; and
/// over a year in four zones, each time offered once, soonest first.
final class LaterPresetTests: XCTestCase {
    private let british = Locale(identifier: "en_GB")

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        calendar.locale = british
        return calendar
    }

    private lazy var london = calendar("Europe/London")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0,
                      in calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? london
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else {
            XCTFail("invalid components \(components)")
            return Date()
        }
        return date
    }

    private func offered(at now: Date, in calendar: Calendar? = nil) -> [LaterPreset: Date] {
        Dictionary(uniqueKeysWithValues: LaterPreset.offered(at: now, calendar: calendar ?? london).map { ($0.preset, $0.date) })
    }

    /// Thursday 6 March 2025, 09:20: every preset, in menu order.
    func testAMorningOffersAllFourInOrder() {
        let now = date(2025, 3, 6, 9, 20)
        XCTAssertEqual(LaterPreset.offered(at: now, calendar: london).map(\.preset), [.laterToday, .thisEvening, .tomorrow, .nextWeek])
        let times = offered(at: now)
        XCTAssertEqual(times[.laterToday], date(2025, 3, 6, 13), "three hours on, rounded up to the next full hour")
        XCTAssertEqual(times[.thisEvening], date(2025, 3, 6, 18))
        XCTAssertEqual(times[.tomorrow], date(2025, 3, 7, 9))
        XCTAssertEqual(times[.nextWeek], date(2025, 3, 10, 9), "the next Monday")
        XCTAssertEqual(LaterPreset.allCases.map(\.title), ["Later Today", "This Evening", "Tomorrow", "Next Week"])
    }

    func testLaterTodayRoundsUpOnlyWhenOffTheHour() {
        XCTAssertEqual(offered(at: date(2025, 3, 6, 9, 0, 0))[.laterToday], date(2025, 3, 6, 12), "already on the hour")
        XCTAssertEqual(offered(at: date(2025, 3, 6, 9, 0, 1))[.laterToday], date(2025, 3, 6, 13), "a second past rounds up")
        XCTAssertEqual(offered(at: date(2025, 3, 6, 9, 59, 59))[.laterToday], date(2025, 3, 6, 13))
    }

    /// This Evening is offered before 17:00 only; Later Today while it lands before This Evening's 18:00.
    func testAfterFiveThisEveningGoesAndLaterTodayGoesBeforeItsTime() {
        XCTAssertNotNil(offered(at: date(2025, 3, 6, 16, 59, 59))[.thisEvening])
        XCTAssertNil(offered(at: date(2025, 3, 6, 17, 0))[.thisEvening])
        XCTAssertEqual(offered(at: date(2025, 3, 6, 14, 0, 0))[.laterToday], date(2025, 3, 6, 17), "14:00 + 3 h, before 18:00")
        XCTAssertNil(offered(at: date(2025, 3, 6, 14, 0, 1))[.laterToday], "rounds up to 18:00, This Evening's own time")
        XCTAssertNil(offered(at: date(2025, 3, 6, 16, 0))[.laterToday], "19:00 would sit above This Evening's 18:00")
        let evening = LaterPreset.offered(at: date(2025, 3, 6, 21, 30), calendar: london).map(\.preset)
        XCTAssertEqual(evening, [.tomorrow, .nextWeek])
        // Late at night three hours on is past midnight, which is not "today".
        XCTAssertEqual(LaterPreset.offered(at: date(2025, 3, 6, 23, 30), calendar: london).map(\.preset), [.tomorrow, .nextWeek])
    }

    func testNextWeekIsTheNextMondayAndAWeekOnFromAMonday() {
        let monday = date(2025, 3, 10, 8, 0)
        XCTAssertEqual(offered(at: monday)[.nextWeek], date(2025, 3, 17, 9), "a Monday morning: a week on, not this morning")
        XCTAssertEqual(offered(at: monday)[.tomorrow], date(2025, 3, 11, 9))
        XCTAssertNil(offered(at: date(2025, 3, 9, 15))[.nextWeek], "a Sunday: the next Monday is Tomorrow's")
        XCTAssertEqual(offered(at: date(2025, 3, 9, 15))[.tomorrow], date(2025, 3, 10, 9))
        XCTAssertEqual(offered(at: date(2025, 3, 15, 12))[.nextWeek], date(2025, 3, 17, 9), "a Saturday")
    }

    /// The menu never offers one time twice and reads soonest first: in the afternoon Later Today would land on or after
    /// This Evening, and on a Sunday Next Week on Tomorrow's Monday.
    func testTheMenuOffersEachTimeOnceSoonestFirst() {
        let presets = { (now: Date) in LaterPreset.offered(at: now, calendar: self.london).map(\.preset) }
        XCTAssertEqual(presets(date(2025, 3, 6, 14, 30)), [.thisEvening, .tomorrow, .nextWeek], "not Later Today 18:00 beside This Evening 18:00")
        XCTAssertEqual(presets(date(2025, 3, 6, 15, 30)), [.thisEvening, .tomorrow, .nextWeek], "not Later Today 19:00 above This Evening 18:00")
        XCTAssertEqual(presets(date(2025, 3, 9, 10)), [.laterToday, .thisEvening, .tomorrow], "a Sunday: Tomorrow is Monday 09:00")
        XCTAssertEqual(presets(date(2025, 3, 9, 21)), [.tomorrow])
        // Every 45 minutes of a year (so every quarter hour comes round), in zones that change their clocks in spring and
        // autumn and in one that does not.
        for zone in ["Europe/London", "America/New_York", "Australia/Sydney", "Asia/Tokyo"] {
            let calendar = calendar(zone)
            var now = date(2025, 1, 1, 0, in: calendar)
            let end = date(2026, 1, 1, 0, in: calendar)
            while now < end {
                let dates = LaterPreset.offered(at: now, calendar: calendar).map(\.date)
                XCTAssertEqual(dates, dates.sorted(), "\(zone) \(now): soonest first")
                XCTAssertEqual(Set(dates).count, dates.count, "\(zone) \(now): each time once")
                XCTAssertTrue(dates.allSatisfy { $0 > now }, "\(zone) \(now): every time ahead")
                now = now.addingTimeInterval(2_700)
            }
        }
    }

    func testMonthAndYearEnds() {
        XCTAssertEqual(offered(at: date(2025, 2, 28, 10))[.tomorrow], date(2025, 3, 1, 9))
        XCTAssertEqual(offered(at: date(2024, 2, 28, 10))[.tomorrow], date(2024, 2, 29, 9), "a leap year")
        XCTAssertEqual(offered(at: date(2025, 12, 31, 10))[.tomorrow], date(2026, 1, 1, 9))
        XCTAssertEqual(offered(at: date(2025, 12, 31, 10))[.nextWeek], date(2026, 1, 5, 9))
        XCTAssertEqual(offered(at: date(2025, 4, 30, 22))[.nextWeek], date(2025, 5, 5, 9))
    }

    /// The clocks go forward at 01:00 on 30 March 2025 in London: three hours from 23:30 on the 29th is 03:30 on the
    /// wall, and 09:00 the next day is still 09:00 on the wall, 23 hours later.
    func testTheClocksGoingForward() {
        let saturday = date(2025, 3, 29, 23, 30)
        XCTAssertEqual(offered(at: saturday)[.tomorrow], date(2025, 3, 30, 9))
        XCTAssertEqual(offered(at: saturday)[.nextWeek], date(2025, 3, 31, 9))
        // 00:20 GMT plus three hours is 03:20 GMT, which the wall shows as 04:20 BST: rounded up, 05:00.
        let early = date(2025, 3, 30, 0, 20)
        XCTAssertEqual(LaterPreset.laterToday.date(after: early, calendar: london), date(2025, 3, 30, 5))
        XCTAssertEqual(offered(at: saturday)[.nextWeek]?.timeIntervalSince(date(2025, 3, 30, 9)), 24 * 3_600)
        XCTAssertEqual(date(2025, 3, 30, 9).timeIntervalSince(date(2025, 3, 29, 9)), 23 * 3_600, "the short day")
    }

    /// The clocks go back at 02:00 on 26 October 2025: the hour 01:00–02:00 happens twice, and rounding up lands on the
    /// next full hour the wall clock shows.
    func testTheClocksGoingBack() {
        let calendar = london
        let first = date(2025, 10, 26, 0, 30, in: calendar)
        let laterToday = LaterPreset.laterToday.date(after: first, calendar: calendar)
        XCTAssertEqual(laterToday, first.addingTimeInterval(3.5 * 3_600), "three absolute hours on is 02:30, rounded up to 03:00")
        XCTAssertEqual(calendar.component(.hour, from: laterToday!), 3)
        XCTAssertEqual(offered(at: first)[.tomorrow], date(2025, 10, 27, 9))
        XCTAssertEqual(offered(at: first)[.tomorrow]?.timeIntervalSince(date(2025, 10, 26, 9)), 24 * 3_600)
        XCTAssertEqual(offered(at: date(2025, 10, 25, 12))[.tomorrow]?.timeIntervalSince(date(2025, 10, 25, 9)), 25 * 3_600,
                       "09:00 on the 26th is 25 hours after 09:00 on the 25th")
    }

    /// Every time is the zone's own: the same instant gives each zone its own today and tomorrow.
    func testTimesFollowTheTimeZone() {
        let tokyo = calendar("Asia/Tokyo")
        let instant = date(2025, 3, 6, 22, 0) // 07:00 on the 7th in Tokyo
        XCTAssertEqual(offered(at: instant)[.tomorrow], date(2025, 3, 7, 9))
        XCTAssertEqual(offered(at: instant, in: tokyo)[.tomorrow], date(2025, 3, 8, 9, in: tokyo))
        XCTAssertEqual(offered(at: instant, in: tokyo)[.thisEvening], date(2025, 3, 7, 18, in: tokyo))
    }

    func testPickADateStartsTomorrowMorningAndCombinesItsTwoFields() {
        let now = date(2025, 3, 6, 21, 30)
        XCTAssertEqual(LaterPreset.tomorrowMorning(after: now, calendar: london), date(2025, 3, 7, 9))
        let day = date(2025, 3, 20, 0, 0)
        let time = date(2025, 1, 1, 7, 45)
        XCTAssertEqual(LaterPreset.combine(day: day, time: time, calendar: london), date(2025, 3, 20, 7, 45))
    }

    // MARK: The times beside them

    func testTimesAheadAreWrittenAsTheRowsWriteTimes() {
        let formatting = DateFormatting(locale: british, calendar: london, timeZone: london.timeZone)
        let now = date(2025, 3, 6, 9, 20) // Thursday
        let reference = formatting.reference(now: now)
        XCTAssertEqual(formatting.dueTime(for: date(2025, 3, 6, 13), reference: reference), "13:00", "today: the time alone")
        XCTAssertEqual(formatting.dueTime(for: date(2025, 3, 7, 9), reference: reference), "Fri 09:00", "tomorrow: the day too")
        XCTAssertEqual(formatting.dueTime(for: date(2025, 3, 12, 9), reference: reference), "Wed 09:00", "within six days")
        XCTAssertEqual(formatting.dueTime(for: date(2025, 3, 13, 9), reference: reference), "13 Mar 09:00",
                       "a week on would read as today's weekday")
        XCTAssertEqual(formatting.dueTime(for: date(2026, 1, 2, 9), reference: reference), "2 Jan 09:00",
                       "next year but less than eleven months ahead: the day and month can only mean the coming one")
        XCTAssertEqual(formatting.dueTime(for: date(2026, 2, 5, 9), reference: reference), "5 Feb 09:00")
        XCTAssertEqual(formatting.dueTime(for: date(2026, 2, 6, 9), reference: reference), "6 Feb 2026 09:00",
                       "eleven months ahead or more: the year too, or it could read as last month's")
        XCTAssertEqual(formatting.dueTime(for: date(2024, 12, 30, 9), reference: reference), "30 Dec 2024 09:00", "a past year")
        // Next Week from the last Monday of December lands in January.
        let december = formatting.reference(now: date(2025, 12, 29, 8))
        XCTAssertEqual(formatting.dueTime(for: date(2026, 1, 5, 9), reference: december), "5 Jan 09:00")
        // Next Week from a Monday is a week on, so it names its date.
        let monday = formatting.reference(now: date(2025, 3, 10, 8))
        XCTAssertEqual(formatting.dueTime(for: date(2025, 3, 17, 9), reference: monday), "17 Mar 09:00")
        // The words around them.
        XCTAssertEqual(MailActionCopy.snoozed(until: "Fri 09:00"), "Snoozed until Fri 09:00")
    }

    func testTimesFollowTheTwelveHourClock() {
        var us = Calendar(identifier: .gregorian)
        us.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let locale = Locale(identifier: "en_US")
        us.locale = locale
        let formatting = DateFormatting(locale: locale, calendar: us, timeZone: us.timeZone)
        let now = us.date(from: DateComponents(year: 2025, month: 3, day: 6, hour: 9))!
        let due = us.date(from: DateComponents(year: 2025, month: 3, day: 7, hour: 9))!
        let text = formatting.dueTime(for: due, reference: formatting.reference(now: now))
        XCTAssertTrue(text.hasPrefix("Fri 9:00"), text)
        XCTAssertTrue(text.contains("AM"), text)
    }
}
