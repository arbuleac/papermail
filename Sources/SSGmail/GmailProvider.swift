import Foundation
import SSCore
import os

/// `MailProvider` over the Gmail REST API. Stateless beyond the account id and token source; every call
/// is a fresh HTTP exchange so the engine can retry, back off or reset without provider cooperation.
public final class GmailProvider: MailProvider, Sendable {
    public let accountID: AccountID
    public let kind: ProviderKind = .gmail

    private let http: GmailHTTPClient
    private let log = Logger(subsystem: "io.supersparrow.mac", category: "gmail")

    /// Bootstrap excludes spam and trash so the first paint matches "All mail". Chat history (Hangouts and
    /// Google Chat, stored as messages under the CHAT label) is excluded too: Gmail lists it but never shows
    /// it as mail, and it has no subject or inbox role to show.
    static let bootstrapQuery = "-in:spam -in:trash -in:chats"
    static let historyTypes = ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"]
    static let batchModifyChunk = 1000
    /// Gmail rejects maxResults above 500 for list and history calls.
    static let maxListResults = 500
    /// Bounds the work of one `changes` call; a run of history pages longer than this continues on the next
    /// call through the page token carried in the cursor.
    static let maxHistoryPagesPerCall = 20
    /// Messages whose RFC 5322 form is larger than this go through the upload endpoint. The JSON endpoint
    /// inflates them by a third (base64url on top of the MIME base64) and rejects bodies of a few MB,
    /// where the upload endpoint takes the raw bytes up to Gmail's 35 MB message limit.
    static let uploadThresholdBytes = 1 << 20

    public init(accountID: AccountID, tokens: AccessTokenProvider, session: URLSession = .shared) {
        self.accountID = accountID
        self.http = GmailHTTPClient(accountID: accountID, tokens: tokens, session: session)
    }

    // MARK: Profile

    public func profile() async throws -> AccountProfile {
        let profile = try await fetchProfile()
        let localPart = profile.emailAddress.split(separator: "@").first.map(String.init) ?? profile.emailAddress
        return AccountProfile(email: profile.emailAddress, displayName: localPart)
    }

    private func fetchProfile() async throws -> GmailProfile {
        try await http.json(GmailProfile.self, for: try GmailRequest.get("profile"))
    }

    // MARK: Bootstrap

    public func bootstrap(page: String?, limit: Int) async throws -> BootstrapPage {
        // The cursor must predate enumeration so changes made while paging are replayed, never lost. The same
        // read gives the mailbox's size, an estimate for “Downloading · 3,412 of 8,120” at no extra request.
        let profile: GmailProfile? = page == nil ? try await fetchProfile() : nil
        let changeCursor = profile?.historyId
        var query = [
            URLQueryItem(name: "q", value: Self.bootstrapQuery),
            URLQueryItem(name: "maxResults", value: String(Self.clampedLimit(limit))),
        ]
        if let page, !page.isEmpty {
            query.append(URLQueryItem(name: "pageToken", value: page))
        }
        let list = try await http.json(GmailMessageList.self, for: try GmailRequest.get("messages", query: query))
        let ids = (list.messages ?? []).map(\.id)
        let messages = try await fetchMetadata(ids: ids)
        log.debug("bootstrap page: \(ids.count, privacy: .public) listed, \(messages.count, privacy: .public) hydrated")
        return BootstrapPage(messages: messages, nextPage: list.nextPageToken, changeCursor: changeCursor,
                             estimatedTotal: profile?.messagesTotal)
    }

    // MARK: Changes

    public func changes(since cursor: String, limit: Int) async throws -> ChangesPage {
        let start = GmailHistoryCursor(parsing: cursor)
        var affected: [String] = []
        var affectedSet: Set<String> = []
        var deleted: [String] = []
        var deletedSet: Set<String> = []
        var lastRecordID: String?
        var finalHistoryID: String?
        var pageToken = start.pageToken
        var pagesFetched = 0
        var hasMore = false

        func noteAffected(_ id: String) {
            if affectedSet.insert(id).inserted { affected.append(id) }
        }

        while true {
            let response: GmailHistoryList
            do {
                response = try await fetchHistory(startHistoryID: start.startHistoryID, pageToken: pageToken, limit: limit)
            } catch ProviderError.server(let status, _) where status == 400 && pagesFetched == 0 && pageToken != nil {
                // A resume token Gmail no longer honors must not wedge the account on the same cursor forever;
                // the run starts over from its history id, which is still valid or answers 404 as usual.
                log.notice("history page token rejected; restarting the run from its history id")
                pageToken = nil
                continue
            }
            pagesFetched += 1
            for record in response.history ?? [] {
                lastRecordID = record.id
                for entry in record.messagesAdded ?? [] { noteAffected(entry.message.id) }
                for entry in record.labelsAdded ?? [] { noteAffected(entry.message.id) }
                for entry in record.labelsRemoved ?? [] { noteAffected(entry.message.id) }
                for ref in record.messages ?? [] { noteAffected(ref.id) }
                for entry in record.messagesDeleted ?? [] where deletedSet.insert(entry.message.id).inserted {
                    deleted.append(entry.message.id)
                }
            }
            guard let next = response.nextPageToken, !next.isEmpty else {
                finalHistoryID = response.historyId
                hasMore = false
                break
            }
            hasMore = true
            pageToken = next
            // Stop early once a page's worth of ids is in hand, or once this call has done its share of
            // paging; either way the cursor below says where the next call picks up.
            if affected.count + deleted.count >= limit || pagesFetched >= Self.maxHistoryPagesPerCall {
                break
            }
        }

        let toFetch = affected.filter { !deletedSet.contains($0) }
        let served = try await fetchMessages(ids: toFetch)
        let servedIDs = Set(served.map(\.id))
        // A message that history still mentions but Gmail no longer serves was deleted after the record.
        for id in toFetch where !servedIDs.contains(id) && deletedSet.insert(id).inserted {
            deleted.append(id)
        }
        // Chat history rides along in history.list; it is never shown, so it is neither upserted nor
        // reported as deleted (the store never held it).
        let fetched = served
            .filter { !GmailMessageMapper.isChat($0) }
            .map { GmailMessageMapper.metadata(from: $0, accountID: accountID) }

        let nextCursor: String
        if !hasMore {
            nextCursor = finalHistoryID ?? lastRecordID ?? start.startHistoryID
        } else if let lastRecordID {
            // Records were seen: Gmail serves everything after the last one from its id alone.
            nextCursor = lastRecordID
        } else {
            // Only empty pages so far: the page token is the only way to make progress through the run.
            nextCursor = GmailHistoryCursor(startHistoryID: start.startHistoryID, pageToken: pageToken).encoded
        }
        log.debug("changes: \(fetched.count, privacy: .public) upserts, \(deleted.count, privacy: .public) deletions")
        return ChangesPage(upserts: fetched, deletedIDs: deleted, cursor: nextCursor, hasMore: hasMore)
    }

    private func fetchHistory(startHistoryID: String, pageToken: String?, limit: Int) async throws -> GmailHistoryList {
        var query = [
            URLQueryItem(name: "startHistoryId", value: startHistoryID),
            URLQueryItem(name: "maxResults", value: String(Self.clampedLimit(limit))),
        ]
        query += Self.historyTypes.map { URLQueryItem(name: "historyTypes", value: $0) }
        if let pageToken {
            query.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        do {
            return try await http.json(GmailHistoryList.self, for: try GmailRequest.get("history", query: query))
        } catch ProviderError.notFound {
            // Gmail answers 404 when the start id has aged out of its history window.
            throw ProviderError.resetRequired
        }
    }

    // MARK: Metadata

    /// Chat history counts as unknown here: it is not mail and the store never holds it.
    public func metadata(for providerIDs: [String]) async throws -> [MessageMetadata] {
        try await fetchMetadata(ids: providerIDs)
    }

    private func fetchMetadata(ids: [String]) async throws -> [MessageMetadata] {
        try await fetchMessages(ids: ids)
            .filter { !GmailMessageMapper.isChat($0) }
            .map { GmailMessageMapper.metadata(from: $0, accountID: accountID) }
    }

    /// Hydrates ids in list order, 50 per batch call, dropping ids Gmail no longer knows.
    private func fetchMessages(ids: [String]) async throws -> [GmailMessage] {
        guard !ids.isEmpty else { return [] }
        var byID: [String: GmailMessage] = [:]
        for chunk in ids.chunked(into: GmailBatch.maxPartsPerBatch) {
            for message in try await metadataChunk(chunk) {
                byID[message.id] = message
            }
        }
        return ids.compactMap { byID[$0] }
    }

    private func metadataChunk(_ ids: [String]) async throws -> [GmailMessage] {
        do {
            return try await batchMetadata(ids)
        } catch GmailBatchError.unparseable(let reason) {
            log.notice("Gmail batch reply unparseable (\(reason, privacy: .public)); fetching \(ids.count, privacy: .public) ids one by one")
            return try await sequentialMetadata(ids)
        }
    }

    private func batchMetadata(_ ids: [String]) async throws -> [GmailMessage] {
        let boundary = "ss_batch_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let request = try GmailBatch.request(paths: ids.map(GmailRequest.metadataPath), boundary: boundary)
        return try await http.withAuthRetry { token in
            let response = try await http.sendOnce(request, token: token)
            let parts = try GmailBatch.parse(response.data, contentType: response.http.value(forHTTPHeaderField: "Content-Type"))
            var messages: [GmailMessage] = []
            var retryIDs: [String] = []
            for (position, part) in parts.enumerated() {
                let index = part.index ?? position
                switch part.status {
                case 200..<300:
                    guard let message = try? JSONDecoder().decode(GmailMessage.self, from: part.body) else {
                        throw GmailBatchError.unparseable("Part \(index) is not a message")
                    }
                    messages.append(message)
                case 404:
                    continue
                case 401, 403, 429:
                    // The batch envelope itself is never rate limited or auth checked; its parts are.
                    if let error = GmailHTTPClient.error(status: part.status, body: part.body, retryAfter: part.headers["retry-after"]) {
                        throw error
                    }
                default:
                    if ids.indices.contains(index) { retryIDs.append(ids[index]) }
                }
            }
            if !retryIDs.isEmpty {
                messages += try await sequentialMetadata(retryIDs)
            }
            return messages
        }
    }

    private func sequentialMetadata(_ ids: [String]) async throws -> [GmailMessage] {
        var messages: [GmailMessage] = []
        for id in ids {
            do {
                messages.append(try await fetchMessage(id, query: GmailRequest.metadataQuery()))
            } catch ProviderError.notFound {
                continue
            }
        }
        return messages
    }

    private func fetchMessage(_ id: String, query: [URLQueryItem]) async throws -> GmailMessage {
        try await http.json(GmailMessage.self, for: try GmailRequest.get("messages/" + Self.pathComponent(id), query: query))
    }

    // MARK: Bodies and attachments

    public func body(for providerID: String) async throws -> MessageBody {
        let message = try await fetchMessage(providerID, query: [URLQueryItem(name: "format", value: "full")])
        var parsed = GmailBodyParser.parse(message)
        // Gmail hands oversized text parts out behind attachment ids; the body is incomplete until they are in.
        for part in parsed.deferred {
            let bytes = try await attachment(messageID: providerID, attachmentID: part.attachmentID)
            parsed.resolve(part, bytes: bytes)
        }
        return parsed.body
    }

    public func attachment(messageID providerID: String, attachmentID: String) async throws -> Data {
        let resource = "messages/" + Self.pathComponent(providerID) + "/attachments/" + Self.pathComponent(attachmentID)
        let attachment = try await http.json(GmailAttachment.self, for: try GmailRequest.get(resource))
        guard let encoded = attachment.data, let data = Base64URL.decode(encoded) else {
            throw ProviderError.decoding("Attachment payload is not base64url")
        }
        return data
    }

    // MARK: Changes to messages

    public func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {
        guard !providerIDs.isEmpty else { return }
        let edit = GmailLabelEdit(change)
        for chunk in providerIDs.chunked(into: Self.batchModifyChunk) {
            let body = GmailBatchModifyRequest(
                ids: chunk,
                addLabelIds: edit.add.isEmpty ? nil : edit.add,
                removeLabelIds: edit.remove.isEmpty ? nil : edit.remove
            )
            _ = try await http.send(try GmailRequest.post("messages/batchModify", json: body))
        }
    }

    // MARK: Send

    public func send(_ message: OutgoingMessage) async throws -> SendReceipt {
        let profile = try await fetchProfile()
        var outgoing = message
        var threadID: String?
        if let replied = message.inReplyTo {
            // Gmail threads by threadId, not by In-Reply-To, so the parent's thread must be looked up. The
            // same fetch supplies the RFC 5322 ids other mail clients thread by, for composers that did not
            // pass them. A parent that vanished meanwhile is not a reason to fail the send.
            do {
                let fetched = try await fetchMessage(replied.providerID, query: GmailRequest.metadataQuery())
                let parent = GmailMessageMapper.metadata(from: fetched, accountID: accountID)
                threadID = parent.conversationID.providerID
                if outgoing.inReplyToInternetMessageID == nil, !outgoing.isForward {
                    outgoing.inReplyToInternetMessageID = parent.internetMessageID
                }
                if outgoing.references.isEmpty {
                    outgoing.references = parent.references
                }
            } catch ProviderError.notFound {
                threadID = nil
            }
        }
        let mime = MIMEBuilder(message: outgoing, from: EmailAddress(address: profile.emailAddress)).build()
        let request: GmailRequest
        if mime.count > Self.uploadThresholdBytes {
            request = try GmailRequest.upload(
                "messages/send",
                metadata: GmailUploadSendMetadata(threadId: threadID),
                media: mime,
                mediaType: "message/rfc822"
            )
        } else {
            request = try GmailRequest.post("messages/send", json: GmailSendRequest(raw: Base64URL.encode(mime), threadId: threadID))
        }
        let response = try await http.json(GmailSendResponse.self, for: request)
        log.debug("sent message \(response.id, privacy: .public)")
        return SendReceipt(providerMessageID: response.id, providerConversationID: response.threadId)
    }

    // MARK: Search

    public func search(_ text: String, limit: Int) async throws -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let query = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "maxResults", value: String(Self.clampedLimit(limit))),
        ]
        let list = try await http.json(GmailMessageList.self, for: try GmailRequest.get("messages", query: query))
        return (list.messages ?? []).map(\.id)
    }

    // MARK: Helpers

    private static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, 1), maxListResults)
    }

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
