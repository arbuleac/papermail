import Foundation

/// The opaque change cursor `GmailProvider.changes` hands the engine. Normally it is a bare history id.
/// When a call stops partway through a run of history pages it also carries the page token to resume
/// from, so progress through a long run of empty pages survives between polls and across restarts
/// instead of starting over from the same history id every time. It also carries, while there are any, the
/// messages whose metadata Gmail failed for now (`recheck`), so the next calls ask for them again rather than the
/// history moving past them for good.
struct GmailHistoryCursor: Codable, Equatable, Sendable {
    var startHistoryID: String
    var pageToken: String?
    /// Messages history named (or a bootstrap listed) whose metadata Gmail failed for now (a 500 for that message, on
    /// the batch and again on its own), with the tries that have failed them so far.
    var recheck: [String: Int]?
    /// When `recheck`'s messages were last asked for, in seconds since 1970.
    var recheckAt: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case startHistoryID = "h"
        case pageToken = "p"
        case recheck = "r"
        case recheckAt = "t"
    }

    init(startHistoryID: String, pageToken: String? = nil, recheck: [String: Int] = [:], recheckAt: Date? = nil) {
        self.startHistoryID = startHistoryID
        self.pageToken = pageToken
        self.recheck = recheck.isEmpty ? nil : recheck
        self.recheckAt = recheck.isEmpty ? nil : recheckAt?.timeIntervalSince1970
    }

    /// Bare history ids (the common case, and every cursor stored before page tokens were carried) are
    /// taken as they are; anything else must be the JSON `encoded` wrote.
    init(parsing cursor: String) {
        let trimmed = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let decoded = try? JSONDecoder().decode(GmailHistoryCursor.self, from: Data(trimmed.utf8)) {
            self = decoded
        } else {
            self.init(startHistoryID: trimmed)
        }
    }

    /// Whether a call at `now` asks for `recheck`'s messages again: once `spacing` has passed since the last try, or
    /// when that time cannot be read or lies ahead (a clock set back), so a carried message is never held for good.
    func recheckDue(at now: Date, spacing: TimeInterval) -> Bool {
        guard let recheckAt else { return true }
        let elapsed = now.timeIntervalSince1970 - recheckAt
        return elapsed < 0 || elapsed >= spacing
    }

    var encoded: String {
        let carries = !(recheck ?? [:]).isEmpty
        guard carries || !(pageToken ?? "").isEmpty else { return startHistoryID }
        var cursor = self
        if pageToken?.isEmpty == true { cursor.pageToken = nil }
        // Encoding a few strings cannot fail in practice; the bare id is still a valid cursor if it ever did.
        guard let data = try? JSONEncoder().encode(cursor) else { return startHistoryID }
        return String(decoding: data, as: UTF8.self)
    }
}
