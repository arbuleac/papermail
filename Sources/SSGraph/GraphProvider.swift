import Foundation
import SSCore

/// `MailProvider` over Microsoft Graph for Microsoft 365 and Outlook.com mailboxes.
///
/// Stateless beyond the account id and token source, as the port demands: the change cursor carries every
/// delta link, and the only in-process memory is a cache of the system folder ids.
public final class GraphProvider: MailProvider, Sendable {
    public let accountID: AccountID
    public var kind: ProviderKind { .microsoft }

    let client: GraphHTTPClient
    let folderCache = GraphFolderCache()
    let clock: @Sendable () -> Date

    /// `internetMessageHeaders` is not selectable on list calls, so In-Reply-To and References are never mapped.
    static let metadataSelect = "id,conversationId,conversationIndex,internetMessageId,subject,bodyPreview,from,toRecipients,ccRecipients,bccRecipients,replyTo,receivedDateTime,isRead,flag,inferenceClassification,parentFolderId,hasAttachments,changeKey,isDraft"
    static let bodySelect = "body,uniqueBody,internetMessageHeaders"
    static let attachmentSelect = "id,name,contentType,size,isInline,contentId"
    /// Graph caps `$top` on message lists; asking for more is a 400.
    static let maxListPageSize = 999
    static let maxSearchPageSize = 250

    public convenience init(accountID: AccountID, tokens: AccessTokenProvider, session: URLSession = .shared) {
        self.init(accountID: accountID, tokens: tokens, session: session, clock: { Date() })
    }

    init(accountID: AccountID, tokens: AccessTokenProvider, session: URLSession, clock: @escaping @Sendable () -> Date) {
        self.accountID = accountID
        self.client = GraphHTTPClient(accountID: accountID, tokens: tokens, session: session)
        self.clock = clock
    }

    // MARK: Profile

    public func profile() async throws -> AccountProfile {
        let url = try GraphURL.make("/me", query: [("$select", "displayName,mail,userPrincipalName")])
        let user = try await client.json(GraphUser.self, for: GraphRequest(method: .get, url: url))
        // Personal accounts often leave `mail` empty; the principal name is the address they sign in with.
        return AccountProfile(email: user.mail ?? user.userPrincipalName ?? "", displayName: user.displayName ?? "")
    }

    // MARK: Metadata

    public func metadata(for providerIDs: [String]) async throws -> [MessageMetadata] {
        try await metadata(for: providerIDs, folders: try await wellKnownFolders())
    }

    func metadata(for providerIDs: [String], folders: GraphWellKnownFolders) async throws -> [MessageMetadata] {
        let mapper = GraphMessageMapper(accountID: accountID, folders: folders)
        var result: [MessageMetadata] = []
        for chunk in providerIDs.chunks(of: GraphBatch.maxRequests) {
            let requests = chunk.enumerated().map { index, id in
                GraphBatchRequest(
                    id: String(index + 1),
                    method: "GET",
                    url: "/me/messages/\(GraphURL.pathComponent(id))?$select=\(Self.metadataSelect)"
                )
            }
            let responses = GraphBatch.byID(try await client.batch(requests))
            for request in requests {
                guard let response = responses[request.id] else {
                    throw ProviderError.decoding("$batch response missing item \(request.id)")
                }
                // Unknown ids are omitted, never thrown.
                if response.status == 404 { continue }
                try GraphBatch.check(response)
                guard let body = response.body else { continue }
                result.append(mapper.metadata(from: try GraphJSON.decode(GraphMessage.self, from: body)))
            }
        }
        return result
    }

    // MARK: Bodies and attachments

    public func body(for providerID: String) async throws -> MessageBody {
        let url = try GraphURL.make("/me/messages/\(providerID)", query: [("$select", Self.bodySelect)])
        let request = GraphRequest(method: .get, url: url, prefer: ["outlook.body-content-type=\"html\""])
        let message = try await client.json(GraphMessage.self, for: request)
        // `hasAttachments` is false for inline-only images, so the attachment list is always fetched.
        let attachments = try await attachments(for: providerID)
        return GraphMessageMapper.body(from: message, attachments: attachments)
    }

    public func attachment(messageID providerID: String, attachmentID: String) async throws -> Data {
        let path = "/me/messages/\(providerID)/attachments/\(attachmentID)"
        do {
            var request = GraphRequest(method: .get, url: try GraphURL.make(path + "/$value"))
            request.accept = "*/*"
            return try await client.send(request).data
        } catch ProviderError.notFound {
            return try await attachmentBytesFromJSON(path: path)
        } catch ProviderError.server(_, _) {
            return try await attachmentBytesFromJSON(path: path)
        }
    }

    /// Raw `$value` exists for file attachments only; item and reference attachments carry their bytes inline.
    private func attachmentBytesFromJSON(path: String) async throws -> Data {
        let attachment = try await client.json(GraphAttachment.self, for: GraphRequest(method: .get, url: try GraphURL.make(path)))
        guard let encoded = attachment.contentBytes, let data = Data(base64Encoded: encoded) else {
            throw ProviderError.notFound
        }
        return data
    }

    private func attachments(for providerID: String) async throws -> [GraphAttachment] {
        do {
            return try await listAttachments(for: providerID, select: Self.attachmentSelect)
        } catch ProviderError.server(let status, _) where status == 400 {
            // Some tenants reject selecting the fileAttachment-only `contentId` on the base collection.
            return try await listAttachments(for: providerID, select: "id,name,contentType,size,isInline")
        }
    }

    private func listAttachments(for providerID: String, select: String) async throws -> [GraphAttachment] {
        var next: URL? = try GraphURL.make("/me/messages/\(providerID)/attachments", query: [("$select", select)])
        var all: [GraphAttachment] = []
        while let url = next {
            let page = try await client.json(GraphListResponse<GraphAttachment>.self, for: GraphRequest(method: .get, url: url))
            all += page.value
            next = try page.nextLink.map(GraphURL.absolute)
        }
        return all
    }

    // MARK: Search

    public func search(_ text: String, limit: Int) async throws -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        let url = try GraphURL.make("/me/messages", query: [
            ("$search", "\"\(escaped)\""),
            ("$top", String(Self.pageSize(limit, max: Self.maxSearchPageSize))),
            ("$select", "id"),
        ])
        let page = try await client.json(GraphListResponse<GraphMessage>.self, for: GraphRequest(method: .get, url: url))
        return page.value.map(\.id)
    }

    // MARK: Folders

    func wellKnownFolders() async throws -> GraphWellKnownFolders {
        if let cached = await folderCache.current() { return cached }
        return try await resolveWellKnownFolders()
    }

    func resolveWellKnownFolders() async throws -> GraphWellKnownFolders {
        var ids: [String: String] = [:]
        for name in GraphWellKnownFolders.names {
            let url = try GraphURL.make("/me/mailFolders/\(name)", query: [("$select", "id")])
            do {
                ids[name] = try await client.json(GraphFolder.self, for: GraphRequest(method: .get, url: url)).id
            } catch ProviderError.notFound {
                // Outlook creates Archive lazily; a mailbox without it simply has nothing to map to that role.
                continue
            }
        }
        let folders = GraphWellKnownFolders(ids: ids)
        await folderCache.store(folders)
        return folders
    }

    /// Every folder that gets its own delta: the top level, children one level deep, and the system folders in
    /// case the listing missed one.
    func enumerateFolderIDs(including wellKnown: GraphWellKnownFolders) async throws -> [String] {
        var ids: [String] = []
        var seen: Set<String> = []
        let query = [("$top", "200"), ("$select", "id,childFolderCount")]
        for folder in try await listFolders(from: try GraphURL.make("/me/mailFolders", query: query)) {
            if seen.insert(folder.id).inserted { ids.append(folder.id) }
            guard (folder.childFolderCount ?? 0) > 0 else { continue }
            for child in try await listFolders(from: try GraphURL.make("/me/mailFolders/\(folder.id)/childFolders", query: query))
            where seen.insert(child.id).inserted {
                ids.append(child.id)
            }
        }
        for name in GraphWellKnownFolders.names {
            if let id = wellKnown.id(name), seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    private func listFolders(from url: URL) async throws -> [GraphFolder] {
        var next: URL? = url
        var all: [GraphFolder] = []
        while let url = next {
            let page = try await client.json(GraphListResponse<GraphFolder>.self, for: GraphRequest(method: .get, url: url))
            all += page.value
            next = try page.nextLink.map(GraphURL.absolute)
        }
        return all
    }

    static func pageSize(_ limit: Int, max: Int) -> Int {
        Swift.max(1, Swift.min(limit, max))
    }
}
