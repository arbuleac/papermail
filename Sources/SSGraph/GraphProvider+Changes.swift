import Foundation
import SSCore

extension GraphProvider {
    /// Per-folder delta queries drained round-robin: every folder gets one page per pass, and passes repeat
    /// until each folder has reached its `@odata.deltaLink` or roughly `limit` items have been collected.
    /// A folder still on a `nextLink` keeps it in the cursor and flags `hasMore`, so the engine drains it with
    /// further calls and a crash between calls loses nothing.
    public func changes(since cursorString: String, limit: Int) async throws -> ChangesPage {
        var cursor = try GraphCursor.decode(cursorString)
        let now = clock()
        if cursor.needsFolderRefresh(at: now) {
            try await refreshFolders(in: &cursor, at: now)
        }
        let folders = GraphWellKnownFolders(ids: cursor.wellKnown)
        await folderCache.store(folders)
        let mapper = GraphMessageMapper(accountID: accountID, folders: folders)
        let pageSize = Swift.max(1, limit)
        let preferPageSize = "odata.maxpagesize=\(pageSize)"

        var upserts: [String: MessageMetadata] = [:]
        var order: [String] = []
        var removed: [String] = []

        // The first pass visits every folder so one already sitting on a delta link is still polled; later
        // passes only continue folders that handed back a nextLink.
        var active = Self.folderOrder(in: cursor)
        while !active.isEmpty {
            var continuing: [String] = []
            for folderID in active {
                let url = try deltaURL(for: folderID, in: cursor)
                let page: GraphListResponse<GraphMessage>
                do {
                    page = try await client.json(GraphListResponse<GraphMessage>.self, for: GraphRequest(method: .get, url: url, prefer: [preferPageSize]))
                } catch ProviderError.notFound {
                    // The folder was deleted; its messages resurface through whichever folder received them.
                    cursor.folders.removeValue(forKey: folderID)
                    cursor.nextLinks.removeValue(forKey: folderID)
                    continue
                }
                for item in page.value {
                    if item.removed != nil {
                        removed.append(item.id)
                    } else if upserts.updateValue(mapper.metadata(from: item), forKey: item.id) == nil {
                        order.append(item.id)
                    }
                }
                if let next = page.nextLink {
                    cursor.nextLinks[folderID] = next
                    continuing.append(folderID)
                } else if let delta = page.deltaLink {
                    cursor.nextLinks.removeValue(forKey: folderID)
                    cursor.folders.updateValue(delta, forKey: folderID)
                } else {
                    throw ProviderError.decoding("delta page carries neither nextLink nor deltaLink")
                }
            }
            active = continuing
            if upserts.count + removed.count >= pageSize { break }
        }

        // A folder delta reports a move out of the folder as a removal; only a lookup tells a move from a
        // deletion, and dropping a merely moved message would also throw away its cached body.
        var deletedIDs: [String] = []
        var candidates: [String] = []
        var seen: Set<String> = []
        for id in removed where upserts[id] == nil && seen.insert(id).inserted {
            candidates.append(id)
        }
        if !candidates.isEmpty {
            let alive = try await metadata(for: candidates, folders: folders)
            for message in alive where upserts.updateValue(message, forKey: message.id.providerID) == nil {
                order.append(message.id.providerID)
            }
            deletedIDs = candidates.filter { upserts[$0] == nil }
        }

        return ChangesPage(
            upserts: order.compactMap { upserts[$0] },
            deletedIDs: deletedIDs,
            cursor: try cursor.encoded(),
            hasMore: !active.isEmpty
        )
    }

    /// System folders first, inbox ahead of the rest, so new mail reaches the store before a long custom
    /// folder is drained; the remainder in a stable order.
    static func folderOrder(in cursor: GraphCursor) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []
        for name in GraphWellKnownFolders.names {
            if let id = cursor.wellKnown[name], cursor.folders.keys.contains(id), seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        for id in cursor.folders.keys.sorted() where seen.insert(id).inserted {
            ordered.append(id)
        }
        return ordered
    }

    private func deltaURL(for folderID: String, in cursor: GraphCursor) throws -> URL {
        if let next = cursor.nextLinks[folderID] {
            return try GraphURL.absolute(next)
        }
        if let delta = cursor.deltaLink(for: folderID) {
            return try GraphURL.absolute(delta)
        }
        return try GraphURL.make("/me/mailFolders/\(folderID)/messages/delta", query: [
            ("$select", Self.metadataSelect),
            ("$filter", "receivedDateTime ge \(cursor.since)"),
        ])
    }

    /// Folders created since the last look get a delta of their own; deleted ones stop being polled.
    private func refreshFolders(in cursor: inout GraphCursor, at now: Date) async throws {
        let wellKnown = try await resolveWellKnownFolders()
        let ids = try await enumerateFolderIDs(including: wellKnown)
        var folders: [String: String?] = [:]
        for id in ids {
            folders.updateValue(cursor.deltaLink(for: id), forKey: id)
        }
        cursor.folders = folders
        cursor.nextLinks = cursor.nextLinks.filter { folders.keys.contains($0.key) }
        cursor.wellKnown = wellKnown.ids
        cursor.foldersResolvedAt = GraphDate.string(now)
    }
}
