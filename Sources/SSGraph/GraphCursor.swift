import Foundation
import SSCore

/// The opaque change cursor: one delta link per folder plus what is needed to seed folders that have none yet.
///
/// JSON shape: `{"folders": {folderId: deltaLink | null}, "nextLinks": {folderId: nextLink}, "wellKnown":
/// {name: folderId}, "since": ISO date, "foldersResolvedAt": ISO date}`.
struct GraphCursor: Equatable, Sendable {
    static let folderRefreshInterval: TimeInterval = 24 * 60 * 60

    /// `nil` means the folder's delta has not been seeded yet.
    var folders: [String: String?]
    /// Pages still to fetch before a folder reaches its next delta link; kept so an interrupted poll resumes.
    var nextLinks: [String: String]
    var wellKnown: [String: String]
    /// Bootstrap start; seeds every delta with `receivedDateTime ge since`.
    var since: String
    var foldersResolvedAt: String?

    init(folders: [String: String?], nextLinks: [String: String] = [:], wellKnown: [String: String], since: String, foldersResolvedAt: String? = nil) {
        self.folders = folders
        self.nextLinks = nextLinks
        self.wellKnown = wellKnown
        self.since = since
        self.foldersResolvedAt = foldersResolvedAt
    }

    func deltaLink(for folderID: String) -> String? {
        folders[folderID] ?? nil
    }

    func needsFolderRefresh(at now: Date) -> Bool {
        guard let stamp = foldersResolvedAt, let resolved = GraphDate.parse(stamp) else { return true }
        return now.timeIntervalSince(resolved) >= Self.folderRefreshInterval
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
        case folders, nextLinks, wellKnown, since, foldersResolvedAt
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
        self.folders = folders
        nextLinks = try container.decodeIfPresent([String: String].self, forKey: .nextLinks) ?? [:]
        wellKnown = try container.decodeIfPresent([String: String].self, forKey: .wellKnown) ?? [:]
        since = try container.decode(String.self, forKey: .since)
        foldersResolvedAt = try container.decodeIfPresent(String.self, forKey: .foldersResolvedAt)
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
    }
}
