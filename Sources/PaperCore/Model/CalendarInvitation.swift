import Foundation

/// The facts of a calendar invitation a message carries, read once when its body is fetched (sync time) and stored
/// with the body, so opening the message never reads iCalendar. Gmail's come from the message's text/calendar part
/// (`CalendarInvitationReader`); Microsoft's from the event of Graph's event message. Only an invitation
/// (METHOD:REQUEST) or a cancellation (METHOD:CANCEL) is kept: anything the reader could not read whole is none,
/// so the reader shows no card rather than a wrong one.
public struct CalendarInvitation: Hashable, Codable, Sendable {
    public enum Method: String, Codable, Sendable {
        /// An invitation, new or updated: the user can answer it.
        case request
        /// The organizer called it off (METHOD:CANCEL, or an event marked cancelled): nothing to answer.
        case cancel
    }

    /// Someone on the invitation. `response` is their answer as the invitation states it (attendees only).
    public struct Person: Hashable, Codable, Sendable {
        public var name: String?
        public var address: String
        public var response: InvitationResponse?

        public init(name: String? = nil, address: String, response: InvitationResponse? = nil) {
            self.name = name
            self.address = address
            self.response = response
        }

        /// The name, or the address's local part when there is none.
        public var displayName: String {
            if let name, !name.isEmpty { return name }
            return address.split(separator: "@").first.map(String.init) ?? address
        }
    }

    public var method: Method
    /// The event's UID, which an answer names.
    public var uid: String
    /// The revision the organizer sent (SEQUENCE); an answer repeats it.
    public var sequence: Int
    /// For an invitation to one occurrence of a repeating event (RECURRENCE-ID): that occurrence's start, as `start`
    /// is held. An answer repeats it.
    public var recurrenceID: Date?
    /// When the organizer's calendar wrote this revision (DTSTAMP), which orders two revisions with the same SEQUENCE;
    /// nil when not stated, and for Microsoft's (Graph reads the event as it is now, never an earlier revision).
    public var stamp: Date?
    public var title: String
    public var start: Date
    /// Exclusive: an all-day event on 10 November ends at the start of 11 November.
    public var end: Date
    public var isAllDay: Bool
    /// True when `start` and `end` are wall-clock times (all-day dates, or times written without a zone): they are
    /// held as if they were UTC and shown as written, wherever the Mac is.
    public var isFloating: Bool
    /// The zone the event was written in, when it has one: an IANA identifier, or a fixed offset (`GMT+0100`) for a
    /// zone the invitation defines itself. Nil for UTC and floating times.
    public var timeZoneID: String?
    public var location: String?
    /// A meeting link the invitation names apart from its location (Google Meet, Teams).
    public var conferenceURL: String?
    public var organizer: Person?
    /// Everyone invited except rooms and resources, the organizer included when the invitation lists them.
    public var attendees: [Person]
    /// The repeat rule in words (“Every week on Tuesday, until 3 March 2027”), never expanded into occurrences.
    public var repeats: String?
    /// The attendee address that is the user's, when one matched the account's address; never a group's, nor one
    /// inferred from the message's recipients.
    public var userAddress: String?
    /// With no attendee matched as the user, whether the answer is still theirs to give, as the account: Microsoft
    /// answers the user's own copy of the event, so the mailbox is the user whomever the invitation named, and an
    /// invitation to a group (CUTYPE=GROUP) reaches its members, each of whom answers as themselves (RFC 5546 §3.2.3).
    /// Otherwise an invitation that does not name the account (a forward, a Bcc, a copy for a delegate, another of the
    /// user's addresses) is not answered from this account: the answer would speak for someone it never invited. Nil,
    /// as in an invitation stored before it was read, is false.
    public var answersAsAccount: Bool?
    /// The user's answer as the invitation, or for Microsoft the event, stated it when the body was fetched.
    public var userResponse: InvitationResponse?
    /// The user organized it: there is nothing for them to answer.
    public var userIsOrganizer: Bool
    /// The event Microsoft Graph answers through (`/me/events/{id}/accept`); nil for Gmail, or when Graph did not
    /// name it, in which case the answer looks it up from the message.
    public var graphEventID: String?
    /// The iCalendar text handed to Calendar by Open in Calendar: the invitation as it arrived, or for Microsoft
    /// one written from these facts.
    public var calendarText: String?

    public init(
        method: Method,
        uid: String,
        sequence: Int = 0,
        recurrenceID: Date? = nil,
        stamp: Date? = nil,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        isFloating: Bool = false,
        timeZoneID: String? = nil,
        location: String? = nil,
        conferenceURL: String? = nil,
        organizer: Person? = nil,
        attendees: [Person] = [],
        repeats: String? = nil,
        userAddress: String? = nil,
        answersAsAccount: Bool? = nil,
        userResponse: InvitationResponse? = nil,
        userIsOrganizer: Bool = false,
        graphEventID: String? = nil,
        calendarText: String? = nil
    ) {
        self.method = method
        self.uid = uid
        self.sequence = sequence
        self.recurrenceID = recurrenceID
        self.stamp = stamp
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isFloating = isFloating
        self.timeZoneID = timeZoneID
        self.location = location
        self.conferenceURL = conferenceURL
        self.organizer = organizer
        self.attendees = attendees
        self.repeats = repeats
        self.userAddress = userAddress
        self.answersAsAccount = answersAsAccount
        self.userResponse = userResponse
        self.userIsOrganizer = userIsOrganizer
        self.graphEventID = graphEventID
        self.calendarText = calendarText
    }

    public var isCancelled: Bool { method == .cancel }

    /// Whether this is a later revision of the same event, or the same occurrence, than `other` (RFC 5546 §2.1.5): the
    /// same UID and RECURRENCE-ID with a higher SEQUENCE, or the same SEQUENCE and a later DTSTAMP. The earlier one is
    /// not answered: its answer would repeat a SEQUENCE and times the organizer has replaced.
    public func supersedes(_ other: CalendarInvitation) -> Bool {
        guard uid == other.uid, recurrenceID == other.recurrenceID else { return false }
        if sequence != other.sequence { return sequence > other.sequence }
        guard let stamp, let otherStamp = other.stamp else { return false }
        return stamp > otherStamp
    }

    /// Whether the user can answer it: an invitation (not a cancellation) someone else organized, with an organizer
    /// to answer, that is the user's to answer (it names them, or `answersAsAccount`).
    public var isAnswerable: Bool {
        method == .request && !userIsOrganizer && organizer.map { !$0.address.isEmpty } == true
            && (userAddress != nil || answersAsAccount == true)
    }
}
