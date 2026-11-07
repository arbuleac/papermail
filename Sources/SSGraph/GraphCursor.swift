import Foundation
import SSCore

/// The opaque change cursor: one delta link per folder plus what is needed to seed folders that have none yet.
///
/// JSON shape: `{"folders": {folderId: deltaLink | null}, "nextLinks": {folderId: nextLink}, "wellKnown":
/// {name: folderId}, "since": ISO date, "foldersResolvedAt": ISO date, "fullVisitAt": ISO date,
/// "deltaScope": "mailbox"}`. `fullVisitAt` is absent from cursors written before polls were thinned; a cursor
/// without it visits every folder on its next call.
///
/// `deltaScope` marks links seeded without a `$filter`. Graph keeps a delta's original query inside its
/// state token, and the only filter message delta accepts (`receivedDateTime ge …`) also limits which
/// messages the delta tracks; links from cursors without the marker were seeded with that filter, so
/// they are dropped on decode and every folder starts a fresh, unfiltered delta.
struct GraphCursor: Equatable, Sendable {
    static let folderRefreshInterval: TimeInterval = 24 * 60 * 60
    /// How often a folder outside the priority set that sits on its delta link is polled. The live lane calls
    /// every 5 s and Outlook allows 10,000 requests per 10 minutes per mailbox: polling forty folders on every
    /// call would spend 4,800 of them, while the inbox, sent and drafts every call and the rest twice a minute
    /// spend 1,100. New mail lands in the priority folders; a rule filing mail elsewhere or a move made on
    /// another device can wait half a minute.
    static let fullVisitInterval: TimeInterval = 30
    /// Every delta link in a cursor carrying this scope tracks the folder's whole content.
    static let mailboxScope = "mailbox"

    /// `nil` means the folder's delta has not been seeded yet.
    var folders: [String: String?]
    /// Pages still to fetch before a folder reaches its next delta link; kept so an interrupted poll resumes.
    var nextLinks: [String: String]
    var wellKnown: [String: String]
    /// Bootstrap start. Kept for diagnostics and older cursors; deltas are no longer filtered by it.
    var since: String
    var foldersResolvedAt: String?
    /// When a call last polled every folder on a delta link; `nil` until the first one.
    var fullVisitAt: String?

    init(
        folders: [String: String?],
        nextLinks: [String: String] = [:],
        wellKnown: [String: String],
        since: String,
        foldersResolvedAt: String? = nil,
        fullVisitAt: String? = nil
    ) {
        self.folders = folders
        self.nextLinks = nextLinks
        self.wellKnown = wellKnown
        self.since = since
        self.foldersResolvedAt = foldersResolvedAt
        self.fullVisitAt = fullVisitAt
    }

    func deltaLink(for folderID: String) -> String? {
        folders[folderID] ?? nil
    }

    func needsFolderRefresh(at now: Date) -> Bool {
        guard let stamp = foldersResolvedAt, let resolved = GraphDate.parse(stamp) else { return true }
        return now.timeIntervalSince(resolved) >= Self.folderRefreshInterval
    }

    /// A missing or unreadable stamp, or one in the future because the clock was set back, counts as due so the
    /// other folders are never starved. The stamp has second precision and is truncated, so a visit is at most a
    /// second early, never late.
    func needsFullVisit(at now: Date) -> Bool {
        guard let stamp = fullVisitAt, let visited = GraphDate.parse(stamp) else { return true }
        let elapsed = now.timeIntervalSince(visited)
        return elapsed < 0 || elapsed >= Self.fullVisitInterval
    }

    /// A cursor that cannot be read cannot be continued; the engine's answer to `resetRequired` is a fresh bootstrap.
    static func decode(_ string: String) throws -> GraphCursor {
        do {
            return try JSONDecoder().decode(GraphCursor.self, from: Data(string.utf8))
        } catch {
            throw ProviderError.resetRequired
        }
    }

    func encoded() throws -> String {
        String(decoding: try GraphJSON.encode(self), as: UTF8.self)
    }
}

extension GraphCursor: Codable {
    private enum CodingKeys: String, CodingKey {
        case folders, nextLinks, wellKnown, since, foldersResolvedAt, fullVisitAt, deltaScope
    }

    private struct FolderKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.nestedContainer(keyedBy: FolderKey.self, forKey: .folders)
        var folders: [String: String?] = [:]
        for key in nested.allKeys {
            folders.updateValue(try nested.decodeIfPresent(String.self, forKey: key), forKey: key.stringValue)
        }
        nextLinks = try container.decodeIfPresent([String: String].self, forKey: .nextLinks) ?? [:]
        if try container.decodeIfPresent(String.self, forKey: .deltaScope) != Self.mailboxScope {
            // Seeded with a receivedDateTime filter: those links would never report changes to older mail.
            folders = folders.mapValues { _ in nil }
            nextLinks = [:]
        }
        self.folders = folders
        wellKnown = try container.decodeIfPresent([String: String].self, forKey: .wellKnown) ?? [:]
        since = try container.decode(String.self, forKey: .since)
        foldersResolvedAt = try container.decodeIfPresent(String.self, forKey: .foldersResolvedAt)
        fullVisitAt = try container.decodeIfPresent(String.self, forKey: .fullVisitAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var nested = container.nestedContainer(keyedBy: FolderKey.self, forKey: .folders)
        for (id, link) in folders.sorted(by: { $0.key < $1.key }) {
            if let link {
                try nested.encode(link, forKey: FolderKey(stringValue: id))
            } else {
                try nested.encodeNil(forKey: FolderKey(stringValue: id))
            }
        }
        try container.encode(nextLinks, forKey: .nextLinks)
        try container.encode(wellKnown, forKey: .wellKnown)
        try container.encode(since, forKey: .since)
        try container.encodeIfPresent(foldersResolvedAt, forKey: .foldersResolvedAt)
        try container.encodeIfPresent(fullVisitAt, forKey: .fullVisitAt)
        try container.encode(Self.mailboxScope, forKey: .deltaScope)
    }
}
