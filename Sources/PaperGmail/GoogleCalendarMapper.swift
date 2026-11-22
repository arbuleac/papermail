import Foundation
import PaperCore

/// Turns Google Calendar events into `CalendarEvent`s. One mapper serves one read: its formatters are built once for
/// every event of every page, and are not shared beyond it.
struct GoogleCalendarMapper {
    let accountID: AccountID

    /// The private extended property a block set aside on this Mac carries its client key in, so a read reports the
    /// key back even when the reply to the create was lost (`CalendarEvent.clientKey`). A block made before the app was
    /// renamed carries it under the old name, read after this one.
    static let clientKeyProperty = "paperKey"

    private let wholeSeconds = ISO8601DateFormatter()
    private let fractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    init(accountID: AccountID) {
        self.accountID = accountID
    }

    /// The event as the calendar draws it, or nil for one it leaves out: cancelled (a deleted occurrence of a series
    /// comes back as one), a working location (where the user works that day, not time they are busy), or one whose
    /// times do not read.
    func event(from item: GoogleCalendarEvent) -> CalendarEvent? {
        guard item.status != "cancelled", item.eventType != "workingLocation" else { return nil }
        guard let start = item.start, let times = times(start: start, end: item.end) else { return nil }
        return CalendarEvent(
            id: CalendarEvent.localID(accountID: accountID, providerID: item.id),
            accountID: accountID,
            providerID: item.id,
            title: Self.trimmed(item.summary) ?? "",
            location: Self.trimmed(item.location),
            start: times.start,
            end: times.end,
            isAllDay: times.isAllDay,
            response: Self.response(of: item),
            isFree: item.transparency == "transparent",
            joinURL: Self.joinURL(of: item),
            webURL: Self.secureWebAddress(item.htmlLink),
            organizer: item.organizer?.isSelf == true ? nil : Self.trimmed(item.organizer?.displayName) ?? Self.trimmed(item.organizer?.email),
            invitationUID: Self.trimmed(item.iCalUID),
            clientKey: Self.clientKey(item.extendedProperties?.privateProperties),
            sync: .synced,
            updatedAt: item.updated.flatMap(instant(_:))
        )
    }

    /// Where the event sits. An all-day event's dates are held as UTC midnights (floating), its end exclusive as Google
    /// gives it; a timed one's are the instants its offsets name. An end before the start (or missing) is taken as one
    /// day for an all-day event and as no length for a timed one.
    func times(start: GoogleCalendarEvent.Time, end: GoogleCalendarEvent.Time?) -> (start: Date, end: Date, isAllDay: Bool)? {
        if let day = start.date {
            guard let first = Self.floatingDay(day) else { return nil }
            let last = end?.date.flatMap(Self.floatingDay).flatMap { $0 > first ? $0 : nil }
            return (first, last ?? first.addingTimeInterval(86_400), true)
        }
        guard let first = start.dateTime.flatMap(instant(_:)) else { return nil }
        let last = end?.dateTime.flatMap(instant(_:)).map { max($0, first) }
        return (first, last ?? first, false)
    }

    /// An RFC 3339 time, with or without fractional seconds (`updated` has them, `dateTime` does not).
    func instant(_ text: String) -> Date? {
        wholeSeconds.date(from: text) ?? fractionalSeconds.date(from: text)
    }

    /// `yyyy-MM-dd` as the UTC midnight that starts it.
    static func floatingDay(_ text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = utcCalendar.date(from: components),
              utcCalendar.component(.day, from: date) == day else { return nil }
        return date
    }

    /// The user's answer: their own attendee entry (`self`) says it, unless they organized the event or it lists no
    /// one (their own event, a block), which they own.
    static func response(of item: GoogleCalendarEvent) -> CalendarEvent.Response {
        if item.organizer?.isSelf == true { return .organizer }
        guard let own = item.attendees?.first(where: { $0.isSelf == true }) else { return .organizer }
        switch own.responseStatus {
        case "accepted": return .accepted
        case "tentative": return .tentative
        case "declined": return .declined
        default: return .needsAction
        }
    }

    /// Meet's link, else the conference's video entry point (Zoom and others added through a Calendar add-on), when it
    /// is an https address.
    static func joinURL(of item: GoogleCalendarEvent) -> String? {
        let video = item.conferenceData?.entryPoints?.first { $0.entryPointType == "video" && trimmed($0.uri) != nil }?.uri
        return [item.hangoutLink, video].lazy.compactMap(secureWebAddress).first
    }

    /// `value` when it is one https address: Join and Open in Google Calendar open nothing else (the window refuses any
    /// other scheme, http included), so a link it would refuse is never offered as a button that does nothing.
    static func secureWebAddress(_ value: String?) -> String? {
        guard let value = trimmed(value), CalendarInvitationReader.webAddress(value)?.scheme?.lowercased() == "https" else {
            return nil
        }
        return value
    }

    /// The client key from an event's private properties: the current property, else the one written before the rename.
    static func clientKey(_ properties: [String: String]?) -> String? {
        trimmed(properties?[clientKeyProperty]) ?? trimmed(properties?[LegacyIdentity.googleCalendarClientKeyProperty])
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
