import Foundation
import PaperCore

/// An event's start and end as Graph writes them: a wall-clock `dateTime` with no offset and seven fractional digits
/// (`2026-11-10T15:00:00.0000000`) beside the name of its zone (`UTC` under `Prefer: outlook.timezone="UTC"`, otherwise
/// a Windows or IANA name). `GraphDate` cannot read these: it needs a `Z` or an offset.
///
/// The digits are read by hand rather than through a DateFormatter, which costs some 45 µs a parse: a calendar read
/// maps hundreds of events, two times each, and a window of 500 took 90 ms to map that way against 7 ms this way.
enum GraphEventTime {
    /// The instant `value` names, and the day it is written on, read as that date's UTC midnight (an all-day event's
    /// day goes through `allDay(_:originalZone:)`, which starts from it). Nil when the `dateTime` is not a whole date
    /// and time to the second (fractional digits after it are dropped).
    static func read(_ value: GraphDateTimeZone) -> (date: Date, day: Date?)? {
        guard let text = value.dateTime, let wall = wallClock(text) else { return nil }
        let zone = value.timeZone.flatMap(CalendarTimeZones.timeZone(named:)) ?? utc
        let day = Double(daysFromCivil(year: wall.year, month: wall.month, day: wall.day)) * 86_400
        let asUTC = Date(timeIntervalSince1970: day + Double(wall.hour * 3_600 + wall.minute * 60 + wall.second))
        // The zone's offset at that wall clock: the offset at the instant first guessed, taken again at the instant it
        // gives, so a time just after a change of offset lands on the right side of it.
        let guess = asUTC.addingTimeInterval(-Double(zone.secondsFromGMT(for: asUTC)))
        let date = asUTC.addingTimeInterval(-Double(zone.secondsFromGMT(for: guess)))
        return (date, Date(timeIntervalSince1970: day))
    }

    /// An all-day event's day, as that date's UTC midnight (floating). Exchange keeps an all-day event as midnight to
    /// midnight in the zone it was made in, and `Prefer: outlook.timezone="UTC"` moves that midnight with the rest:
    /// a Berlin holiday on 19 November comes back as `2026-11-18T23:00:00` UTC. So a wall clock at midnight is the
    /// date as written (a UTC calendar, or Graph keeping the date as it is), and any other is taken back to the
    /// midnight nearest it in `originalZone` (`originalStartTimeZone`, `originalEndTimeZone`), else in UTC. Nearest,
    /// not the day it falls on, so a zone whose rules moved by an hour since still lands on its own date.
    static func allDay(_ value: GraphDateTimeZone, originalZone: String?) -> Date? {
        guard let text = value.dateTime, let wall = wallClock(text), let parsed = Self.read(value) else { return nil }
        if wall.hour == 0, wall.minute == 0, wall.second == 0 { return parsed.day }
        let instant = parsed.date.timeIntervalSince1970
        let offset = originalZone.flatMap(CalendarTimeZones.timeZone(named:)).map { Double($0.secondsFromGMT(for: parsed.date)) } ?? 0
        return Date(timeIntervalSince1970: ((instant + offset + 43_200) / 86_400).rounded(.down) * 86_400)
    }

    /// `dateTime` for a request: the instant's UTC wall clock to the second, without a `Z`, for `timeZone: "UTC"`
    /// beside it.
    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    private static let utc = TimeZone(identifier: "UTC")!

    private struct WallClock {
        var year, month, day, hour, minute, second: Int
    }

    /// `yyyy-MM-ddTHH:mm:ss`, then nothing or a fraction.
    private static func wallClock(_ text: String) -> WallClock? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 19, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":") else { return nil }
        if bytes.count > 19 {
            guard bytes[19] == UInt8(ascii: "."), bytes[20...].allSatisfy(isDigit) else { return nil }
        }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard isDigit(bytes[index]) else { return nil }
                value = value * 10 + Int(bytes[index] - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day),
              hour < 24, minute < 60, second < 60 else { return nil }
        return WallClock(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days from 1970-01-01 to the proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
