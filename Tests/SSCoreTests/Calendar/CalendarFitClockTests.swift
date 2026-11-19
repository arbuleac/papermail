import XCTest
@testable import SSCore

/// Days are local and read by the wall clock: a day with a clock change still runs 00:00 to 24:00, an event that
/// crosses midnight shows on each day it touches, and an all-day event keeps its dates wherever the Mac is.
final class CalendarFitClockTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        return calendar
    }

    private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func event(_ id: String, _ start: String, _ end: String, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, accountID: AccountID("a"), providerID: id, title: id, start: utc(start), end: utc(end),
                      isAllDay: allDay)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func minutes(_ fit: CalendarFit, _ id: String) -> [Double] {
        fit.items.filter { $0.eventID == id }.flatMap { [$0.startMinute, $0.endMinute] }
    }

    // MARK: Clock changes

    /// New York springs forward at 02:00 on 8 March 2026: the day has 23 hours and 02:00 to 03:00 never happens.
    func testNewYorkSpringForwardDayStillRunsMidnightToMidnight() {
        let ny = calendar("America/New_York")
        let sunday = day(2026, 3, 8, in: ny)
        let events = [
            event("across", "2026-03-08T06:30:00Z", "2026-03-08T07:30:00Z"), // 01:30 EST to 03:30 EDT: an hour
            event("evening", "2026-03-09T02:00:00Z", "2026-03-09T03:00:00Z"), // 22:00 to 23:00 EDT
            event("last", "2026-03-09T03:30:00Z", "2026-03-09T04:00:00Z"), // 23:30 EDT to midnight
        ]
        let fit = CalendarFit(days: [sunday], events: events, height: 600, width: 196, calendar: ny)
        XCTAssertEqual(minutes(fit, "across"), [90, 210], "the wall clock, not the hour that passed")
        XCTAssertEqual(minutes(fit, "evening"), [1_320, 1_380], "22:00 is minute 1,320 though only 21 hours have passed")
        XCTAssertEqual(minutes(fit, "last"), [1_410, 1_440], "the day still ends at 24:00")
        XCTAssertEqual(fit.openRuns, [1..<4, 9..<18, 22..<24])

        let now = utc("2026-03-08T07:15:00Z") // 03:15 EDT
        XCTAssertEqual(fit.locate(now)?.minute, 195)
        XCTAssertEqual(fit.date(atMinute: 150, onDay: 0), utc("2026-03-08T07:30:00Z"),
                       "02:30 does not exist: it reads as 03:30, the same distance past the gap")
        XCTAssertEqual(fit.date(atMinute: 540, onDay: 0), utc("2026-03-08T13:00:00Z"))

        let quiet = CalendarFit(days: [sunday], events: [], height: 600, width: 196, calendar: ny)
        let plain = CalendarFit(days: [day(2026, 3, 9, in: ny)], events: [], height: 600, width: 196, calendar: ny)
        XCTAssertEqual(quiet.hoursHeight, plain.hoursHeight, "a short day takes the same room as any other")
        XCTAssertEqual(quiet.openRuns, plain.openRuns)
    }

    /// New York falls back at 02:00 on 1 November 2026: the day has 25 hours and 01:00 to 02:00 happens twice.
    func testNewYorkFallBackDayStillRunsMidnightToMidnight() {
        let ny = calendar("America/New_York")
        let sunday = day(2026, 11, 1, in: ny)
        let events = [
            event("second", "2026-11-01T06:00:00Z", "2026-11-01T07:00:00Z"), // 01:00 to 02:00 EST, the second pass
            event("back", "2026-11-01T05:30:00Z", "2026-11-01T06:15:00Z"), // 01:30 EDT to 01:15 EST: 45 minutes
            event("evening", "2026-11-02T03:00:00Z", "2026-11-02T04:00:00Z"), // 22:00 to 23:00 EST
        ]
        let fit = CalendarFit(days: [sunday], events: events, height: 600, width: 196, calendar: ny)
        XCTAssertEqual(minutes(fit, "second"), [60, 120])
        XCTAssertEqual(minutes(fit, "back"), [90, 135], "the clock runs back: the part keeps its real 45 minutes")
        XCTAssertEqual(minutes(fit, "evening"), [1_320, 1_380], "22:00 is minute 1,320 though 23 hours have passed")
        XCTAssertEqual(fit.openRuns, [1..<3, 9..<18, 22..<23])
        XCTAssertEqual(fit.locate(utc("2026-11-01T06:30:00Z"))?.minute, 90, "01:30 the second time is still 01:30")
        XCTAssertEqual(fit.date(atMinute: 90, onDay: 0), utc("2026-11-01T05:30:00Z"), "the first pass")
    }

    /// Bucharest springs forward at 03:00 on 29 March 2026 (EET to EEST).
    func testBucharestSpringForwardDayStillRunsMidnightToMidnight() {
        let bucharest = calendar("Europe/Bucharest")
        let sunday = day(2026, 3, 29, in: bucharest)
        let events = [
            event("across", "2026-03-29T00:30:00Z", "2026-03-29T01:30:00Z"), // 02:30 EET to 04:30 EEST
            event("night", "2026-03-29T20:00:00Z", "2026-03-29T21:00:00Z"), // 23:00 to 24:00 EEST
        ]
        let fit = CalendarFit(days: [sunday], events: events, height: 600, width: 196, calendar: bucharest)
        XCTAssertEqual(minutes(fit, "across"), [150, 270])
        XCTAssertEqual(minutes(fit, "night"), [1_380, 1_440])
        XCTAssertEqual(fit.openRuns, [2..<5, 9..<18, 23..<24])
        XCTAssertEqual(fit.items.first { $0.eventID == "night" }?.endsAfterDay, false, "it ends at the day's end")
    }

    /// Bucharest falls back at 04:00 on 25 October 2026 (EEST to EET): 03:00 to 04:00 happens twice.
    func testBucharestFallBackDayStillRunsMidnightToMidnight() {
        let bucharest = calendar("Europe/Bucharest")
        let sunday = day(2026, 10, 25, in: bucharest)
        let events = [
            event("twice", "2026-10-25T00:30:00Z", "2026-10-25T01:30:00Z"), // 03:30 EEST to 03:30 EET
            event("night", "2026-10-25T21:00:00Z", "2026-10-25T22:00:00Z"), // 23:00 to 24:00 EET
        ]
        let fit = CalendarFit(days: [sunday], events: events, height: 600, width: 196, calendar: bucharest)
        XCTAssertEqual(minutes(fit, "twice"), [210, 270], "an hour from 03:30 to 03:30 is drawn as the hour it lasted")
        XCTAssertEqual(minutes(fit, "night"), [1_380, 1_440])
        XCTAssertEqual(fit.openRuns, [3..<5, 9..<18, 23..<24])
    }

    /// A week across a clock change keeps every day on the same hours.
    func testAWeekAcrossAClockChangeLinesUpItsDays() {
        let bucharest = calendar("Europe/Bucharest")
        let monday = day(2026, 10, 19, in: bucharest)
        let week = (0..<7).map { bucharest.date(byAdding: .day, value: $0, to: monday)! }
        let events = [
            event("thu", "2026-10-22T07:00:00Z", "2026-10-22T08:00:00Z"), // Thursday 10:00 EEST
            event("sun", "2026-10-25T08:00:00Z", "2026-10-25T09:00:00Z"), // Sunday 10:00 EET
        ]
        let fit = CalendarFit(days: week, events: events, height: 600, width: 700, calendar: bucharest)
        let thursday = fit.items.first { $0.eventID == "thu" }
        let sunday = fit.items.first { $0.eventID == "sun" }
        XCTAssertEqual(thursday?.startMinute, 600)
        XCTAssertEqual(sunday?.startMinute, 600)
        XCTAssertEqual(thursday?.top, sunday?.top, "10:00 is at the same height on both sides of the change")
        XCTAssertEqual(sunday?.dayIndex, 6)
    }

    /// Free time is read by the wall clock too: the working day on a short day is still 09:00 to 18:00.
    func testFreeTimeOnAClockChangeDayKeepsTheWorkingDay() {
        let ny = calendar("America/New_York")
        let sunday = day(2026, 3, 8, in: ny)
        let slots = CalendarFit.freeSlots(on: sunday, events: [], now: utc("2026-03-01T12:00:00Z"), calendar: ny)
        XCTAssertEqual(slots, [DateInterval(start: utc("2026-03-08T13:00:00Z"), end: utc("2026-03-08T22:00:00Z"))])
    }

    // MARK: Midnight

    /// An event from 22:00 to 02:00 is cut at midnight: the evening on one day, the small hours on the next.
    func testAnEventAcrossMidnightShowsOnEachDayItTouches() {
        let bucharest = calendar("Europe/Bucharest")
        let friday = day(2026, 11, 20, in: bucharest)
        let saturday = day(2026, 11, 21, in: bucharest)
        let night = event("night", "2026-11-20T20:00:00Z", "2026-11-21T00:00:00Z") // Fri 22:00 to Sat 02:00

        let both = CalendarFit(days: [friday, saturday], events: [night], height: 600, width: 400, calendar: bucharest)
        XCTAssertEqual(both.items.map(\.dayIndex), [0, 1])
        XCTAssertEqual(minutes(both, "night"), [1_320, 1_440, 0, 120])
        XCTAssertEqual(both.items.map(\.startsBeforeDay), [false, true])
        XCTAssertEqual(both.items.map(\.endsAfterDay), [true, false])
        XCTAssertEqual(both.openRuns, [0..<2, 9..<18, 22..<24], "the hours either day needs open for both")
        XCTAssertEqual(both.days.map(\.isFolded), [false, false])

        let saturdayOnly = CalendarFit(days: [saturday], events: [night], height: 600, width: 196, calendar: bucharest)
        XCTAssertEqual(minutes(saturdayOnly, "night"), [0, 120])
        XCTAssertEqual(saturdayOnly.openRuns, [0..<2, 9..<18])
        XCTAssertEqual(saturdayOnly.items.first?.top, 0)

        let fridayOnly = CalendarFit(days: [friday], events: [night], height: 600, width: 196, calendar: bucharest)
        XCTAssertEqual(fridayOnly.openRuns, [9..<18, 22..<24])
        XCTAssertEqual(fridayOnly.items.first.map { $0.top + $0.height } ?? 0, fridayOnly.hoursHeight, accuracy: 1e-9)
    }

    /// An event that ends at midnight belongs to its own day only (the end is exclusive); a weekend day it ends on
    /// still folds.
    func testAnEventEndingAtMidnightStaysOnItsDay() {
        let bucharest = calendar("Europe/Bucharest")
        let monday = day(2026, 11, 16, in: bucharest)
        let week = (0..<7).map { bucharest.date(byAdding: .day, value: $0, to: monday)! }
        let late = event("late", "2026-11-20T21:00:00Z", "2026-11-20T22:00:00Z") // Fri 23:00 to 24:00
        let fit = CalendarFit(days: week, events: [late], height: 600, width: 700, calendar: bucharest)
        XCTAssertEqual(fit.items.map(\.dayIndex), [4])
        XCTAssertEqual(fit.days.map(\.isFolded), [false, false, false, false, false, true, true])
    }

    /// A timed event of several days covers each whole day between its ends.
    func testATimedEventOfSeveralDaysCoversTheDaysBetween() {
        let bucharest = calendar("Europe/Bucharest")
        let monday = day(2026, 11, 16, in: bucharest)
        let days = (0..<3).map { bucharest.date(byAdding: .day, value: $0, to: monday)! }
        let conference = event("conf", "2026-11-16T14:00:00Z", "2026-11-18T10:00:00Z") // Mon 16:00 to Wed 12:00
        let fit = CalendarFit(days: days, events: [conference], height: 600, width: 600, calendar: bucharest)
        XCTAssertEqual(minutes(fit, "conf"), [960, 1_440, 0, 1_440, 0, 720])
        XCTAssertEqual(fit.openHourCount, 24)
    }

    // MARK: All-day dates

    /// An all-day event is held floating (its dates' UTC midnights): it shows on those dates in any zone.
    func testAnAllDayEventKeepsItsDatesInEveryZone() {
        let trip = event("trip", "2026-11-18T00:00:00Z", "2026-11-20T00:00:00Z", allDay: true) // 18 and 19 November
        for zone in ["Europe/Bucharest", "America/Los_Angeles", "Pacific/Auckland", "Asia/Tokyo", "UTC"] {
            let calendar = calendar(zone)
            let start = day(2026, 11, 17, in: calendar)
            let days = (0..<4).map { calendar.date(byAdding: .day, value: $0, to: start)! }
            let fit = CalendarFit(days: days, events: [trip], height: 600, width: 400, calendar: calendar)
            XCTAssertEqual(fit.allDay.map { $0.shown.map(\.id) }, [[], ["trip"], ["trip"], []], zone)
            XCTAssertTrue(fit.items.isEmpty, "\(zone): an all-day event takes no hours")
            XCTAssertEqual(fit.openRuns, [9..<18], zone)
            XCTAssertEqual(fit.allDayRows, 1, zone)
        }
    }

    /// Two rows show; a day with more says how many more; the band is as tall as the busiest day needs.
    func testTheAllDayBandShowsTwoRowsAndCountsTheRest() {
        let bucharest = calendar("Europe/Bucharest")
        let events = [
            event("long", "2026-11-16T00:00:00Z", "2026-11-19T00:00:00Z", allDay: true),
            event("b", "2026-11-17T00:00:00Z", "2026-11-18T00:00:00Z", allDay: true),
            event("a", "2026-11-17T00:00:00Z", "2026-11-18T00:00:00Z", allDay: true),
            event("c", "2026-11-17T00:00:00Z", "2026-11-18T00:00:00Z", allDay: true),
            event("declined", "2026-11-18T00:00:00Z", "2026-11-19T00:00:00Z", allDay: true),
        ].map { event -> CalendarEvent in
            var event = event
            if event.id == "declined" { event.response = .declined }
            return event
        }
        let monday = day(2026, 11, 16, in: bucharest)
        let days = (0..<3).map { bucharest.date(byAdding: .day, value: $0, to: monday)! }
        let fit = CalendarFit(days: days, events: events, height: 600, width: 600, calendar: bucharest)
        XCTAssertEqual(fit.allDay.map { $0.shown.map(\.id) }, [["long"], ["long", "a"], ["long"]],
                       "by start, the longer first, then by id")
        XCTAssertEqual(fit.allDay.map(\.overflow), [0, 2, 0])
        XCTAssertEqual(fit.allDayRows, 2)
        XCTAssertEqual(fit.allDayHeight, 50)
        XCTAssertEqual(fit.hoursHeight, 550, accuracy: 0.001)
    }
}
