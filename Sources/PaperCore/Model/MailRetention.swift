import Foundation

/// Settings › General › Keep mail on this Mac (docs/ARCHITECTURE.md, "Storage bounds"): how far back a message keeps
/// its whole body on this Mac. An older message keeps its row, its plain text and its full-text row, so the list,
/// snippets and search are unchanged; its source and rendered HTML are evicted and fetched again when it is opened.
public enum MailRetention: String, CaseIterable, Sendable {
    /// Every body stays: the default, and what the app did before the setting existed.
    case everything
    case oneYear
    case threeMonths

    /// Messages received before this moment lose their source and rendered HTML; nil keeps every body.
    public func cutoff(now: Date) -> Date? {
        switch self {
        case .everything: return nil
        case .oneYear: return Self.calendar.date(byAdding: .year, value: -1, to: now)
        case .threeMonths: return Self.calendar.date(byAdding: .month, value: -3, to: now)
        }
    }

    /// Whether moving from `other` to this window leaves outside it bodies that `other` kept, so a sweep has work.
    /// Widening the window (back to Everything included) evicts nothing more and fetches nothing back.
    public func isNarrower(than other: MailRetention) -> Bool {
        rank > other.rank
    }

    private var rank: Int {
        switch self {
        case .everything: return 0
        case .oneYear: return 1
        case .threeMonths: return 2
        }
    }

    // One calendar in UTC, so "a year ago" is the same moment wherever the Mac thinks it is.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar
    }()
}
