import Foundation

/// The opaque change cursor `GmailProvider.changes` hands the engine. Normally it is a bare history id.
/// When a call stops partway through a run of history pages it also carries the page token to resume
/// from, so progress through a long run of empty pages survives between polls and across restarts
/// instead of starting over from the same history id every time.
struct GmailHistoryCursor: Codable, Equatable, Sendable {
    var startHistoryID: String
    var pageToken: String?

    private enum CodingKeys: String, CodingKey {
        case startHistoryID = "h"
        case pageToken = "p"
    }

    init(startHistoryID: String, pageToken: String? = nil) {
        self.startHistoryID = startHistoryID
        self.pageToken = pageToken
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

    var encoded: String {
        guard let pageToken, !pageToken.isEmpty else { return startHistoryID }
        // Encoding two strings cannot fail in practice; the bare id is still a valid cursor if it ever did.
        guard let data = try? JSONEncoder().encode(self) else { return startHistoryID }
        return String(decoding: data, as: UTF8.self)
    }
}
