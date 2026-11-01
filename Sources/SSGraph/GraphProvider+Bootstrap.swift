import Foundation
import SSCore

extension GraphProvider {
    /// First enumeration: newest first across the whole mailbox, trash and junk dropped by folder id.
    ///
    /// The cursor is built before the first list call so the deltas it seeds start no later than any message
    /// handed back here; overlap between the two is harmless because upserts are idempotent.
    public func bootstrap(page: String?, limit: Int) async throws -> BootstrapPage {
        if let page {
            // A corrupt page is rejected before any folder lookup so the failure is cheap and unambiguous.
            let url = try GraphURL.absolute(page)
            let folders = try await wellKnownFolders()
            let list = try await client.json(GraphListResponse<GraphMessage>.self, for: GraphRequest(method: .get, url: url))
            return BootstrapPage(messages: bootstrapMessages(list.value, folders: folders), nextPage: list.nextLink, changeCursor: nil)
        }

        let startedAt = GraphDate.string(clock())
        let folders = try await resolveWellKnownFolders()
        let folderIDs = try await enumerateFolderIDs(including: folders)
        var cursor = GraphCursor(folders: [:], wellKnown: folders.ids, since: startedAt, foldersResolvedAt: startedAt)
        for id in folderIDs {
            cursor.folders.updateValue(nil, forKey: id)
        }

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
