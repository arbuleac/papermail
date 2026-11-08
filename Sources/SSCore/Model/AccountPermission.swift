import Foundation

/// A permission an account grants beyond reading and sending mail, asked for only when the user first does what
/// needs it: the account reconnects with the added scope (incremental authorization) and the work that waited for
/// it goes out.
public enum AccountPermission: String, Codable, Sendable, CaseIterable {
    /// Updating the user's calendar, to answer invitations: Google's `calendar.events`, Microsoft's
    /// `Calendars.ReadWrite`.
    case calendar
}
