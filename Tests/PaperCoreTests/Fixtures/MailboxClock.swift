import Foundation

/// Millisecond-aligned dates: the SQLite store keeps epoch milliseconds, so fixtures with finer precision
/// would never compare equal after a round trip.
public enum MailboxClock {
    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    public static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// `date` rounded to whole milliseconds.
    public static func aligned(_ date: Date) -> Date {
        self.date(milliseconds(date))
    }
}
