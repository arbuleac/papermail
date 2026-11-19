import Foundation

/// What a provider reads and writes on the account's main calendar, beside `MailProvider` (Gmail's provider reads
/// Google Calendar; Graph's reads Outlook's default calendar). A provider that has no calendar (a test double) does
/// not adopt it, and the engine then reads nothing for that account.
///
/// Every call needs `AccountPermission.calendar`; the engine asks `hasCalendarPermission()` first, which costs no
/// request (the granted scopes come with the token).
public protocol CalendarProvider: Sendable {
    /// Whether the account's token holds the calendar scope.
    func hasCalendarPermission() async -> Bool

    /// Every event on the account's main calendar that overlaps `window`, repeats expanded into single occurrences,
    /// every page read. Cancelled events are left out; declined ones are kept with `response == .declined` (the store
    /// keeps them so a refresh does not bring them back as new, and the UI never draws them). Each event's `id` is
    /// `CalendarEvent.localID(accountID:providerID:)` and its `sync` is `.synced`.
    /// Throws `CalendarProviderError` for the calendar's own refusals, `ProviderError` for the rest.
    func calendarEvents(in window: DateInterval) async throws -> CalendarListing

    /// Creates `event` (time set aside for a mail: title, start, end, and a description that links back to the mail)
    /// on the main calendar, shown as busy, with no attendees and no reminders. Idempotent through `event.clientKey`
    /// (Google: the event's id plus a private extended property; Graph: `transactionId`): creating it again after a
    /// lost reply returns the copy already made rather than a second one. Every read reports `clientKey` back for the
    /// events made this way. Returns it as the provider now has it: its `providerID`, `webURL` and `updatedAt` filled
    /// in, its local `id`, `clientKey` and `sourceMessage` kept, `sync == .synced`.
    func createCalendarEvent(_ event: CalendarEvent) async throws -> CalendarEvent

    /// Deletes the event. An event the provider no longer has counts as deleted (no throw).
    func deleteCalendarEvent(providerID: String) async throws
}

/// One read of a calendar window.
public struct CalendarListing: Sendable {
    public var events: [CalendarEvent]
    /// The requests the read made (one per page), which the engine charges to the account.
    public var requestCount: Int

    public init(events: [CalendarEvent], requestCount: Int) {
        self.events = events
        self.requestCount = requestCount
    }
}

/// The calendar's own refusals, apart from `ProviderError`, so the engine can say what the user can do about them.
public enum CalendarProviderError: Error, Sendable, Equatable {
    /// The token lacks the calendar scope (Google's `insufficientPermissions`, Graph's 403 for the calendar):
    /// Connect asks for it.
    case permissionMissing
    /// Google answered that the Calendar API is not enabled for the OAuth client (`accessNotConfigured`,
    /// `SERVICE_DISABLED`).
    case apiDisabled
}
