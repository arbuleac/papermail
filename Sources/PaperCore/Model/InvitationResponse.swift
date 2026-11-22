import Foundation

/// An attendee's answer to an invitation, in iCalendar's words for an event's participation status (PARTSTAT,
/// RFC 5545 §3.2.12). `needsAction` is no answer yet; the other three are the answers the reader offers.
public enum InvitationResponse: String, Codable, Sendable, CaseIterable {
    case needsAction
    case accepted
    case tentative
    case declined

    /// The answers a user can give: Accept · Tentative · Decline, in the card's order.
    public static let answers: [InvitationResponse] = [.accepted, .tentative, .declined]

    /// The PARTSTAT value an iMIP reply carries.
    public var partstat: String {
        switch self {
        case .needsAction: return "NEEDS-ACTION"
        case .accepted: return "ACCEPTED"
        case .tentative: return "TENTATIVE"
        case .declined: return "DECLINED"
        }
    }

    /// Reads a PARTSTAT. `DELEGATED` and the to-do values say nothing the card can show as an answer, so they read
    /// as no answer; an unknown value is nil.
    public init?(partstat: String) {
        switch partstat.trimmingCharacters(in: .whitespaces).uppercased() {
        case "NEEDS-ACTION", "DELEGATED", "IN-PROCESS", "COMPLETED": self = .needsAction
        case "ACCEPTED": self = .accepted
        case "TENTATIVE": self = .tentative
        case "DECLINED": self = .declined
        default: return nil
        }
    }

    /// True for the three answers, false for no answer yet.
    public var isAnswer: Bool { self != .needsAction }
}
