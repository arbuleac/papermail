import Foundation
@testable import PaperCore

/// The approved concept page's sample (its mock's `EV`, `MARKS` and `ROWS`), ported so the fit can be checked against
/// the numbers the page shows: three accounts, the week of Monday 16 November 2026 and the weeks around it, "now"
/// Thursday 19 November 11:40, an invitation from mail on Thursday 13:00 - 14:00, a Later return and a Send Later
/// time. Days are counted from that Monday, as the mock counts them; event ids are the mock's (`e1`...).
///
/// The page measures its window: the column's fit gets the window's height less the header (92), the day cells (48)
/// and a 10 pt foot; the week's, the height less the header, the day headings (34) and the foot. The week is as wide
/// as the reader and the column together (832 at the 1,280 window) less its 48 pt gutter and 12 pt trailing inset.
struct CalendarFitSample {
    static let northwind = AccountID("nw")
    static let contoso = AccountID("ct")
    static let gmail = AccountID("me")

    let calendar: Calendar
    let events: [CalendarEvent]
    let pencil: CalendarEvent
    let marks: [CalendarFit.Mark]
    let now: Date

    /// The column's fit height in a window `height` tall.
    static func columnHeight(window height: Double) -> Double { height - 92 - 48 - 10 }
    /// The week's fit height in a window `height` tall.
    static func weekHeight(window height: Double) -> Double { height - 92 - 34 - 10 }
    /// The week's days' width in the 1,280 pt window.
    static let weekWidth = 832.0 - 48 - 12

    init(zone: String = "Europe/Bucharest", locale: String = "en_GB") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: locale)
        calendar.firstWeekday = 2
        self.calendar = calendar
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16))!

        func at(_ day: Int, _ time: String) -> Date { Self.date(day, time, from: monday, calendar: calendar) }
        var events: [CalendarEvent] = []
        func event(_ day: Int, _ start: String, _ end: String, _ title: String, _ account: AccountID) {
            let id = "e\(events.count + 1)"
            events.append(CalendarEvent(id: id, accountID: account, providerID: id, title: title,
                                        start: at(day, start), end: at(day, end)))
        }
        func allDay(_ day: Int, _ title: String, _ account: AccountID) {
            let id = "e\(events.count + 1)"
            let date = calendar.dateComponents([.year, .month, .day], from: at(day, "12:00"))
            let start = Self.floating(date.year!, date.month!, date.day!)
            events.append(CalendarEvent(id: id, accountID: account, providerID: id, title: title, start: start,
                                        end: start.addingTimeInterval(86_400), isAllDay: true))
        }
        let nw = Self.northwind, ct = Self.contoso, me = Self.gmail
        for week in -1...3 { for day in 0..<5 { event(7 * week + day, "9:30", "9:45", "Standup", nw) } }
        event(-7, "13:00", "14:00", "Interview: frontend", nw)
        event(-5, "15:00", "16:00", "Roadmap prep", nw)
        event(-4, "11:00", "11:30", "Contract call", ct)
        event(-3, "19:00", "22:00", "Dinner at Ana's", me)
        event(-2, "9:00", "10:30", "Farmers market", me)
        event(0, "11:00", "12:00", "Hiring sync", nw)
        event(0, "14:00", "15:30", "Design critique", nw)
        event(1, "12:30", "13:30", "Lunch with Priya", me)
        event(1, "16:00", "17:00", "Vendor call", ct)
        event(2, "10:00", "11:30", "Q1 planning", nw)
        event(2, "15:00", "15:30", "Dentist", me)
        event(3, "8:00", "8:45", "Gym", me)
        event(3, "10:30", "11:00", "Contract review", ct)
        event(3, "13:30", "14:00", "1:1 with Sam", nw)
        event(3, "17:00", "18:00", "Contoso QBR", ct)
        event(4, "11:00", "12:00", "Customer interview", ct)
        event(4, "18:30", "20:00", "Concert", me)
        event(6, "12:30", "14:00", "Family lunch", me)
        allDay(2, "Ana's birthday", me)
        allDay(4, "Release freeze", nw)
        event(7, "10:00", "11:00", "Offsite prep", nw)
        event(7, "16:00", "16:30", "Expenses", ct)
        event(8, "14:00", "15:00", "Board dry run", nw)
        event(9, "12:00", "13:00", "Lunch and learn", ct)
        allDay(10, "Thanksgiving, US office closed", ct)
        event(11, "17:30", "19:00", "Team drinks", nw)
        event(12, "10:00", "12:00", "Climbing", me)
        allDay(17, "Offsite", nw)
        allDay(18, "Offsite", nw)
        event(15, "11:00", "12:00", "Quarterly review", ct)
        event(16, "15:00", "16:00", "Physio", me)
        event(21, "10:00", "11:00", "Planning retro", nw)
        self.events = events

        let invitation = CalendarInvitation(method: .request, uid: "roadmap-review@northwind.test",
                                            title: "Roadmap review", start: at(3, "13:00"), end: at(3, "14:00"),
                                            location: "Bay 4")
        pencil = CalendarFit.pencil(for: invitation, message: MessageID(accountID: nw, providerID: "r1"),
                                    timeZone: calendar.timeZone)!
        marks = [
            CalendarFit.Mark(id: "m1", start: at(4, "17:00")),
            CalendarFit.Mark(id: "m2", start: at(3, "16:00")),
        ]
        now = at(3, "11:40")
        self.monday = monday
    }

    private let monday: Date

    private static func date(_ day: Int, _ time: String, from monday: Date, calendar: Calendar) -> Date {
        let parts = time.split(separator: ":").map { Int($0)! }
        let date = calendar.date(byAdding: .day, value: day, to: monday)!
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date)!
    }

    /// `time` ("13:30") on the day `day` days after Monday 16 November.
    func date(_ day: Int, _ time: String) -> Date { Self.date(day, time, from: monday, calendar: calendar) }

    /// The start of the day `day` days after Monday 16 November.
    func day(_ day: Int) -> Date { calendar.date(byAdding: .day, value: day, to: monday)! }

    /// The seven days of week `week` (0 is the week of 16 November).
    func week(_ week: Int) -> [Date] { (0..<7).map { day(7 * week + $0) } }

    /// What the calendar draws: the events and the selected mail's pencil.
    var drawn: [CalendarEvent] { events + [pencil] }

    /// A time found in the selected mail: marked with the 30 minutes B would set aside.
    func mailTime(_ id: String, _ day: Int, _ time: String) -> CalendarFit.Mark {
        CalendarFit.Mark(id: id, start: date(day, time), span: 30 * 60)
    }

    /// The column's fit of `day` in a window `height` tall.
    func column(_ day: Int, window height: Double, marks extra: [CalendarFit.Mark] = []) -> CalendarFit {
        CalendarFit(days: [self.day(day)], events: drawn, marks: marks + extra,
                    height: Self.columnHeight(window: height), width: 240 - 36 - 8, calendar: calendar)
    }

    /// The week's fit of week `week` in a window `height` tall.
    func weekFit(_ week: Int, window height: Double, marks extra: [CalendarFit.Mark] = []) -> CalendarFit {
        CalendarFit(days: self.week(week), events: drawn, marks: marks + extra,
                    height: Self.weekHeight(window: height), width: Self.weekWidth, calendar: calendar)
    }

    /// Midnight UTC of a date: how an all-day event holds it.
    static func floating(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
