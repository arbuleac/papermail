import Foundation
import os
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
    let sendLimits: GraphSendLimits

    /// `internetMessageHeaders` is not selectable on list calls, so In-Reply-To and References are never mapped.
    static let metadataSelect = "id,conversationId,conversationIndex,internetMessageId,subject,bodyPreview,from,toRecipients,ccRecipients,bccRecipients,replyTo,receivedDateTime,isRead,flag,inferenceClassification,parentFolderId,hasAttachments,changeKey,isDraft"
    static let bodySelect = "body,uniqueBody,internetMessageHeaders"
    /// `contentId` is declared on fileAttachment only; selecting it by its bare name on the attachment
    /// collection is a 400, so it is named through the derived type.
    static let attachmentSelect = "id,name,contentType,size,isInline,microsoft.graph.fileAttachment/contentId"
    static let attachmentBaseSelect = "id,name,contentType,size,isInline"
    /// Graph caps `$top` on message lists; asking for more is a 400.
    static let maxListPageSize = 999
    static let maxSearchPageSize = 250
    /// Says when the folder walk stopped at its depth cap or gave up on a listing, so a folder that never syncs
    /// between reconciles can be explained from the log; counts only, never folder names.
    static let folderLog = Logger(subsystem: "io.supersparrow.mac", category: "graph")

    public convenience init(accountID: AccountID, tokens: AccessTokenProvider, session: URLSession = .shared) {
        self.init(accountID: accountID, tokens: tokens, session: session, clock: { Date() })
    }

    init(
        accountID: AccountID,
        tokens: AccessTokenProvider,
        session: URLSession,
        clock: @escaping @Sendable () -> Date,
        sendLimits: GraphSendLimits = .graph
    ) {
        self.accountID = accountID
        self.client = GraphHTTPClient(accountID: accountID, tokens: tokens, session: session)
        self.clock = clock
        self.sendLimits = sendLimits
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

    /// With `skippingUnreadable` (the delta's own lookups), a message Graph will not return on its own (a 400, 403 or
    /// 500 for that one item, or a reply that does not decode) is left out like an unknown one. Failing the call for
    /// it would hold the cursor, so every later poll would meet the same message and the account would stop syncing.
    /// A failure the next request would meet too (a throttle, a refused token, the network) still fails the call.
    func metadata(for providerIDs: [String], folders: GraphWellKnownFolders,
                  skippingUnreadable: Bool = false) async throws -> [MessageMetadata] {
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
                do {
                    try GraphBatch.check(response)
                    guard let body = response.body else { continue }
                    result.append(mapper.metadata(from: try GraphJSON.decode(GraphMessage.self, from: body)))
                } catch let error where skippingUnreadable && Self.isItemFailure(error) {
                    // Status and Graph's error code name the failure, never the mail.
                    let code = response.body?.objectValue?["error"]?.objectValue?["code"]?.stringValue ?? "no code"
                    Self.folderLog.notice("lookup left out a message Graph would not return: HTTP \(response.status, privacy: .public) \(code, privacy: .public)")
                }
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
        var body = GraphMessageMapper.body(from: message, attachments: attachments)
        if message.isEventMessage {
            body.invitation = try await invitation(forEventMessage: providerID)
        }
        return body
    }

    /// The invitation of an event message, read from its expanded event: one more request, only for meeting mail.
    /// Times come in UTC (`outlook.timezone`), the zone the event was written in from `originalStartTimeZone`. A
    /// failure the next request would meet too (a throttle, a refused token, the network) fails the body fetch so it is
    /// tried again; any other leaves the message without a card rather than without a body.
    func invitation(forEventMessage providerID: String) async throws -> CalendarInvitation? {
        do {
            return GraphInvitationMapper.invitation(from: try await eventMessage(providerID))
        } catch let error where Self.failsTheCall(error) {
            throw error
        } catch ProviderError.network(let message) {
            throw ProviderError.network(message)
        } catch {
            Self.folderLog.notice("invitation: event not read: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// The event message with its event (`$expand=microsoft.graph.eventMessage/event`), the documented way to reach it.
    func eventMessage(_ providerID: String) async throws -> GraphMessage {
        let url = try GraphURL.make("/me/messages/\(providerID)", query: [("$expand", "microsoft.graph.eventMessage/event")])
        let request = GraphRequest(method: .get, url: url, prefer: ["outlook.timezone=\"UTC\"", "outlook.body-content-type=\"text\""])
        return try await client.json(GraphMessage.self, for: request)
    }

    public func attachment(messageID providerID: String, attachmentID: String) async throws -> Data {
        let path = Self.attachmentPath(providerID, attachmentID)
        do {
            return try await client.send(try Self.rawAttachmentRequest(path: path)).data
        } catch ProviderError.notFound {
            return try await attachmentBytesFromJSON(path: path)
        } catch ProviderError.server(_, _) {
            return try await attachmentBytesFromJSON(path: path)
        }
    }

    /// Streams the raw bytes (`$value`) into `destination`, counting them against the response's Content-Length or,
    /// without one, against `expectedSize`. An attachment with no `$value` (an item or reference attachment) comes
    /// back as base64 in JSON, in one response, as `attachment` fetches it.
    public func downloadAttachment(messageID providerID: String, attachmentID: String, expectedSize: Int, to destination: URL,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        let path = Self.attachmentPath(providerID, attachmentID)
        let meter = DownloadProgressMeter(estimatedLength: Int64(max(0, expectedSize)), report: progress)
        meter.start()
        do {
            try await client.download(try Self.rawAttachmentRequest(path: path), to: destination) { written, response in
                meter.received(written, of: response)
            }
        } catch ProviderError.notFound {
            try await attachmentBytesFromJSON(path: path).write(to: destination, options: .atomic)
        } catch ProviderError.server(_, _) {
            try await attachmentBytesFromJSON(path: path).write(to: destination, options: .atomic)
        }
        meter.finish()
    }

    private static func attachmentPath(_ providerID: String, _ attachmentID: String) -> String {
        "/me/messages/\(providerID)/attachments/\(attachmentID)"
    }

    private static func rawAttachmentRequest(path: String) throws -> GraphRequest {
        var request = GraphRequest(method: .get, url: try GraphURL.make(path + "/$value"))
        request.accept = "*/*"
        return request
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
            // A mailbox that refuses even the derived-type select still owes the Content-IDs: without them no
            // `cid:` image in the body resolves, in the reader or in a quoted reply. Images are read one at a
            // time without `$select`, which returns every fileAttachment property.
            var listed = try await listAttachments(for: providerID, select: Self.attachmentBaseSelect)
            for index in listed.indices where listed[index].contentId == nil && Self.mayBeReferencedInline(listed[index]) {
                let url = try GraphURL.make("/me/messages/\(providerID)/attachments/\(listed[index].id)")
                let full = try? await client.json(GraphAttachment.self, for: GraphRequest(method: .get, url: url))
                listed[index].contentId = full?.contentId
            }
            return listed
        }
    }

    /// Outlook often marks images a body references as regular attachments, so `isInline` alone is not enough.
    private static func mayBeReferencedInline(_ attachment: GraphAttachment) -> Bool {
        attachment.isInline == true || (attachment.contentType?.lowercased().hasPrefix("image/") ?? false)
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
        // `$search` takes one quoted phrase in which a backslash escapes the next character: backslashes go first, so
        // words ending in one cannot escape the closing quote.
        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
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

    /// How many levels of the folder tree the walk descends, the top level being the first. Outlook allows far
    /// deeper trees, but people file mail a handful of levels down; the cap is there so a broken listing that keeps
    /// handing back new children cannot keep a walk going for ever (one that repeats a folder is ended by the walk's
    /// `found` list). A folder below it gets no delta of its own: the bootstrap listing and a reconcile still cover
    /// its mail.
    static let maxFolderDepth = 16

    /// Listing pages one step of a walk sends, whichever listings they belong to. They go one after another, about a
    /// fifth of a second each, before the call's delta requests and the new inbox mail they carry; five keep a step
    /// to about a second and within the seven requests a quiet poll leaves a walk step
    /// (`GraphCursor.maxQuietVisitsPerCall`), and a tree of 60 folders with children, each listed in a page, is
    /// walked in twelve polls, a minute while the app is active. Counted in pages rather than listings because one
    /// folder can hold thousands of others, listed 200 a page. The step that starts a walk sends one page, after its
    /// six system folder lookups.
    static let maxWalkPagesPerCall = 5

    /// Calls on which a failing listing is tried before the walk gives up on it. A step comes before the call's
    /// delta requests, so a listing that fails for good (a folder that answers 500, or access denied) must not stop
    /// the polls, and new inbox mail with them; one that failed once gets two more tries on the calls after.
    static let maxWalkAttempts = 3

    /// One step of the walk that decides which folders get a delta of their own: the whole tree, a level at a time
    /// through `childFolders` wherever a folder reports children, down to `maxFolderDepth`. Without a walk under way
    /// the step starts one and sends the top level's first page; otherwise it sends the next `maxWalkPagesPerCall`
    /// pages of the listings in `pending`, keeping a listing's nextLink where the pages run out partway through it.
    /// Returns the walk as it stands and the folders this step found, each once in the whole walk.
    ///
    /// A folder gone since its parent was listed (404) is skipped with its children, as the next walk would find. A
    /// throttle, a refused token, a cancellation or a reset fails the step, as it would the call's next request. Any
    /// other failure ends the step and leaves the listing first in `pending` for the next call to try again; after
    /// `maxWalkAttempts` calls the walk gives up on it and goes on with the rest (`GraphFolderWalk.gaveUp`).
    func stepFolderWalk(_ walk: GraphFolderWalk?) async throws -> (walk: GraphFolderWalk, found: [String]) {
        let query = [("$top", "200"), ("$select", "id,childFolderCount")]
        var next = walk ?? GraphFolderWalk(found: [], pending: [.top])
        var seen = Set(next.found)
        var found: [String] = []
        var cappedParents = 0
        func meet(_ folders: [GraphFolder], depth: Int) {
            for folder in folders where seen.insert(folder.id).inserted {
                found.append(folder.id)
                guard (folder.childFolderCount ?? 0) > 0 else { continue }
                if depth < Self.maxFolderDepth {
                    next.pending.append(GraphFolderWalk.Parent(id: folder.id, depth: depth))
                } else {
                    cappedParents += 1
                }
            }
        }
        var pagesLeft = walk == nil ? 1 : Self.maxWalkPagesPerCall
        listing: while pagesLeft > 0, var parent = next.pending.first {
            next.pending.removeFirst()
            do {
                let path = parent.isTop ? "/me/mailFolders" : "/me/mailFolders/\(parent.id)/childFolders"
                var url: URL? = try parent.nextLink.map(GraphURL.absolute) ?? GraphURL.make(path, query: query)
                while let pageURL = url, pagesLeft > 0 {
                    pagesLeft -= 1
                    let page = try await client.json(GraphListResponse<GraphFolder>.self, for: GraphRequest(method: .get, url: pageURL))
                    meet(page.value, depth: parent.depth + 1)
                    parent.nextLink = page.nextLink
                    parent.failures = nil
                    url = try page.nextLink.map(GraphURL.absolute)
                }
                if parent.nextLink != nil { next.pending.insert(parent, at: 0) }
            } catch ProviderError.notFound {
                continue
            } catch let error where Self.failsTheCall(error) {
                throw error
            } catch {
                let failures = (parent.failures ?? 0) + 1
                if failures < Self.maxWalkAttempts {
                    parent.failures = failures
                    next.pending.insert(parent, at: 0)
                } else {
                    next.gaveUp = true
                    Self.folderLog.notice("folder walk gave up on a listing after \(failures, privacy: .public) failed calls: \(String(describing: error), privacy: .private)")
                }
                break listing
            }
        }
        if cappedParents > 0 {
            Self.folderLog.notice("folder tree deeper than \(Self.maxFolderDepth, privacy: .public) levels: \(cappedParents, privacy: .public) folders' children get no delta")
        }
        next.found += found
        return (next, found)
    }

    /// Failures the call's next request would meet as well, which a walk step passes on rather than holding against
    /// the listing: the engine waits out a throttle, asks for a new sign-in, stops, or starts over.
    static func failsTheCall(_ error: Error) -> Bool {
        guard let error = error as? ProviderError else { return error is CancellationError }
        switch error {
        case .throttled, .unauthorized, .cancelled, .resetRequired: return true
        case .notFound, .network, .decoding, .server: return false
        }
    }

    /// A failure that belongs to one message: anything but what fails the call, and the network, which a
    /// `$batch` part reports (503, 504) when the service rather than the message is at fault.
    static func isItemFailure(_ error: Error) -> Bool {
        if failsTheCall(error) { return false }
        if case ProviderError.network = error { return false }
        return true
    }

    static func pageSize(_ limit: Int, max: Int) -> Int {
        Swift.max(1, Swift.min(limit, max))
    }
}
