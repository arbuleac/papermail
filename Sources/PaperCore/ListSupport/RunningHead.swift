import Foundation

/// A date divider in the message list (spec §5.8): local-day groups, newest first. Each head also decides how
/// the rows under it write their time, so a row never repeats what its head already says.
public enum RunningHead: Hashable, Sendable {
    case today
    case yesterday
    case earlierThisWeek
    case lastWeek
    /// A calendar month before last week: "October", or "October 2025" in an earlier year.
    case month(year: Int, month: Int)

    /// The row time shape under this head (spec §4.13).
    public var timeStyle: DateFormatting.Style {
        switch self {
        case .today, .yesterday: return .timeOfDay
        case .earlierThisWeek: return .weekday
        case .lastWeek, .month: return .dayMonth
        }
    }

    /// Heads show only in date-ordered views long enough to need them: never over ranked search results,
    /// and not in a view of fewer than eight conversations, where a divider would outnumber the rows.
    public static let minimumConversations = 8

    public static func showsHeads(conversationCount: Int, isSearch: Bool) -> Bool {
        !isSearch && conversationCount >= minimumConversations
    }
}
