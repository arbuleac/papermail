import Foundation

/// The date shapes the message list shows (spec §4.13, §5.8), and the running head each date falls under.
///
/// Under running heads a row shows only what its head leaves out: the time of day under Today and Yesterday,
/// the weekday under Earlier this week, day and month under Last week and the month heads. Without heads
/// (search results, short views) a row carries the whole answer: today "23:39", yesterday "Yesterday", this
/// week "Tue" (six days back at most, so a weekday name can never mean two different days), this year
/// "30 Oct", older "30 Oct 2025". Times follow the system 12/24-hour setting and the locale's day and month
/// order, through formatter templates rather than fixed patterns.
public struct DateFormatting: @unchecked Sendable {
    /// Which shape a row's time takes, decided by the running head above it.
    public enum Style: Int, Hashable, Sendable, CaseIterable {
        /// Under Today and Yesterday: the time of day.
        case timeOfDay
        /// Under Earlier this week: the weekday.
        case weekday
        /// Under Last week and every month head: day and month (the year is in the head).
        case dayMonth
        /// No heads: the full relative shape.
        case relative
    }

    /// Day boundaries derived from one "now", so a refresh pass does the calendar math once instead of per row.
    public struct Reference: Hashable, Sendable {
        public let now: Date
        public let startOfToday: Date
        public let startOfTomorrow: Date
        public let startOfYesterday: Date
        /// Six days before today. Dates in `[startOfWeekWindow, startOfYesterday)` show a weekday name when
        /// there are no heads.
        public let startOfWeekWindow: Date
        /// The first day of this calendar week in the locale (Monday or Sunday).
        public let startOfThisWeek: Date
        public let startOfLastWeek: Date
        public let startOfYear: Date
        public let startOfNextYear: Date
        public let year: Int

        /// Changes exactly when the "today" and "this week" buckets shift, so any cache of formatted dates
        /// must include it in its key.
        public var dayStamp: Int { Int(startOfToday.timeIntervalSinceReferenceDate) }
    }

    private let calendar: Calendar
    private let timeFormatter: DateFormatter
    private let weekdayFormatter: DateFormatter
    private let dayMonthFormatter: DateFormatter
    private let dayMonthYearFormatter: DateFormatter
    private let monthFormatter: DateFormatter
    private let monthYearFormatter: DateFormatter
    private let yesterdayWord: String

    /// The formatters are configured once and never mutated afterwards; Foundation documents `DateFormatter`
    /// as safe to use concurrently in that state, which is why the type can be `@unchecked Sendable`.
    public init(
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        var calendar = calendar
        calendar.locale = locale
        calendar.timeZone = timeZone
        self.calendar = calendar

        func make(template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        // The short time style, unlike a template, honours the system's 24-hour override.
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        timeFormatter = time
        weekdayFormatter = make(template: "EEE")
        dayMonthFormatter = make(template: "dMMM")
        dayMonthYearFormatter = make(template: "dMMMy")
        monthFormatter = make(template: "LLLL")
        monthYearFormatter = make(template: "MMMMy")

        // The locale's own word for yesterday, read once from a relative formatter.
        let relative = DateFormatter()
        relative.locale = locale
        relative.calendar = calendar
        relative.timeZone = timeZone
        relative.dateStyle = .medium
        relative.timeStyle = .none
        relative.doesRelativeDateFormatting = true
        let startOfToday = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday.addingTimeInterval(-86_400)
        yesterdayWord = relative.string(from: yesterday.addingTimeInterval(43_200))
    }

    public func reference(now: Date = Date()) -> Reference {
        let startOfToday = calendar.startOfDay(for: now)
        // The fallbacks only matter for calendars that cannot add days, which Gregorian always can.
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? startOfToday.addingTimeInterval(86_400)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)
            ?? startOfToday.addingTimeInterval(-86_400)
        let startOfWeekWindow = calendar.date(byAdding: .day, value: -6, to: startOfToday)
            ?? startOfToday.addingTimeInterval(-6 * 86_400)
        let startOfThisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        let startOfLastWeek = calendar.date(byAdding: .day, value: -7, to: startOfThisWeek)
            ?? startOfThisWeek.addingTimeInterval(-7 * 86_400)
        let year = calendar.dateInterval(of: .year, for: now)
        return Reference(
            now: now,
            startOfToday: startOfToday,
            startOfTomorrow: startOfTomorrow,
            startOfYesterday: startOfYesterday,
            startOfWeekWindow: startOfWeekWindow,
            startOfThisWeek: startOfThisWeek,
            startOfLastWeek: startOfLastWeek,
            startOfYear: year?.start ?? startOfToday,
            startOfNextYear: year?.end ?? startOfTomorrow,
            year: calendar.component(.year, from: now)
        )
    }

    // MARK: Row times

    public func string(for date: Date, reference: Reference, style: Style = .relative) -> String {
        switch style {
        case .timeOfDay:
            return timeFormatter.string(from: date)
        case .weekday:
            return weekdayFormatter.string(from: date)
        case .dayMonth:
            return dayMonthFormatter.string(from: date)
        case .relative:
            if date >= reference.startOfToday && date < reference.startOfTomorrow {
                return timeFormatter.string(from: date)
            }
            if date >= reference.startOfYesterday && date < reference.startOfToday {
                return yesterdayWord
            }
            if date >= reference.startOfWeekWindow && date < reference.startOfYesterday {
                return weekdayFormatter.string(from: date)
            }
            if date >= reference.startOfYear && date < reference.startOfNextYear {
                return dayMonthFormatter.string(from: date)
            }
            return dayMonthYearFormatter.string(from: date)
        }
    }

    public func string(for date: Date, now: Date = Date(), style: Style = .relative) -> String {
        string(for: date, reference: reference(now: now), style: style)
    }

    // MARK: Running heads

    /// The head a date falls under. Dates after today (a sender's clock running fast) count as today, so a
    /// future date never opens a head of its own above Today.
    public func runningHead(for date: Date, reference: Reference) -> RunningHead {
        if date >= reference.startOfToday { return .today }
        if date >= reference.startOfYesterday { return .yesterday }
        if date >= reference.startOfThisWeek { return .earlierThisWeek }
        if date >= reference.startOfLastWeek { return .lastWeek }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return .month(year: parts.year ?? reference.year, month: parts.month ?? 1)
    }

    /// The start of the month `date` is in, for callers that walk a sorted list and want to skip the calendar
    /// math until a row crosses into the previous month.
    public func monthInterval(containing date: Date) -> DateInterval? {
        calendar.dateInterval(of: .month, for: date)
    }

    /// The head's words before uppercasing: "Today", "Earlier this week", "October", "October 2025".
    public func title(for head: RunningHead, reference: Reference) -> String {
        switch head {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .earlierThisWeek: return "Earlier this week"
        case .lastWeek: return "Last week"
        case .month(let year, let month):
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 15)) else { return "" }
            return year == reference.year ? monthFormatter.string(from: date) : monthYearFormatter.string(from: date)
        }
    }
}
