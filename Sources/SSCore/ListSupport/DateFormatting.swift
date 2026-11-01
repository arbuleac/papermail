import Foundation

/// The four date shapes the message list shows, chosen by distance from "now".
///
/// Rules: same calendar day → "14:05"; one to six days back → "Tue" (six, so a weekday name can never mean two
/// different days); same year → "3 Mar"; anything else → "3 Mar 2025". The clock is 24-hour on purpose: every
/// row then gets a time of the same width, which matters because rows are laid out by hand.
public struct DateFormatting: @unchecked Sendable {
    /// Day boundaries derived from one "now", so a refresh pass does the calendar math once instead of per row.
    public struct Reference: Hashable, Sendable {
        public let now: Date
        public let startOfToday: Date
        public let startOfTomorrow: Date
        /// Six days before today. Dates in `[startOfWeekWindow, startOfToday)` show a weekday name.
        public let startOfWeekWindow: Date
        public let startOfYear: Date
        public let startOfNextYear: Date

        /// Changes exactly when the "today" and "this week" buckets shift, so any cache of formatted dates
        /// must include it in its key.
        public var dayStamp: Int { Int(startOfToday.timeIntervalSinceReferenceDate) }
    }

    private let calendar: Calendar
    private let timeFormatter: DateFormatter
    private let weekdayFormatter: DateFormatter
    private let dayMonthFormatter: DateFormatter
    private let dayMonthYearFormatter: DateFormatter

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

        func make(_ format: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            return formatter
        }
        timeFormatter = make("HH:mm")
        weekdayFormatter = make("EEE")
        dayMonthFormatter = make("d MMM")
        dayMonthYearFormatter = make("d MMM yyyy")
    }

    public func reference(now: Date = Date()) -> Reference {
        let startOfToday = calendar.startOfDay(for: now)
        // The fallbacks only matter for calendars that cannot add days, which Gregorian always can.
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? startOfToday.addingTimeInterval(86_400)
        let startOfWeekWindow = calendar.date(byAdding: .day, value: -6, to: startOfToday)
            ?? startOfToday.addingTimeInterval(-6 * 86_400)
        let year = calendar.dateInterval(of: .year, for: now)
        return Reference(
            now: now,
            startOfToday: startOfToday,
            startOfTomorrow: startOfTomorrow,
            startOfWeekWindow: startOfWeekWindow,
            startOfYear: year?.start ?? startOfToday,
            startOfNextYear: year?.end ?? startOfTomorrow
        )
    }

    public func string(for date: Date, reference: Reference) -> String {
        if date >= reference.startOfToday && date < reference.startOfTomorrow {
            return timeFormatter.string(from: date)
        }
        if date >= reference.startOfWeekWindow && date < reference.startOfToday {
            return weekdayFormatter.string(from: date)
        }
        if date >= reference.startOfYear && date < reference.startOfNextYear {
            return dayMonthFormatter.string(from: date)
        }
        return dayMonthYearFormatter.string(from: date)
    }

    public func string(for date: Date, now: Date = Date()) -> String {
        string(for: date, reference: reference(now: now))
    }
}
