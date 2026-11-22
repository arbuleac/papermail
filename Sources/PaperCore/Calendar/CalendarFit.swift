import Foundation

/// The day column's and the week's fitted layout (Quire "Day and week"): which hours are open, where the closed runs
/// fold, how many points an hour gets, and where each event, all-day chip and mark goes, for one day (the column and
/// its strip) or seven (the week). Arithmetic only, over what the store holds and without AppKit, so the views just
/// draw it, the fit can be tested on its own, and it can run again on every change of the window, the day or the
/// events (the store read plus this fit of up to 300 events must land in 50 ms; docs/ARCHITECTURE.md).
///
/// Nothing scrolls, so the hours are fitted to the height rather than the height to the hours:
/// 1. The core hours (09:00 to 18:00) are always open, and so is every hour that holds an event, an invitation, a
///    mark or a time from the selected mail on any shown day.
/// 2. Every run of closed hours folds into one band (14 pt) that names its range: nothing is ever inside a fold.
/// 3. The open hours share what is left, at most 64 pt an hour; while they would get more, one more hour opens,
///    before the open ones and after them in turn, so a quiet day widens its working day instead of stretching it.
/// 4. The floor is 16 pt an hour: all 24 hours and two rows of all-day events in the column of a 600 pt window.
///
/// Coordinates: y is points down from the top of the hours (the all-day band, `allDayHeight` tall, sits above them
/// inside the `height` the fit was given); x is points from the leading edge of the first day (the hour gutter is the
/// caller's). Minutes are wall-clock minutes from the day's start, 0 to 1,440 (`CalendarDayClock`), so a day with a
/// clock change still runs 00:00 to 24:00 and every day of the week lines up on the same hours.
public struct CalendarFit: Sendable {
    /// The fit's constants (Quire `layout.calendarPane`). `standard` is the approved design; tests and the strip
    /// use it as is.
    public struct Metrics: Hashable, Sendable {
        /// Always open, whatever the days hold: the working day.
        public var coreHours: Range<Int>
        /// A run of closed hours, folded.
        public var foldHeight: Double
        public var minHourHeight: Double
        public var maxHourHeight: Double
        /// An event shorter than a line still gets one line, and overlaps by what it draws, not by its minutes.
        public var minEventHeight: Double
        /// Events that overlap sit side by side up to this many; the rest are hidden behind "+N" on the last one.
        public var maxColumns: Int
        /// An empty weekend day in the week.
        public var foldedDayWidth: Double
        /// One all-day row: an 18 pt chip and the 4 pt gap below it.
        public var allDayRowHeight: Double
        /// What the all-day band adds around its rows, when it has any.
        public var allDayBandPadding: Double
        /// All-day rows shown; a day with more says "+N".
        public var maxAllDayRows: Int

        public init(
            coreHours: Range<Int> = 9..<18,
            foldHeight: Double = 14,
            minHourHeight: Double = 16,
            maxHourHeight: Double = 64,
            minEventHeight: Double = 18,
            maxColumns: Int = 3,
            foldedDayWidth: Double = 28,
            allDayRowHeight: Double = 22,
            allDayBandPadding: Double = 6,
            maxAllDayRows: Int = 2
        ) {
            self.coreHours = coreHours
            self.foldHeight = foldHeight
            self.minHourHeight = minHourHeight
            self.maxHourHeight = maxHourHeight
            self.minEventHeight = minEventHeight
            self.maxColumns = max(1, maxColumns)
            self.foldedDayWidth = foldedDayWidth
            self.allDayRowHeight = allDayRowHeight
            self.allDayBandPadding = allDayBandPadding
            self.maxAllDayRows = max(0, maxAllDayRows)
        }

        public static let standard = Metrics()
    }

    /// An instant the calendar must show without being an event: a Later return, a Send Later time, a time found in
    /// the selected mail. It opens the hours from its instant through `span` after it (cut at the end of its day), and
    /// a weekend day holding one never folds.
    public struct Mark: Hashable, Sendable {
        public var id: String
        public var start: Date
        /// How long after `start` must stay visible: a minute for a return or a send, 30 minutes (or the length the
        /// text names) for a time found in mail, where B would set the time aside.
        public var span: TimeInterval

        public init(id: String, start: Date, span: TimeInterval = 60) {
            self.id = id
            self.start = start
            self.span = span
        }
    }

    /// A shown day and where it sits across the width.
    public struct Day: Hashable, Sendable {
        /// The day's first instant in the fit's calendar.
        public var start: Date
        public var x: Double
        public var width: Double
        /// An empty weekend day of the week, narrowed to `Metrics.foldedDayWidth`: it has nothing to lay out.
        public var isFolded: Bool
    }

    /// A run of closed hours, drawn as one band labelled with its range ("00:00 - 08:00").
    public struct Fold: Hashable, Sendable {
        /// The first closed hour.
        public var from: Int
        /// The hour after the last closed one (24 for a run to midnight).
        public var to: Int
        /// The band's top.
        public var y: Double
    }

    /// An event's part on one shown day, placed. An event that crosses midnight has one item on each shown day it
    /// touches, cut at the day's edge.
    public struct Item: Hashable, Sendable {
        public var event: CalendarEvent
        public var dayIndex: Int
        /// Wall-clock minutes of the part on this day.
        public var startMinute: Double
        public var endMinute: Double
        /// The event began on an earlier day (or ends on a later one): the view may square that edge.
        public var startsBeforeDay: Bool
        public var endsAfterDay: Bool
        public var top: Double
        /// At least `Metrics.minEventHeight`. An event that would hang below the hours is lifted to end with them.
        public var height: Double
        /// Its place among the events it overlaps (0 is leading). 3 and more are hidden.
        public var column: Int
        /// Side-by-side columns in its group of overlapping events, at most `Metrics.maxColumns`.
        public var columnCount: Int
        /// The fourth or later event side by side: not drawn; the third column's first event counts it.
        public var isHidden: Bool
        /// On the third column's first event of a group: how many hidden events "+N" stands for. 0 elsewhere.
        public var moreCount: Int

        public var eventID: String { event.id }

        /// The share of the day's width before the item, 0 to 1 (a hidden item sits where the last column does).
        public var leadingFraction: Double {
            Double(min(column, max(0, columnCount - 1))) / Double(max(1, columnCount))
        }

        /// The share of the day's width the item takes.
        public var widthFraction: Double { 1 / Double(max(1, columnCount)) }
    }

    /// A day's all-day events, in the band above the hours.
    public struct AllDay: Hashable, Sendable {
        /// Up to `Metrics.maxAllDayRows`, one a row, by start (longer first, then id).
        public var shown: [CalendarEvent]
        /// The day's other all-day events, which "+N" stands for.
        public var overflow: Int

        public var isEmpty: Bool { shown.isEmpty }
    }

    /// A mark on the day of its instant.
    public struct PlacedMark: Hashable, Sendable {
        public var id: String
        public var dayIndex: Int
        public var minute: Double
        public var y: Double
    }

    /// The shown days, in the order given, with their x and width.
    public let days: [Day]
    /// One flag an hour, 0 to 23.
    public let openHours: [Bool]
    public let folds: [Fold]
    /// Points an hour, the same for every open hour.
    public let hourHeight: Double
    /// The hours' height, folds included: the height given less the all-day band, unless the floor or the cap won.
    public let hoursHeight: Double
    /// All-day rows the band shows (0 when no shown day has an all-day event): the same for every day of the week.
    public let allDayRows: Int
    /// The band's height above the hours; 0 without rows.
    public let allDayHeight: Double
    /// Every placed item, day by day, each day's by start (longer first, then id).
    public let items: [Item]
    /// Parallel to `days`.
    public let allDay: [AllDay]
    /// Every mark on a shown day, day by day, in the order given.
    public let marks: [PlacedMark]
    public let metrics: Metrics

    private let grid: HourGrid
    private let clocks: [CalendarDayClock]
    private let calendar: Calendar

    /// Fits `days` (1 for the column or its strip, 7 for the week; any instant of each day will do) to `height`
    /// points (the all-day band and the hours: what lies under the day cells or the day headings) and `width` points
    /// (the days' width, without the hour gutter).
    ///
    /// `events` are drawn when `isShown`: timed ones in the hours, all-day ones in the band. An invitation drawn from
    /// mail goes in as an event of its own (`pencil(for:message:timeZone:response:)`). `marks` open their hours
    /// without being laid out. The calendar's zone reads the wall clock, and its locale decides which days are the
    /// weekend.
    public init(
        days: [Date],
        events: [CalendarEvent],
        marks: [Mark] = [],
        height: Double,
        width: Double,
        calendar: Calendar,
        metrics: Metrics = .standard
    ) {
        let content = CalendarDayContent(days: days, events: events, marks: marks, calendar: calendar)
        self.metrics = metrics
        self.calendar = calendar
        clocks = content.clocks

        let mostAllDay = content.allDay.map(\.count).max() ?? 0
        allDayRows = min(metrics.maxAllDayRows, mostAllDay)
        allDayHeight = allDayRows > 0 ? Double(allDayRows) * metrics.allDayRowHeight + metrics.allDayBandPadding : 0

        let grid = HourGrid(open: content.openHours(core: metrics.coreHours), room: height - allDayHeight,
                            metrics: metrics)
        self.grid = grid
        openHours = grid.open
        folds = grid.folds
        hourHeight = grid.hourHeight
        hoursHeight = grid.height

        self.days = Self.place(content: content, width: width, calendar: calendar, metrics: metrics)
        allDay = content.allDay.map { events in
            AllDay(shown: Array(events.prefix(metrics.maxAllDayRows)),
                   overflow: max(0, events.count - metrics.maxAllDayRows))
        }
        var items: [Item] = []
        items.reserveCapacity(content.parts.reduce(0) { $0 + $1.count })
        for (index, parts) in content.parts.enumerated() where !parts.isEmpty {
            items.append(contentsOf: Self.layOut(parts, dayIndex: index, grid: grid, metrics: metrics))
        }
        self.items = items
        self.marks = content.marks.enumerated().flatMap { index, placed in
            placed.map {
                PlacedMark(id: $0.mark.id, dayIndex: index, minute: $0.minute, y: grid.y(forMinute: $0.minute))
            }
        }
    }

    // MARK: Reading the fit

    public var openHourCount: Int { openHours.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// The runs of open hours, earliest first ("08:00 to 18:00").
    public var openRuns: [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for hour in 0...24 {
            let open = hour < 24 && openHours[hour]
            if open, start == nil { start = hour }
            if !open, let first = start {
                runs.append(first..<hour)
                start = nil
            }
        }
        return runs
    }

    /// Where `minute` of a day sits: inside an open hour by its share of the hour, at a fold's top for a minute the
    /// fold holds, at the hours' bottom from 24:00 on.
    public func y(forMinute minute: Double) -> Double { grid.y(forMinute: minute) }

    /// The minute at `y`: inside an open hour by its share of the hour; on a fold, the hour after it (or, for the
    /// fold that runs to midnight, half an hour before it), so a drop there lands next to the fold; nil above the
    /// hours or at and below their bottom.
    public func minute(atY y: Double) -> Double? { grid.minute(atY: y) }

    /// `minute(atY:)` rounded to the quarter hour, for a drop that sets 30 minutes aside: never past 23:30.
    public func snappedMinute(atY y: Double) -> Int? {
        guard let minute = grid.minute(atY: y) else { return nil }
        return min(1_410, max(0, Int((minute / 15).rounded()) * 15))
    }

    /// The day under `x`, when it is one that holds events (a folded day takes no drop).
    public func dayIndex(atX x: Double) -> Int? {
        days.firstIndex { !$0.isFolded && x >= $0.x && x < $0.x + $0.width }
    }

    /// The instant a day's wall clock shows `minute` at: where a drop at `snappedMinute(atY:)` sets time aside.
    public func date(atMinute minute: Double, onDay index: Int) -> Date? {
        guard clocks.indices.contains(index) else { return nil }
        return clocks[index].date(atMinute: minute, calendar: calendar)
    }

    /// The shown day `date` falls on and its wall-clock minute there (the now line), or nil when no shown day has it.
    public func locate(_ date: Date) -> (dayIndex: Int, minute: Double)? {
        guard let index = clocks.firstIndex(where: { $0.contains(date) }) else { return nil }
        return (index, clocks[index].minute(of: date))
    }

    /// The vertical extent of `interval`'s part on a day, cut at the day's edges: an overlap's hatch on an event, or
    /// (with `minimumHeight`) the ghost of a drop. Nil when the interval misses the day.
    public func span(of interval: DateInterval, onDay index: Int, minimumHeight: Double = 0)
        -> (top: Double, height: Double)? {
        guard clocks.indices.contains(index) else { return nil }
        let clock = clocks[index]
        let touches = interval.duration == 0
            ? clock.contains(interval.start)
            : interval.start < clock.end && interval.end > clock.start
        guard touches else { return nil }
        let minutes = clock.minutes(from: interval.start, to: interval.end)
        let top = grid.y(forMinute: minutes.start)
        return (top, max(grid.y(forMinute: minutes.end) - top, minimumHeight))
    }

    // MARK: Building

    /// The days across `width`: an empty weekend day of a week folds to `foldedDayWidth` and the others share the
    /// rest. Which days are the weekend is the calendar's locale's to say (`Calendar.isDateInWeekend`: Saturday and
    /// Sunday in most places, Friday and Saturday in some), wherever they fall in the week the caller passes
    /// (`Calendar.firstWeekday` decides that). A single day never folds, nor do the days of a week that would fold
    /// whole.
    private static func place(content: CalendarDayContent, width: Double, calendar: Calendar,
                              metrics: Metrics) -> [Day] {
        let count = content.clocks.count
        var folded = [Bool](repeating: false, count: count)
        if count > 1 {
            for index in 0..<count where content.isEmpty(index) {
                folded[index] = calendar.isDateInWeekend(content.clocks[index].start)
            }
            if !folded.contains(false) { folded = [Bool](repeating: false, count: count) }
        }
        let foldedCount = folded.filter { $0 }.count
        let open = count - foldedCount
        let dayWidth = open > 0 ? (width - Double(foldedCount) * metrics.foldedDayWidth) / Double(open) : 0
        var x = 0.0
        return content.clocks.indices.map { index in
            let width = folded[index] ? metrics.foldedDayWidth : dayWidth
            defer { x += width }
            return Day(start: content.clocks[index].start, x: x, width: width, isFolded: folded[index])
        }
    }

    /// One day's parts, side by side where they overlap. Overlap is judged by what is drawn (an event is at least a
    /// line tall), so two short events a few minutes apart sit side by side instead of on top of each other. A group
    /// runs while each part starts before the group's drawn end; within it each part takes the first column free at
    /// its start, and the whole group shares one column count.
    private static func layOut(_ parts: [CalendarDayContent.Part], dayIndex: Int, grid: HourGrid,
                               metrics: Metrics) -> [Item] {
        let sorted = parts.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return a.event.id < b.event.id
        }
        let minimumMinutes = grid.hourHeight > 0 ? metrics.minEventHeight / grid.hourHeight * 60 : 0
        var columns = [Int](repeating: 0, count: sorted.count)
        var counts = [Int](repeating: 1, count: sorted.count)
        var more = [Int](repeating: 0, count: sorted.count)

        var group: [Int] = []
        var groupEnd = -Double.infinity
        func flush() {
            guard !group.isEmpty else { return }
            var columnEnds: [Double] = []
            for index in group {
                let part = sorted[index]
                var column = 0
                while column < columnEnds.count, columnEnds[column] > part.start { column += 1 }
                let drawnEnd = max(part.end, part.start + minimumMinutes)
                if column == columnEnds.count { columnEnds.append(drawnEnd) } else { columnEnds[column] = drawnEnd }
                columns[index] = column
            }
            let count = min(metrics.maxColumns, columnEnds.count)
            let hidden = group.filter { columns[$0] >= metrics.maxColumns }.count
            for index in group { counts[index] = count }
            if hidden > 0, let last = group.first(where: { columns[$0] == metrics.maxColumns - 1 }) {
                more[last] = hidden
            }
            group.removeAll(keepingCapacity: true)
        }
        for (index, part) in sorted.enumerated() {
            if part.start >= groupEnd { flush() }
            group.append(index)
            groupEnd = max(groupEnd, max(part.end, part.start + minimumMinutes))
        }
        flush()

        return sorted.enumerated().map { index, part in
            var top = grid.y(forMinute: part.start)
            let height = max(grid.y(forMinute: part.end) - top, metrics.minEventHeight)
            if top + height > grid.height { top = max(0, grid.height - height) }
            return Item(event: part.event, dayIndex: dayIndex, startMinute: part.start, endMinute: part.end,
                        startsBeforeDay: part.startsBefore, endsAfterDay: part.endsAfter, top: top, height: height,
                        column: columns[index], columnCount: counts[index],
                        isHidden: columns[index] >= metrics.maxColumns, moreCount: more[index])
        }
    }
}

/// The hours fitted to a height: which are open, the points each gets, and every hour's top (a closed hour's is its
/// fold's). Rules 2 to 4 of `CalendarFit`.
private struct HourGrid: Sendable {
    let open: [Bool]
    let folds: [CalendarFit.Fold]
    let hourHeight: Double
    let height: Double
    let foldHeight: Double
    /// Each hour's top; a closed hour's is the top of the fold that holds it.
    private let tops: [Double]

    init(open start: [Bool], room: Double, metrics: CalendarFit.Metrics) {
        var open = start
        var count = open.filter { $0 }.count
        func closedRuns() -> Int {
            var runs = 0
            var inRun = false
            for flag in open {
                if !flag, !inRun { runs += 1 }
                inRun = !flag
            }
            return runs
        }
        func share() -> Double { (room - Double(closedRuns()) * metrics.foldHeight) / Double(count) }

        var scale = count > 0 ? share() : metrics.maxHourHeight
        // Too much room: open one more hour, before the open ones then after them in turn, until each gets no more
        // than the cap. At either end of the day the other side takes the turn; with both ends open, an inner run
        // fills from its first hour.
        var side = 0
        while count > 0, count < 24, scale > metrics.maxHourHeight,
              let first = open.firstIndex(of: true), let last = open.lastIndex(of: true) {
            var hour = side % 2 == 0 ? (first > 0 ? first - 1 : last + 1) : (last < 23 ? last + 1 : first - 1)
            if hour < 0 || hour > 23, let closed = open.firstIndex(of: false) { hour = closed }
            open[hour] = true
            count += 1
            side += 1
            scale = share()
        }
        scale = min(metrics.maxHourHeight, max(metrics.minHourHeight, scale))

        var tops = [Double](repeating: 0, count: 24)
        var folds: [CalendarFit.Fold] = []
        var y = 0.0
        var hour = 0
        while hour < 24 {
            if open[hour] {
                tops[hour] = y
                y += scale
                hour += 1
            } else {
                let from = hour
                while hour < 24, !open[hour] {
                    tops[hour] = y
                    hour += 1
                }
                folds.append(CalendarFit.Fold(from: from, to: hour, y: y))
                y += metrics.foldHeight
            }
        }
        self.open = open
        self.folds = folds
        hourHeight = scale
        height = y
        foldHeight = metrics.foldHeight
        self.tops = tops
    }

    func y(forMinute minute: Double) -> Double {
        if minute >= 1_440 { return height }
        if minute <= 0 { return 0 }
        let hour = min(23, Int(minute / 60))
        guard open[hour] else { return tops[hour] }
        return tops[hour] + (minute - Double(hour) * 60) / 60 * hourHeight
    }

    func minute(atY y: Double) -> Double? {
        for hour in 0..<24 where open[hour] && y >= tops[hour] && y < tops[hour] + hourHeight {
            return Double(hour) * 60 + (y - tops[hour]) / hourHeight * 60
        }
        for fold in folds where y >= fold.y && y < fold.y + foldHeight {
            return fold.to < 24 ? Double(fold.to) * 60 : Double(fold.from) * 60 - 30
        }
        return nil
    }
}
