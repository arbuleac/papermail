import Foundation
import SSCore

/// The calendar's words (spec §5.54, §4.13): times in the system's 12/24-hour setting with “ - ” between them, the
/// locale's day and month order, the kickers that say where a day is from today. Formatters are made once per
/// calendar; nothing here reads the store.
struct CalendarText {
    let calendar: Calendar
    private let time: DateFormatter
    private let hour: DateFormatter
    private let weekday: DateFormatter
    private let narrowWeekday: DateFormatter
    private let dayNumber: DateFormatter
    private let weekdayDay: DateFormatter
    private let headline: DateFormatter
    private let headlineYear: DateFormatter
    private let longDay: DateFormatter
    private let shortDay: DateFormatter
    private let shortDayYear: DateFormatter
    private let dayMonthLong: DateFormatter
    private let dayMonthLongYear: DateFormatter
    /// The system shows times with AM and PM.
    let usesTwelveHours: Bool

    init(calendar: Calendar) {
        self.calendar = calendar
        let locale = calendar.locale ?? .autoupdatingCurrent
        func make(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        // The short time style, unlike a template, honours the system's 24-hour override (as DateFormatting does).
        let time = DateFormatter()
        time.calendar = calendar
        time.locale = locale
        time.timeZone = calendar.timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        self.time = time
        usesTwelveHours = time.dateFormat.contains("a")
        hour = usesTwelveHours ? make("ha") : time
        weekday = make("EEE")
        narrowWeekday = make("EEEEEE")
        dayNumber = make("d")
        weekdayDay = make("EEEd")
        headline = make("EEEEdMMM")
        headlineYear = make("EEEEdMMMy")
        longDay = make("EEEEdMMMM")
        shortDay = make("EEEdMMM")
        shortDayYear = make("EEEdMMMy")
        dayMonthLong = make("dMMMM")
        dayMonthLongYear = make("dMMMMy")
    }

    // MARK: Times

    /// “13:00”, or “1:00 PM” under the 12-hour setting.
    func time(_ date: Date) -> String { time.string(from: date) }

    /// “13:00 - 14:00”.
    func range(_ start: Date, _ end: Date) -> String { time(start) + " - " + time(end) }

    /// “13:00 to 14:00”, as VoiceOver reads a span.
    func spokenRange(_ start: Date, _ end: Date) -> String { time(start) + " to " + time(end) }

    /// An hour's label in the gutter: “09:00”, “9 AM” under the 12-hour setting. Hour 24 is the end of the day.
    func hourLabel(_ hourOfDay: Int, on day: Date) -> String {
        guard hourOfDay < 24 else { return usesTwelveHours ? hour.string(from: calendar.startOfDay(for: day)) : "24:00" }
        let date = calendar.date(bySettingHour: hourOfDay, minute: 0, second: 0, of: day) ?? day
        return hour.string(from: date)
    }

    /// A fold's label: “00:00 - 08:00”.
    func foldLabel(from: Int, to: Int, on day: Date) -> String {
        hourLabel(from, on: day) + " - " + hourLabel(to, on: day)
    }

    /// A fold for VoiceOver: “Nothing from 00:00 to 08:00”.
    func spokenFold(from: Int, to: Int, on day: Date) -> String {
        "Nothing from " + hourLabel(from, on: day) + " to " + hourLabel(to, on: day)
    }

    // MARK: Days

    /// “Thu”.
    func weekday(_ day: Date) -> String { weekday.string(from: day) }

    /// “Sa”, a folded day's heading.
    func narrowWeekday(_ day: Date) -> String { narrowWeekday.string(from: day) }

    /// “19”.
    func dayNumber(_ day: Date) -> String { dayNumber.string(from: day) }

    /// “Thu 19”, a day's heading in the week.
    func weekHeading(_ day: Date) -> String { weekdayDay.string(from: day) }

    /// “Thursday 19 Nov”, the column's headline; “Thursday 19 Nov 2027” outside this year.
    func headline(_ day: Date, now: Date) -> String {
        isThisYear(day, now: now) ? headline.string(from: day) : headlineYear.string(from: day)
    }

    /// “Thursday 19 November”, as VoiceOver names a day.
    func longDay(_ day: Date) -> String { longDay.string(from: day) }

    /// “Thu 19 Nov”, “Thu 19 Nov 2027” outside this year.
    func shortDay(_ day: Date, now: Date) -> String {
        isThisYear(day, now: now) ? shortDay.string(from: day) : shortDayYear.string(from: day)
    }

    private func isThisYear(_ date: Date, now: Date) -> Bool {
        calendar.component(.year, from: date) == calendar.component(.year, from: now)
    }

    /// The first day of the week `day` is in (the Mac's first weekday), and its seven days.
    func week(containing day: Date) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? calendar.startOfDay(for: day)
        return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start) ?? start }
    }

    /// Whole weeks from today's week to `day`'s.
    private func weeks(from today: Date, to day: Date) -> Int {
        let here = week(containing: today)[0]
        let there = week(containing: day)[0]
        let days = calendar.dateComponents([.day], from: here, to: there).day ?? 0
        return Int((Double(days) / 7).rounded())
    }

    /// Where the column's day is from today (spec §5.54): “Today”, “Tomorrow”, “Yesterday”, “Earlier this week”,
    /// “Later this week”, “Next week”, “Last week”, “In 3 weeks”, “2 weeks ago”.
    func kicker(for day: Date, now: Date) -> String {
        let today = calendar.startOfDay(for: now)
        let shown = calendar.startOfDay(for: day)
        let offset = calendar.dateComponents([.day], from: today, to: shown).day ?? 0
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: break
        }
        let weeks = weeks(from: today, to: shown)
        if weeks == 0 { return offset < 0 ? "Earlier this week" : "Later this week" }
        return weekWords(weeks)
    }

    /// Where a week is from this one: “This week”, “Next week”, “Last week”, “In 3 weeks”, “2 weeks ago”.
    func weekKicker(for day: Date, now: Date) -> String {
        let weeks = weeks(from: now, to: day)
        return weeks == 0 ? "This week" : weekWords(weeks)
    }

    private func weekWords(_ weeks: Int) -> String {
        switch weeks {
        case 1: return "Next week"
        case -1: return "Last week"
        case let ahead where ahead > 1: return "In \(ahead) weeks"
        default: return "\(-weeks) weeks ago"
        }
    }

    /// The week's headline: “16 - 22 November”, “30 November - 6 December”, with the year outside this one.
    func weekHeadline(_ days: [Date], now: Date) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        let sameMonth = calendar.component(.month, from: first) == calendar.component(.month, from: last)
        let thisYear = isThisYear(first, now: now) && isThisYear(last, now: now)
        let lastText = thisYear ? dayMonthLong.string(from: last) : dayMonthLongYear.string(from: last)
        let firstText = sameMonth ? dayNumber.string(from: first)
            : (thisYear || calendar.component(.year, from: first) == calendar.component(.year, from: last)
                ? dayMonthLong.string(from: first) : dayMonthLongYear.string(from: first))
        return firstText + " - " + lastText
    }

    // MARK: Events

    /// When an event is, as the invitation card writes it (spec §5.14): “Thu 19 Nov · 13:00 - 14:00”, “Thu 19 Nov ·
    /// All day”, “Tue 10 - Thu 12 Nov · All day”, “Tue 10 Nov, 22:00 - Wed 11 Nov, 02:00”.
    func when(_ event: CalendarEvent, now: Date) -> String {
        if event.isAllDay {
            // Floating dates: read them in UTC so they name the date they were written for.
            var utc = calendar
            utc.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
            let floating = CalendarText(calendar: utc)
            let lastDay = max(event.start, event.end.addingTimeInterval(-86_400))
            if utc.isDate(lastDay, inSameDayAs: event.start) { return floating.shortDay(event.start, now: now) + " · All day" }
            return floating.shortDay(event.start, now: now) + " - " + floating.shortDay(lastDay, now: now) + " · All day"
        }
        if event.end <= event.start { return shortDay(event.start, now: now) + " · " + time(event.start) }
        if calendar.isDate(event.end, inSameDayAs: event.start) {
            return shortDay(event.start, now: now) + " · " + range(event.start, event.end)
        }
        return shortDay(event.start, now: now) + ", " + time(event.start) + " - " + shortDay(event.end, now: now) + ", "
            + time(event.end)
    }

    /// The ghost of a drop: “Thu 13:30 - 14:00”.
    func ghost(_ start: Date, _ end: Date) -> String {
        weekday(start) + " " + range(start, end)
    }

    /// The call's service, read from its join address: “Google Meet”, “Teams”, “Zoom”, else “Video call”.
    static func service(of joinURL: String) -> String {
        let host = URL(string: joinURL)?.host?.lowercased() ?? ""
        if host.hasSuffix("meet.google.com") { return "Google Meet" }
        if host.hasSuffix("teams.microsoft.com") || host.hasSuffix("teams.live.com") { return "Teams" }
        if host.hasSuffix("zoom.us") || host.hasSuffix("zoom.com") { return "Zoom" }
        if host.hasSuffix("webex.com") { return "Webex" }
        return "Video call"
    }

    /// The provider's web calendar, for Open in … and the failed line.
    static func providerCalendarName(_ kind: ProviderKind?) -> String {
        kind == .microsoft ? "Outlook" : "Google Calendar"
    }

    /// An untitled event: what the details and VoiceOver call it.
    static let noTitle = "No title"
}
