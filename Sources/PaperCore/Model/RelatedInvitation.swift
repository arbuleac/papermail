import Foundation

/// A message in the store carrying an invitation to a calendar event (`MailStoring.invitationMessages(for:)`): what an
/// event's details show as its mail, answer through when it names the span answered, and read as cancelled when the
/// latest is a cancellation.
public struct RelatedInvitation: Hashable, Sendable {
    public var message: MessageMetadata
    public var invitation: CalendarInvitation

    public init(message: MessageMetadata, invitation: CalendarInvitation) {
        self.message = message
        self.invitation = invitation
    }

    /// The one that stands for `event` among `candidates` (newest first, as the store returns them): for an occurrence,
    /// the invitation to that occurrence when there is one, else the series'; for a single event, one with no
    /// RECURRENCE-ID. An occurrence's own invitation never stands for another occurrence. Of those, the latest revision
    /// (none another supersedes), then the newest message. Nil when none fits.
    public static func pick(_ candidates: [RelatedInvitation], for event: CalendarEvent) -> RelatedInvitation? {
        let original = event.originalStart ?? event.start
        let own = candidates.filter { candidate in
            guard let recurrence = candidate.invitation.recurrenceID else { return false }
            return abs(recurrence.timeIntervalSince(original)) <= 1
        }
        let whole = candidates.filter { $0.invitation.recurrenceID == nil }
        let fitting: [RelatedInvitation]
        if event.seriesID != nil {
            fitting = own.isEmpty ? whole : own
        } else {
            fitting = whole.isEmpty ? own : whole
        }
        let latest = fitting.filter { candidate in
            !fitting.contains { other in other != candidate && other.invitation.supersedes(candidate.invitation) }
        }
        return latest.max { $0.message.date < $1.message.date }
    }
}
