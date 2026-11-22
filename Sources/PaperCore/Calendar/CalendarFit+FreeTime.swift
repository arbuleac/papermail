import Foundation

/// Free time in a day, for B (time set aside for a mail) and for a row dropped on a day cell: the first free half
/// hour of the working day that is still ahead.
extension CalendarFit {
    /// The free stretches of `day` between the working hours (09:00 to 18:00) that last at least `minimum`, earliest
    /// first. Only `CalendarEvent.isBusy` events take time: free, declined and all-day events do not, and an
    /// unanswered invitation does (pass the selected mail's pencil among `events` when it should count too).
    ///
    /// Each stretch starts on a quarter hour: today's no earlier than now (rounded up), a later day's at the working
    /// day's start, and after a busy event at the quarter hour it ends in. A day before today has none.
    public static func freeSlots(
        on day: Date,
        events: [CalendarEvent],
        now: Date,
        calendar: Calendar,
        hours: Range<Int> = Metrics.standard.coreHours,
        minimum: TimeInterval = 30 * 60
    ) -> [DateInterval] {
        let clock = CalendarDayClock(day: day, calendar: calendar,
                                     floatingCalendar: CalendarDayClock.floatingCalendar(like: calendar))
        let today = calendar.startOfDay(for: now)
        guard clock.start >= today else { return [] }

        let least = minimum / 60
        let close = Double(hours.upperBound * 60)
        var from = Double(hours.lowerBound * 60)
        if clock.contains(now) { from = max(from, quarterHourUp(clock.minute(of: now))) }

        let busy = events
            .filter { $0.isBusy && $0.overlaps(clock.interval) }
            .map { clock.minutes(from: $0.start, to: $0.end) }
            .sorted { $0.start < $1.start }
        var slots: [(start: Double, end: Double)] = []
        for taken in busy {
            guard from < close else { break }
            if taken.start > from {
                let end = min(taken.start, close)
                if end - from >= least { slots.append((from, end)) }
            }
            from = max(from, quarterHourUp(taken.end))
        }
        if close - from >= least { slots.append((from, close)) }
        return slots.map {
            DateInterval(start: clock.date(atMinute: $0.start, calendar: calendar),
                         end: clock.date(atMinute: $0.end, calendar: calendar))
        }
    }

    /// The start of `day`'s first free half hour (`freeSlots`), or nil when the day has none left: where a row
    /// dropped on that day's cell sets time aside.
    public static func firstFreeHalfHour(
        on day: Date,
        events: [CalendarEvent],
        now: Date,
        calendar: Calendar,
        hours: Range<Int> = Metrics.standard.coreHours
    ) -> Date? {
        freeSlots(on: day, events: events, now: now, calendar: calendar, hours: hours).first?.start
    }

    /// Where B sets time aside when the mail names no time: the first free half hour of `day` (the day the column
    /// shows, or today), else of the days after it, looking `searchDays` days ahead. Weekend days are skipped, except
    /// `day` itself when `dayIsShown` (the user is looking at it). A day before today starts the search at today.
    public static func firstFreeHalfHour(
        searchingFrom day: Date,
        dayIsShown: Bool,
        events: [CalendarEvent],
        now: Date,
        calendar: Calendar,
        hours: Range<Int> = Metrics.standard.coreHours,
        searchDays: Int = 21
    ) -> Date? {
        let asked = calendar.startOfDay(for: day)
        var current = max(asked, calendar.startOfDay(for: now))
        for _ in 0..<max(0, searchDays) {
            let weekend = calendar.isDateInWeekend(current)
            if !weekend || (dayIsShown && current == asked),
               let start = firstFreeHalfHour(on: current, events: events, now: now, calendar: calendar, hours: hours) {
                return start
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { return nil }
            current = calendar.startOfDay(for: next)
        }
        return nil
    }

    /// The quarter hour at or after `minute`.
    static func quarterHourUp(_ minute: Double) -> Double {
        (minute / 15).rounded(.up) * 15
    }
}
