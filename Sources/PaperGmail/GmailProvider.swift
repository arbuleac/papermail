import Foundation
import PaperCore
import os

/// `MailProvider` over the Gmail REST API. Stateless beyond the account id and token source; every call
/// is a fresh HTTP exchange so the engine can retry, back off or reset without provider cooperation.
public final class GmailProvider: MailProvider, Sendable {
    public let accountID: AccountID
    public let kind: ProviderKind = .gmail
    /// The account's address, when the caller knows it (empty while signing in): a block's link back to its mail
    /// names the account with it, so the browser opens this account's Gmail rather than the first one signed in.
    let accountEmail: String?

    let http: GmailHTTPClient
    private let throttleRetry: GmailThrottleRetry
    private let clock: @Sendable () -> Date
    private let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "gmail")

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
    /// Metadata gets per batch call. Gmail takes up to 50, but each part costs 20 quota units of the user's
    /// 6,000 a minute and Google runs the parts concurrently: 50 parts spend 1,000 units at once and trip
    /// the concurrency limit, where 10 spend 200 and leave room for the live lane's polls beside them.
    static let metadataBatchSize = 10
    /// Tries a message whose metadata Gmail failed for now (`GmailHistoryCursor.recheck`) gets before the history
    /// moves on without it: the failed one and two more, `recheckSpacing` apart. A backendError rarely outlasts a
    /// minute; the bound keeps a message Gmail always fails from being asked for on every poll for ever.
    static let maxRecheckTries = 3
    /// The least time between two tries of a carried message. The engine calls again at once while a page says
    /// `hasMore`, so tries counted per call could all fall within a second of one burst of failures.
    static let recheckSpacing: TimeInterval = 30

    public convenience init(accountID: AccountID, accountEmail: String? = nil, tokens: AccessTokenProvider,
                            session: URLSession = .shared) {
        self.init(accountID: accountID, accountEmail: accountEmail, tokens: tokens, session: session, throttleRetry: .standard)
    }

    init(accountID: AccountID, accountEmail: String? = nil, tokens: AccessTokenProvider, session: URLSession,
         throttleRetry: GmailThrottleRetry, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.http = GmailHTTPClient(accountID: accountID, tokens: tokens, session: session)
        self.throttleRetry = throttleRetry
        self.clock = clock
    }

    // MARK: Profile

    public func profile() async throws -> AccountProfile {
        let profile = try await fetchProfile()
        let localPart = profile.emailAddress.split(separator: "@").first.map(String.init) ?? profile.emailAddress
        return AccountProfile(email: profile.emailAddress, displayName: localPart)
    }

    private func fetchProfile() async throws -> GmailProfile {
        try await http.json(GmailProfile.self, for: try GmailRequest.get("profile", kind: .profile))
    }

    // MARK: Bootstrap

    public func bootstrap(page: String?, limit: Int) async throws -> BootstrapPage {
        // The cursor must predate enumeration so changes made while paging are replayed, never lost. The same
        // read gives the mailbox's size, an estimate for “Downloading · 3,412 of 8,120” at no extra request.
        let profile: GmailProfile? = page == nil ? try await fetchProfile() : nil
        let list = try await listMessages(page: page, limit: limit)
        let ids = (list.messages ?? []).map(\.id)
        let fetched = try await fetchMessages(ids: ids)
        let messages = map(fetched.messages)
        // A message Gmail failed for now is asked for again by the polls that follow, so new mail among the newest is
        // not lost to a backendError; one it refused is only reported, for a reconcile to count as listed.
        let changeCursor = profile.map { profile in
            GmailHistoryCursor(startHistoryID: profile.historyId,
                               recheck: Dictionary(fetched.failing.map { ($0, 1) }, uniquingKeysWith: max),
                               recheckAt: clock()).encoded
        }
        log.debug("bootstrap page: \(ids.count, privacy: .public) listed, \(messages.count, privacy: .public) hydrated")
        return BootstrapPage(messages: messages, nextPage: list.nextPageToken, changeCursor: changeCursor,
                             estimatedTotal: profile?.messagesTotal, unreadableIDs: fetched.unreadable)
    }

    /// Ids only: listing costs 5 quota units a page where metadata costs 20 a message, so the engine lists
    /// first and fetches metadata just for the messages its store lacks. Same query and page size as
    /// `bootstrap`, so a page token from either continues the same enumeration.
    public func backfillListing(page: String, limit: Int) async throws -> BackfillListing {
        let list = try await listMessages(page: page, limit: limit)
        let ids = (list.messages ?? []).map(\.id)
        log.debug("backfill page: \(ids.count, privacy: .public) listed")
        return BackfillListing(ids: ids, messages: nil, nextPage: list.nextPageToken)
    }

    /// Spam and Trash, which the enumeration leaves out but history reports when mail lands there, so the store holds
    /// some: a reconcile after an expired history lists their ids too and its sweep keeps what Gmail still has.
    public var hasMailOutsideEnumeration: Bool {
        true
    }

    /// Ids only, 500 a page for 5 quota units.
    public func mailOutsideEnumeration(page: String?, limit: Int) async throws -> BackfillListing {
        let list = try await listMessages(page: page, limit: limit, query: Self.outsideEnumerationQuery, includeSpamTrash: true)
        return BackfillListing(ids: (list.messages ?? []).map(\.id), messages: nil, nextPage: list.nextPageToken)
    }

    static let outsideEnumerationQuery = "in:trash OR in:spam"

    private func listMessages(page: String?, limit: Int, query search: String = bootstrapQuery,
                              includeSpamTrash: Bool = false) async throws -> GmailMessageList {
        var query = [
            URLQueryItem(name: "q", value: search),
            URLQueryItem(name: "maxResults", value: String(Self.clampedLimit(limit))),
        ]
        if includeSpamTrash {
            query.append(URLQueryItem(name: "includeSpamTrash", value: "true"))
        }
        if let page, !page.isEmpty {
            query.append(URLQueryItem(name: "pageToken", value: page))
        }
        return try await http.json(GmailMessageList.self, for: try GmailRequest.get("messages", query: query, kind: .list))
    }

    // MARK: Changes

    /// History since the cursor, and the metadata of every message it names. A message Gmail fails for now (a 500 for
    /// it alone) is neither upserted nor taken as deleted: the history moves on and the cursor carries it
    /// (`GmailHistoryCursor.recheck`), for a call `recheckSpacing` later to ask again, up to `maxRecheckTries` tries.
    /// One Gmail refused (a 400, a reply that does not decode) keeps what the store has; only a 404 is gone.
    public func changes(since cursor: String, limit: Int) async throws -> ChangesPage {
        let start = GmailHistoryCursor(parsing: cursor)
        let now = clock()
        let carried = start.recheck ?? [:]
        let recheckDue = !carried.isEmpty && start.recheckDue(at: now, spacing: Self.recheckSpacing)
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

        var toFetch = affected.filter { !deletedSet.contains($0) }
        var asked = Set(toFetch)
        if recheckDue {
            for id in carried.keys.sorted() where !deletedSet.contains(id) && asked.insert(id).inserted {
                toFetch.append(id)
            }
        }
        let served = try await fetchMessages(ids: toFetch)
        // A message that history still mentions but Gmail no longer serves (404) was deleted after the record. One it
        // would not return on its own says nothing of the kind: it keeps what the store has, and the cursor moves on.
        let answered = Set(served.messages.map(\.id)).union(served.unreadable)
        for id in toFetch where !answered.contains(id) && deletedSet.insert(id).inserted {
            deleted.append(id)
        }
        // Chat history rides along in history.list; it is never shown, so it is neither upserted nor
        // reported as deleted (the store never held it).
        let fetched = map(served.messages)

        // Carried messages not asked this call keep their place; those Gmail failed again count a try.
        var recheck = carried.filter { !asked.contains($0.key) && !deletedSet.contains($0.key) }
        var recheckAt = start.recheckAt.map { Date(timeIntervalSince1970: $0) }
        var givenUp = 0
        for id in served.failing {
            let tries = (carried[id] ?? 0) + 1
            if tries < Self.maxRecheckTries {
                recheck[id] = tries
                recheckAt = now
            } else {
                givenUp += 1
            }
        }
        if givenUp > 0 {
            log.notice("changes: \(givenUp, privacy: .public) messages Gmail kept failing are left as stored")
        }

        var nextStart = start.startHistoryID
        var nextPageToken: String?
        if !hasMore {
            nextStart = finalHistoryID ?? lastRecordID ?? start.startHistoryID
        } else if let lastRecordID {
            // Records were seen: Gmail serves everything after the last one from its id alone.
            nextStart = lastRecordID
        } else {
            // Only empty pages so far: the page token is the only way to make progress through the run.
            nextPageToken = pageToken
        }
        let nextCursor = GmailHistoryCursor(startHistoryID: nextStart, pageToken: nextPageToken, recheck: recheck,
                                            recheckAt: recheckAt).encoded
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
            return try await http.json(GmailHistoryList.self, for: try GmailRequest.get("history", query: query, kind: .history))
        } catch ProviderError.notFound {
            // Gmail answers 404 when the start id has aged out of its history window.
            throw ProviderError.resetRequired
        }
    }

    // MARK: Metadata

    /// Chat history counts as unknown here: it is not mail and the store never holds it. A message Gmail will not return
    /// on its own is left out too (`sequentialMetadata`), so it fails neither a backfill page nor a server search.
    public func metadata(for providerIDs: [String]) async throws -> [MessageMetadata] {
        try await fetchMetadata(ids: providerIDs)
    }

    public func lookUpMetadata(for providerIDs: [String]) async throws -> MetadataLookup {
        let fetched = try await fetchMessages(ids: providerIDs)
        return MetadataLookup(messages: map(fetched.messages), refused: fetched.refused, failing: fetched.failing)
    }

    private func fetchMetadata(ids: [String]) async throws -> [MessageMetadata] {
        map(try await fetchMessages(ids: ids).messages)
    }

    private func map(_ messages: [GmailMessage]) -> [MessageMetadata] {
        messages
            .filter { !GmailMessageMapper.isChat($0) }
            .map { GmailMessageMapper.metadata(from: $0, accountID: accountID) }
    }

    /// What a fetch by id found. An id in none of the lists is one Gmail no longer knows (404).
    struct Fetched {
        var messages: [GmailMessage] = []
        /// Refused for that message alone: a 4xx other than a rate limit, a reply that does not decode.
        var refused: [String] = []
        /// Failed by the service for now: a 500 for that message, on the batch and again on its own.
        var failing: [String] = []

        var unreadable: [String] { refused + failing }

        static func + (lhs: Fetched, rhs: Fetched) -> Fetched {
            Fetched(messages: lhs.messages + rhs.messages, refused: lhs.refused + rhs.refused, failing: lhs.failing + rhs.failing)
        }
    }

    /// Hydrates ids in list order, 10 per batch call, dropping ids Gmail no longer knows and setting aside those it
    /// would not return on their own.
    private func fetchMessages(ids: [String]) async throws -> Fetched {
        guard !ids.isEmpty else { return Fetched() }
        var byID: [String: GmailMessage] = [:]
        var fetched = Fetched()
        for chunk in ids.chunked(into: Self.metadataBatchSize) {
            let part = try await metadataChunk(chunk, hasFetched: !byID.isEmpty)
            for message in part.messages {
                byID[message.id] = message
            }
            fetched.refused += part.refused
            fetched.failing += part.failing
        }
        fetched.messages = ids.compactMap { byID[$0] }
        return fetched
    }

    /// One chunk, keeping every part Google answered: throttled parts go out again in a smaller batch after
    /// a wait, parts that failed otherwise are fetched one by one once the throttled ones are in. Waits run
    /// between sends, never inside the auth retry, so nothing is held while sleeping. `hasFetched` says
    /// whether earlier chunks of the call returned messages, which a reported throttle would discard.
    private func metadataChunk(_ ids: [String], hasFetched: Bool) async throws -> Fetched {
        var messages: [GmailMessage] = []
        var failed: [String] = []
        var pending = ids
        var retry = 0
        while true {
            let outcome: BatchOutcome
            do {
                outcome = try await batchMetadata(pending)
            } catch GmailBatchError.unparseable(let reason) {
                log.notice("Gmail batch reply unparseable (\(reason, privacy: .public)); fetching \(pending.count, privacy: .public) ids one by one")
                failed += pending
                break
            }
            messages += outcome.messages
            failed += outcome.failed
            guard !outcome.throttled.isEmpty else { break }
            let delay = throttleRetry.delay(beforeRetry: retry, retryAfter: outcome.retryAfter,
                                            hasFetched: hasFetched || !messages.isEmpty)
            guard let delay else {
                // Reported, not returned short: an id missing from the result reads as deleted to `changes`.
                throw ProviderError.throttled(retryAfter: outcome.retryAfter)
            }
            retry += 1
            try await throttleRetry.wait(delay)
            pending = outcome.throttled
        }
        guard !failed.isEmpty else { return Fetched(messages: messages) }
        return Fetched(messages: messages) + (try await sequentialMetadata(failed))
    }

    /// What one batch send settled. Ids are the requested ones, matched to parts by Content-ID.
    private struct BatchOutcome {
        var messages: [GmailMessage] = []
        /// Parts Google rate limited, to send again.
        var throttled: [String] = []
        /// The longest wait any throttled part asked for, from its Retry-After or its message.
        var retryAfter: TimeInterval?
        /// Parts that failed for another reason, or that the reply never answered, to fetch one by one.
        var failed: [String] = []
    }

    private func batchMetadata(_ ids: [String]) async throws -> BatchOutcome {
        let boundary = "paper_batch_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let request = try GmailBatch.request(paths: ids.map(GmailRequest.metadataPath), boundary: boundary)
        return try await http.withAuthRetry { token in
            let response = try await http.sendOnce(request, token: token)
            let parts = try GmailBatch.parse(response.data, contentType: response.http.value(forHTTPHeaderField: "Content-Type"))
            var outcome = BatchOutcome()
            var answered = Set<Int>()
            // Each group keeps its own longest wait, so the log says which limit asked for it.
            var throttleGroups: [(details: GmailHTTPClient.ThrottleDetails, count: Int, retryAfter: TimeInterval?)] = []
            // Written however the reply ends (kept, refused or unparseable): every throttle Google sent is
            // logged, even when the parts are then fetched another way.
            defer {
                for group in throttleGroups {
                    GmailHTTPClient.logThrottle(group.details, kind: .batchMetadata, retryAfter: group.retryAfter,
                                                parts: (group.count, ids.count))
                }
            }
            // Both are thrown only once every part is read, so throttled parts after them are still seen.
            var refusal: ProviderError?
            var unparseable: String?
            for (position, part) in parts.enumerated() {
                let index = part.index ?? position
                // A part repeating an index already answered must not queue its id twice.
                let requested = ids.indices.contains(index) && answered.insert(index).inserted ? ids[index] : nil
                switch part.status {
                case 200..<300:
                    guard let message = try? JSONDecoder().decode(GmailMessage.self, from: part.body) else {
                        unparseable = unparseable ?? "Part \(index) is not a message"
                        continue
                    }
                    outcome.messages.append(message)
                case 404:
                    continue
                case 401, 403, 429:
                    // The batch envelope itself is never rate limited or auth checked; its parts are.
                    guard let error = GmailHTTPClient.error(status: part.status, body: part.body, retryAfter: part.headers["retry-after"]) else {
                        continue
                    }
                    guard case .throttled(let retryAfter) = error else {
                        refusal = refusal ?? error
                        continue
                    }
                    if let requested { outcome.throttled.append(requested) }
                    if let retryAfter { outcome.retryAfter = max(outcome.retryAfter ?? 0, retryAfter) }
                    let details = GmailHTTPClient.ThrottleDetails(status: part.status, body: part.body)
                    if let group = throttleGroups.firstIndex(where: { $0.details == details }) {
                        throttleGroups[group].count += 1
                        if let retryAfter {
                            throttleGroups[group].retryAfter = max(throttleGroups[group].retryAfter ?? 0, retryAfter)
                        }
                    } else {
                        throttleGroups.append((details, 1, retryAfter))
                    }
                default:
                    if let requested { outcome.failed.append(requested) }
                }
            }
            // A refused token or account wins over an unreadable part: re-fetching one by one would be
            // refused too, where a 401 earns the whole batch a fresh token.
            if let refusal { throw refusal }
            if let unparseable { throw GmailBatchError.unparseable(unparseable) }
            // An id no part answered is fetched on its own rather than dropped, which `changes` would read
            // as a deletion.
            outcome.failed += ids.indices.filter { !answered.contains($0) }.map { ids[$0] }
            return outcome
        }
    }

    /// Fetches, one at a time, the ids a batch did not settle. A message Gmail will not return on its own even then is
    /// set aside rather than thrown: refused (a 400, a 403 that is not a rate limit, a reply that does not decode) or
    /// failing (a 500, Gmail's backendError, which may well pass). Failing the call for it would fail `changes` after it
    /// paged the history, on every poll, and hold the cursor for good; a bootstrap would never get its cursor and a
    /// backfill page would never end. What the next request would meet too (a throttle, a refused token, the network,
    /// a 502 to 504, a cancellation) still fails it.
    private func sequentialMetadata(_ ids: [String]) async throws -> Fetched {
        var fetched = Fetched()
        for id in ids {
            do {
                fetched.messages.append(try await fetchMessage(id, query: GmailRequest.metadataQuery()))
            } catch ProviderError.notFound {
                continue
            } catch let error where Self.isItemFailure(error) {
                log.notice("metadata: a message Gmail would not return is left out: \(Self.failureLabel(error), privacy: .public)")
                if Self.isServiceFailure(error) {
                    fetched.failing.append(id)
                } else {
                    fetched.refused.append(id)
                }
            }
        }
        return fetched
    }

    /// A failure of one message's request that the next request would not meet.
    static func isItemFailure(_ error: Error) -> Bool {
        switch error as? ProviderError {
        case .server?, .decoding?: return true
        default: return false
        }
    }

    /// An item failure of the service rather than of the message (a 500): a later request may find it.
    static func isServiceFailure(_ error: Error) -> Bool {
        if case .server(let status, _)? = error as? ProviderError { return status >= 500 }
        return false
    }

    /// For public logs: the status, never Google's message.
    private static func failureLabel(_ error: Error) -> String {
        switch error as? ProviderError {
        case .server(let status, _)?: return "HTTP \(status)"
        case .decoding?: return "a reply that does not decode"
        default: return "other"
        }
    }

    private func fetchMessage(_ id: String, query: [URLQueryItem]) async throws -> GmailMessage {
        try await http.json(GmailMessage.self, for: try GmailRequest.get("messages/" + Self.pathComponent(id), query: query, kind: .message))
    }

    // MARK: Bodies and attachments

    public func body(for providerID: String) async throws -> MessageBody {
        let message = try await fetchMessage(providerID, query: [URLQueryItem(name: "format", value: "full")])
        var parsed = GmailBodyParser.parse(message)
        // Gmail hands oversized text parts out behind attachment ids; the body is incomplete until they are in.
        for part in parsed.deferred {
            let bytes: Data
            do {
                bytes = try await attachment(messageID: providerID, attachmentID: part.attachmentID)
            } catch let error where part.mimeType == GmailBodyParser.calendarType && !Self.failsTheBody(error) {
                // The calendar is an extra: the message keeps its body without a card rather than failing whole, unless
                // the next request would meet the same failure, when the fetch is tried again with it.
                log.notice("invitation: calendar not fetched: \(String(describing: error), privacy: .private)")
                continue
            }
            parsed.resolve(part, bytes: bytes)
        }
        return parsed.body
    }

    /// Failures the body's next request would meet too: a throttle, a refused token, the network, a cancellation.
    static func failsTheBody(_ error: Error) -> Bool {
        switch error as? ProviderError {
        case .throttled?, .unauthorized?, .network?, .cancelled?: return true
        default: return error is CancellationError
        }
    }

    /// In one response, for the oversized text parts a body fetch resolves; files the user opens go through
    /// `downloadAttachment`.
    public func attachment(messageID providerID: String, attachmentID: String) async throws -> Data {
        let request = try GmailRequest.get(Self.attachmentResource(providerID, attachmentID), kind: .attachment)
        let attachment = try await http.json(GmailAttachment.self, for: request)
        guard let encoded = attachment.data, let data = Base64URL.decode(encoded) else {
            throw ProviderError.decoding("Attachment payload is not base64url")
        }
        return data
    }

    /// Streams the reply, a JSON object whose `data` is the file in base64url, to a file beside `destination` (so
    /// whatever sweeps the caller's unfinished downloads sweeps it too), then decodes it into `destination` a slice
    /// at a time. Progress counts the reply's bytes against its Content-Length or, as Google usually sends it
    /// chunked, against the base64 length of `expectedSize`; it stops at 99% until the file is decoded and written.
    public func downloadAttachment(messageID providerID: String, attachmentID: String, expectedSize: Int, to destination: URL,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        let request = try GmailRequest.get(Self.attachmentResource(providerID, attachmentID), kind: .attachment)
        let meter = DownloadProgressMeter(estimatedLength: Self.replyLength(forAttachmentOf: expectedSize), report: progress)
        let reply = destination.appendingPathExtension("reply")
        defer { try? FileManager.default.removeItem(at: reply) }
        meter.start()
        try await http.download(request, to: reply) { written, response in
            meter.received(written, of: response)
        }
        if Task.isCancelled { throw ProviderError.cancelled }
        try GmailAttachmentDecoder.decode(reply: reply, to: destination)
        meter.finish()
    }

    /// About how long the reply for an attachment of `size` bytes is: base64 takes 4 characters for every 3 bytes,
    /// and the JSON around it (`{"size": …, "data": "…"}`, pretty-printed) a few dozen more. nil when the size is
    /// unknown.
    static func replyLength(forAttachmentOf size: Int) -> Int64? {
        guard size > 0 else { return nil }
        return Int64((size + 2) / 3) * 4 + replyOverhead
    }

    private static let replyOverhead: Int64 = 64

    private static func attachmentResource(_ providerID: String, _ attachmentID: String) -> String {
        "messages/" + pathComponent(providerID) + "/attachments/" + pathComponent(attachmentID)
    }

    // MARK: Changes to messages

    public func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {
        guard !providerIDs.isEmpty else { return }
        if case .answerInvitation(let answer) = change {
            // One answer per event, however many copies of the invitation the operations named.
            try await self.answer(answer)
            return
        }
        let edit = GmailLabelEdit(change)
        guard !(edit.add.isEmpty && edit.remove.isEmpty) else { return }
        for chunk in providerIDs.chunked(into: Self.batchModifyChunk) {
            let body = GmailBatchModifyRequest(
                ids: chunk,
                addLabelIds: edit.add.isEmpty ? nil : edit.add,
                removeLabelIds: edit.remove.isEmpty ? nil : edit.remove
            )
            _ = try await http.send(try GmailRequest.post("messages/batchModify", json: body, kind: .batchModify))
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
        return try await sendRaw(mime, threadID: threadID)
    }

    /// Sends an RFC 5322 message as it is, through the upload endpoint when it is large.
    private func sendRaw(_ mime: Data, threadID: String?) async throws -> SendReceipt {
        let request: GmailRequest
        if mime.count > Self.uploadThresholdBytes {
            request = try GmailRequest.upload(
                "messages/send",
                metadata: GmailUploadSendMetadata(threadId: threadID),
                media: mime,
                mediaType: "message/rfc822",
                kind: .send
            )
        } else {
            request = try GmailRequest.post("messages/send", json: GmailSendRequest(raw: Base64URL.encode(mime), threadId: threadID), kind: .send)
        }
        let response = try await http.json(GmailSendResponse.self, for: request)
        log.debug("sent message \(response.id, privacy: .public)")
        return SendReceipt(providerMessageID: response.id, providerConversationID: response.threadId)
    }

    // MARK: Invitations

    /// Answering needs `calendar.events` on top of mail: without it the answer waits and the account asks to reconnect.
    public func missingPermission(for change: MetadataChange) async -> AccountPermission? {
        guard case .answerInvitation = change else { return nil }
        let granted = await http.tokens.grantedScopes(for: accountID)
        return OAuthEndpoints.grants(granted, .calendar, kind: .gmail) ? nil : .calendar
    }

    /// The user's own Google Calendar copy is marked first, then the organizer is answered by mail: the mail alone
    /// leaves that copy at “needs action” on the phone. The outbox retries an answer whose request may have landed, so
    /// each step checks before it acts: the copy is patched only when it does not say the answer yet, and the mail,
    /// whose Message-ID comes from the answer (`InvitationAnswer.replyID`), goes only when the mailbox does not hold it
    /// yet, since a send whose reply was lost has already reached the organizer.
    func answer(_ answer: InvitationAnswer) async throws {
        var answer = answer
        // Fixed before the copy can change the attendee, so every attempt names the same message.
        let messageID = answer.replyID.flatMap { Self.replyMessageID($0, from: answer.attendee.address) }
        // The copy's own attendee is the address Google knows the user by on this event, which can be an alias the
        // sync-time reader could not know was theirs; without a copy the reply names whom the answer named.
        if let own = try await markCalendarCopy(answer) { answer.attendee = own }
        if let messageID, try await mailboxHolds(messageID: messageID) {
            log.debug("invitation: reply already sent")
            return
        }
        try await mailReply(answer, messageID: messageID)
    }

    /// The reply's Message-ID for an answer: its reply id at the attendee's domain. Nil for an id that is not the
    /// plain token this app makes, which then sends without the check.
    static func replyMessageID(_ replyID: String, from address: String) -> String? {
        guard !replyID.isEmpty, replyID.count <= 64,
              replyID.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }) else {
            return nil
        }
        return "<invitation-reply-" + replyID.lowercased() + "@" + MIMEBuilder.domain(of: address) + ">"
    }

    /// Whether a message with this Message-ID is in the mailbox (Sent, or wherever the user has moved it since):
    /// `rfc822msgid:` searches the header Gmail keeps from the raw message it sent.
    private func mailboxHolds(messageID: String) async throws -> Bool {
        let id = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let query = [
            URLQueryItem(name: "q", value: "rfc822msgid:" + id),
            URLQueryItem(name: "includeSpamTrash", value: "true"),
            URLQueryItem(name: "maxResults", value: "1"),
        ]
        let list = try await http.json(GmailMessageList.self, for: try GmailRequest.get("messages", query: query, kind: .list))
        return !(list.messages ?? []).isEmpty
    }

    /// Sets the user's responseStatus on their copy of the event, found by its iCalendar UID (`events.list?iCalUID=`),
    /// with `sendUpdates=none` because the iMIP reply is what tells the organizer, and returns the copy's attendee that
    /// is the user (`self`). A copy Google Calendar never made (an outside organizer, events not added automatically),
    /// one that does not list the user, or a calendar the client may not reach (the Calendar API not enabled for the
    /// OAuth client, 403) is skipped: the mail still goes.
    private func markCalendarCopy(_ answer: InvitationAnswer) async throws -> EmailAddress? {
        let listing: GmailHTTPClient.Response
        do {
            listing = try await http.send(try GmailRequest.calendarEvents(query: [URLQueryItem(name: "iCalUID", value: answer.uid)]))
        } catch let error where Self.skipsCalendarCopy(error) {
            log.notice("invitation: calendar copy not reachable: \(String(describing: error), privacy: .private)")
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: listing.data) as? [String: Any] else {
            throw ProviderError.decoding("Calendar events listing is not a JSON object")
        }
        let items = object["items"] as? [[String: Any]] ?? []
        guard let event = Self.calendarEvent(in: items, recurrenceID: answer.recurrenceID, isAllDay: answer.isAllDay),
              let eventID = event["id"] as? String,
              var attendees = event["attendees"] as? [[String: Any]],
              let index = attendees.firstIndex(where: { ($0["self"] as? Bool) == true }) else {
            log.debug("invitation: no calendar copy lists the user")
            return nil
        }
        let own = Self.ownAttendee(attendees[index], answering: answer.attendee)
        let status = Self.calendarResponseStatus(answer.response)
        guard attendees[index]["responseStatus"] as? String != status else { return own }
        attendees[index]["responseStatus"] = status
        // A patch replaces the attendee list whole, so every other entry goes back as it came, unknown fields and all.
        let body = try JSONSerialization.data(withJSONObject: ["attendees": attendees])
        do {
            _ = try await http.send(try GmailRequest.calendarEvents(
                Self.pathComponent(eventID), method: .patch, query: [URLQueryItem(name: "sendUpdates", value: "none")], json: body
            ))
        } catch let error where Self.skipsCalendarCopy(error) {
            log.notice("invitation: calendar copy not updated: \(String(describing: error), privacy: .private)")
        }
        return own
    }

    /// The user as the copy lists them: its address, with the name the answer gives the user (the invitation's own
    /// entry for them, else the account's name) unless Google names them itself. Nil when the entry has no address.
    static func ownAttendee(_ entry: [String: Any], answering attendee: EmailAddress) -> EmailAddress? {
        guard let address = (entry["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            return nil
        }
        if address.caseInsensitiveCompare(attendee.address) == .orderedSame { return attendee }
        let named = (entry["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EmailAddress(name: named.flatMap { $0.isEmpty ? nil : $0 } ?? attendee.name, address: address)
    }

    /// The iMIP reply (RFC 6047): METHOD:REPLY with the user's ATTENDEE and PARTSTAT, mailed from the address the
    /// invitation names to the organizer, at once and with no undo window, outside the composer's outbox.
    private func mailReply(_ answer: InvitationAnswer, messageID: String?) async throws {
        let message = OutgoingMessage(
            accountID: accountID,
            to: [answer.organizer],
            subject: InvitationCalendarWriter.replySubject(answer),
            html: InvitationCalendarWriter.replyHTML(answer),
            text: InvitationCalendarWriter.replyText(answer)
        )
        let calendar = MIMEBuilder.CalendarPart(method: "REPLY", text: InvitationCalendarWriter.reply(answer))
        // From is the attendee address: Gmail keeps it when it is the account or a verified alias, otherwise it writes
        // the account's own.
        let mime = MIMEBuilder(message: message, from: answer.attendee, messageID: messageID, calendar: calendar).build()
        let receipt = try await sendRaw(mime, threadID: nil)
        log.debug("invitation: answered with \(receipt.providerMessageID ?? "?", privacy: .public)")
    }

    /// Failures that mean the calendar copy cannot be reached rather than that the answer failed.
    static func skipsCalendarCopy(_ error: Error) -> Bool {
        switch error as? ProviderError {
        case .notFound?: return true
        case .server(let status, _)?: return status == 403 || status == 400 || status == 410
        default: return false
        }
    }

    /// The event the answer is about: for one occurrence, the copy of that occurrence (`originalStartTime` at the
    /// RECURRENCE-ID); otherwise the series or single event, never an occurrence of it.
    static func calendarEvent(in items: [[String: Any]], recurrenceID: Date?, isAllDay: Bool) -> [String: Any]? {
        guard let recurrenceID else {
            return items.first { $0["recurringEventId"] == nil } ?? items.first
        }
        return items.first { item in
            guard let original = item["originalStartTime"] as? [String: Any] else { return false }
            if let dateTime = original["dateTime"] as? String, let date = calendarDateTime(dateTime) {
                return abs(date.timeIntervalSince(recurrenceID)) < 1
            }
            if let day = original["date"] as? String {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.dateFormat = "yyyy-MM-dd"
                return isAllDay && formatter.string(from: recurrenceID) == day
            }
            return false
        }
    }

    private static func calendarDateTime(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    static func calendarResponseStatus(_ response: InvitationResponse) -> String {
        switch response {
        case .accepted: return "accepted"
        case .tentative: return "tentative"
        case .declined: return "declined"
        case .needsAction: return "needsAction"
        }
    }

    // MARK: Search

    public func search(_ text: String, limit: Int) async throws -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let query = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "maxResults", value: String(Self.clampedLimit(limit))),
        ]
        let list = try await http.json(GmailMessageList.self, for: try GmailRequest.get("messages", query: query, kind: .list))
        return (list.messages ?? []).map(\.id)
    }

    // MARK: Helpers

    private static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, 1), maxListResults)
    }

    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
