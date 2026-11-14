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
    /// on a `nextLink` do; the others, quiet on their delta link, join only during a full visit, which starts at most
    /// once per `GraphCursor.fullVisitInterval` and is spread over calls: a call takes the next quiet folders in id
    /// order after the last one the visit polled, `GraphCursor.quietVisitsPerSecond` for each second since the last
    /// call and at most `GraphCursor.maxQuietVisitsPerCall`. So a 5 s poll costs three requests plus about ten during
    /// a visit, never one per folder, however large the tree, and the engine's further calls while `hasMore` holds,
    /// which come within a second, continue nextLinks with two quiet folders at most.
    ///
    /// Seeding folders (any other folder still in its first round) share `maxSeedPagesPerCall` pages per call,
    /// spent on the first unfinished one in `folderOrder` until it reaches its delta link, then on the next; one whose
    /// page failed waits behind those that did not (`nextSeed`). Seeding left over on its own does not set `hasMore`:
    /// the engine's poll ends and the next poll seeds on, so the live lane is never held behind a folder's full listing.
    ///
    /// A folder other than the inbox whose request fails waits for the next call rather than failing this one
    /// (`recordFolderFailure`), and after `maxFolderFailures` calls in a row only full visits ask it. A folder that
    /// answers 404 is gone: it leaves the cursor and the page names it in `goneFolders`, as it does a folder the walk
    /// drops.
    ///
    /// A folder walk under way (`GraphCursor.walk`), or one due because the folder list is a day old, takes one step
    /// first: the system folder lookups and the top level's first page to start one, a few listing pages to go on
    /// with one. A listing that fails holds up neither the step nor the call (`stepFolderWalk`).
    ///
    /// The page reports the requests the call sent (`requestCount`): the delta GETs, a walk step's lookups and
    /// listings and a `$batch` part per removal it looked up. That is anywhere from three to well over a hundred,
    /// and the engine paces its live lane by it.
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
        var goneFolders: [String] = []
        if cursor.walk != nil || cursor.needsFolderRefresh(at: now) {
            goneFolders += try await walkFolders(in: &cursor, at: now)
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
        var partial: [String] = []
        var removed: [String] = []

        // The first pass visits every drained folder due this call, so a quiet folder whose turn in the full visit
        // has come is polled; later passes only continue drained folders that handed back a nextLink. A parked folder
        // still in its first round gets a page when the visit reaches it, outside the seed slot.
        let visiting = Self.quietFoldersDue(in: &cursor, order: folderOrder, priority: priority, at: now)
        var drained = folderOrder.filter { folderID in
            !Self.isSeeding(folderID, in: cursor, priority: priority)
                && (visiting.contains(folderID) || Self.isPolledEveryCall(folderID, in: cursor, priority: priority))
        }
        let parkedSeeds = folderOrder.filter { visiting.contains($0) && Self.isSeeding($0, in: cursor, priority: priority) }
        var seedPagesLeft = Self.maxSeedPagesPerCall
        let inboxID = cursor.wellKnown["inbox"]
        var anyAnswered = false
        var firstSkipped: Error?
        var firstPass = true
        while true {
            var pass = drained
            if firstPass { pass += parkedSeeds }
            firstPass = false
            // Last in its pass, so the drained folders' new mail leads the page.
            if seedPagesLeft > 0, let seed = Self.nextSeed(in: cursor, order: folderOrder, priority: priority) {
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
                    // The folder was deleted. Mail moved out of it comes through the folder that received it, but a
                    // purge takes the rest with it and no delta reports that: the engine checks what it stores there.
                    cursor.folders.removeValue(forKey: folderID)
                    cursor.nextLinks.removeValue(forKey: folderID)
                    cursor.folderFailures.removeValue(forKey: folderID)
                    goneFolders.append(folderID)
                    continue
                } catch let error where folderID != inboxID && !Self.failsTheCall(error) {
                    Self.recordFolderFailure(error, of: folderID, in: &cursor)
                    firstSkipped = firstSkipped ?? error
                    continue
                }
                anyAnswered = true
                cursor.folderFailures.removeValue(forKey: folderID)
                for item in page.value {
                    if item.removed != nil {
                        removed.append(item.id)
                    } else if item.receivedDateTime == nil {
                        // A delta may report a change with only what changed (a read flag); mapped whole it would
                        // become a message with no sender, no subject and a 1970 date. Its metadata is looked up.
                        partial.append(item.id)
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
        // Every folder failing is the service down, not a folder: the call fails as it would have.
        if !anyAnswered, let firstSkipped { throw firstSkipped }

        let deletedIDs = try await lookUpReported(removed: removed, partial: partial, in: &cursor, folders: folders,
                                                  upserts: &upserts, upsertOrder: &upsertOrder)

        return ChangesPage(
            upserts: upsertOrder.compactMap { upserts[$0] },
            deletedIDs: deletedIDs,
            cursor: try cursor.encoded(),
            // Only drained folders still on a nextLink count; a seeding folder's nextLink waits for the next poll.
            hasMore: !drained.isEmpty,
            goneFolders: goneFolders
        )
    }

    /// Calls in a row a folder's delta may fail before it is parked: asked only when a full visit reaches it, and,
    /// when Graph refused it rather than the service failing, from a fresh round (its stored link may be what Graph
    /// refuses). A third call is well past a passing failure, and a full visit every 30 s still finds it again soon
    /// after it mends.
    static let maxFolderFailures = 3

    /// Through Exchange's November 2026 outage the inbox answered while one folder kept failing with a 502, and
    /// failing the call for it threw away every other folder's changes, new inbox mail included; a folder that answers
    /// "access denied" for good, or a 400 on its stored link, did the same on every poll. So a folder other than the
    /// inbox that fails with anything but a throttle, a refused token, a cancellation or a reset keeps its place and
    /// waits: asked again next call, behind the others for the seed page, and parked at `maxFolderFailures`. The inbox
    /// failing, or every folder, still fails the call, so the account shows it is not syncing. Logged with the status
    /// only.
    static func recordFolderFailure(_ error: Error, of folderID: String, in cursor: inout GraphCursor) {
        let failures = (cursor.folderFailures[folderID] ?? 0) + 1
        cursor.folderFailures[folderID] = failures
        let label = failureLabel(error)
        guard failures >= maxFolderFailures else {
            folderLog.notice("delta: a folder failed (\(failures, privacy: .public) in a row) and waits for the next call: \(label, privacy: .public)")
            return
        }
        if failures == maxFolderFailures, !isServiceFailure(error) {
            cursor.nextLinks.removeValue(forKey: folderID)
            cursor.folders.updateValue(nil, forKey: folderID)
        }
        folderLog.notice("delta: a folder failed \(failures, privacy: .public) calls in a row and waits for full visits: \(label, privacy: .public)")
    }

    /// Whether the folder failed `maxFolderFailures` calls in a row and is asked only on full visits.
    static func isParked(_ folderID: String, in cursor: GraphCursor) -> Bool {
        (cursor.folderFailures[folderID] ?? 0) >= maxFolderFailures
    }

    /// The folder this call's seed page goes to: the first still seeding in folder order among those that failed
    /// least, so one whose page keeps failing yields the slot to the next and never holds every later folder back
    /// from its first round. A parked folder gets its page from a full visit instead.
    static func nextSeed(in cursor: GraphCursor, order: [String], priority: Set<String>) -> String? {
        order.filter { isSeeding($0, in: cursor, priority: priority) && !isParked($0, in: cursor) }
            .min { (cursor.folderFailures[$0] ?? 0) < (cursor.folderFailures[$1] ?? 0) }
    }

    /// Calls on which a message whose lookup the service failed is looked up (`GraphCursor.recheck`) before it is left
    /// as the store has it. Through Exchange's November 2026 outage a part failed now and then, so a second or third
    /// try settles nearly every one; the bound keeps a message the service always fails from being carried for ever.
    static let maxLookupCalls = 3

    /// Looks up what the delta did not report whole, and returns the deletions. A removal is a move or a deletion and
    /// only a lookup tells them apart (dropping a merely moved message would throw away its cached body, and with the
    /// conversation's last message its snooze); a change reported with only what changed needs the rest of its
    /// metadata. Messages whose lookup the service failed on an earlier call (`GraphCursor.recheck`) are asked again
    /// with them, unless another folder has reported them since.
    ///
    /// Found: an upsert. Unknown (404): a removal, or a message asked again, is gone; a partial change's removal comes
    /// through the delta like any other. Refused for that one message (a 400 or 403, a reply that does not decode): a
    /// removal is taken as gone, which is what Graph's 403 ErrorAccessDenied for a deleted item means, and a move comes
    /// back through its new folder's delta; anything else keeps what the store has. Failed by the service (a 5xx, the
    /// network, for the part or its whole `$batch`): that says nothing about the message, so it keeps what the store has
    /// and is asked again on the next call, up to `maxLookupCalls`. The delta links move on meanwhile, so new mail never
    /// waits on a lookup. A throttle or a refused token still fails the call.
    private func lookUpReported(
        removed: [String],
        partial: [String],
        in cursor: inout GraphCursor,
        folders: GraphWellKnownFolders,
        upserts: inout [String: MessageMetadata],
        upsertOrder: inout [String]
    ) async throws -> [String] {
        let carried = cursor.recheck
        cursor.recheck = [:]
        var removals: Set<String> = []
        var asked: [String] = []
        var seen: Set<String> = []
        for id in removed where upserts[id] == nil && seen.insert(id).inserted {
            removals.insert(id)
            asked.append(id)
        }
        for id in carried.keys.sorted() where upserts[id] == nil && seen.insert(id).inserted {
            asked.append(id)
        }
        for id in partial where upserts[id] == nil && seen.insert(id).inserted {
            asked.append(id)
        }
        guard !asked.isEmpty else { return [] }
        let lookup = try await lookUp(asked, folders: folders, carryingFailedBatches: true)
        for message in lookup.messages where upserts.updateValue(message, forKey: message.id.providerID) == nil {
            upsertOrder.append(message.id.providerID)
        }
        var givenUp = 0
        for id in lookup.failing {
            let calls = (carried[id] ?? 0) + 1
            if calls < Self.maxLookupCalls {
                cursor.recheck[id] = calls
            } else {
                givenUp += 1
            }
        }
        if givenUp > 0 {
            Self.folderLog.notice("lookup: \(givenUp, privacy: .public) messages the service kept failing are left as stored")
        }
        let refused = Set(lookup.refused)
        let failing = Set(lookup.failing)
        return asked.filter { id in
            guard upserts[id] == nil, !failing.contains(id) else { return false }
            return removals.contains(id) || (!refused.contains(id) && carried[id] != nil)
        }
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

    /// The quiet folders this call polls, moving the cursor's full visit along: one starts when none is under way
    /// and the interval since the last has run out, and it takes the next folders in id order after the last one it
    /// polled, as many as the time since the last call earns. Stamps the call.
    static func quietFoldersDue(in cursor: inout GraphCursor, order: [String], priority: Set<String>, at now: Date) -> Set<String> {
        let allowance = cursor.quietVisitAllowance(at: now)
        cursor.polledAt = GraphDate.string(now)
        if cursor.fullVisitAfter == nil, cursor.needsFullVisit(at: now) {
            cursor.fullVisitAt = GraphDate.string(now)
            cursor.fullVisitAfter = ""
        }
        guard let after = cursor.fullVisitAfter else { return [] }
        let left = order.filter { folderID in
            folderID > after
                && (isParked(folderID, in: cursor)
                    || (!isSeeding(folderID, in: cursor, priority: priority) && !isPolledEveryCall(folderID, in: cursor, priority: priority)))
        }.sorted()
        let due = left.prefix(allowance)
        cursor.fullVisitAfter = due.count < left.count ? (due.last ?? after) : nil
        return Set(due)
    }

    static func priorityFolderIDs(in cursor: GraphCursor) -> Set<String> {
        Set(priorityFolderNames.compactMap { cursor.wellKnown[$0] })
    }

    /// A priority folder, or one partway through a round: either may hold new mail or owe the engine more pages, so
    /// neither waits for a full visit. A seeding folder on a nextLink is seeding first and takes its seed page. A
    /// parked folder waits for full visits whatever it is.
    static func isPolledEveryCall(_ folderID: String, in cursor: GraphCursor, priority: Set<String>) -> Bool {
        !isParked(folderID, in: cursor) && (priority.contains(folderID) || cursor.nextLinks[folderID] != nil)
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

    /// Folders created since the last look, at any depth, get a delta of their own as the walk finds them; folders
    /// that a second walk in a row does not find stop being polled once it ends (`GraphCursor.takeIn`). Started once
    /// a day (`GraphCursor.folderRefreshInterval`, counted from the walk's start), not every poll: the walk costs a
    /// request per folder with children, and a folder deleted in between drops out sooner, when its delta answers
    /// 404. A step a call; the call that starts a walk also looks up the system folders again, and keeps the ids it
    /// had where a lookup fails (they do not change), so the step and the polls go on. Returns the folders the step
    /// dropped from the polls, whose stored mail no delta will report again.
    private func walkFolders(in cursor: inout GraphCursor, at now: Date) async throws -> [String] {
        if cursor.walk == nil {
            cursor.foldersResolvedAt = GraphDate.string(now)
            do {
                cursor.wellKnown = try await resolveWellKnownFolders().ids
            } catch let error where Self.failsTheCall(error) {
                throw error
            } catch {
                Self.folderLog.notice("system folder lookup failed; the folder walk keeps the ids it had")
            }
        }
        let step = try await stepFolderWalk(cursor.walk)
        let polled = Set(cursor.folders.keys)
        cursor.takeIn(step.walk, found: step.found)
        let dropped = polled.subtracting(cursor.folders.keys).sorted()
        for folderID in dropped { cursor.folderFailures.removeValue(forKey: folderID) }
        return dropped
    }
}
