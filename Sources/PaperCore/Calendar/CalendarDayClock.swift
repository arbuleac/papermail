import Foundation

/// One local day read by its wall clock, as the calendar's grid draws it: minutes run from 0 at the day's start to
/// 1,440 at the next day's start whatever the clock does in between, so a day with a clock change still fills
/// 00:00 to 24:00 (the hour the clock skips takes no room; the hour it repeats is drawn once, its two passes on top of
/// each other) and every day of a week lines up on the same hours.
///
/// Built once per shown day; reading a minute is arithmetic on the zone's offsets rather than a calendar query, so a
/// fit of a few hundred events stays far inside its budget.
struct CalendarDayClock: Sendable {
    /// The day's first instant (`Calendar.startOfDay`).
    let start: Date
    /// The next day's first instant: exclusive.
    let end: Date
    /// The date's midnight held as UTC, which is how an all-day event names its dates (floating, as
    /// `CalendarEvent.start` documents), so an all-day event is matched by date wherever the Mac is.
    let floatingDate: Date
    private let zone: TimeZone
    private let startOffset: Int
    /// The wall-clock minute of `start`: 0, except in a zone whose clock skips midnight itself, where the day begins
    /// at the first minute after the gap.
    private let startMinute: Double

    init(day: Date, calendar: Calendar, floatingCalendar: Calendar) {
        let start = calendar.startOfDay(for: day)
        self.start = start
        end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        zone = calendar.timeZone
        startOffset = calendar.timeZone.secondsFromGMT(for: start)
        let time = calendar.dateComponents([.hour, .minute, .second], from: start)
        startMinute = Double((time.hour ?? 0) * 60 + (time.minute ?? 0)) + Double(time.second ?? 0) / 60
        floatingDate = floatingCalendar.date(from: calendar.dateComponents([.era, .year, .month, .day], from: start))
            ?? start
    }

    /// `calendar` read in UTC: how a floating date (an all-day event's) is turned into its instant.
    static func floatingCalendar(like calendar: Calendar) -> Calendar {
        var floating = calendar
        floating.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return floating
    }

    var interval: DateInterval { DateInterval(start: start, end: end) }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// The wall-clock minute `date` shows on this day: the day's first minute for anything before it, 1,440 for
    /// anything at or after its end, so a part of an event that crosses midnight is cut at the day's edge.
    func minute(of date: Date) -> Double {
        if date <= start { return startMinute }
        if date >= end { return 1_440 }
        let wall = date.timeIntervalSince(start) + Double(zone.secondsFromGMT(for: date) - startOffset)
        return min(1_440, max(0, startMinute + wall / 60))
    }

    /// The part of `start..<end` that falls on this day, in wall-clock minutes. Inside the hour a clock repeats, the
    /// wall clock can run backwards (01:30 summer time to 01:15 winter time); the part then keeps its real length
    /// from its start rather than turning inside out.
    func minutes(from start: Date, to end: Date) -> (start: Double, end: Double) {
        let first = minute(of: start)
        var last = minute(of: end)
        if last <= first, end > start, end < self.end {
            last = min(1_440, first + end.timeIntervalSince(max(start, self.start)) / 60)
        }
        return (first, max(first, last))
    }

    /// The instant this day's wall clock shows `minute` at. A minute the clock skips reads as the same distance past
    /// the gap (Foundation's rule); a minute it repeats reads as its first pass.
    func date(atMinute minute: Double, calendar: Calendar) -> Date {
        if minute >= 1_440 { return end }
        let seconds = Int((max(0, minute) * 60).rounded())
        var parts = calendar.dateComponents([.era, .year, .month, .day], from: start)
        parts.hour = seconds / 3_600
        parts.minute = seconds % 3_600 / 60
        parts.second = seconds % 60
        return calendar.date(from: parts) ?? start.addingTimeInterval(Double(seconds) - startMinute * 60)
    }
}

/// What a run of shown days holds, read once from the events and marks: each day's clock, the parts of timed events
/// that fall on it, its all-day events and its marks. The fit, the day cells and the free-time answers all start
/// from it, so they agree on what is on a day.
struct CalendarDayContent: Sendable {
    /// A timed event's part on one day.
    struct Part: Sendable {
        var event: CalendarEvent
        var start: Double
        var end: Double
        var startsBefore: Bool
        var endsAfter: Bool
    }

    /// A mark on the day of its instant.
    struct PlacedMark: Sendable {
        var mark: CalendarFit.Mark
        var minute: Double
        /// Where the hours it must keep visible end: its instant plus its span, cut at the day's end.
        var end: Double
    }

    let clocks: [CalendarDayClock]
    var parts: [[Part]]
    var allDay: [[CalendarEvent]]
    var marks: [[PlacedMark]]

    init(days: [Date], events: [CalendarEvent], marks: [CalendarFit.Mark], calendar: Calendar) {
        let floating = CalendarDayClock.floatingCalendar(like: calendar)
        let clocks = days.map { CalendarDayClock(day: $0, calendar: calendar, floatingCalendar: floating) }
        self.clocks = clocks
        var parts = [[Part]](repeating: [], count: clocks.count)
        var allDay = [[CalendarEvent]](repeating: [], count: clocks.count)
        for event in events where event.isShown {
            if event.isAllDay {
                // Floating dates: the event covers each date whose UTC midnight lies in [start, end); an event of no
                // length still marks the date it starts on.
                let end = max(event.end, event.start.addingTimeInterval(1))
                for index in clocks.indices where clocks[index].floatingDate >= event.start
                    && clocks[index].floatingDate < end {
                    allDay[index].append(event)
                }
                continue
            }
            for index in clocks.indices where event.overlaps(clocks[index].interval) {
                let clock = clocks[index]
                let minutes = clock.minutes(from: event.start, to: event.end)
                parts[index].append(Part(event: event, start: minutes.start, end: minutes.end,
                                         startsBefore: event.start < clock.start, endsAfter: event.end > clock.end))
            }
        }
        for index in allDay.indices where allDay[index].count > 1 {
            allDay[index].sort { a, b in
                if a.start != b.start { return a.start < b.start }
                if a.end != b.end { return a.end > b.end }
                return a.id < b.id
            }
        }
        var placed = [[PlacedMark]](repeating: [], count: clocks.count)
        for mark in marks {
            guard let index = clocks.firstIndex(where: { $0.contains(mark.start) }) else { continue }
            let minute = clocks[index].minute(of: mark.start)
            placed[index].append(PlacedMark(mark: mark, minute: minute,
                                            end: min(1_440, minute + max(0, mark.span) / 60)))
        }
        self.parts = parts
        self.allDay = allDay
        self.marks = placed
    }

    /// Nothing on the day: no timed part, no mark and no all-day event. Only such a weekend day folds in the week.
    func isEmpty(_ index: Int) -> Bool {
        parts[index].isEmpty && marks[index].isEmpty && allDay[index].isEmpty
    }

    /// The hours open before the fit shares the height: `core` always, and every hour any shown day holds a timed
    /// part or a mark in (an hour is open from the one a span starts in through the one it ends in; a span of no
    /// length opens the hour it sits in).
    func openHours(core: Range<Int>) -> [Bool] {
        var open = [Bool](repeating: false, count: 24)
        for hour in core where hour >= 0 && hour < 24 { open[hour] = true }
        func openSpan(_ start: Double, _ end: Double) {
            let first = max(0, Int((start / 60).rounded(.down)))
            var last = min(24, Int((end / 60).rounded(.up)))
            if last <= first { last = min(24, first + 1) }
            guard first < last else { return }
            for hour in first..<last { open[hour] = true }
        }
        for day in parts.indices {
            for part in parts[day] { openSpan(part.start, part.end) }
            for mark in marks[day] { openSpan(mark.minute, mark.end) }
        }
        return open
    }
}
