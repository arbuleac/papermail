import Foundation
import SSCore

extension GraphProvider {
    /// Pages one call spends on folders still listing their content for the first time. The first round of an
    /// unfiltered delta lists the whole folder and the bootstrap leaves every folder in that state; draining them
    /// all before the poll returns would hold new inbox mail behind a re-listing of the mailbox.
    static let maxSeedPagesPerCall = 1

    /// Where new mail, sends and drafts land: drained in full on every call, even while their first round still
    /// lists the folder's content.
    static let priorityFolderNames: Set<String> = ["inbox", "sentitems", "drafts"]

    /// Per-folder delta queries in two classes.
    ///
    /// Drained folders (the priority ones, and every folder that already holds a delta link) go round-robin:
    /// every one gets a page per pass, and passes repeat until each reaches its `@odata.deltaLink` or roughly
    /// `limit` items have been collected. One still on a `nextLink` keeps it in the cursor and flags `hasMore`, so
    /// the engine drains it with further calls and a crash between calls loses nothing.
    ///
    /// Not every drained folder starts on every call. The priority folders and any folder partway through a round
    /// on a `nextLink` do; the others, sitting on their delta link, join only on a full visit, at most once per
    /// `GraphCursor.fullVisitInterval`, so a quiet 5 s poll costs three requests rather than one per folder. The
    /// cursor stamps each full visit, and the engine's further calls while `hasMore` holds fall inside the
    /// interval, so they continue nextLinks without re-polling the quiet folders.
    ///
    /// Seeding folders (any other folder still in its first round) share `maxSeedPagesPerCall` pages per call,
    /// spent on the first unfinished one in `folderOrder` until it reaches its delta link, then on the next.
    /// Seeding left over on its own does not set `hasMore`: the engine's poll ends and the next poll seeds on, so
    /// the live lane is never held behind a folder's full listing.
    ///
    /// The page reports the requests the call sent (`requestCount`): the delta GETs, a folder refresh's lookups and
    /// a `$batch` part per removal it looked up. That is anywhere from three to well over a hundred, and the engine
    /// paces its live lane by it.
    public func changes(since cursorString: String, limit: Int) async throws -> ChangesPage {
        let (collected, sent) = try await GraphRequestTally.counting {
            try await collectChanges(since: cursorString, limit: limit)
        }
        var page = collected
        page.requestCount = sent
        return page
    }

    private func collectChanges(since cursorString: String, limit: Int) async throws -> ChangesPage {
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
        let priority = Self.priorityFolderIDs(in: cursor)
        let folderOrder = Self.folderOrder(in: cursor)

        var upserts: [String: MessageMetadata] = [:]
        var upsertOrder: [String] = []
        var removed: [String] = []

        // The first pass visits every drained folder due this call, so one already sitting on a delta link is
        // still polled on a full visit; later passes only continue drained folders that handed back a nextLink.
        let fullVisit = cursor.needsFullVisit(at: now)
        var drained = folderOrder.filter { folderID in
            !Self.isSeeding(folderID, in: cursor, priority: priority)
                && (fullVisit || Self.isPolledEveryCall(folderID, in: cursor, priority: priority))
        }
        if fullVisit {
            cursor.fullVisitAt = GraphDate.string(now)
        }
        var seedPagesLeft = Self.maxSeedPagesPerCall
        while true {
            var pass = drained
            // Last in its pass, so the drained folders' new mail leads the page.
            if seedPagesLeft > 0, let seed = folderOrder.first(where: { Self.isSeeding($0, in: cursor, priority: priority) }) {
                seedPagesLeft -= 1
                pass.append(seed)
            }
            if pass.isEmpty { break }
            var continuing: [String] = []
            for folderID in pass {
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
                        upsertOrder.append(item.id)
                    }
                }
                if let next = page.nextLink {
                    cursor.nextLinks[folderID] = next
                    // A seeding folder resumes from this link only when the seed budget allows, so it never
                    // joins the passes that drain the others.
                    if drained.contains(folderID) { continuing.append(folderID) }
                } else if let delta = page.deltaLink {
                    cursor.nextLinks.removeValue(forKey: folderID)
                    cursor.folders.updateValue(delta, forKey: folderID)
                } else {
                    throw ProviderError.decoding("delta page carries neither nextLink nor deltaLink")
                }
            }
            drained = continuing
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
                upsertOrder.append(message.id.providerID)
            }
            deletedIDs = candidates.filter { upserts[$0] == nil }
        }

        return ChangesPage(
            upserts: upsertOrder.compactMap { upserts[$0] },
            deletedIDs: deletedIDs,
            cursor: try cursor.encoded(),
            // Only drained folders still on a nextLink count; a seeding folder's nextLink waits for the next poll.
            hasMore: !drained.isEmpty
        )
    }

    /// System folders first, inbox ahead of the rest, so new mail reaches the store before a long custom
    /// folder is drained; the remainder in a stable order. Folders are seeded in this order too.
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

    static func priorityFolderIDs(in cursor: GraphCursor) -> Set<String> {
        Set(priorityFolderNames.compactMap { cursor.wellKnown[$0] })
    }

    /// A priority folder, or one partway through a round: either may hold new mail or owe the engine more pages, so
    /// neither waits for a full visit. A seeding folder on a nextLink is seeding first and takes its seed page.
    static func isPolledEveryCall(_ folderID: String, in cursor: GraphCursor, priority: Set<String>) -> Bool {
        priority.contains(folderID) || cursor.nextLinks[folderID] != nil
    }

    /// A non-priority folder whose first round has not reached a delta link, whether or not it is partway through
    /// on a nextLink. A folder that has a delta link and holds a nextLink is continuing an incremental round.
    /// One deleted during this call has left the cursor and is not picked to seed again.
    static func isSeeding(_ folderID: String, in cursor: GraphCursor, priority: Set<String>) -> Bool {
        !priority.contains(folderID) && cursor.folders.keys.contains(folderID) && cursor.deltaLink(for: folderID) == nil
    }

    private func deltaURL(for folderID: String, in cursor: GraphCursor) throws -> URL {
        if let next = cursor.nextLinks[folderID] {
            return try GraphURL.absolute(next)
        }
        if let delta = cursor.deltaLink(for: folderID) {
            return try GraphURL.absolute(delta)
        }
        // No `$filter`: the only one message delta accepts (receivedDateTime) also narrows what the delta
        // tracks for its whole life, and reads, moves and deletes of older mail would never be reported.
        // The first round therefore lists the folder's current content once, which also repairs anything
        // the offset-paged bootstrap skipped; the upserts are idempotent.
        return try GraphURL.make("/me/mailFolders/\(folderID)/messages/delta", query: [
            ("$select", Self.metadataSelect),
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
