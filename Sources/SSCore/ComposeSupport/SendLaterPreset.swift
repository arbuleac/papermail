import Foundation

/// The times Send Later offers in the Send button's drop-down (spec §5.23), before Pick a Time…: the start of the next
/// working morning and of the next week, worked out as Later works out its own (`LaterPreset`), in the calendar's time
/// zone, so a daylight-saving change lands where the clock on the wall says. Pure, so the rules are tested on a fixed
/// clock.
public enum SendLaterPreset: String, CaseIterable, Sendable {
    /// The next calendar day at 09:00.
    case tomorrow
    /// The next Monday at 09:00: a week on when today is Monday; not offered on a Sunday, when that Monday is Tomorrow's.
    case monday

    /// The menu item's name (title case, §4.13).
    public var title: String {
        switch self {
        case .tomorrow: return "Tomorrow"
        case .monday: return "Monday"
        }
    }

    /// When this preset sends if chosen at `now`, or nil when it is not offered then.
    public func date(after now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .tomorrow: return LaterPreset.tomorrow.date(after: now, calendar: calendar)
        case .monday: return LaterPreset.nextWeek.date(after: now, calendar: calendar)
        }
    }

    /// The presets offered at `now` with their times, in menu order, which is also the order of their times.
    public static func offered(at now: Date, calendar: Calendar) -> [(preset: SendLaterPreset, date: Date)] {
        allCases.compactMap { preset in preset.date(after: now, calendar: calendar).map { (preset, $0) } }
    }

    /// Pick a Time's starting value: tomorrow at 09:00, as Later's Pick a Date opens.
    public static func pickerStart(after now: Date, calendar: Calendar) -> Date? {
        LaterPreset.tomorrowMorning(after: now, calendar: calendar)
    }
}
