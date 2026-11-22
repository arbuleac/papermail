import Foundation

/// The times Later offers (spec §5.45), worked out in the calendar's time zone so a day boundary, a month end or a
/// daylight-saving change lands where the clock on the wall says. Pure, so every rule is tested on a fixed clock.
/// Each preset is offered only where it lands after the one above it, so the menu reads soonest first and never offers
/// one time twice.
public enum LaterPreset: String, CaseIterable, Sendable {
    /// Three hours from now, rounded up to the next full hour; offered while that is before This Evening's 18:00.
    case laterToday
    /// Today at 18:00; offered before 17:00.
    case thisEvening
    /// The next calendar day at 09:00.
    case tomorrow
    /// The next Monday at 09:00: a week on when today is Monday; not offered on a Sunday, when that Monday is Tomorrow's.
    case nextWeek

    /// The menu item's name (title case, §4.13).
    public var title: String {
        switch self {
        case .laterToday: return "Later Today"
        case .thisEvening: return "This Evening"
        case .tomorrow: return "Tomorrow"
        case .nextWeek: return "Next Week"
        }
    }

    /// The hour Tomorrow, Next Week and Pick a Date's default bring mail back: the start of a working day.
    public static let morningHour = 9
    /// This Evening's hour, before which Later Today must land to be offered.
    public static let eveningHour = 18
    static let eveningOfferedBefore = 17
    static let laterTodayDelay: TimeInterval = 3 * 60 * 60

    /// When this preset brings mail back if chosen at `now`, or nil when it is not offered then.
    public func date(after now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .laterToday:
            // At or past 18:00 it would repeat This Evening's time, or sit above it in the menu with a later one.
            let target = Self.roundedUpToHour(now.addingTimeInterval(Self.laterTodayDelay), calendar: calendar)
            guard let evening = calendar.date(bySettingHour: Self.eveningHour, minute: 0, second: 0, of: today),
                  target < evening else { return nil }
            return target
        case .thisEvening:
            guard let cutoff = calendar.date(bySettingHour: Self.eveningOfferedBefore, minute: 0, second: 0, of: today),
                  now < cutoff else { return nil }
            return calendar.date(bySettingHour: Self.eveningHour, minute: 0, second: 0, of: today)
        case .tomorrow:
            return Self.tomorrowMorning(after: now, calendar: calendar)
        case .nextWeek:
            // The first Monday after today: a week on when today is Monday. On a Sunday it is tomorrow, which Tomorrow
            // already offers at the same time.
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
                  calendar.component(.weekday, from: tomorrow) != 2 else { return nil }
            var day = tomorrow
            for _ in 0..<7 where calendar.component(.weekday, from: day) != 2 {
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
                day = next
            }
            return calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: day)
        }
    }

    /// The presets offered at `now` with their times, in menu order, which is also the order of their times.
    public static func offered(at now: Date, calendar: Calendar) -> [(preset: LaterPreset, date: Date)] {
        allCases.compactMap { preset in preset.date(after: now, calendar: calendar).map { (preset, $0) } }
    }

    /// Pick a Date's starting value: tomorrow at 09:00.
    public static func tomorrowMorning(after now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        return calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: tomorrow)
    }

    /// The day of `day` at the hour and minute of `time`, both read in the calendar's time zone: Pick a Date's calendar
    /// and time field put together.
    public static func combine(day: Date, time: Date, calendar: Calendar) -> Date? {
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: clock.hour ?? morningHour, minute: clock.minute ?? 0, second: 0,
                             of: calendar.startOfDay(for: day))
    }

    /// The start of the next full hour, or `date` itself when it is already on one. Measured on the calendar's own
    /// hours, so the hour repeated when the clocks go back still ends where the clock says.
    static func roundedUpToHour(_ date: Date, calendar: Calendar) -> Date {
        guard let hour = calendar.dateInterval(of: .hour, for: date) else { return date }
        return hour.start == date ? date : hour.end
    }
}
