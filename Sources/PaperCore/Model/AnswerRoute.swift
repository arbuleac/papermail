import Foundation

/// How an answer given from an event's details reaches the provider: through the invitation's message (the reader
/// card's way), or on the calendar with no message (`InvitationAnswer.calendar.providerEventID`).
public enum AnswerRoute: String, Codable, Sendable, CaseIterable {
    case mail
    case calendar
}
