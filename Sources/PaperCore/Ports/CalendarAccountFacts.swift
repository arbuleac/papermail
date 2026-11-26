import Foundation

/// What a details read needs of the account and the Mac: the account's address (Graph's attendee list names the user
/// only by it), and the zone and locale a series' rule is said in.
public struct CalendarAccountFacts: Sendable {
    public var email: String
    public var timeZone: TimeZone
    public var locale: Locale

    public init(email: String, timeZone: TimeZone = .current, locale: Locale = .current) {
        self.email = email
        self.timeZone = timeZone
        self.locale = locale
    }
}
