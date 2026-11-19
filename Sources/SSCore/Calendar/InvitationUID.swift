import Foundation

/// Whether a calendar event is an occurrence of an invitation, by their iCalendar UIDs: the calendar's copy of the
/// invitation is never drawn twice and never overlaps it (spec §5.14, §5.54).
///
/// Most calendars give every occurrence of a repeating event the series' UID. Exchange does not: Graph's `iCalUId` is
/// the meeting's GlobalObjectId written in hex ([MS-OXOCAL] PidLidGlobalObjectId), whose bytes 16 to 19 hold the
/// occurrence's date, while the invitation mail names the series with those bytes zero (its "clean" id). So two
/// Exchange UIDs are compared with those eight hex digits set aside; any other UID must be equal.
public enum InvitationUID {
    /// Whether `a` and `b` name the same event, any occurrence of it.
    public static func matches(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        if a == b { return true }
        guard let cleanA = seriesID(a), let cleanB = seriesID(b) else { return false }
        return cleanA == cleanB
    }

    /// The 16-byte class id every Exchange GlobalObjectId starts with, in hex.
    private static let exchangePrefix = "040000008200E00074C5B7101A82E008"

    /// Where the occurrence's date sits in the hex id: bytes 16 to 19.
    private static let dateDigits = 32..<40

    /// An Exchange UID with its occurrence date set aside, upper-cased; nil for any other UID.
    private static func seriesID(_ uid: String) -> String? {
        let hex = Array(uid.uppercased().utf8)
        guard hex.count > dateDigits.upperBound, hex.starts(with: exchangePrefix.utf8) else { return nil }
        return String(decoding: hex[..<dateDigits.lowerBound] + hex[dateDigits.upperBound...], as: UTF8.self)
    }
}
