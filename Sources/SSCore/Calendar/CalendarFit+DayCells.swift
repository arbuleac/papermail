import Foundation

/// The seven day cells over the day column: each a small timeline of that day's busy time in account inks, so a full
/// day shows without opening the week.
extension CalendarFit {
    /// One day's cell.
    public struct DayCell: Hashable, Sendable {
        /// A busy event's part on the cell's track.
        public struct Segment: Hashable, Sendable {
            public var eventID: String
            /// Whose ink it takes.
            public var accountID: AccountID
            /// Its start as a share of the track, 0 to 1.
            public var start: Double
            /// Its length as a share of the track: at least `minimumSegmentWidth`, so a quarter hour still shows.
            public var width: Double
            /// Not answered yet (an invitation): drawn as an outline, as the calendar pencils it.
            public var isHollow: Bool
        }

        public var day: Date
        /// By start (longer first, then id).
        public var segments: [Segment]
        /// The day's first all-day event: the line drawn above the track in its account's ink. Nil without one.
        public var allDay: CalendarEvent?
    }

    /// The least share of a track a segment takes.
    public static let minimumSegmentWidth = 0.04

    /// The cells of `days` (the week the column's day is in). Every track spans the same hours: from the first hour
    /// open to the end of the last one, as the week's fit opens them before it shares any height (the working day,
    /// widened to whatever any of the seven days holds, marks included), so the cells line up with one another
    /// whatever the window's height. Only busy events show (`CalendarEvent.isBusy`); pass the selected mail's pencil
    /// among `events` for its outline.
    public static func dayCells(
        days: [Date],
        events: [CalendarEvent],
        marks: [Mark] = [],
        calendar: Calendar,
        metrics: Metrics = .standard
    ) -> [DayCell] {
        let content = CalendarDayContent(days: days, events: events, marks: marks, calendar: calendar)
        let open = content.openHours(core: metrics.coreHours)
        let first = Double((open.firstIndex(of: true) ?? 0) * 60)
        let last = Double(((open.lastIndex(of: true) ?? 23) + 1) * 60)
        let range = max(1, last - first)

        return content.clocks.indices.map { index in
            let segments = content.parts[index]
                .filter { $0.event.isBusy }
                .sorted { a, b in
                    if a.start != b.start { return a.start < b.start }
                    if a.end != b.end { return a.end > b.end }
                    return a.event.id < b.event.id
                }
                .map { part -> DayCell.Segment in
                    let width = max(minimumSegmentWidth, (min(part.end, last) - max(part.start, first)) / range)
                    let start = min(max(0, (part.start - first) / range), max(0, 1 - width))
                    return DayCell.Segment(eventID: part.event.id, accountID: part.event.accountID, start: start,
                                           width: min(1, width), isHollow: part.event.response == .needsAction)
                }
            return DayCell(day: content.clocks[index].start, segments: segments, allDay: content.allDay[index].first)
        }
    }
}
