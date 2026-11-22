import Foundation

/// The span of days the engine keeps each account's calendar for: two weeks back to eight weeks ahead of today, whole
/// local days. The day column and the week turn within it without a network wait; a day outside it asks the engine for
/// a read (`MailClient.refreshCalendars`).
public enum CalendarWindow {
    public static let daysBack = 14
    public static let daysAhead = 56

    /// The window around `now` in `calendar`'s zone: from the start of the day `daysBack` before today to the start of
    /// the day `daysAhead` after it.
    public static func around(_ now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -daysBack, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: daysAhead + 1, to: today) ?? today
        return DateInterval(start: start, end: end)
    }
}
