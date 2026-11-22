import Foundation

/// How soon the reader needs a body it asks the engine for (`MailClient.ensureBody(for:priority:)`). Every one of them
/// comes before the account's background work: while one waits or is on its way, the backfill sends nothing and the live
/// lane's prefetch of new mail's bodies and the calendar's read hold back (docs/ARCHITECTURE.md, "Opening a message").
/// Among themselves they go highest first.
public enum BodyFetchPriority: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    /// A conversation the reader pre-renders beside the one shown.
    case prefetch
    /// A message of the open conversation the reader shows folded.
    case conversation
    /// A message the reader shows open: the newest, or one the user expanded or picked. Sent at once, whatever else waits.
    case opened

    public static func < (lhs: BodyFetchPriority, rhs: BodyFetchPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .prefetch: return "prefetch"
        case .conversation: return "conversation"
        case .opened: return "opened"
        }
    }
}
