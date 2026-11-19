import Foundation

/// One event on an account's main calendar, as the day column and the week draw it (docs/DATA-MODEL.md, "Calendar
/// events"). The engine reads each account's calendar for a window around today (`CalendarWindow`) and the store keeps
/// what it read; the UI reads only the store. Time the user sets aside for a mail (B, or a row dropped on the
/// calendar) is written here first, as `creating`, and the engine creates it on the provider.
///
/// Repeating events arrive expanded by the provider into single occurrences, each its own event: the app never
/// expands a repeat rule.
public struct CalendarEvent: Hashable, Codable, Sendable, Identifiable {
    /// The user's answer to the event, as the provider states it.
    public enum Response: String, Codable, Sendable, CaseIterable {
        /// The user organized it, or it is on their calendar without an invitation (their own event, a block).
        case organizer
        case accepted
        case tentative
        /// Invited and not answered yet: drawn pencilled in, like an invitation found in mail.
        case needsAction
        /// The calendar keeps it but the user said no: never drawn.
        case declined
    }

    /// Where the event stands between this Mac and the provider.
    public enum Sync: String, Codable, Sendable, CaseIterable {
        /// As the provider last reported it.
        case synced
        /// Set aside on this Mac; the engine has not created it on the provider yet. Drawn as if it were there.
        case creating
        /// Removed on this Mac; the engine has not deleted it on the provider yet. Never drawn.
        case deleting
        /// The provider refused to create it: drawn with the failed mark until the user removes it.
        case failed
    }

    /// Stable local id, unique across accounts: what the UI keys by and the store's primary key. For an event read
    /// from the provider it is derived from the account and `providerID` (`CalendarEvent.localID(accountID:providerID:)`);
    /// for time set aside on this Mac it is made when it is set aside and kept once the provider has created it.
    public var id: String
    public var accountID: AccountID
    /// The provider's id; nil while a block set aside on this Mac waits to be created.
    public var providerID: String?
    public var title: String
    public var location: String?
    /// The first instant. For an all-day event, the start of its first day held as UTC (floating, as
    /// `CalendarInvitation.isFloating` holds it): shown on that date wherever the Mac is.
    public var start: Date
    /// Exclusive. An all-day event on 10 November ends at the start of 11 November (floating, as `start`).
    public var end: Date
    public var isAllDay: Bool
    public var response: Response
    /// Shown as free (Google's `transparency: transparent`, Graph's `showAs: free`): drawn but never counted busy,
    /// so B and the free-time answers look past it.
    public var isFree: Bool
    /// The video call to join (Google Meet's `hangoutLink` or a conference entry point, Teams' `onlineMeeting.joinUrl`).
    public var joinURL: String?
    /// The event on the provider's web calendar (`htmlLink`, `webLink`): Open in Google Calendar or Outlook.
    public var webURL: String?
    /// The organizer's name, or address when there is no name; nil when the user organized it.
    public var organizer: String?
    /// The iCalendar UID the provider gives the event (`iCalUID`, `iCalUId`): an invitation found in mail with the same
    /// UID is this event, so it is drawn once.
    public var invitationUID: String?
    /// For time set aside for a mail: the message it was set aside for, which its details offer to show.
    public var sourceMessage: MessageID?
    /// For time set aside on this Mac: the key this Mac chose for it (`CalendarEvent.newClientKey()`), which makes its
    /// creation idempotent (Google takes it as the event's id, Graph as its `transactionId`) and which a read reports
    /// back, so the store matches the provider's copy to the row that asked for it even when the reply to the create
    /// was lost. Nil for events made elsewhere.
    public var clientKey: String?
    /// For time set aside for a mail: the provider's id of that mail's conversation (Gmail's thread id), which the
    /// engine fills in from the store just before it asks the provider to create the event, so the provider can link
    /// back to the mail without a request of its own. The store never keeps it: it lives only on the copy handed over.
    public var sourceThreadID: String?
    public var sync: Sync
    /// When the provider last changed it, when the provider says.
    public var updatedAt: Date?

    public init(
        id: String,
        accountID: AccountID,
        providerID: String?,
        title: String,
        location: String? = nil,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        response: Response = .organizer,
        isFree: Bool = false,
        joinURL: String? = nil,
        webURL: String? = nil,
        organizer: String? = nil,
        invitationUID: String? = nil,
        sourceMessage: MessageID? = nil,
        clientKey: String? = nil,
        sync: Sync = .synced,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.providerID = providerID
        self.title = title
        self.location = location
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.response = response
        self.isFree = isFree
        self.joinURL = joinURL
        self.webURL = webURL
        self.organizer = organizer
        self.invitationUID = invitationUID
        self.sourceMessage = sourceMessage
        self.clientKey = clientKey
        self.sync = sync
        self.updatedAt = updatedAt
    }

    /// The local id of an event read from the provider: the same for every read of it, so a refresh replaces the row
    /// rather than adding one.
    public static func localID(accountID: AccountID, providerID: String) -> String {
        "\(accountID.rawValue)|\(providerID)"
    }

    /// A new local id for time set aside on this Mac.
    public static func newLocalID(accountID: AccountID) -> String {
        "\(accountID.rawValue)|local-\(UUID().uuidString)"
    }

    /// A new client key: 32 lowercase hexadecimal digits, which Google accepts as an event id (base32hex, 5 to 1,024
    /// characters) and Graph as a `transactionId`. Never reused: Google keeps a deleted event's id reserved.
    public static func newClientKey() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Drawn on the calendar: not declined and not being deleted.
    public var isShown: Bool {
        response != .declined && sync != .deleting
    }

    /// Counted busy: shown, not free, and not an all-day event (an all-day event marks the day, not its hours).
    public var isBusy: Bool {
        isShown && !isFree && !isAllDay
    }

    /// Time the user set aside for a mail from this Mac.
    public var isSetAside: Bool {
        sourceMessage != nil
    }

    /// Whether it overlaps `interval` (end exclusive; an event of no length overlaps the instant it starts at).
    public func overlaps(_ interval: DateInterval) -> Bool {
        if start == end { return start >= interval.start && start < interval.end }
        return start < interval.end && end > interval.start
    }
}
