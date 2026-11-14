import Foundation

/// Reference implementation of `MailStoring` kept entirely in memory.
///
/// It defines the semantics the SQLite store must match (conversation summaries, pending operations win,
/// view predicates) and backs engine and UI tests. Not optimized; do not use for real mailboxes.
public final class InMemoryMailStore: MailStoring, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var accountRows: [AccountID: Account] = [:]
    private var cursors: [AccountID: String] = [:]
    private var bootstraps: [AccountID: BootstrapState] = [:]
    private var messagesByID: [MessageID: MessageMetadata] = [:]
    private var bodies: [MessageID: StoredBody] = [:]
    /// `bodies.evicted`: these keep their entry in `bodies` (plain text for search, so the message is not "missing")
    /// with the source and rendered HTML cleared, and `body(for:)` answers nil for them.
    private var evicted: Set<MessageID> = []
    private var operations: [String: Operation] = [:]
    /// Each operation's place in the order rows were first written (`noteQueuedLocked`).
    private var queueOrder: [String: Int] = [:]
    private var queued = 0
    /// `operation_targets.prior_*`: per operation and target, the flags its change replaced, which a give-up
    /// puts back. Recorded at enqueue and refreshed by every upsert that replays the operation.
    private var priors: [String: [MessageID: Prior]] = [:]
    /// `conversations.failed_op_kind`: kept by operation writes, never derived (see `FailedOperationMarks`).
    private var failedMarks: [ConversationID: OperationKind] = [:]
    private var sends: [String: PendingSend] = [:]
    /// `backfill_live_marks`: what the live lane wrote (false) or deleted (true) while a backfill runs.
    private var liveMarks: [MessageID: Bool] = [:]
    /// `backfill_seen`: what a reconciling backfill's listing has returned.
    private var backfillSeen: Set<MessageID> = []
    /// `queued_lookups`: stored messages of a gone folder still to look up, with their failed tries.
    private var lookupQueue: [MessageID: Int] = [:]
    private var contactCounts: [AccountID: [String: (name: String?, count: Int, lastSeen: Date)]] = [:]
    /// `snoozes`: kept when a wipe drops the conversation, as the SQLite store keeps them (the rules are written out on
    /// `SnoozeTable`). Dates are held to the millisecond, as that store keeps them.
    private var snoozeRows: [ConversationID: Snooze] = [:]
    /// `conversations.returned_at`: what a refresh keeps, so it is checked whenever a conversation is touched.
    private var returnedMarks: [ConversationID: Date] = [:]
    private var snoozeObservers: [UUID: SnoozeObserver] = [:]
    /// `conversations.muted`: lives on the summary row in the SQLite store, so it goes with that row (a wipe, or no
    /// message left outside Spam).
    private var mutedConversations: Set<ConversationID> = []
    /// `sender_rules`, by account and normalized address.
    private var senderRuleRows: [AccountID: [String: SenderRule]] = [:]
    private var senderRuleObservers: [UUID: SenderRuleObserver] = [:]
    private var conversationObservers: [UUID: (ConversationQuery, ([ConversationSummary]) -> Void)] = [:]
    private var messageObservers: [UUID: (ConversationID, ([MessageMetadata]) -> Void)] = [:]
    private var sendObservers: [UUID: ([PendingSend]) -> Void] = [:]

    public init() {}

    // MARK: Accounts

    public func accounts() throws -> [Account] {
        lock.lock(); defer { lock.unlock() }
        return accountRows.values.sorted { $0.addedAt < $1.addedAt }
    }

    public func upsertAccount(_ account: Account) throws {
        lock.lock(); defer { lock.unlock() }
        try AccountTable.validate(inkSlot: account.inkSlot)
        var stored = account
        stored.monogram = Account.normalizedMonogram(account.monogram)
        stored.signature = Account.normalizedSignature(account.signature)
        accountRows[account.id] = stored
        notifyAll()
    }

    public func deleteAccount(_ id: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        accountRows[id] = nil
        wipeLocked(id)
        // The foreign key removes them in the SQLite store; a wipe alone keeps them.
        snoozeRows = snoozeRows.filter { $0.key.accountID != id }
        senderRuleRows[id] = nil
        for operation in operations.values where operation.accountID == id { priors[operation.id] = nil }
        operations = operations.filter { $0.value.accountID != id }
        sends = sends.filter { $0.value.message.accountID != id }
        notifyAll()
        notifySends()
    }

    public func setInkSlot(_ slot: Int, for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        try AccountTable.validate(inkSlot: slot)
        guard accountRows[accountID] != nil else { throw StoreError.notFound }
        accountRows[accountID]?.inkSlot = slot
        notifyAll()
    }

    public func setMonogram(_ monogram: String?, for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        guard accountRows[accountID] != nil else { throw StoreError.notFound }
        accountRows[accountID]?.monogram = Account.normalizedMonogram(monogram)
        notifyAll()
    }

    public func setSignature(_ signature: String?, for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        guard accountRows[accountID] != nil else { throw StoreError.notFound }
        accountRows[accountID]?.signature = Account.normalizedSignature(signature)
        notifyAll()
    }

    // MARK: Sync state

    public func syncCursor(for accountID: AccountID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return cursors[accountID]
    }

    public func setSyncCursor(_ cursor: String?, for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        cursors[accountID] = cursor
    }

    public func bootstrapState(for accountID: AccountID) throws -> BootstrapState? {
        lock.lock(); defer { lock.unlock() }
        return bootstraps[accountID]
    }

    public func setBootstrapState(_ state: BootstrapState?, for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        bootstraps[accountID] = state
    }

    public func wipeMailData(for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        wipeLocked(accountID)
        notifyAll()
    }

    private func wipeLocked(_ accountID: AccountID) {
        messagesByID = messagesByID.filter { $0.key.accountID != accountID }
        bodies = bodies.filter { $0.key.accountID != accountID }
        evicted = evicted.filter { $0.accountID != accountID }
        cursors[accountID] = nil
        bootstraps[accountID] = nil
        contactCounts[accountID] = nil
        clearBackfillMarksLocked(accountID)
        lookupQueue = lookupQueue.filter { $0.key.accountID != accountID }
        dropOrphanedMarksLocked()
        // The summary rows go with the wipe, and the return mark and the mute live on them; the snoozes stay.
        returnedMarks = returnedMarks.filter { $0.key.accountID != accountID }
        mutedConversations = mutedConversations.filter { $0.accountID != accountID }
    }

    /// The SQLite store keeps the mark on the summary row, which goes when a conversation has no non-spam
    /// message left; a conversation that comes back later starts unmarked there, so it must here too.
    private func dropOrphanedMarksLocked() {
        guard !failedMarks.isEmpty || !mutedConversations.isEmpty else { return }
        let summarized = Set(messagesByID.values.lazy.filter { !$0.roles.contains(.spam) }.map(\.conversationID))
        failedMarks = failedMarks.filter { summarized.contains($0.key) }
        mutedConversations = mutedConversations.filter { summarized.contains($0) }
    }

    // MARK: Messages

    public func upsertMessages(_ messages: [MessageMetadata]) throws {
        lock.lock(); defer { lock.unlock() }
        upsertLocked(messages, senderRules: true)
        notifyAll()
    }

    /// The one write path for provider metadata, shared by `upsertMessages` and `writeBackfillMessages` as
    /// `MessageTable.upsert` is in the SQLite store; `senderRules` as there (`ArrivalRules`).
    private func upsertLocked(_ messages: [MessageMetadata], senderRules: Bool) {
        var touched: Set<ConversationID> = []
        var arrivals: [Arrival] = []
        for incoming in messages {
            var metadata = incoming
            // Headers never change, and a path that cannot carry them (a Graph listing) says nil: one already stored
            // stays (`MessageTable.upsertSQL`).
            if metadata.listUnsubscribe == nil, let stored = messagesByID[incoming.id] {
                metadata.listUnsubscribe = stored.listUnsubscribe
                metadata.listUnsubscribePost = stored.listUnsubscribePost
            }
            // The answer to an invitation is recorded here and never reported by a provider (as the SQLite upsert never
            // writes `invitation_reply`).
            metadata.invitationReply = messagesByID[incoming.id]?.invitationReply
            // Pending operations win: provider state older than a queued intent must not undo it. Each one's
            // prior follows the report, so a give-up puts back what the provider last said.
            for op in liveOperationsLocked(on: incoming.id) {
                priors[op.id, default: [:]][incoming.id] = Prior(metadata)
                metadata = applying(op.change, to: metadata)
            }
            let previous = messagesByID[incoming.id]
            if let previous { touched.insert(previous.conversationID) }
            messagesByID[incoming.id] = metadata
            touched.insert(metadata.conversationID)
            if previous == nil {
                let muted = mutedConversations.contains(metadata.conversationID)
                let rule = senderRules ? metadata.from.flatMap { senderRuleLocked(metadata.id.accountID, $0.address)?.action } : nil
                if let change = ArrivalRule.change(for: metadata, inMutedConversation: muted, senderRule: rule) {
                    arrivals.append(Arrival(message: metadata, change: change, muted: muted && change == .archive))
                }
                if !ArrivalRule.keepsSnooze(inMutedConversation: muted, senderRule: rule) {
                    endSnoozeForArrivalLocked(of: metadata)
                }
            }
            recordContacts(of: metadata)
        }
        enqueueArrivalsLocked(arrivals)
        dropOrphanedMarksLocked()
        applySnoozeRulesLocked(touched: touched)
    }

    private struct Arrival {
        var message: MessageMetadata
        var change: MetadataChange
        var muted: Bool
    }

    /// `ArrivalRules.enqueue`: per account one Archive (a muted conversation's every message in the Inbox, a sender's
    /// own message) and one Move to Trash a millisecond later, applied and queued as a user action is.
    private func enqueueArrivalsLocked(_ arrivals: [Arrival]) {
        guard !arrivals.isEmpty else { return }
        let now = Date()
        var order: [AccountID] = []
        for arrival in arrivals where !order.contains(arrival.message.id.accountID) { order.append(arrival.message.id.accountID) }
        for account in order {
            let mine = arrivals.filter { $0.message.id.accountID == account }
            let toTrash = Self.unique(mine.filter { $0.change == .trash }.map(\.message.id))
            var toArchive: [MessageID] = []
            var mutedDone: Set<ConversationID> = []
            for arrival in mine where arrival.change == .archive {
                if arrival.muted {
                    guard mutedDone.insert(arrival.message.conversationID).inserted else { continue }
                    toArchive += messagesLocked(in: arrival.message.conversationID).filter(\.isInInbox).map(\.id)
                } else {
                    toArchive.append(arrival.message.id)
                }
            }
            let skipped = Set(toTrash)
            toArchive = Self.unique(toArchive).filter { !skipped.contains($0) }
            if !toArchive.isEmpty {
                enqueueLocked(Operation(accountID: account, change: .archive, targets: toArchive, createdAt: now))
            }
            if !toTrash.isEmpty {
                enqueueLocked(Operation(accountID: account, change: .trash, targets: toTrash, createdAt: now.addingTimeInterval(0.001)))
            }
        }
    }

    private static func unique(_ ids: [MessageID]) -> [MessageID] {
        var seen: Set<MessageID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    public func deleteMessages(_ ids: [MessageID]) throws {
        lock.lock(); defer { lock.unlock() }
        deleteLocked(ids)
        notifyAll()
    }

    private func deleteLocked(_ ids: [MessageID]) {
        var touched: Set<ConversationID> = []
        for id in ids {
            if let message = messagesByID[id] { touched.insert(message.conversationID) }
            messagesByID[id] = nil
            bodies[id] = nil
            evicted.remove(id)
        }
        dropOrphanedMarksLocked()
        applySnoozeRulesLocked(touched: touched)
    }

    public func message(_ id: MessageID) throws -> MessageMetadata? {
        lock.lock(); defer { lock.unlock() }
        return messagesByID[id]
    }

    public func messages(in conversation: ConversationID) throws -> [MessageMetadata] {
        lock.lock(); defer { lock.unlock() }
        return messagesLocked(in: conversation)
    }

    private func messagesLocked(in conversation: ConversationID) -> [MessageMetadata] {
        messagesByID.values
            .filter { $0.conversationID == conversation }
            .sorted { ($0.date, $0.id.providerID) < ($1.date, $1.id.providerID) }
    }

    public func saveBody(_ body: StoredBody, for id: MessageID) throws {
        lock.lock(); defer { lock.unlock() }
        bodies[id] = Self.kept(body)
        evicted.remove(id)
        takeHeadersLocked(of: body, for: id)
        notifyAll()
    }

    @discardableResult
    public func saveBody(_ body: StoredBody, for id: MessageID, evictingIfReceivedBefore cutoff: Date) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        takeHeadersLocked(of: body, for: id)
        guard let message = messagesByID[id], evictableLocked(message, before: cutoff) else {
            bodies[id] = Self.kept(body)
            evicted.remove(id)
            notifyAll()
            return false
        }
        bodies[id] = Self.evictedForm(of: Self.kept(body))
        evicted.insert(id)
        notifyAll()
        return true
    }

    /// The headers a body fetch brought go on the message, as `MessageTable.saveBody` writes them.
    private func takeHeadersLocked(of body: StoredBody, for id: MessageID) {
        guard let list = body.body.listUnsubscribe, var message = messagesByID[id] else { return }
        message.listUnsubscribe = list
        message.listUnsubscribePost = body.body.listUnsubscribePost
        messagesByID[id] = message
    }

    /// What the bodies table keeps: the headers live on the message, so a body read back has none.
    private static func kept(_ body: StoredBody) -> StoredBody {
        var kept = body
        kept.body.listUnsubscribe = nil
        kept.body.listUnsubscribePost = nil
        return kept
    }

    public func body(for id: MessageID) throws -> StoredBody? {
        lock.lock(); defer { lock.unlock() }
        return evicted.contains(id) ? nil : bodies[id]
    }

    public func attachments(of id: MessageID) throws -> [AttachmentInfo]? {
        lock.lock(); defer { lock.unlock() }
        return bodies[id]?.body.attachments
    }

    @discardableResult
    public func evictBodies(from start: Date?, limit: Int,
                            rules: () -> (cutoff: Date, excluding: Set<MessageID>)?) throws -> (evicted: Int, next: Date?) {
        lock.lock(); defer { lock.unlock() }
        // One lock covers the look and the eviction, so the rules are asked once, as the SQLite store's write asks them.
        guard limit > 0, let rules = rules() else { return (0, nil) }
        let candidates = bodies.keys
            .compactMap { id -> MessageMetadata? in
                guard !evicted.contains(id), let message = messagesByID[id] else { return nil }
                if let start, message.date < start { return nil }
                return evictableLocked(message, before: rules.cutoff) ? message : nil
            }
            .sorted { ($0.date, $0.id.providerID) < ($1.date, $1.id.providerID) }
        var chosen: [MessageMetadata] = []
        var reached: Date?
        for message in candidates where chosen.count < limit {
            reached = message.date
            if !rules.excluding.contains(message.id) { chosen.append(message) }
        }
        for message in chosen {
            guard let body = bodies[message.id] else { continue }
            bodies[message.id] = Self.evictedForm(of: body)
            evicted.insert(message.id)
        }
        // Nothing an observation reads changed, as in the SQLite store, whose observations never read `bodies`.
        return (chosen.count, chosen.count < limit ? nil : reached)
    }

    /// `BodyEviction`'s rules: received before the cutoff, not a draft, no live operation targets it.
    private func evictableLocked(_ message: MessageMetadata, before cutoff: Date) -> Bool {
        message.date < cutoff && !message.roles.contains(.drafts) && liveOperationsLocked(on: message.id).isEmpty
    }

    /// What an eviction leaves: the plain text, attachment list and design facts, no source or rendered HTML.
    private static func evictedForm(of body: StoredBody) -> StoredBody {
        var body = body
        body.body.html = nil
        body.body.text = nil
        body.renderedHTML = ""
        body.invitation = nil
        return body
    }

    /// Whether the body is held in the evicted state, for tests.
    func isEvicted(_ id: MessageID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return evicted.contains(id)
    }

    public func messageIDsMissingBodies(accountID: AccountID, limit: Int) throws -> [MessageID] {
        lock.lock(); defer { lock.unlock() }
        return messagesByID.values
            .filter { $0.id.accountID == accountID && bodies[$0.id] == nil && !$0.roles.contains(.spam) }
            .sorted { lhs, rhs in
                if lhs.isInInbox != rhs.isInInbox { return lhs.isInInbox }
                return lhs.date > rhs.date
            }
            .prefix(limit)
            .map(\.id)
    }

    public func messageIDsMissingDesignFacts(accountID: AccountID, limit: Int) throws -> [MessageID] {
        lock.lock(); defer { lock.unlock() }
        return bodies
            .filter { $0.key.accountID == accountID && $0.value.typesetting == nil && !evicted.contains($0.key) }
            .map(\.key)
            .sorted { ($0.accountID.rawValue, $0.providerID) < ($1.accountID.rawValue, $1.providerID) }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func saveDesignFacts(_ facts: [MessageID: BodyDesignFacts]) throws {
        lock.lock(); defer { lock.unlock() }
        for (id, fact) in facts {
            guard var body = bodies[id] else { continue }
            body.typesetting = fact.typesetting
            body.declaresColors = fact.declaresColors
            body.coveredByNewYork = fact.coveredByNewYork
            bodies[id] = body
        }
    }

    // MARK: Backfill (the rules are written out on `BackfillMarks` and in docs/DATA-MODEL.md)

    public func backfillSkippableIDs(accountID: AccountID, providerIDs: [String], includeStored: Bool) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(providerIDs.filter {
            isBackfillSkippableLocked(MessageID(accountID: accountID, providerID: $0), includeStored: includeStored)
        })
    }

    public func storedRoles(accountID: AccountID, providerIDs: [String]) throws -> [String: Set<MailboxRole>] {
        lock.lock(); defer { lock.unlock() }
        var roles: [String: Set<MailboxRole>] = [:]
        for providerID in providerIDs {
            if let stored = messagesByID[MessageID(accountID: accountID, providerID: providerID)] { roles[providerID] = stored.roles }
        }
        return roles
    }

    private func isBackfillSkippableLocked(_ id: MessageID, includeStored: Bool) -> Bool {
        liveMarks[id] != nil || (includeStored && messagesByID[id] != nil)
    }

    @discardableResult
    public func writeBackfillMessages(_ messages: [MessageMetadata], refreshExisting: Bool) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let written = BackfillMarks.lastOccurrences(messages).filter {
            !isBackfillSkippableLocked($0.id, includeStored: !refreshExisting)
        }
        guard !written.isEmpty else { return 0 }
        upsertLocked(written, senderRules: false)
        notifyAll()
        return written.count
    }

    public func markLiveChanges(accountID: AccountID, upserted: [String], deleted: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        for providerID in upserted { liveMarks[MessageID(accountID: accountID, providerID: providerID)] = false }
        for providerID in deleted { liveMarks[MessageID(accountID: accountID, providerID: providerID)] = true }
    }

    public func markBackfillSeen(accountID: AccountID, providerIDs: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        for providerID in providerIDs { backfillSeen.insert(MessageID(accountID: accountID, providerID: providerID)) }
    }

    @discardableResult
    public func finishBackfill(accountID: AccountID, sweepUnseen: Bool) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var swept: [MessageID] = []
        if sweepUnseen {
            swept = messagesByID.keys.filter { id in
                id.accountID == accountID && !backfillSeen.contains(id) && liveMarks[id] == nil
                    && liveOperationsLocked(on: id).isEmpty
            }
            deleteLocked(swept)
        }
        clearBackfillMarksLocked(accountID)
        if !swept.isEmpty { notifyAll() }
        return swept.count
    }

    // MARK: Queued lookups

    @discardableResult
    public func queueLookups(accountID: AccountID, inFolders folderIDs: [String]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let folders = Set(folderIDs)
        var queued = 0
        for message in messagesByID.values where message.id.accountID == accountID {
            guard let folder = message.folderID, folders.contains(folder), lookupQueue[message.id] == nil else { continue }
            lookupQueue[message.id] = 0
            queued += 1
        }
        return queued
    }

    public func queuedLookups(accountID: AccountID, limit: Int) throws -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        let queued = lookupQueue.filter { $0.key.accountID == accountID }.sorted { $0.key.providerID < $1.key.providerID }
        return Dictionary(uniqueKeysWithValues: queued.prefix(max(0, limit)).map { ($0.key.providerID, $0.value) })
    }

    public func settleQueuedLookups(accountID: AccountID, settled: [String], retried: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        for providerID in settled { lookupQueue[MessageID(accountID: accountID, providerID: providerID)] = nil }
        for providerID in retried {
            let id = MessageID(accountID: accountID, providerID: providerID)
            if let tries = lookupQueue[id] { lookupQueue[id] = tries + 1 }
        }
    }

    private func clearBackfillMarksLocked(_ accountID: AccountID) {
        liveMarks = liveMarks.filter { $0.key.accountID != accountID }
        backfillSeen = backfillSeen.filter { $0.accountID != accountID }
    }

    // MARK: Conversations

    public func conversations(_ query: ConversationQuery) throws -> [ConversationSummary] {
        lock.lock(); defer { lock.unlock() }
        return conversationsLocked(query)
    }

    private func conversationsLocked(_ query: ConversationQuery) -> [ConversationSummary] {
        let isLater = query.view == .later
        var grouped: [ConversationID: [MessageMetadata]] = [:]
        for message in messagesByID.values {
            if let ids = query.accountIDs, !ids.contains(message.id.accountID) { continue }
            grouped[message.conversationID, default: []].append(message)
        }
        let terms = query.search?.terms ?? []
        // As the SQLite store: index terms with nothing indexable are left out, and some message of the conversation
        // must match every positive one and no negated one.
        let indexed = terms.filter { FullTextMatcher.query(for: $0) != nil }
        let positive = indexed.filter { !$0.negated }
        let negative = indexed.filter(\.negated)
        var result: [ConversationSummary] = []
        for (id, messages) in grouped {
            guard var summary = summarize(id: id, messages: messages) else { continue }
            guard matches(summary, view: query.view) else { continue }
            if let section = query.section, summary.inboxSection != section { continue }
            if query.unreadOnly, summary.unreadCount == 0 { continue }
            if let before = query.before, !isLater, Self.sortDate(of: summary, for: query) >= before { continue }
            guard terms.allSatisfy({ matches(summary, operator: $0, open: query.openConversationID) }) else { continue }
            if isLater { summary.snoozedUntil = snoozeRows[id]?.dueAt }
            // What a search of the server found stands in for the index terms, as in the SQLite store's hits.
            if !indexed.isEmpty, !query.serverMatches.contains(id) {
                let columns = messages.map { FullTextMatcher.Columns(message: $0, body: bodies[$0.id]?.plainText) }
                let found = columns.contains { message in
                    positive.allSatisfy { FullTextMatcher.matches($0, in: message) }
                        && !negative.contains { FullTextMatcher.matches($0, in: message) }
                }
                guard found else { continue }
            }
            result.append(summary)
        }
        if isLater {
            // Soonest first, as the SQLite store orders `snoozes.due_at`.
            result.sort { lhs, rhs in
                let left = (MailStoreCodec.milliseconds(lhs.snoozedUntil ?? .distantFuture), lhs.id.accountID.rawValue, lhs.id.providerID)
                let right = (MailStoreCodec.milliseconds(rhs.snoozedUntil ?? .distantFuture), rhs.id.accountID.rawValue, rhs.id.providerID)
                return left < right
            }
        } else {
            result.sort { (Self.sortDate(of: $0, for: query), $0.id.providerID) > (Self.sortDate(of: $1, for: query), $1.id.providerID) }
        }
        return Array(result.prefix(query.limit))
    }

    /// The date a query sorts and pages by: the Inbox's own (`inboxDate`), every other view's and every search's (an
    /// `in:inbox` one too) the latest message's, as the SQLite store's `ConversationTable.sortKey`.
    private static func sortDate(of summary: ConversationSummary, for query: ConversationQuery) -> Date {
        query.view == .inbox && query.search == nil ? summary.inboxDate : summary.latestDate
    }

    private func matches(_ summary: ConversationSummary, view: MailboxView) -> Bool {
        switch view {
        case .inbox: return summary.inInbox
        case .starred: return summary.isStarred && !summaryIsTrash(summary)
        case .sent: return summaryFlags[summary.id]?.inSent == true && !summaryIsTrash(summary)
        case .drafts: return summaryFlags[summary.id]?.inDrafts == true && !summaryIsTrash(summary)
        case .trash: return summaryIsTrash(summary)
        case .all: return summary.messageCount > 0 && !summaryIsTrash(summary)
        case .later: return snoozeRows[summary.id] != nil
        }
    }

    /// The SQLite store's operator predicates (`ConversationTable.predicate(for:)`) on the summary; true for index terms.
    private func matches(_ summary: ConversationSummary, operator term: SearchTerm, open: ConversationID?) -> Bool {
        let holds: Bool
        switch term.kind {
        case .text, .phrase, .from, .to, .subject:
            return true
        case .unread, .read:
            if summary.id == open { return true }
            holds = (summary.unreadCount > 0) == (term.kind == .unread)
        case .starred:
            holds = summary.isStarred
        case .attachment:
            holds = summary.hasAttachments
        case .before(let day):
            holds = MailStoreCodec.milliseconds(summary.latestDate) < MailStoreCodec.milliseconds(day)
        case .after(let day):
            holds = MailStoreCodec.milliseconds(summary.latestDate) >= MailStoreCodec.milliseconds(day)
        case .mailbox(let view):
            holds = matches(summary, view: view)
        }
        return holds != term.negated
    }

    private struct Flags { var inSent: Bool; var inDrafts: Bool; var inTrash: Bool }
    private var summaryFlags: [ConversationID: Flags] = [:]
    private func summaryIsTrash(_ summary: ConversationSummary) -> Bool { summaryFlags[summary.id]?.inTrash == true }

    /// The summary rules the SQLite store must reproduce. Returns nil for conversations with no messages.
    private func summarize(id: ConversationID, messages: [MessageMetadata]) -> ConversationSummary? {
        let nonSpam = messages.filter { !$0.roles.contains(.spam) }
        guard !nonSpam.isEmpty else { return nil }
        let sorted = nonSpam.sorted { ($0.date, $0.id.providerID) < ($1.date, $1.id.providerID) }
        let visible = sorted.filter { !$0.roles.contains(.trash) }
        let inTrash = visible.isEmpty
        let basis = visible.isEmpty ? sorted : visible
        let latest = basis.last!
        var participants: [EmailAddress] = []
        var seen: Set<String> = []
        for message in sorted {
            guard let from = message.from else { continue }
            let key = from.address.lowercased()
            if seen.insert(key).inserted { participants.append(from) }
        }
        let subject = sorted.first { !$0.subject.trimmingCharacters(in: .whitespaces).isEmpty }?.subject ?? ""
        let inboxMessages = basis.filter(\.isInInbox)
        let section: InboxSection = inboxMessages.contains { $0.inboxSection == .focused } ? .focused
            : inboxMessages.contains { $0.inboxSection == .other } ? .other : .unknown
        let pending = operations.values.contains { op in
            op.status.isLive && op.targets.contains { messagesByID[$0]?.conversationID == id }
        }
        summaryFlags[id] = Flags(
            inSent: basis.contains { $0.roles.contains(.sent) },
            inDrafts: basis.contains { $0.roles.contains(.drafts) },
            inTrash: inTrash
        )
        return ConversationSummary(
            id: id,
            subject: subject,
            snippet: latest.snippet,
            participants: participants,
            latestDate: latest.date,
            messageCount: visible.count,
            unreadCount: visible.filter { !$0.isRead }.count,
            isStarred: basis.contains(where: \.isStarred),
            hasAttachments: basis.contains(where: \.hasAttachments),
            inInbox: !inboxMessages.isEmpty,
            inboxSection: section,
            latestMessageID: latest.id,
            hasPendingOperations: pending,
            failedOperation: failedMarks[id],
            returnedAt: returnedMarks[id],
            isMuted: mutedConversations.contains(id)
        )
    }

    /// The conversation's summary as a refresh would leave it, or nil when it has none (no message outside Spam).
    private func summaryLocked(_ id: ConversationID) -> ConversationSummary? {
        summarize(id: id, messages: messagesLocked(in: id))
    }

    public func observeConversations(_ query: ConversationQuery, onChange: @escaping @Sendable ([ConversationSummary]) -> Void) -> StoreObservation {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        conversationObservers[token] = (query, onChange)
        let current = conversationsLocked(query)
        deliver { onChange(current) }
        return StoreObservation { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.conversationObservers[token] = nil
        }
    }

    public func observeConversation(_ id: ConversationID, onChange: @escaping @Sendable ([MessageMetadata]) -> Void) -> StoreObservation {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        messageObservers[token] = (id, onChange)
        let current = messagesLocked(in: id)
        deliver { onChange(current) }
        return StoreObservation { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.messageObservers[token] = nil
        }
    }

    public func unreadInboxCount(accountIDs: [AccountID]?) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return conversationsLocked(ConversationQuery(accountIDs: accountIDs, view: .inbox, limit: .max))
            .reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: Snoozes (the rules are written out on `SnoozeTable`)

    private struct SnoozeObserver {
        var last: [Snooze]?
        var callback: ([Snooze]) -> Void
    }

    public func snoozes() throws -> [Snooze] {
        lock.lock(); defer { lock.unlock() }
        return snoozesLocked()
    }

    /// Only those whose conversation has a summary, soonest first, as the SQLite store joins and orders them.
    private func snoozesLocked() -> [Snooze] {
        snoozeRows.values
            .filter { summaryLocked($0.conversationID) != nil }
            .sorted { lhs, rhs in
                (MailStoreCodec.milliseconds(lhs.dueAt), lhs.conversationID.accountID.rawValue, lhs.conversationID.providerID)
                    < (MailStoreCodec.milliseconds(rhs.dueAt), rhs.conversationID.accountID.rawValue, rhs.conversationID.providerID)
            }
    }

    public func setSnoozes(_ changes: [Snooze.Change], enqueueing operations: [Operation], at now: Date) throws {
        lock.lock(); defer { lock.unlock() }
        guard !changes.isEmpty || !operations.isEmpty else { return }
        for operation in operations { enqueueLocked(operation) }
        let created = Self.storedDate(now)
        for change in changes {
            let id = change.conversationID
            if let returnedAt = change.returnedAt { markReturnedLocked(id, at: returnedAt) }
            guard let until = change.until else {
                snoozeRows[id] = nil
                continue
            }
            guard holdsSnoozeLocked(id) else { continue }
            snoozeRows[id] = Snooze(conversationID: id, dueAt: Self.storedDate(until), createdAt: created)
        }
        notifyAll()
    }

    /// `SnoozeTable.markReturned`: only a conversation in the Inbox whose newest mail is older takes the mark.
    private func markReturnedLocked(_ id: ConversationID, at date: Date) {
        guard let summary = summaryLocked(id), summary.inInbox,
              MailStoreCodec.milliseconds(summary.latestDate) < MailStoreCodec.milliseconds(date) else { return }
        returnedMarks[id] = Self.storedDate(date)
    }

    @discardableResult
    public func returnDueSnoozes(at now: Date, dueBy: [AccountID: Date], limit: Int,
                                 operations: (ConversationID, [MessageMetadata]) -> [Operation]) throws -> [ConversationID] {
        lock.lock(); defer { lock.unlock() }
        let nowMS = MailStoreCodec.milliseconds(now)
        let due = snoozeRows.values
            .filter { snooze in
                let dueMS = MailStoreCodec.milliseconds(snooze.dueAt)
                return dueMS <= nowMS && dueBy[snooze.conversationID.accountID].map { dueMS <= MailStoreCodec.milliseconds($0) } ?? true
            }
            .sorted { lhs, rhs in
                (MailStoreCodec.milliseconds(lhs.dueAt), lhs.conversationID.accountID.rawValue, lhs.conversationID.providerID)
                    < (MailStoreCodec.milliseconds(rhs.dueAt), rhs.conversationID.accountID.rawValue, rhs.conversationID.providerID)
            }
            .prefix(max(0, limit))
        guard !due.isEmpty else { return [] }
        var returned: [ConversationID] = []
        for snooze in due {
            let id = snooze.conversationID
            snoozeRows[id] = nil
            let messages = messagesLocked(in: id)
            guard !messages.isEmpty else { continue }
            for operation in operations(id, messages) where !operation.targets.isEmpty { enqueueLocked(operation) }
            returned.append(id)
        }
        for id in returned { markReturnedLocked(id, at: now) }
        notifyAll()
        return returned
    }

    public func observeSnoozes(onChange: @escaping @Sendable ([Snooze]) -> Void) -> StoreObservation {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        let current = snoozesLocked()
        snoozeObservers[token] = SnoozeObserver(last: current, callback: onChange)
        deliver { onChange(current) }
        return StoreObservation { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.snoozeObservers[token] = nil
        }
    }

    // MARK: Mute and sender rules (the rules are written out on `ArrivalRules`)

    private struct SenderRuleObserver {
        var last: [SenderRule]?
        var callback: ([SenderRule]) -> Void
    }

    public func setMuted(_ muted: Bool, conversations: [ConversationID], enqueueing operations: [Operation],
                         returnMarks: [ConversationID: Date]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !conversations.isEmpty || !operations.isEmpty || !returnMarks.isEmpty else { return }
        for operation in operations { enqueueLocked(operation) }
        for id in conversations where summaryLocked(id) != nil {
            if muted { mutedConversations.insert(id) } else { mutedConversations.remove(id) }
        }
        for (id, date) in returnMarks { markReturnedLocked(id, at: date) }
        notifyAll()
    }

    public func senderRules() throws -> [SenderRule] {
        lock.lock(); defer { lock.unlock() }
        return senderRulesLocked()
    }

    private func senderRulesLocked() -> [SenderRule] {
        senderRuleRows.values.flatMap(\.values).sorted { ($0.accountID.rawValue, $0.address) < ($1.accountID.rawValue, $1.address) }
    }

    private func senderRuleLocked(_ accountID: AccountID, _ address: String) -> SenderRule? {
        senderRuleRows[accountID]?[SenderRule.normalizedAddress(address)]
    }

    public func setSenderRule(_ action: SenderRule.Action?, for address: String, accountID: AccountID,
                              enqueueing operations: [Operation], at now: Date) throws {
        lock.lock(); defer { lock.unlock() }
        for operation in operations { enqueueLocked(operation) }
        let key = SenderRule.normalizedAddress(address)
        if !key.isEmpty {
            if let action {
                senderRuleRows[accountID, default: [:]][key] = SenderRule(accountID: accountID, address: key, action: action,
                                                                          createdAt: Self.storedDate(now))
            } else {
                senderRuleRows[accountID]?[key] = nil
            }
        }
        notifyAll()
    }

    public func observeSenderRules(onChange: @escaping @Sendable ([SenderRule]) -> Void) -> StoreObservation {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        let current = senderRulesLocked()
        senderRuleObservers[token] = SenderRuleObserver(last: current, callback: onChange)
        deliver { onChange(current) }
        return StoreObservation { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.senderRuleObservers[token] = nil
        }
    }

    /// Mail new to the store arrived: a snooze set before it was received ends, unless it is the user's own or spam.
    private func endSnoozeForArrivalLocked(of message: MessageMetadata) {
        guard message.roles.isDisjoint(with: [.sent, .drafts, .spam]), let snooze = snoozeRows[message.conversationID],
              MailStoreCodec.milliseconds(snooze.createdAt) < MailStoreCodec.milliseconds(message.date) else { return }
        snoozeRows[message.conversationID] = nil
    }

    /// What the SQLite store's summary refresh does for the conversations a write touched: a snooze ends once its
    /// conversation no longer holds mail put away (in the Inbox, in the Trash or gone), and the return mark stays only
    /// while the conversation is in the Inbox and its newest mail is older.
    private func applySnoozeRulesLocked(touched: Set<ConversationID>) {
        guard !snoozeRows.isEmpty || !returnedMarks.isEmpty else { return }
        for id in touched where snoozeRows[id] != nil || returnedMarks[id] != nil {
            let summary = summaryLocked(id)
            if let returned = returnedMarks[id],
               !(summary.map { $0.inInbox && MailStoreCodec.milliseconds(returned) > MailStoreCodec.milliseconds($0.latestDate) } ?? false) {
                returnedMarks[id] = nil
            }
            if let snooze = snoozeRows[id], !holdsSnoozeLocked(id, snoozedAt: snooze.createdAt) {
                snoozeRows[id] = nil
            }
        }
    }

    /// `SnoozeTable.holdsSnooze`, in the words of `Snooze.canHold`: the conversation is stored, out of the Inbox and out
    /// of the Trash, and its mail other than the user's own copies is not all in the Trash or Spam (spam received after
    /// `snoozedAt` counting for nothing).
    private func holdsSnoozeLocked(_ id: ConversationID, snoozedAt: Date? = nil) -> Bool {
        Snooze.canHold(messagesLocked(in: id), snoozedAt: snoozedAt)
    }

    /// A date as the SQLite store reads it back: to the millisecond.
    private static func storedDate(_ date: Date) -> Date {
        MailStoreCodec.date(MailStoreCodec.milliseconds(date))
    }

    // MARK: Operations

    public func enqueue(_ operation: Operation) throws {
        try enqueue([operation])
    }

    public func enqueue(_ operations: [Operation]) throws {
        lock.lock(); defer { lock.unlock() }
        for operation in operations { enqueueLocked(operation) }
        notifyAll()
    }

    /// The order rows were first written in, as SQLite's `rowid` keeps it: what breaks a tie in creation time.
    private func noteQueuedLocked(_ operation: Operation) {
        guard queueOrder[operation.id] == nil else { return }
        queued += 1
        queueOrder[operation.id] = queued
    }

    private func enqueueLocked(_ operation: Operation) {
        noteQueuedLocked(operation)
        for target in operation.targets {
            if let current = messagesByID[target] {
                priors[operation.id, default: [:]][target] = Prior(current)
                messagesByID[target] = applying(operation.change, to: current)
            }
        }
        let previous = operations[operation.id]?.status
        operations[operation.id] = operation
        operationWrittenLocked(operation, previousStatus: previous)
        applySnoozeRulesLocked(touched: conversationsLocked(targetedBy: operation))
    }

    public func pendingOperations(accountID: AccountID, limit: Int) throws -> [Operation] {
        lock.lock(); defer { lock.unlock() }
        return operations.values
            .filter { $0.accountID == accountID && ($0.status == .pending || $0.status == .uncertain) }
            .sorted { isOlderLocked($0, than: $1) }
            .prefix(limit)
            .map { $0 }
    }

    public func updateOperation(_ operation: Operation) throws {
        lock.lock(); defer { lock.unlock() }
        let previous = operations[operation.id]?.status
        let targetsBefore = Set(operations[operation.id]?.targets ?? [])
        noteQueuedLocked(operation)
        operations[operation.id] = operation
        // A target dropped from the operation (the provider took it) loses its prior with its row, as in SQLite: a
        // give-up never puts back what the provider has.
        if !targetsBefore.subtracting(operation.targets).isEmpty {
            priors[operation.id] = priors[operation.id]?.filter { operation.targets.contains($0.key) }
        }
        if operation.status == .failed, let previous, previous.isLive { giveBackLocked(operation) }
        operationWrittenLocked(operation, previousStatus: previous)
        applySnoozeRulesLocked(touched: conversationsLocked(targetedBy: operation))
        notifyAll()
    }

    public func confirmOperation(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let confirmed = removeOperationLocked(id: id) else { return }
        settleLocked(confirmed, .confirmed)
        notifyAll()
    }

    public func deleteOperation(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        deleteOperationLocked(id: id)
        notifyAll()
    }

    public func acknowledgeFailedOperation(conversationID: ConversationID) throws {
        lock.lock(); defer { lock.unlock() }
        guard failedMarks.removeValue(forKey: conversationID) != nil else { return }
        notifyAll()
    }

    @discardableResult
    public func pruneFailedOperations(accountID: AccountID, now: Date) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let cutoff = MailStoreCodec.milliseconds(now)
        let due = operations.values
            .filter { op in
                op.accountID == accountID && op.status == .failed
                    && (op.nextAttemptAt.map { MailStoreCodec.milliseconds($0) <= cutoff } ?? true)
            }
            .sorted { Self.isOlder($0, than: $1) }
        for operation in due { deleteOperationLocked(id: operation.id) }
        if !due.isEmpty { notifyAll() }
        return due.count
    }

    private func deleteOperationLocked(id: String) {
        guard let deleted = removeOperationLocked(id: id), deleted.status == .failed else { return }
        settleLocked(deleted, .failureEnded)
    }

    private func removeOperationLocked(id: String) -> Operation? {
        priors[id] = nil
        let removed = operations.removeValue(forKey: id)
        // The SQLite store refreshes the conversations of a removed operation's targets, which runs the snooze rules.
        if let removed { applySnoozeRulesLocked(touched: conversationsLocked(targetedBy: removed)) }
        return removed
    }

    // MARK: Giving up (the rules are written out on `OperationTable.giveBack`)

    /// Live operations targeting the message, oldest first as the SQLite store orders them.
    private func liveOperationsLocked(on id: MessageID) -> [Operation] {
        operations.values
            .filter { $0.status.isLive && $0.targets.contains(id) }
            .sorted { isOlderLocked($0, than: $1) }
    }

    /// Queue order as the SQLite store reads it: epoch milliseconds, then the order the rows were first written in.
    private func isOlderLocked(_ lhs: Operation, than rhs: Operation) -> Bool {
        let left = MailStoreCodec.milliseconds(lhs.createdAt)
        let right = MailStoreCodec.milliseconds(rhs.createdAt)
        guard left == right else { return left < right }
        return (queueOrder[lhs.id] ?? 0) < (queueOrder[rhs.id] ?? 0)
    }

    private func giveBackLocked(_ operation: Operation) {
        guard let recorded = priors[operation.id] else { return }
        for (target, prior) in recorded {
            guard let current = messagesByID[target] else { continue }
            var state = current
            prior.apply(to: &state)
            let isAnswer = operation.change.kind == .answerInvitation
            if case .answerInvitation(let answer) = operation.change { state.invitationReply = answer.previous }
            for newer in liveOperationsLocked(on: target) where isOlderLocked(operation, than: newer) {
                priors[newer.id, default: [:]][target] = Prior(state)
                if isAnswer, case .answerInvitation(var answer) = newer.change, answer.previous != state.invitationReply {
                    answer.previous = state.invitationReply
                    operations[newer.id]?.change = .answerInvitation(answer)
                }
                state = applying(newer.change, to: state)
            }
            messagesByID[target] = state
        }
    }

    /// The fields `applying(_:to:)` can change, as they were before an operation changed them.
    private struct Prior {
        var roles: Set<MailboxRole>
        var isRead: Bool
        var isStarred: Bool

        init(_ metadata: MessageMetadata) {
            roles = metadata.roles
            isRead = metadata.isRead
            isStarred = metadata.isStarred
        }

        func apply(to metadata: inout MessageMetadata) {
            metadata.roles = roles
            metadata.isRead = isRead
            metadata.isStarred = isStarred
        }
    }

    // MARK: Failed-operation marks (the rules are written out on `FailedOperationMarks`)

    private enum Settlement { case confirmed, failureEnded }

    private func operationWrittenLocked(_ operation: Operation, previousStatus: OperationStatus?) {
        if operation.status == .failed {
            guard previousStatus != .failed else { return }
            for conversation in conversationsLocked(targetedBy: operation) where hasSummaryLocked(conversation) {
                if failedMarks[conversation] != nil, newerFailureExistsLocked(in: conversation, than: operation) { continue }
                failedMarks[conversation] = operation.change.kind
            }
        } else if operation.status == .confirmed, previousStatus != .confirmed {
            settleLocked(operation, .confirmed)
        } else if previousStatus == .failed {
            settleLocked(operation, .failureEnded)
        }
    }

    private func settleLocked(_ operation: Operation, _ settlement: Settlement) {
        for conversation in conversationsLocked(targetedBy: operation) where failedMarks[conversation] != nil {
            let standing = switch settlement {
            case .confirmed: newerFailureExistsLocked(in: conversation, than: operation)
            case .failureEnded: otherFailureExistsLocked(in: conversation, than: operation)
            }
            guard !standing else { continue }
            failedMarks[conversation] = nil
        }
    }

    private func otherFailureExistsLocked(in conversation: ConversationID, than operation: Operation) -> Bool {
        operations.values.contains { other in
            other.status == .failed && other.id != operation.id
                && other.targets.contains { messagesByID[$0]?.conversationID == conversation }
        }
    }

    private func conversationsLocked(targetedBy operation: Operation) -> Set<ConversationID> {
        Set(operation.targets.compactMap { messagesByID[$0]?.conversationID })
    }

    private func hasSummaryLocked(_ conversation: ConversationID) -> Bool {
        messagesByID.values.contains { $0.conversationID == conversation && !$0.roles.contains(.spam) }
    }

    private func newerFailureExistsLocked(in conversation: ConversationID, than operation: Operation) -> Bool {
        operations.values.contains { other in
            other.status == .failed && other.id != operation.id && Self.isOlder(operation, than: other)
                && other.targets.contains { messagesByID[$0]?.conversationID == conversation }
        }
    }

    /// Creation order as the SQLite store sees it: epoch milliseconds, then id.
    private static func isOlder(_ lhs: Operation, than rhs: Operation) -> Bool {
        let left = MailStoreCodec.milliseconds(lhs.createdAt)
        let right = MailStoreCodec.milliseconds(rhs.createdAt)
        return left != right ? left < right : lhs.id < rhs.id
    }

    public func enqueueSend(_ send: PendingSend) throws {
        lock.lock(); defer { lock.unlock() }
        sends[send.id] = send
        notifySends()
    }

    public func pendingSends() throws -> [PendingSend] {
        lock.lock(); defer { lock.unlock() }
        return pendingSendsLocked()
    }

    public func updateSend(_ send: PendingSend) throws {
        lock.lock(); defer { lock.unlock() }
        sends[send.id] = send
        notifySends()
    }

    public func deleteSend(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        sends[id] = nil
        notifySends()
    }

    public func observePendingSends(onChange: @escaping @Sendable ([PendingSend]) -> Void) -> StoreObservation {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        sendObservers[token] = onChange
        let current = pendingSendsLocked()
        deliver { onChange(current) }
        return StoreObservation { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.sendObservers[token] = nil
        }
    }

    private func pendingSendsLocked() -> [PendingSend] {
        sends.values.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Contacts

    public func suggestAddresses(prefix: String, limit: Int) throws -> [EmailAddress] {
        lock.lock(); defer { lock.unlock() }
        let needle = prefix.lowercased()
        var merged: [String: (name: String?, score: Double)] = [:]
        for (_, table) in contactCounts {
            for (address, entry) in table {
                let name = entry.name ?? ""
                guard needle.isEmpty || address.hasPrefix(needle) || name.lowercased().hasPrefix(needle)
                    || name.lowercased().split(separator: " ").contains(where: { $0.hasPrefix(needle) }) else { continue }
                let ageDays = max(0, Date().timeIntervalSince(entry.lastSeen) / 86_400)
                let score = Double(entry.count) / (1 + ageDays / 30)
                if let existing = merged[address], existing.score >= score { continue }
                merged[address] = (entry.name, score)
            }
        }
        return merged.sorted { $0.value.score > $1.value.score }
            .prefix(limit)
            .map { EmailAddress(name: $0.value.name, address: $0.key) }
    }

    private func recordContacts(of message: MessageMetadata) {
        var table = contactCounts[message.id.accountID] ?? [:]
        for address in [message.from].compactMap({ $0 }) + message.to + message.cc {
            let key = address.address.lowercased()
            let current = table[key]
            table[key] = (
                name: address.name ?? current?.name,
                count: (current?.count ?? 0) + 1,
                lastSeen: max(current?.lastSeen ?? .distantPast, message.date)
            )
        }
        contactCounts[message.id.accountID] = table
    }

    // MARK: Observation delivery

    private func notifyAll() {
        let conversationSnapshot = conversationObservers.values.map { (query, callback) in
            (callback, conversationsLocked(query))
        }
        let messageSnapshot = messageObservers.values.map { (id, callback) in
            (callback, messagesLocked(in: id))
        }
        // Only a changed list, as the SQLite store's observation removes duplicates.
        var snoozeSnapshot: [(([Snooze]) -> Void, [Snooze])] = []
        if !snoozeObservers.isEmpty {
            let current = snoozesLocked()
            for (token, observer) in snoozeObservers where observer.last != current {
                snoozeObservers[token]?.last = current
                snoozeSnapshot.append((observer.callback, current))
            }
        }
        var ruleSnapshot: [(([SenderRule]) -> Void, [SenderRule])] = []
        if !senderRuleObservers.isEmpty {
            let current = senderRulesLocked()
            for (token, observer) in senderRuleObservers where observer.last != current {
                senderRuleObservers[token]?.last = current
                ruleSnapshot.append((observer.callback, current))
            }
        }
        deliver {
            for (callback, value) in conversationSnapshot { callback(value) }
            for (callback, value) in messageSnapshot { callback(value) }
            for (callback, value) in snoozeSnapshot { callback(value) }
            for (callback, value) in ruleSnapshot { callback(value) }
        }
    }

    /// Apart from `notifyAll`, as the SQLite store's observations track tables: an outbox write wakes no list.
    private func notifySends() {
        guard !sendObservers.isEmpty else { return }
        let callbacks = Array(sendObservers.values)
        let current = pendingSendsLocked()
        deliver {
            for callback in callbacks { callback(current) }
        }
    }

    private func deliver(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
