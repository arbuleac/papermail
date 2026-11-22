import Foundation

/// The user's answer to an invitation as the outbox replays it (`MetadataChange.answerInvitation`): everything a
/// provider needs to answer without reading the store, taken from the stored invitation when the user answered.
/// Gmail mails the organizer an iMIP reply built from it and marks the user's own Google Calendar copy; Microsoft
/// answers the event through Graph.
public struct InvitationAnswer: Hashable, Codable, Sendable {
    /// Accepted, tentative or declined.
    public var response: InvitationResponse
    /// The answer recorded on this Mac before this one (`MessageMetadata.invitationReply`), which a give-up puts back.
    /// When that answer is itself given up, never having gone out, the store rewrites this to the one it replaced.
    public var previous: InvitationResponse?
    public var uid: String
    public var sequence: Int
    public var recurrenceID: Date?
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isFloating: Bool
    /// Who the answer goes to.
    public var organizer: EmailAddress
    /// The user as the answer names them: the attendee entry that is theirs, else the account's address.
    public var attendee: EmailAddress
    public var graphEventID: String?
    /// Made once, when the user answers, and kept through every retry: Gmail builds the reply's Message-ID from it and
    /// looks for that message in the mailbox before mailing, so a retry after a send whose reply was lost (a timeout,
    /// a dropped connection, a quit mid-request) never mails the organizer twice. Nil sends without that check.
    public var replyID: String?

    public init(
        response: InvitationResponse,
        previous: InvitationResponse? = nil,
        uid: String,
        sequence: Int = 0,
        recurrenceID: Date? = nil,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        isFloating: Bool = false,
        organizer: EmailAddress,
        attendee: EmailAddress,
        graphEventID: String? = nil,
        replyID: String? = nil
    ) {
        self.response = response
        self.previous = previous
        self.uid = uid
        self.sequence = sequence
        self.recurrenceID = recurrenceID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isFloating = isFloating
        self.organizer = organizer
        self.attendee = attendee
        self.graphEventID = graphEventID
        self.replyID = replyID
    }

    /// The answer to `invitation` from the account `accountEmail`, or nil when it cannot be answered (a cancellation,
    /// the user's own event, no organizer) or `response` is not an answer.
    public init?(_ response: InvitationResponse, to invitation: CalendarInvitation, accountEmail: String, accountName: String?,
                 previous: InvitationResponse?) {
        guard response.isAnswer, invitation.isAnswerable, let organizer = invitation.organizer else { return nil }
        let address = invitation.userAddress ?? accountEmail
        let listed = invitation.attendees.first { $0.address.caseInsensitiveCompare(address) == .orderedSame }
        let name = listed?.name ?? accountName
        self.init(
            response: response,
            previous: previous,
            uid: invitation.uid,
            sequence: invitation.sequence,
            recurrenceID: invitation.recurrenceID,
            title: invitation.title,
            start: invitation.start,
            end: invitation.end,
            isAllDay: invitation.isAllDay,
            isFloating: invitation.isFloating,
            organizer: EmailAddress(name: organizer.name, address: organizer.address),
            attendee: EmailAddress(name: (name?.isEmpty ?? true) ? nil : name, address: address),
            graphEventID: invitation.graphEventID,
            replyID: UUID().uuidString.lowercased()
        )
    }
}
