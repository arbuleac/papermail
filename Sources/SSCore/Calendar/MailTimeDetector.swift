import Foundation

/// Finds the days and times of day a message's own words name (“Could we move our call to Friday at 3pm?”), once, when
/// its body is stored (`Hydrator`), so selecting the conversation never reads its text again (docs/DATA-MODEL.md,
/// "Mail times"). The system's date detector reads the words; this decides which of its finds are times the calendar
/// can mark and B can set time aside at.
///
/// The detector resolves relative words (“tomorrow”, “Friday”) against the moment it runs, not the day the mail was
/// written, so only mail received in the last `recentDays` days is read: in older mail “tomorrow” has long passed and
/// would land on the wrong day. What is kept is a time of day (a date alone, “charged on 1 December”, never is), still
/// to come, inside the calendar's window (`CalendarWindow`), from the message's own words rather than the replies it
/// quotes, at most `maximumTimes` of them.
struct MailTimeDetector: @unchecked Sendable {
    /// The most times kept for one message: a mail proposing a few slots, not a timetable.
    static let maximumTimes = 3
    /// The most of a message's own words read, in UTF-8 bytes. The detector costs about a millisecond per kilobyte and
    /// runs beside the sanitizer for every recent body, and a time worth marking sits near the top of a mail.
    static let maximumScannedLength = 16 * 1024
    /// Mail received longer ago than this is not read (see above).
    static let recentDays = 3

    /// One for the process: building the detector costs several milliseconds, and matching on it is thread-safe
    /// (`NSRegularExpression` is immutable), so the hydrator's concurrent fetches share it.
    static let shared = MailTimeDetector()

    private let detector: NSDataDetector?

    init() {
        detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    }

    /// The times `plainText` names, in the order the text names them. Empty when the message was received more than
    /// `recentDays` days before `now`.
    ///
    /// - Parameters:
    ///   - received: when the message arrived (`MessageMetadata.date`).
    ///   - window: the span kept; `CalendarWindow.around(now, calendar:)` when nil.
    ///   - calendar: the zone the words are read in. The system detector reads a wall clock in the Mac's own zone; a
    ///     time it found with no zone of its own is read again as the same wall clock in `calendar`'s.
    func times(in plainText: String, messageID: MessageID, received: Date, now: Date, window: DateInterval? = nil,
               calendar: Calendar = .autoupdatingCurrent) -> [MailTime] {
        guard let detector, Self.isRecent(received, now: now, calendar: calendar) else { return [] }
        let text = Self.ownWords(of: plainText)
        // Most mail names no time of day at all, and this look costs a fraction of the detector's.
        guard Self.namesTimeOfDay(text) else { return [] }
        let window = window ?? CalendarWindow.around(now, calendar: calendar)
        let scanned = text as NSString
        var found: [MailTime] = []
        var starts: Set<Date> = []
        for match in detector.matches(in: text, range: NSRange(location: 0, length: scanned.length)) {
            guard let date = match.date else { continue }
            let phrase = scanned.substring(with: match.range)
            guard Self.namesTimeOfDay(phrase) else { continue }
            let start = match.timeZone == nil ? Self.wallClock(of: date, in: calendar) : date
            // A slot named twice (asked, then confirmed lower down) marks the calendar once.
            guard start > now, start >= window.start, start < window.end, starts.insert(start).inserted else { continue }
            found.append(MailTime(messageID: messageID, start: start, duration: match.duration > 0 ? match.duration : nil,
                                  phrase: phrase))
            if found.count == Self.maximumTimes { break }
        }
        return found
    }

    private static func isRecent(_ received: Date, now: Date, calendar: Calendar) -> Bool {
        let earliest = calendar.date(byAdding: .day, value: -recentDays, to: now) ?? now.addingTimeInterval(-Double(recentDays) * 86_400)
        return received >= earliest
    }

    // MARK: Time of day

    /// Whether `text` names a time of day rather than only a date. The system detector gives a date for “25 Nov” too
    /// (at noon) and says nothing of whether a time was written, so the words decide: digits with am or pm (“3pm”,
    /// “10:30 a.m.”), hours and minutes (“14:30”, the French and Portuguese “14h30”), the German “15 Uhr”, “3 o'clock”,
    /// a bare hour after “at” or “@” (“tomorrow at 10”), “noon” and “midnight”. Other languages' words are left to the
    /// detector, which reads them, but one of these forms must be among them.
    static func namesTimeOfDay(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return timeOfDayPattern?.firstMatch(in: text, range: range) != nil
    }

    private static let timeOfDayPattern = try? NSRegularExpression(
        pattern: [
            #"\b\d{1,2}(?::\d{2})?\s?[ap]\.?m\b"#,
            #"\b\d{1,2}:\d{2}\b"#,
            #"\b\d{1,2}h\d{2}\b"#,
            #"\b\d{1,2}\s?uhr\b"#,
            #"\b\d{1,2}\s?o['’]clock\b"#,
            #"(?:\bat|@)\s?\d{1,2}\b"#,
            #"\bnoon\b"#,
            #"\bmidnight\b"#,
        ].joined(separator: "|"),
        options: [.caseInsensitive]
    )

    /// `date`, a wall clock the system detector read in the Mac's zone, as the same wall clock in `calendar`'s zone.
    private static func wallClock(of date: Date, in calendar: Calendar) -> Date {
        guard calendar.timeZone.identifier != TimeZone.current.identifier else { return date }
        var source = Calendar(identifier: .gregorian)
        source.timeZone = .current
        var target = source
        target.timeZone = calendar.timeZone
        let parts = source.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
        return target.date(from: parts) ?? date
    }

    // MARK: The message's own words

    /// The words the sender wrote, without the replies they quote, cut to `maximumScannedLength` (`QuotedHistory`).
    static func ownWords(of plainText: String) -> String {
        QuotedHistory.ownWords(of: plainText, limit: maximumScannedLength)
    }
}
