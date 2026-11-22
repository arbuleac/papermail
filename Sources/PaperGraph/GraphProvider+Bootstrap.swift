import Foundation
import PaperCore

extension GraphProvider {
    /// First enumeration: newest first across the whole mailbox, trash and junk dropped by folder id.
    ///
    /// The cursor is built before the first list call. Its folders have no delta link yet, so the polls seed an
    /// unfiltered delta per folder that reports each folder's whole content once and every change after that
    /// (the inbox, sent and drafts on the first poll, the other folders a page per poll); overlap with this
    /// enumeration is harmless because upserts are idempotent. The cursor's folders are the top level and the
    /// children of its first few folders that have any (a walk's first two steps, six listing pages at most); a
    /// deeper or wider tree is walked on by the polls, so the head page never waits for a large tree, nor for a
    /// listing that fails (the polls try it again). A folder the polls find later misses nothing: its first round
    /// lists its whole content.
    ///
    /// The page reports the requests the call sent (`requestCount`): the system folder lookups, the walk's
    /// listings and the page itself.
    public func bootstrap(page: String?, limit: Int) async throws -> BootstrapPage {
        let (listed, sent) = try await GraphRequestTally.counting {
            try await bootstrapPage(page, limit: limit)
        }
        var result = listed
        result.requestCount = sent
        return result
    }

    private func bootstrapPage(_ page: String?, limit: Int) async throws -> BootstrapPage {
        if let page {
            // A corrupt page is rejected before any folder lookup so the failure is cheap and unambiguous.
            let url = try GraphURL.absolute(page)
            let folders = try await wellKnownFolders()
            let list = try await client.json(GraphListResponse<GraphMessage>.self, for: GraphRequest(method: .get, url: url))
            return BootstrapPage(messages: bootstrapMessages(list.value, folders: folders), nextPage: list.nextLink, changeCursor: nil)
        }

        let startedAt = GraphDate.string(clock())
        let folders = try await resolveWellKnownFolders()
        var cursor = GraphCursor(folders: [:], wellKnown: folders.ids, since: startedAt, foldersResolvedAt: startedAt)
        var step = try await stepFolderWalk(nil)
        var found = step.found
        // A listing that just failed is left to the polls, so a brief failure does not spend its tries in one call.
        if !step.walk.isFinished, step.walk.pending.first?.failures == nil {
            step = try await stepFolderWalk(step.walk)
            found += step.found
        }
        cursor.takeIn(step.walk, found: found)

        // `$filter` and `$orderby` cannot be combined on this endpoint, so the exclusion happens client side.
        let url = try GraphURL.make("/me/messages", query: [
            ("$top", String(Self.pageSize(limit, max: Self.maxListPageSize))),
            ("$orderby", "receivedDateTime desc"),
            ("$select", Self.metadataSelect),
        ])
        let list = try await client.json(GraphListResponse<GraphMessage>.self, for: GraphRequest(method: .get, url: url))
        return BootstrapPage(
            messages: bootstrapMessages(list.value, folders: folders),
            nextPage: list.nextLink,
            changeCursor: try cursor.encoded()
        )
    }

    private func bootstrapMessages(_ messages: [GraphMessage], folders: GraphWellKnownFolders) -> [MessageMetadata] {
        let excluded = folders.excludedFromBootstrap
        let mapper = GraphMessageMapper(accountID: accountID, folders: folders)
        return messages
            .filter { message in message.parentFolderId.map { !excluded.contains($0) } ?? true }
            .map(mapper.metadata)
    }
}
