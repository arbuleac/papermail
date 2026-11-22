import XCTest
@testable import PaperCore

/// The fit (Quire "Day and week"): the approved concept's numbers for its sample week, and each rule on its own.
/// The expected values were computed by the concept page's own `model()` over the same data.
final class CalendarFitTests: XCTestCase {
    private let sample = CalendarFitSample()
    private let accuracy = 0.001

    private func runs(_ fit: CalendarFit) -> [Range<Int>] { fit.openRuns }
    private func folds(_ fit: CalendarFit) -> [[Int]] { fit.folds.map { [$0.from, $0.to] } }

    // MARK: The concept's numbers

    /// "Column at 600 pt: 10 hours open (08:00 to 18:00), 42 pt an hour", and the other window heights the page lists.
    func testTheColumnOnTheSampleThursdayFitsAsTheConceptShows() {
        let expected: [(window: Double, open: Int, runs: [Range<Int>], hour: Double)] = [
            (600, 10, [8..<18], 42.2),
            (700, 10, [8..<18], 52.2),
            (800, 10, [8..<18], 62.2),
            (900, 12, [7..<19], 60.1667),
        ]
        for row in expected {
            let fit = sample.column(3, window: row.window)
            XCTAssertEqual(fit.openHourCount, row.open, "window \(row.window)")
            XCTAssertEqual(runs(fit), row.runs, "window \(row.window)")
            XCTAssertEqual(fit.hourHeight, row.hour, accuracy: 0.0001, "window \(row.window)")
            XCTAssertEqual(fit.folds.count, 2)
            XCTAssertEqual(fit.allDayRows, 0, "Thursday has no all-day event")
            XCTAssertEqual(fit.hoursHeight, CalendarFitSample.columnHeight(window: row.window), accuracy: accuracy,
                           "the hours fill the column exactly: nothing scrolls")
        }
        let tall = sample.column(3, window: 900)
        XCTAssertEqual(folds(tall), [[0, 7], [19, 24]], "a quiet evening opens an hour on each side, not one stretched hour")
    }

    /// "Week at 800 pt: 12 hours open (08:00 to 20:00), 51 pt an hour, Saturday folded to 28 pt."
    func testTheSampleWeekFitsAsTheConceptShows() {
        let expected: [(window: Double, hour: Double)] = [(600, 34), (700, 42.3333), (800, 50.6667), (900, 59)]
        for row in expected {
            let fit = sample.weekFit(0, window: row.window)
            XCTAssertEqual(fit.openHourCount, 12, "window \(row.window)")
            XCTAssertEqual(runs(fit), [8..<20], "the Gym at 08:00 on Thursday and the Concert to 20:00 on Friday")
            XCTAssertEqual(folds(fit), [[0, 8], [20, 24]])
            XCTAssertEqual(fit.hourHeight, row.hour, accuracy: 0.0001, "window \(row.window)")
            XCTAssertEqual(fit.allDayRows, 1, "Ana's birthday and the release freeze each take a day's only row")
            XCTAssertEqual(fit.allDayHeight, 28)
            XCTAssertEqual(fit.allDayHeight + fit.hoursHeight, CalendarFitSample.weekHeight(window: row.window),
                           accuracy: accuracy)
        }
        let fit = sample.weekFit(0, window: 800)
        XCTAssertEqual(fit.days.map(\.isFolded), [false, false, false, false, false, true, false],
                       "the empty Saturday folds; Sunday has the family lunch")
        XCTAssertEqual(fit.days.map(\.x), [0, 124, 248, 372, 496, 620, 648])
        XCTAssertEqual(fit.days.map(\.width), [124, 124, 124, 124, 124, 28, 124])
        XCTAssertEqual(fit.folds.map(\.y), [0, 622])
    }

    /// The worst case the floor is set by: all 24 hours open and two rows of all-day events in the column of the
    /// 600 pt minimum window get 16.7 pt an hour, and still fit.
    func testTheWorstCaseColumnStillFitsAtTheMinimumWindow() {
        let day = sample.day(3)
        let early = CalendarEvent(id: "night", accountID: CalendarFitSample.gmail, providerID: "night", title: "Flight",
                                  start: sample.date(3, "0:15"), end: sample.date(3, "1:00"))
        let late = CalendarEvent(id: "late", accountID: CalendarFitSample.gmail, providerID: "late", title: "Call",
                                 start: sample.date(3, "23:45"), end: sample.calendar.date(byAdding: .day, value: 1, to: day)!)
        let spanning = (0..<24).map { hour in
            CalendarEvent(id: "h\(hour)", accountID: CalendarFitSample.contoso, providerID: "h\(hour)", title: "Hour",
                          start: sample.date(3, "\(hour):10"), end: sample.date(3, "\(hour):20"))
        }
        let allDay = (0..<3).map { index in
            CalendarEvent(id: "a\(index)", accountID: CalendarFitSample.northwind, providerID: "a\(index)",
                          title: "All day \(index)", start: CalendarFitSample.floating(2026, 11, 19),
                          end: CalendarFitSample.floating(2026, 11, 20), isAllDay: true)
        }
        let fit = CalendarFit(days: [day], events: spanning + allDay + [early, late],
                              height: CalendarFitSample.columnHeight(window: 600), width: 196, calendar: sample.calendar)
        XCTAssertEqual(fit.openHourCount, 24)
        XCTAssertTrue(fit.folds.isEmpty)
        XCTAssertEqual(fit.allDayRows, 2)
        XCTAssertEqual(fit.allDayHeight, 50)
        XCTAssertEqual(fit.hourHeight, 400.0 / 24, accuracy: 0.0001)
        XCTAssertEqual(fit.hoursHeight, 400, accuracy: accuracy)
        XCTAssertEqual(fit.allDay[0].shown.map(\.id), ["a0", "a1"])
        XCTAssertEqual(fit.allDay[0].overflow, 1, "the third says +1")

        let last = try? XCTUnwrap(fit.items.first { $0.eventID == "late" })
        XCTAssertEqual(last?.height, 18, "a quarter hour still gets a line")
        XCTAssertEqual(last.map { $0.top + $0.height } ?? 0, 400, accuracy: accuracy,
                       "an event at the bottom is lifted to end with the hours instead of hanging below them")
    }

    /// Below the floor the hours keep 16 pt and run past the height given: only a window under Quire's minimum
    /// gets there.
    func testTheFloorHoldsBelowTheMinimumWindow() {
        let fit = CalendarFit(days: [sample.day(3)], events: [], height: 100, width: 196, calendar: sample.calendar)
        XCTAssertEqual(fit.hourHeight, 16)
        XCTAssertEqual(fit.hoursHeight, 9 * 16 + 2 * 14)
    }

    /// Each sample event of the week at 800 pt lands where the concept page draws it.
    func testTheSampleWeekPlacesEveryEventAsTheConceptDrawsIt() {
        let fit = sample.weekFit(0, window: 800)
        let third = 50.6667, h = 50.6667
        let expected: [(id: String, day: Int, top: Double, height: Double, column: Int, count: Int)] = [
            ("e6", 0, 90, 18, 0, 1), ("e31", 0, 166, h, 0, 1), ("e32", 0, 318, 76, 0, 1),
            ("e7", 1, 90, 18, 0, 1), ("e33", 1, 242, h, 0, 1), ("e34", 1, 419.3333, h, 0, 1),
            ("e8", 2, 90, 18, 0, 1), ("e35", 2, 115.3333, 76, 0, 1), ("e36", 2, 368.6667, 25.3333, 0, 1),
            ("e37", 3, 14, 38, 0, 1), ("e9", 3, 90, 18, 0, 1), ("e38", 3, 140.6667, 25.3333, 0, 1),
            (sample.pencil.id, 3, 267.3333, third, 0, 2), ("e39", 3, 292.6667, 25.3333, 1, 2),
            ("e40", 3, 470, h, 0, 1),
            ("e10", 4, 90, 18, 0, 1), ("e41", 4, 166, h, 0, 1), ("e42", 4, 546, 76, 0, 1),
            ("e43", 6, 242, 76, 0, 1),
        ]
        XCTAssertEqual(fit.items.map(\.eventID), expected.map(\.id), "day by day, each day's by start")
        for (item, row) in zip(fit.items, expected) {
            XCTAssertEqual(item.dayIndex, row.day, row.id)
            XCTAssertEqual(item.top, row.top, accuracy: 0.001, row.id)
            XCTAssertEqual(item.height, row.height, accuracy: 0.001, row.id)
            XCTAssertEqual(item.column, row.column, row.id)
            XCTAssertEqual(item.columnCount, row.count, row.id)
            XCTAssertFalse(item.isHidden)
            XCTAssertEqual(item.moreCount, 0)
        }
        XCTAssertEqual(fit.allDay.map { $0.shown.map(\.title) },
                       [[], [], ["Ana's birthday"], [], ["Release freeze"], [], []])
        XCTAssertEqual(fit.marks.map(\.id), ["m2", "m1"], "day by day: Thursday's send, then Friday's return")
        XCTAssertEqual(fit.marks.map(\.dayIndex), [3, 4])
        XCTAssertEqual(fit.marks[0].y, fit.y(forMinute: 16 * 60), accuracy: accuracy)

        let hatch = fit.span(of: DateInterval(start: sample.date(3, "13:30"), end: sample.date(3, "14:00")), onDay: 3)
        XCTAssertEqual(hatch?.top ?? 0, 292.6667, accuracy: 0.001, "the overlap's hatch sits on the 1:1's half hour")
        XCTAssertEqual(hatch?.height ?? 0, 25.3333, accuracy: 0.001)
    }

    /// The other sample weeks: an inner fold between an evening and the working day, Thanksgiving's band, a week
    /// with an all-day offsite and an empty weekend.
    func testTheOtherSampleWeeksFoldAsTheConceptShows() {
        let last = sample.weekFit(-1, window: 800)
        XCTAssertEqual(runs(last), [9..<18, 19..<22], "dinner at Ana's opens 19:00 to 22:00 apart from the working day")
        XCTAssertEqual(folds(last), [[0, 9], [18, 19], [22, 24]])
        XCTAssertEqual(last.folds.map(\.y)[1], 480.5, accuracy: 0.001)
        XCTAssertEqual(last.hourHeight, 51.8333, accuracy: 0.0001)
        XCTAssertEqual(last.days.map(\.isFolded), [false, false, false, false, false, false, true],
                       "the farmers market keeps Saturday open; Sunday is empty")

        let next = sample.weekFit(1, window: 800)
        XCTAssertEqual(runs(next), [9..<19])
        XCTAssertEqual(next.hourHeight, 60.8, accuracy: 0.0001)
        XCTAssertEqual(next.allDayRows, 1)
        XCTAssertEqual(next.days.map(\.isFolded), [false, false, false, false, false, false, true])

        let offsite = sample.weekFit(2, window: 800)
        XCTAssertEqual(runs(offsite), [8..<18], "a quiet week opens 08:00 rather than give an hour 67 pt")
        XCTAssertEqual(offsite.hourHeight, 60.8, accuracy: 0.0001)
        XCTAssertEqual(offsite.days.map(\.isFolded), [false, false, false, false, false, true, true])
        XCTAssertEqual(offsite.days[0].width, 143.2, accuracy: 0.0001)
        XCTAssertEqual(offsite.days[6].x, 143.2 * 5 + 28, accuracy: 0.0001)

        let quiet = sample.weekFit(3, window: 800)
        XCTAssertEqual(runs(quiet), [8..<18])
        XCTAssertEqual(quiet.hourHeight, 63.6, accuracy: 0.0001)
    }

    /// The selected mail's time is marked with the half hour B would take, which opens its hour.
    func testAMailTimeOpensItsHalfHour() {
        let plain = sample.column(4, window: 800)
        XCTAssertEqual(runs(plain), [9..<20], "Friday: the concert runs to 20:00")
        let late = sample.column(4, window: 800, marks: [sample.mailTime("t", 4, "21:45")])
        XCTAssertEqual(runs(late), [9..<20, 21..<23], "21:45 plus 30 minutes opens 21:00 and 22:00")
        XCTAssertEqual(folds(late), [[0, 9], [20, 21], [23, 24]])
        XCTAssertEqual(late.allDayHeight, 28, "Friday's release freeze takes a row above the hours")
        XCTAssertEqual(late.hourHeight, (650 - 28 - 3 * 14) / 13, accuracy: 0.0001)
        XCTAssertEqual(late.marks.first { $0.id == "t" }?.minute, 21 * 60 + 45)
    }

    // MARK: Folding and growing

    /// Hours that hold something open apart from the working day; each run of closed hours between them folds on
    /// its own.
    func testInnerRunsFoldOnTheirOwn() {
        let events = [
            CalendarEvent(id: "early", accountID: CalendarFitSample.gmail, providerID: "early", title: "Run",
                          start: sample.date(0, "6:00"), end: sample.date(0, "6:30")),
            CalendarEvent(id: "late", accountID: CalendarFitSample.gmail, providerID: "late", title: "Call",
                          start: sample.date(0, "21:00"), end: sample.date(0, "21:30")),
        ]
        let fit = CalendarFit(days: [sample.day(0)], events: events, height: 650, width: 196, calendar: sample.calendar)
        XCTAssertEqual(runs(fit), [6..<7, 9..<18, 21..<22])
        XCTAssertEqual(folds(fit), [[0, 6], [7, 9], [18, 21], [22, 24]])
        XCTAssertEqual(fit.hourHeight, (650 - 4 * 14) / 11, accuracy: 0.0001)
        let hour = 54.0, fold = 14.0
        let tops: [Double] = [0, fold + hour, fold + hour + fold + 9 * hour, fold + hour + fold + 9 * hour + fold + hour]
        XCTAssertEqual(fit.folds.map(\.y), tops)
        XCTAssertEqual(fit.hoursHeight, 650, accuracy: accuracy)
        XCTAssertNil(fit.minute(atY: 650))
    }

    /// A quiet day opens an hour before and after the working day in turn until no hour gets more than 64 pt, and
    /// stops at 64 once all 24 are open.
    func testAQuietDayGrowsTowardTheCap() {
        let saturday = sample.day(5)
        let expected: [(window: Double, runs: [Range<Int>], hour: Double)] = [
            (600, [9..<18], 46.8889), (800, [8..<18], 62.2), (900, [7..<19], 60.1667), (1200, [5..<21], 63.875),
        ]
        for row in expected {
            let fit = CalendarFit(days: [saturday], events: sample.drawn,
                                  height: CalendarFitSample.columnHeight(window: row.window), width: 196,
                                  calendar: sample.calendar)
            XCTAssertEqual(runs(fit), row.runs, "window \(row.window)")
            XCTAssertEqual(fit.hourHeight, row.hour, accuracy: 0.0001, "window \(row.window)")
        }
        let huge = CalendarFit(days: [saturday], events: [], height: 2_000, width: 196, calendar: sample.calendar)
        XCTAssertEqual(huge.openHourCount, 24)
        XCTAssertEqual(huge.hourHeight, 64, "the cap holds: the rest of the height stays empty below")
        XCTAssertEqual(huge.hoursHeight, 64 * 24)
        XCTAssertTrue(huge.folds.isEmpty)
    }

    /// With the evening already open to midnight, the turn after it goes to the morning instead.
    func testGrowingSkipsAnEndThatIsAlreadyOpen() {
        let late = CalendarEvent(id: "late", accountID: CalendarFitSample.gmail, providerID: "late", title: "Late",
                                 start: sample.date(0, "23:00"), end: sample.date(0, "23:30"))
        let fit = CalendarFit(days: [sample.day(0)], events: [late], height: 1_000, width: 196, calendar: sample.calendar)
        XCTAssertEqual(runs(fit), [3..<18, 23..<24])
        XCTAssertEqual(fit.hourHeight, (1_000 - 28) / 16, accuracy: 0.0001)
    }

    // MARK: Side by side

    private func stacked(_ count: Int, at time: String = "10:00", until end: String = "11:00") -> CalendarFit {
        let events = (0..<count).map { index in
            CalendarEvent(id: "o\(index)", accountID: CalendarFitSample.contoso, providerID: "o\(index)",
                          title: "Overlap \(index)", start: sample.date(0, time), end: sample.date(0, end))
        }
        return CalendarFit(days: [sample.day(0)], events: events, height: 500, width: 196, calendar: sample.calendar)
    }

    func testTwoAndThreeOverlappingEventsSitSideBySide() {
        let two = stacked(2)
        XCTAssertEqual(two.items.map(\.column), [0, 1])
        XCTAssertEqual(two.items.map(\.columnCount), [2, 2])
        XCTAssertEqual(two.items.map(\.leadingFraction), [0, 0.5])
        XCTAssertEqual(two.items.map(\.widthFraction), [0.5, 0.5])

        let three = stacked(3)
        XCTAssertEqual(three.items.map(\.column), [0, 1, 2])
        XCTAssertEqual(three.items.map(\.columnCount), [3, 3, 3])
        XCTAssertEqual(three.items.map(\.isHidden), [false, false, false])
        XCTAssertEqual(three.items.map(\.moreCount), [0, 0, 0])
    }

    /// Past three across, the rest hide and the third says how many: "+1" for four, "+2" for five.
    func testFourAndFiveOverlappingEventsShowThreeAndCountTheRest() {
        let four = stacked(4)
        XCTAssertEqual(four.items.map(\.column), [0, 1, 2, 3])
        XCTAssertEqual(four.items.map(\.columnCount), [3, 3, 3, 3])
        XCTAssertEqual(four.items.map(\.isHidden), [false, false, false, true])
        XCTAssertEqual(four.items.map(\.moreCount), [0, 0, 1, 0])
        XCTAssertEqual(four.items[3].leadingFraction, 2.0 / 3, accuracy: 1e-9, "a hidden one sits under the third")

        let five = stacked(5)
        XCTAssertEqual(five.items.map(\.isHidden), [false, false, false, true, true])
        XCTAssertEqual(five.items.map(\.moreCount), [0, 0, 2, 0, 0])
    }

    /// A chain of overlaps is one group sharing one count; a column frees up once its event has ended.
    func testAChainOfOverlapsSharesColumnsAsTheyFreeUp() {
        let events = [("a", "9:00", "10:00"), ("b", "9:30", "10:30"), ("c", "10:15", "11:00"), ("d", "12:00", "13:00")]
            .map { id, start, end in
                CalendarEvent(id: id, accountID: CalendarFitSample.gmail, providerID: id, title: id,
                              start: sample.date(0, start), end: sample.date(0, end))
            }
        let fit = CalendarFit(days: [sample.day(0)], events: events, height: 500, width: 196, calendar: sample.calendar)
        XCTAssertEqual(fit.items.map(\.eventID), ["a", "b", "c", "d"])
        XCTAssertEqual(fit.items.map(\.column), [0, 1, 0, 0])
        XCTAssertEqual(fit.items.map(\.columnCount), [2, 2, 2, 1], "d starts after the group's end: a group of its own")
    }

    /// Two five-minute events ten minutes apart overlap by what is drawn (each is a line tall), so they sit side by
    /// side instead of covering each other.
    func testShortEventsOverlapByTheLineTheyDraw() {
        let events = [("a", "10:00", "10:05"), ("b", "10:10", "10:15"), ("c", "11:00", "11:05")].map { id, start, end in
            CalendarEvent(id: id, accountID: CalendarFitSample.gmail, providerID: id, title: id,
                          start: sample.date(0, start), end: sample.date(0, end))
        }
        let fit = CalendarFit(days: [sample.day(0)], events: events, height: 450, width: 196, calendar: sample.calendar)
        XCTAssertLessThan(fit.hourHeight, 18 * 6, "a line covers more than ten minutes at this height")
        XCTAssertEqual(fit.items.map(\.column), [0, 1, 0])
        XCTAssertEqual(fit.items.map(\.columnCount), [2, 2, 1])
        XCTAssertEqual(fit.items.map(\.height), [18, 18, 18])
    }

    // MARK: What is drawn

    /// Declined events and events being deleted are never drawn; free ones are, without opening anything special.
    func testOnlyShownEventsAreLaidOut() {
        func event(_ id: String, response: CalendarEvent.Response = .accepted, sync: CalendarEvent.Sync = .synced,
                   free: Bool = false) -> CalendarEvent {
            CalendarEvent(id: id, accountID: CalendarFitSample.gmail, providerID: id, title: id,
                          start: sample.date(0, "20:00"), end: sample.date(0, "21:00"), response: response,
                          isFree: free, sync: sync)
        }
        let hidden = CalendarFit(days: [sample.day(0)], events: [event("no", response: .declined),
                                                                  event("gone", sync: .deleting)],
                                 height: 450, width: 196, calendar: sample.calendar)
        XCTAssertTrue(hidden.items.isEmpty)
        XCTAssertEqual(runs(hidden), [9..<18], "a declined evening does not open the evening")

        let shown = CalendarFit(days: [sample.day(0)], events: [event("free", free: true), event("new", sync: .creating),
                                                                 event("bad", sync: .failed)],
                                height: 450, width: 196, calendar: sample.calendar)
        XCTAssertEqual(Set(shown.items.map(\.eventID)), ["free", "new", "bad"])
        XCTAssertEqual(runs(shown), [9..<18, 20..<21])
    }

    // MARK: Coordinates

    /// y and minute convert both ways; a fold reads as the hour after it, the fold to midnight as half an hour before
    /// it; drops snap to the quarter hour and never start past 23:30.
    func testYAndMinuteConvertBothWays() throws {
        let fit = sample.column(3, window: 600)
        XCTAssertEqual(fit.y(forMinute: 0), 0)
        XCTAssertEqual(fit.y(forMinute: 300), 0, "a minute inside the morning fold sits at its top")
        XCTAssertEqual(fit.y(forMinute: 480), 14, accuracy: accuracy)
        XCTAssertEqual(fit.y(forMinute: 481), 14.7033, accuracy: 0.0001)
        XCTAssertEqual(fit.y(forMinute: 540), 56.2, accuracy: accuracy)
        XCTAssertEqual(fit.y(forMinute: 600), 98.4, accuracy: accuracy)
        XCTAssertEqual(fit.y(forMinute: 1_080), 436, accuracy: accuracy)
        XCTAssertEqual(fit.y(forMinute: 1_439), 436, accuracy: accuracy)
        XCTAssertEqual(fit.y(forMinute: 1_440), 450, accuracy: accuracy)

        XCTAssertEqual(fit.minute(atY: 0), 480, "the morning fold reads as 08:00, where the hours start")
        XCTAssertEqual(fit.minute(atY: 13.9), 480)
        XCTAssertEqual(fit.minute(atY: 14) ?? 0, 480, accuracy: accuracy)
        XCTAssertEqual(fit.minute(atY: 35.1) ?? 0, 510, accuracy: accuracy)
        XCTAssertEqual(fit.minute(atY: 100) ?? 0, 602.2749, accuracy: 0.0001)
        XCTAssertEqual(fit.minute(atY: 449), 1_050, "the fold to midnight reads as 17:30")
        XCTAssertNil(fit.minute(atY: 450))
        XCTAssertNil(fit.minute(atY: -1))
        for y in stride(from: 14.0, to: 436, by: 7.3) {
            let minute = try XCTUnwrap(fit.minute(atY: y))
            XCTAssertEqual(fit.y(forMinute: minute), y, accuracy: 1e-9, "round trip at \(y)")
        }

        XCTAssertEqual(fit.snappedMinute(atY: 30), 510)
        XCTAssertEqual(fit.snappedMinute(atY: 35.1), 510)
        XCTAssertEqual(fit.snappedMinute(atY: 100), 600)
        XCTAssertEqual(fit.snappedMinute(atY: 449), 1_050)
        XCTAssertNil(fit.snappedMinute(atY: 451))

        let whole = CalendarFit(days: [sample.day(5)], events: [], height: 2_000, width: 196, calendar: sample.calendar)
        XCTAssertEqual(whole.snappedMinute(atY: whole.hoursHeight - 1), 1_410, "a drop never starts past 23:30")

        XCTAssertEqual(fit.date(atMinute: 510, onDay: 0), sample.date(3, "8:30"))
        XCTAssertNil(fit.date(atMinute: 510, onDay: 1))
        XCTAssertEqual(fit.locate(sample.now)?.dayIndex, 0)
        XCTAssertEqual(fit.locate(sample.now)?.minute, 11 * 60 + 40)
        XCTAssertNil(fit.locate(sample.date(4, "11:40")))
    }

    /// A drop on the week finds its day by x; a folded day takes none.
    func testTheWeekFindsTheDayUnderAPoint() {
        let fit = sample.weekFit(0, window: 800)
        XCTAssertEqual(fit.dayIndex(atX: 0), 0)
        XCTAssertEqual(fit.dayIndex(atX: 123.9), 0)
        XCTAssertEqual(fit.dayIndex(atX: 124), 1)
        XCTAssertNil(fit.dayIndex(atX: 630), "the folded Saturday")
        XCTAssertEqual(fit.dayIndex(atX: 700), 6)
        XCTAssertNil(fit.dayIndex(atX: 772))
        XCTAssertNil(fit.dayIndex(atX: -1))
        XCTAssertEqual(fit.date(atMinute: 915, onDay: 6), sample.date(6, "15:15"))
        let ghost = fit.span(of: DateInterval(start: sample.date(6, "15:15"), duration: 1_800), onDay: 6,
                             minimumHeight: 18)
        XCTAssertEqual(ghost?.height ?? 0, fit.hourHeight / 2, accuracy: accuracy)
        XCTAssertNil(fit.span(of: DateInterval(start: sample.date(6, "15:15"), duration: 1_800), onDay: 5))
    }

    // MARK: Weekends

    private func emptyWeek(from first: Date, calendar: Calendar) -> [Date] {
        (0..<7).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }

    /// A week that starts on Sunday folds its first and last days; the locale's weekend decides, wherever it falls.
    func testTheWeekendIsTheLocalesWhereverTheWeekStarts() {
        var us = sample.calendar
        us.locale = Locale(identifier: "en_US")
        us.firstWeekday = 1
        let sunday = sample.day(-1)
        let fit = CalendarFit(days: emptyWeek(from: sunday, calendar: us), events: [], height: 600, width: 700,
                              calendar: us)
        XCTAssertEqual(fit.days.map(\.isFolded), [true, false, false, false, false, false, true])
        XCTAssertEqual(fit.days[1].width, (700 - 56) / 5.0, accuracy: 1e-9)

        var israel = sample.calendar
        israel.locale = Locale(identifier: "he_IL")
        israel.firstWeekday = 1
        let friday = CalendarFit(days: emptyWeek(from: sunday, calendar: israel), events: [], height: 600, width: 700,
                                 calendar: israel)
        XCTAssertEqual(friday.days.map(\.isFolded), [false, false, false, false, false, true, true],
                       "Friday and Saturday where the weekend is Friday and Saturday")
    }

    /// A weekend day folds only when nothing is on it: no timed event, mark or all-day event.
    func testAWeekendDayWithAnythingOnItKeepsItsWidth() {
        let week = sample.week(5)
        let base = CalendarFit(days: week, events: [], height: 600, width: 700, calendar: sample.calendar)
        XCTAssertEqual(base.days.map(\.isFolded), [false, false, false, false, false, true, true])

        let mark = CalendarFit(days: week, events: [], marks: [CalendarFit.Mark(id: "later", start: sample.date(40, "8:00"))],
                               height: 600, width: 700, calendar: sample.calendar)
        XCTAssertEqual(mark.days.map(\.isFolded), [false, false, false, false, false, false, true],
                       "a Later return on Saturday keeps it")
        XCTAssertEqual(runs(mark), [8..<18])

        let allDay = CalendarEvent(id: "trip", accountID: CalendarFitSample.gmail, providerID: "trip", title: "Trip",
                                   start: CalendarFitSample.floating(2026, 12, 27),
                                   end: CalendarFitSample.floating(2026, 12, 28), isAllDay: true)
        let sunday = CalendarFit(days: week, events: [allDay], height: 600, width: 700, calendar: sample.calendar)
        XCTAssertEqual(sunday.days.map(\.isFolded), [false, false, false, false, false, true, false])
        XCTAssertEqual(sunday.allDay[6].shown.map(\.id), ["trip"])
    }

    /// The column shows one day, which never folds, and a run of days that are all weekend keeps its width.
    func testASingleDayOrAnAllWeekendRunNeverFolds() {
        let saturday = CalendarFit(days: [sample.day(5)], events: [], height: 600, width: 196, calendar: sample.calendar)
        XCTAssertEqual(saturday.days.map(\.isFolded), [false])
        XCTAssertEqual(saturday.days[0].width, 196)

        let weekend = CalendarFit(days: [sample.day(5), sample.day(6)], events: [], height: 600, width: 196,
                                  calendar: sample.calendar)
        XCTAssertEqual(weekend.days.map(\.isFolded), [false, false])
        XCTAssertEqual(weekend.days.map(\.width), [98, 98])
    }

    // MARK: Performance (PAPER_PERF=1)

    /// The week on screen within 50 ms of W is the store read plus this fit; 300 events over a week must fit in a
    /// tenth of that. `PAPER_PERF=1 swift test -c release --filter CalendarFitTests`.
    func testFittingThreeHundredEventsOverAWeekIsFast() throws {
        guard ProcessInfo.processInfo.environment["PAPER_PERF"] == "1" else {
            throw XCTSkip("set PAPER_PERF=1 to run the timing assertion")
        }
        var seed: UInt64 = 0x5eed
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let accounts = [CalendarFitSample.northwind, CalendarFitSample.contoso, CalendarFitSample.gmail]
        let events = (0..<300).map { index -> CalendarEvent in
            let start = sample.date(next(7), "\(6 + next(15)):\([0, 15, 30, 45][next(4)])")
            let allDay = index % 40 == 0
            return CalendarEvent(id: "p\(index)", accountID: accounts[index % 3], providerID: "p\(index)",
                                 title: "Event \(index)",
                                 start: allDay ? CalendarFitSample.floating(2026, 11, 16 + next(7)) : start,
                                 end: allDay ? CalendarFitSample.floating(2026, 11, 24)
                                     : start.addingTimeInterval(Double(15 + next(8) * 15) * 60),
                                 isAllDay: allDay, response: index % 9 == 0 ? .needsAction : .accepted)
        }
        let week = sample.week(0)
        _ = CalendarFit(days: week, events: events, marks: sample.marks, height: 664, width: 772, calendar: sample.calendar)
        let runs = 20
        let begin = DispatchTime.now()
        var placed = 0
        for _ in 0..<runs {
            let fit = CalendarFit(days: week, events: events, marks: sample.marks, height: 664, width: 772,
                                  calendar: sample.calendar)
            placed += fit.items.count
        }
        let each = Double(DispatchTime.now().uptimeNanoseconds - begin.uptimeNanoseconds) / 1e9 / Double(runs)
        XCTAssertGreaterThan(placed, 250 * runs)
        XCTAssertLessThan(each, 0.005, "fitting 300 events over a week took \(each * 1000) ms")
    }
}
