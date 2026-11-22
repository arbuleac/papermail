import Foundation

/// A repeat rule (iCalendar RRULE, RFC 5545 §3.3.10), kept to describe it in words: Paper never expands one
/// into occurrences. Microsoft Graph's recurrence pattern maps onto the same parts.
public struct RecurrenceRule: Hashable, Sendable {
    public enum Frequency: String, Sendable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"
    }

    /// A BYDAY entry: a weekday (1 = Sunday … 7 = Saturday, as `Calendar` counts) and, in a monthly or yearly rule,
    /// which one of the month (1 = first, −1 = last; 0 = every).
    public struct Day: Hashable, Sendable {
        public var weekday: Int
        public var ordinal: Int

        public init(weekday: Int, ordinal: Int = 0) {
            self.weekday = weekday
            self.ordinal = ordinal
        }
    }

    public var frequency: Frequency
    public var interval: Int
    public var days: [Day]
    public var monthDays: [Int]
    public var months: [Int]
    /// A single BYSETPOS, which with one weekday names the nth of the month (“the second Tuesday”).
    public var setPosition: Int?
    public var count: Int?
    /// The last occurrence may start no later than this.
    public var until: Date?
    /// UNTIL was a DATE: `until` is that day's midnight read as UTC.
    public var untilIsDate: Bool
    /// The rule has parts the words cannot say (BYHOUR, BYWEEKNO, several BYSETPOS…); it is described as “Repeats”.
    public var hasUnsayableParts: Bool

    public init(frequency: Frequency, interval: Int = 1, days: [Day] = [], monthDays: [Int] = [], months: [Int] = [],
                setPosition: Int? = nil, count: Int? = nil, until: Date? = nil, untilIsDate: Bool = false,
                hasUnsayableParts: Bool = false) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.days = days
        self.monthDays = monthDays
        self.months = months
        self.setPosition = setPosition
        self.count = count
        self.until = until
        self.untilIsDate = untilIsDate
        self.hasUnsayableParts = hasUnsayableParts
    }

    static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    /// Reads an RRULE value. Nil without a FREQ, for a frequency finer than a day, or for a malformed part; parts the
    /// words cannot say are kept as `hasUnsayableParts`.
    public init?(rrule: String) {
        var frequency: Frequency?
        var interval = 1
        var days: [Day] = []
        var monthDays: [Int] = []
        var months: [Int] = []
        var setPositions: [Int] = []
        var count: Int?
        var until: Date?
        var untilIsDate = false
        var unsayable = false
        for part in rrule.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { return nil }
            let value = pair[1].uppercased()
            switch pair[0].uppercased() {
            case "FREQ":
                guard let parsed = Frequency(rawValue: value) else { return nil }
                frequency = parsed
            case "INTERVAL":
                guard let parsed = Int(value), parsed > 0 else { return nil }
                interval = parsed
            case "COUNT":
                guard let parsed = Int(value), parsed > 0 else { return nil }
                count = parsed
            case "UNTIL":
                guard let parsed = ICalendarTimes.parse(value), let date = parsed.local.asUTC else { return nil }
                until = date
                untilIsDate = parsed.isDate
            case "BYDAY":
                for entry in value.split(separator: ",") {
                    let code = String(entry.suffix(2))
                    guard let index = Self.weekdayCodes.firstIndex(of: code) else { return nil }
                    let prefix = entry.dropLast(2)
                    var ordinal = 0
                    if !prefix.isEmpty {
                        guard let parsed = Int(prefix), parsed != 0, abs(parsed) <= 53 else { return nil }
                        ordinal = parsed
                    }
                    days.append(Day(weekday: index + 1, ordinal: ordinal))
                }
            case "BYMONTHDAY":
                for entry in value.split(separator: ",") {
                    guard let parsed = Int(entry), parsed != 0, abs(parsed) <= 31 else { return nil }
                    monthDays.append(parsed)
                }
            case "BYMONTH":
                for entry in value.split(separator: ",") {
                    guard let parsed = Int(entry), (1...12).contains(parsed) else { return nil }
                    months.append(parsed)
                }
            case "BYSETPOS":
                for entry in value.split(separator: ",") {
                    guard let parsed = Int(entry), parsed != 0 else { return nil }
                    setPositions.append(parsed)
                }
            case "WKST":
                break
            default:
                // BYHOUR, BYMINUTE, BYSECOND, BYWEEKNO, BYYEARDAY and extensions: readable, not sayable.
                unsayable = true
            }
        }
        guard let frequency else { return nil }
        if setPositions.count > 1 { unsayable = true }
        self.init(frequency: frequency, interval: interval, days: days, monthDays: monthDays, months: months,
                  setPosition: setPositions.first, count: count, until: until, untilIsDate: untilIsDate, hasUnsayableParts: unsayable)
    }

    /// The rule as an RRULE value, for a calendar file written from these facts.
    public var rruleText: String {
        var parts = ["FREQ=" + frequency.rawValue]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        if !days.isEmpty {
            parts.append("BYDAY=" + days.map { ($0.ordinal == 0 ? "" : String($0.ordinal)) + Self.weekdayCodes[($0.weekday - 1) % 7] }
                .joined(separator: ","))
        }
        if !monthDays.isEmpty { parts.append("BYMONTHDAY=" + monthDays.map(String.init).joined(separator: ",")) }
        if !months.isEmpty { parts.append("BYMONTH=" + months.map(String.init).joined(separator: ",")) }
        if let setPosition { parts.append("BYSETPOS=\(setPosition)") }
        if let count {
            parts.append("COUNT=\(count)")
        } else if let until {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = ICalendarTimes.utc.timeZone
            formatter.dateFormat = untilIsDate ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'"
            parts.append("UNTIL=" + formatter.string(from: until))
        }
        return parts.joined(separator: ";")
    }

    // MARK: Words

    /// The rule in words: “Every week on Tuesday”, “Every month on the 3rd, until 3 March 2027”, “Every 2 weeks on
    /// Monday and Thursday, 10 times”. `start` is the first occurrence, held as the event holds it (for a floating
    /// event, its wall-clock time read as UTC, with `timeZone` UTC); `timeZone` is the event's own, in which weekdays
    /// and dates are counted. Day and month names follow `locale`.
    public func words(start: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        var sentence = base(start: start, calendar: calendar, locale: locale) ?? "Repeats"
        if let count {
            sentence += count == 1 ? ", once" : ", \(count) times"
        } else if let until {
            let formatter = DateFormatter()
            formatter.locale = locale
            // A DATE is a day as written; a time is counted in the event's zone, where the last occurrence falls.
            formatter.timeZone = untilIsDate ? ICalendarTimes.utc.timeZone : timeZone
            formatter.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
            sentence += ", until " + formatter.string(from: until)
        }
        return sentence
    }

    private func base(start: Date, calendar: Calendar, locale: Locale) -> String? {
        guard !hasUnsayableParts else { return nil }
        let names = calendar.standaloneWeekdaySymbols
        let startWeekday = calendar.component(.weekday, from: start)
        let weekdays: Set<Int> = [2, 3, 4, 5, 6]
        func dayList(_ days: [Day]) -> String {
            // Monday first, as a week reads.
            let ordered = days.map(\.weekday).sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }
            let formatter = ListFormatter()
            formatter.locale = locale
            let items = ordered.map { names[($0 - 1) % 7] }
            return formatter.string(from: items) ?? items.joined(separator: ", ")
        }
        switch frequency {
        case .daily:
            guard months.isEmpty, monthDays.isEmpty, setPosition == nil else { return nil }
            if !days.isEmpty {
                guard days.allSatisfy({ $0.ordinal == 0 }), interval == 1 else { return nil }
                if Set(days.map(\.weekday)) == weekdays { return "Every weekday" }
                return "Every day on " + dayList(days)
            }
            return interval == 1 ? "Every day" : "Every \(interval) days"
        case .weekly:
            guard months.isEmpty, monthDays.isEmpty, setPosition == nil, days.allSatisfy({ $0.ordinal == 0 }) else { return nil }
            let set = days.isEmpty ? [Day(weekday: startWeekday)] : days
            if interval == 1, Set(set.map(\.weekday)) == weekdays, set.count == 5 { return "Every weekday" }
            return (interval == 1 ? "Every week" : "Every \(interval) weeks") + " on " + dayList(set)
        case .monthly:
            guard months.isEmpty else { return nil }
            let head = interval == 1 ? "Every month" : "Every \(interval) months"
            guard let which = monthPhrase(start: start, calendar: calendar, locale: locale, names: names) else { return nil }
            return head + " on " + which
        case .yearly:
            guard months.count <= 1 else { return nil }
            let head = interval == 1 ? "Every year" : "Every \(interval) years"
            let month = months.first ?? calendar.component(.month, from: start)
            let monthName = calendar.standaloneMonthSymbols[(month - 1) % 12]
            if !days.isEmpty {
                guard let which = nthWeekday(names: names) else { return nil }
                return head + " on " + which + " of " + monthName
            }
            guard monthDays.count <= 1, setPosition == nil else { return nil }
            let day = monthDays.first ?? calendar.component(.day, from: start)
            guard day > 0 else { return day == -1 ? head + " on the last day of " + monthName : nil }
            var components = DateComponents(year: 2001, month: month, day: day)
            components.timeZone = calendar.timeZone
            guard let sample = calendar.date(from: components) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("dMMMM")
            return head + " on " + formatter.string(from: sample)
        }
    }

    /// “the 3rd”, “the last day”, “the second Tuesday”, or nil when the month part is not one of those.
    private func monthPhrase(start: Date, calendar: Calendar, locale: Locale, names: [String]) -> String? {
        if !days.isEmpty {
            guard monthDays.isEmpty else { return nil }
            return nthWeekday(names: names)
        }
        guard setPosition == nil, monthDays.count <= 1 else { return nil }
        let day = monthDays.first ?? calendar.component(.day, from: start)
        if day == -1 { return "the last day" }
        guard day > 0 else { return nil }
        return "the " + Self.ordinalNumber(day, locale: locale)
    }

    /// “the second Tuesday”, “the last Friday”: one weekday with an ordinal, from BYDAY or BYSETPOS.
    private func nthWeekday(names: [String]) -> String? {
        guard days.count == 1, let day = days.first else { return nil }
        let ordinal = day.ordinal != 0 ? day.ordinal : (setPosition ?? 0)
        guard ordinal != 0, day.ordinal == 0 || setPosition == nil, let word = Self.ordinalWord(ordinal) else { return nil }
        return "the " + word + " " + names[(day.weekday - 1) % 7]
    }

    static func ordinalWord(_ ordinal: Int) -> String? {
        switch ordinal {
        case 1: return "first"
        case 2: return "second"
        case 3: return "third"
        case 4: return "fourth"
        case 5: return "fifth"
        case -1: return "last"
        case -2: return "second to last"
        default: return nil
        }
    }

    static func ordinalNumber(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
