import Foundation

/// A DATE or DATE-TIME value (RFC 5545 §3.3.4, §3.3.5) resolved to an instant.
struct ICalendarTimeValue: Equatable, Sendable {
    /// The instant. For a date, or a time written without a zone (floating), the wall-clock time read as UTC.
    var date: Date
    var isDate: Bool
    var isFloating: Bool
    /// The zone it was written in: an IANA identifier, or a fixed offset (`GMT+0100`) for a zone the calendar defines
    /// itself. Nil for UTC, dates and floating times.
    var timeZoneID: String?
    /// The wall-clock fields as written.
    var local: ICalendarLocalTime
}

/// Wall-clock fields as an iCalendar value writes them.
struct ICalendarLocalTime: Equatable, Comparable, Sendable {
    var year: Int
    var month: Int
    var day: Int
    var hour = 0
    var minute = 0
    var second = 0

    init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// The fields of `date` read in UTC: the inverse of `asUTC`.
    init(utc date: Date) {
        let fields = ICalendarTimes.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.init(year: fields.year ?? 1970, month: fields.month ?? 1, day: fields.day ?? 1, hour: fields.hour ?? 0,
                  minute: fields.minute ?? 0, second: fields.second ?? 0)
    }

    /// The fields read as a UTC time; how wall-clock times are compared and held.
    var asUTC: Date? {
        ICalendarTimes.utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }

    static func < (lhs: ICalendarLocalTime, rhs: ICalendarLocalTime) -> Bool {
        (lhs.year, lhs.month, lhs.day, lhs.hour, lhs.minute, lhs.second) < (rhs.year, rhs.month, rhs.day, rhs.hour, rhs.minute, rhs.second)
    }
}

/// Reading DATE and DATE-TIME values, with their TZID resolved through the calendar's own VTIMEZONE definitions when
/// the name alone is not a zone the Mac knows.
struct ICalendarTimes: Sendable {
    /// Gregorian in UTC: how floating times and dates are held.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private enum Zone {
        case known(TimeZone)
        case defined(ICalendarDefinedZone)
    }

    private let definitions: [String: ICalendarComponent]

    init(calendar: ICalendarComponent) {
        var definitions: [String: ICalendarComponent] = [:]
        for zone in calendar.children("VTIMEZONE") {
            // The property is TEXT, so a comma or semicolon in the name comes escaped; the TZID parameter that names it
            // quotes them instead.
            if let id = zone.first("TZID")?.text.trimmingCharacters(in: .whitespaces), !id.isEmpty {
                definitions[id] = zone
            }
        }
        self.definitions = definitions
    }

    /// The property's value, or nil when it is malformed, names a zone that cannot be resolved, or is a DATE-TIME
    /// marked VALUE=DATE (or the reverse).
    func value(of property: ICalendarProperty) -> ICalendarTimeValue? {
        let raw = property.value.trimmingCharacters(in: .whitespaces)
        let declared = property.parameter("VALUE")?.uppercased()
        guard let parsed = Self.parse(raw) else { return nil }
        if parsed.isDate {
            guard declared == nil || declared == "DATE", let date = parsed.local.asUTC else { return nil }
            return ICalendarTimeValue(date: date, isDate: true, isFloating: true, timeZoneID: nil, local: parsed.local)
        }
        guard declared == nil || declared == "DATE-TIME", let wall = parsed.local.asUTC else { return nil }
        if parsed.isUTC {
            return ICalendarTimeValue(date: wall, isDate: false, isFloating: false, timeZoneID: nil, local: parsed.local)
        }
        guard let tzid = property.parameter("TZID")?.trimmingCharacters(in: .whitespaces), !tzid.isEmpty else {
            return ICalendarTimeValue(date: wall, isDate: false, isFloating: true, timeZoneID: nil, local: parsed.local)
        }
        switch zone(named: tzid) {
        case .known(let zone)?:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let local = parsed.local
            guard let date = calendar.date(from: DateComponents(year: local.year, month: local.month, day: local.day,
                                                                hour: local.hour, minute: local.minute, second: local.second)) else {
                return nil
            }
            let id = zone.identifier == "Etc/UTC" || zone.identifier == "GMT" ? nil : zone.identifier
            return ICalendarTimeValue(date: date, isDate: false, isFloating: false, timeZoneID: id, local: local)
        case .defined(let zone)?:
            guard let offset = zone.offset(at: parsed.local) else { return nil }
            let date = wall.addingTimeInterval(-TimeInterval(offset))
            let id = offset == 0 ? nil : TimeZone(secondsFromGMT: offset)?.identifier
            return ICalendarTimeValue(date: date, isDate: false, isFloating: false, timeZoneID: id, local: parsed.local)
        case nil:
            return nil
        }
    }

    private func zone(named tzid: String) -> Zone? {
        if let zone = CalendarTimeZones.timeZone(named: tzid) { return .known(zone) }
        guard let definition = definitions[tzid] else { return nil }
        // Mozilla and Google put the IANA name beside their own definition.
        if let location = definition.first("X-LIC-LOCATION")?.text, let zone = CalendarTimeZones.timeZone(named: location) {
            return .known(zone)
        }
        return ICalendarDefinedZone(definition).map(Zone.defined)
    }

    /// `20261110` (a date), `20261110T150000` (floating) or `20261110T150000Z` (UTC); nil for anything else or a
    /// field out of range.
    static func parse(_ raw: String) -> (local: ICalendarLocalTime, isDate: Bool, isUTC: Bool)? {
        let characters = Array(raw.utf8)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= characters.count else { return nil }
            var value = 0
            for index in range {
                let c = characters[index]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8) else { return nil }
        var local = ICalendarLocalTime(year: year, month: month, day: day)
        var isDate = true
        var isUTC = false
        if characters.count == 8 {
            isDate = true
        } else if characters.count == 15 || characters.count == 16, characters[8] == UInt8(ascii: "T") {
            guard let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15) else { return nil }
            local.hour = hour
            local.minute = minute
            local.second = second
            isDate = false
            if characters.count == 16 {
                guard characters[15] == UInt8(ascii: "Z") || characters[15] == UInt8(ascii: "z") else { return nil }
                isUTC = true
            }
        } else {
            return nil
        }
        // 20261340 or 25:00 would roll over into another day rather than fail.
        guard (1...12).contains(local.month), (1...31).contains(local.day), (0...23).contains(local.hour), (0...59).contains(local.minute),
              (0...60).contains(local.second), let date = local.asUTC else { return nil }
        let back = utc.dateComponents([.year, .month, .day], from: date)
        guard back.year == local.year, back.month == local.month, back.day == local.day else { return nil }
        return (local, isDate, isUTC)
    }

    /// A DURATION (RFC 5545 §3.3.6): `P1D`, `PT1H30M`, `P2W`, signed; nil when malformed.
    static func duration(_ raw: String) -> TimeInterval? {
        var text = Substring(raw.trimmingCharacters(in: .whitespaces).uppercased())
        var sign: TimeInterval = 1
        if text.first == "+" { text = text.dropFirst() } else if text.first == "-" { sign = -1; text = text.dropFirst() }
        guard text.first == "P" else { return nil }
        text = text.dropFirst()
        var total: TimeInterval = 0
        var digits = ""
        var inTime = false
        var sawUnit = false
        for character in text {
            if character.isNumber {
                digits.append(character)
                continue
            }
            if character == "T" {
                guard digits.isEmpty, !inTime else { return nil }
                inTime = true
                continue
            }
            guard let value = Double(digits) else { return nil }
            digits = ""
            switch (character, inTime) {
            case ("W", false): total += value * 7 * 86_400
            case ("D", false): total += value * 86_400
            case ("H", true): total += value * 3_600
            case ("M", true): total += value * 60
            case ("S", true): total += value
            default: return nil
            }
            sawUnit = true
        }
        guard digits.isEmpty, sawUnit else { return nil }
        return sign * total
    }
}

/// A zone a calendar defines in its VTIMEZONE, for a TZID the Mac does not know by name (Outlook's “Customized Time
/// Zone”): its STANDARD and DAYLIGHT observances, each starting on a date and repeating yearly on a month's nth
/// weekday or a fixed day. A definition in any other shape is not read.
struct ICalendarDefinedZone: Sendable {
    private struct Observance: Sendable {
        var start: ICalendarLocalTime
        var offsetTo: Int
        var rule: RecurrenceRule?
    }

    private let observances: [Observance]

    init?(_ definition: ICalendarComponent) {
        var observances: [Observance] = []
        for component in definition.components where component.name == "STANDARD" || component.name == "DAYLIGHT" {
            guard let startProperty = component.first("DTSTART"),
                  let start = ICalendarTimes.parse(startProperty.value.trimmingCharacters(in: .whitespaces)), !start.isUTC,
                  let offsetText = component.first("TZOFFSETTO")?.value, let offsetTo = Self.offset(offsetText) else { return nil }
            var rule: RecurrenceRule?
            if let ruleText = component.first("RRULE")?.value {
                guard let parsed = RecurrenceRule(rrule: ruleText), parsed.frequency == .yearly, parsed.interval == 1,
                      parsed.months.count == 1, parsed.days.count + parsed.monthDays.count == 1 else { return nil }
                rule = parsed
            }
            observances.append(Observance(start: start.local, offsetTo: offsetTo, rule: rule))
        }
        guard !observances.isEmpty else { return nil }
        self.observances = observances
    }

    /// The offset from UTC, in seconds, at a wall-clock time in this zone: that of the observance that began last
    /// before it. Nil before the first observance begins.
    func offset(at local: ICalendarLocalTime) -> Int? {
        var latest: (onset: ICalendarLocalTime, offset: Int)?
        for observance in observances {
            for onset in onsets(of: observance, around: local.year) where onset <= local {
                if latest == nil || latest!.onset < onset { latest = (onset, observance.offsetTo) }
            }
        }
        return latest?.offset
    }

    private func onsets(of observance: Observance, around year: Int) -> [ICalendarLocalTime] {
        guard let rule = observance.rule else { return [observance.start] }
        var onsets: [ICalendarLocalTime] = []
        for candidateYear in [year - 1, year] where candidateYear >= observance.start.year {
            guard let month = rule.months.first, let day = Self.day(of: rule, year: candidateYear, month: month) else { continue }
            let onset = ICalendarLocalTime(year: candidateYear, month: month, day: day, hour: observance.start.hour,
                                           minute: observance.start.minute, second: observance.start.second)
            if let until = rule.until, let onsetDate = onset.asUTC, onsetDate > until { continue }
            onsets.append(onset)
        }
        return onsets
    }

    /// The day of the month a yearly rule falls on in that year: a fixed day, or the nth (or nth-last) weekday.
    private static func day(of rule: RecurrenceRule, year: Int, month: Int) -> Int? {
        let calendar = ICalendarTimes.utc
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let length = calendar.range(of: .day, in: .month, for: first)?.count else { return nil }
        if let monthDay = rule.monthDays.first {
            let day = monthDay > 0 ? monthDay : length + monthDay + 1
            return (1...length).contains(day) ? day : nil
        }
        guard let target = rule.days.first, target.ordinal != 0 else { return nil }
        let firstWeekday = calendar.component(.weekday, from: first)
        if target.ordinal > 0 {
            let day = 1 + (target.weekday - firstWeekday + 7) % 7 + (target.ordinal - 1) * 7
            return day <= length ? day : nil
        }
        let lastWeekday = (firstWeekday + length - 1 - 1) % 7 + 1
        let day = length - (lastWeekday - target.weekday + 7) % 7 + (target.ordinal + 1) * 7
        return day >= 1 ? day : nil
    }

    /// `+0100`, `-0530`, `+010000`: seconds east of UTC.
    static func offset(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = text.dropFirst()
        guard digits.count == 4 || digits.count == 6, digits.allSatisfy(\.isNumber),
              let hours = Int(digits.prefix(2)), let minutes = Int(digits.dropFirst(2).prefix(2)) else { return nil }
        let seconds = digits.count == 6 ? Int(digits.suffix(2)) ?? 0 : 0
        guard hours < 24, minutes < 60 else { return nil }
        let total = hours * 3_600 + minutes * 60 + seconds
        return sign == "-" ? -total : total
    }
}
