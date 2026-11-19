import Foundation
@testable import SSCore

/// An in-memory store that can fail chosen writes, for the engine's paths that must survive a write failing (or
/// the process dying) half-way. Every call goes to the wrapped store unless a fault armed with `fail` takes it.
final class FaultyStore: MailStoring, @unchecked Sendable {
    struct Fault: Error {}

    /// The writes a test can make fail.
    enum Call: Hashable, Sendable {
        case setBootstrapState
        case setSyncCursor
        case upsertMessages
        case markBackfillSeen
        case finishBackfill
        /// Either form of `enqueue`: one call, whether it carries one operation or several.
        case enqueue
        /// A calendar read's write.
        case replaceCalendarEvents
        case settleCalendarEvent
    }

    let base: InMemoryMailStore
    private let lock = NSLock()
    private var faults: [Call: (skip: Int, times: Int)] = [:]
    private var stateFault: (matches: @Sendable (BootstrapState?) -> Bool, times: Int)?
    private var failures: [Call] = []

    init(base: InMemoryMailStore) {
        self.base = base
    }

    /// Lets `skip` calls of `call` through, then fails the next `times`.
    func fail(_ call: Call, after skip: Int = 0, times: Int = 1) {
        lock.withLock { faults[call] = (skip, times) }
    }

    /// Fails the next `times` writes of a bootstrap state that `matches`, whatever comes before them.
    func failBootstrapState(times: Int = 1, where matches: @escaping @Sendable (BootstrapState?) -> Bool) {
        lock.withLock { stateFault = (matches, times) }
    }

    /// The faults that fired, in order.
    var fired: [Call] {
        lock.withLock { failures }
    }

    private func check(_ call: Call) throws {
        let fails: Bool = lock.withLock {
            guard var fault = faults[call], fault.times > 0 else { return false }
            if fault.skip > 0 {
                fault.skip -= 1
                faults[call] = fault
                return false
            }
            fault.times -= 1
            faults[call] = fault
            failures.append(call)
            return true
        }
        if fails { throw Fault() }
    }

    // MARK: Faultable writes

    func setSyncCursor(_ cursor: String?, for accountID: AccountID) throws {
        try check(.setSyncCursor)
        try base.setSyncCursor(cursor, for: accountID)
    }
    func setBootstrapState(_ state: BootstrapState?, for accountID: AccountID) throws {
        try check(.setBootstrapState)
        let fails: Bool = lock.withLock {
            guard let fault = stateFault, fault.times > 0, fault.matches(state) else { return false }
            stateFault?.times -= 1
            failures.append(.setBootstrapState)
            return true
        }
        if fails { throw Fault() }
        try base.setBootstrapState(state, for: accountID)
    }
    func upsertMessages(_ messages: [MessageMetadata]) throws {
        try check(.upsertMessages)
        try base.upsertMessages(messages)
    }
    func markBackfillSeen(accountID: AccountID, providerIDs: [String]) throws {
        try check(.markBackfillSeen)
        try base.markBackfillSeen(accountID: accountID, providerIDs: providerIDs)
    }
    func finishBackfill(accountID: AccountID, sweepUnseen: Bool) throws -> Int {
        try check(.finishBackfill)
        return try base.finishBackfill(accountID: accountID, sweepUnseen: sweepUnseen)
    }

    // MARK: Forwarded

    func accounts() throws -> [Account] { try base.accounts() }
    func upsertAccount(_ account: Account) throws { try base.upsertAccount(account) }
    func deleteAccount(_ id: AccountID) throws { try base.deleteAccount(id) }
    func setInkSlot(_ slot: Int, for accountID: AccountID) throws { try base.setInkSlot(slot, for: accountID) }
    func setMonogram(_ monogram: String?, for accountID: AccountID) throws { try base.setMonogram(monogram, for: accountID) }
    func setSignature(_ signature: String?, for accountID: AccountID) throws { try base.setSignature(signature, for: accountID) }
    func syncCursor(for accountID: AccountID) throws -> String? { try base.syncCursor(for: accountID) }
    func bootstrapState(for accountID: AccountID) throws -> BootstrapState? { try base.bootstrapState(for: accountID) }
    func wipeMailData(for accountID: AccountID) throws { try base.wipeMailData(for: accountID) }
    func deleteMessages(_ ids: [MessageID]) throws { try base.deleteMessages(ids) }
    func message(_ id: MessageID) throws -> MessageMetadata? { try base.message(id) }
    func messages(in conversation: ConversationID) throws -> [MessageMetadata] { try base.messages(in: conversation) }
    func saveBody(_ body: StoredBody, for id: MessageID) throws { try base.saveBody(body, for: id) }
    func saveBody(_ body: StoredBody, for id: MessageID, evictingIfReceivedBefore cutoff: Date) throws -> Bool {
        let hook = lock.withLock { evictingSaveHook }
        hook?(false)
        let evicted = try base.saveBody(body, for: id, evictingIfReceivedBefore: cutoff)
        hook?(true)
        return evicted
    }
    func body(for id: MessageID) throws -> StoredBody? {
        lock.withLock { bodyReadCount += 1 }
        return try base.body(for: id)
    }
    func attachments(of id: MessageID) throws -> [AttachmentInfo]? { try base.attachments(of: id) }
    func evictBodies(from start: Date?, limit: Int,
                     rules: () -> (cutoff: Date, excluding: Set<MessageID>)?) throws -> (evicted: Int, next: Date?) {
        let (call, during) = lock.withLock {
            evictionCallCount += 1
            evictionStarts.append(start)
            return (evictionCallCount, duringEvictionHook)
        }
        during?(call)
        let batch = try base.evictBodies(from: start, limit: limit, rules: rules)
        let hook = lock.withLock {
            evictedBySweeps += batch.evicted
            return afterEvictionHook
        }
        hook?(call)
        return batch
    }

    /// Runs after each eviction batch with its number, counting from 1, before the batch returns: a test acting there
    /// acts between two batches of a sweep.
    func afterEviction(_ hook: @escaping @Sendable (Int) -> Void) {
        lock.withLock { afterEvictionHook = hook }
    }
    /// Runs as each eviction batch begins, with its number, after the caller handed over its rules and before the store
    /// reads them: a test acting there acts while the batch is under way.
    func duringEviction(_ hook: @escaping @Sendable (Int) -> Void) {
        lock.withLock { duringEvictionHook = hook }
    }
    /// Where each eviction batch started (`evictBodies(from:)`), in order.
    var evictionBatchStarts: [Date?] {
        lock.withLock { evictionStarts }
    }
    private var duringEvictionHook: (@Sendable (Int) -> Void)?
    private var evictionStarts: [Date?] = []
    /// Runs on the saving thread just before (false) and just after (true) each evicting body save, so a test can hold
    /// the backfill's save at either moment.
    func aroundEvictingSaves(_ hook: @escaping @Sendable (_ saved: Bool) -> Void) {
        lock.withLock { evictingSaveHook = hook }
    }
    /// How many times a body was read.
    var bodyReads: Int {
        lock.withLock { bodyReadCount }
    }
    private var afterEvictionHook: (@Sendable (Int) -> Void)?
    private var evictingSaveHook: (@Sendable (Bool) -> Void)?
    private var bodyReadCount = 0

    /// How many times the engine asked for an eviction batch.
    var evictionCalls: Int {
        lock.withLock { evictionCallCount }
    }
    /// How many bodies those batches evicted.
    var sweptBodies: Int {
        lock.withLock { evictedBySweeps }
    }
    private var evictionCallCount = 0
    private var evictedBySweeps = 0
    func messageIDsMissingBodies(accountID: AccountID, limit: Int) throws -> [MessageID] {
        try base.messageIDsMissingBodies(accountID: accountID, limit: limit)
    }
    func messageIDsMissingDesignFacts(accountID: AccountID, limit: Int) throws -> [MessageID] {
        try base.messageIDsMissingDesignFacts(accountID: accountID, limit: limit)
    }
    func saveDesignFacts(_ facts: [MessageID: BodyDesignFacts]) throws { try base.saveDesignFacts(facts) }
    func backfillSkippableIDs(accountID: AccountID, providerIDs: [String], includeStored: Bool) throws -> Set<String> {
        try base.backfillSkippableIDs(accountID: accountID, providerIDs: providerIDs, includeStored: includeStored)
    }

    func storedRoles(accountID: AccountID, providerIDs: [String]) throws -> [String: Set<MailboxRole>] {
        try base.storedRoles(accountID: accountID, providerIDs: providerIDs)
    }
    func queueLookups(accountID: AccountID, inFolders folderIDs: [String]) throws -> Int {
        try base.queueLookups(accountID: accountID, inFolders: folderIDs)
    }
    func queuedLookups(accountID: AccountID, limit: Int) throws -> [String: Int] {
        try base.queuedLookups(accountID: accountID, limit: limit)
    }
    func settleQueuedLookups(accountID: AccountID, settled: [String], retried: [String]) throws {
        try base.settleQueuedLookups(accountID: accountID, settled: settled, retried: retried)
    }
    func writeBackfillMessages(_ messages: [MessageMetadata], refreshExisting: Bool) throws -> Int {
        try base.writeBackfillMessages(messages, refreshExisting: refreshExisting)
    }
    func markLiveChanges(accountID: AccountID, upserted: [String], deleted: [String]) throws {
        try base.markLiveChanges(accountID: accountID, upserted: upserted, deleted: deleted)
    }
    func conversations(_ query: ConversationQuery) throws -> [ConversationSummary] { try base.conversations(query) }
    func observeConversations(_ query: ConversationQuery, onChange: @escaping @Sendable ([ConversationSummary]) -> Void) -> StoreObservation {
        base.observeConversations(query, onChange: onChange)
    }
    func observeConversation(_ id: ConversationID, onChange: @escaping @Sendable ([MessageMetadata]) -> Void) -> StoreObservation {
        base.observeConversation(id, onChange: onChange)
    }
    func unreadInboxCount(accountIDs: [AccountID]?) throws -> Int { try base.unreadInboxCount(accountIDs: accountIDs) }
    func snoozes() throws -> [Snooze] { try base.snoozes() }
    func setSnoozes(_ changes: [Snooze.Change], enqueueing operations: [Operation], at now: Date) throws {
        try base.setSnoozes(changes, enqueueing: operations, at: now)
    }
    func returnDueSnoozes(at now: Date, dueBy: [AccountID: Date], limit: Int,
                          operations: (ConversationID, [MessageMetadata]) -> [Operation]) throws -> [ConversationID] {
        try base.returnDueSnoozes(at: now, dueBy: dueBy, limit: limit, operations: operations)
    }
    func observeSnoozes(onChange: @escaping @Sendable ([Snooze]) -> Void) -> StoreObservation {
        base.observeSnoozes(onChange: onChange)
    }
    func setMuted(_ muted: Bool, conversations: [ConversationID], enqueueing operations: [Operation],
                  returnMarks: [ConversationID: Date]) throws {
        try base.setMuted(muted, conversations: conversations, enqueueing: operations, returnMarks: returnMarks)
    }
    func isMuted(_ conversation: ConversationID) throws -> Bool { try base.isMuted(conversation) }
    func senderRules() throws -> [SenderRule] { try base.senderRules() }
    func setSenderRule(_ action: SenderRule.Action?, for address: String, accountID: AccountID,
                       enqueueing operations: [Operation], at now: Date) throws {
        try base.setSenderRule(action, for: address, accountID: accountID, enqueueing: operations, at: now)
    }
    func observeSenderRules(onChange: @escaping @Sendable ([SenderRule]) -> Void) -> StoreObservation {
        base.observeSenderRules(onChange: onChange)
    }
    func enqueue(_ operation: Operation) throws {
        try check(.enqueue)
        try base.enqueue(operation)
    }
    /// One call, as both stores make it one transaction: a fault fails the whole batch and stores none of it.
    func enqueue(_ operations: [Operation]) throws {
        try check(.enqueue)
        try base.enqueue(operations)
    }
    func pendingOperations(accountID: AccountID, limit: Int) throws -> [Operation] {
        try base.pendingOperations(accountID: accountID, limit: limit)
    }
    func updateOperation(_ operation: Operation) throws { try base.updateOperation(operation) }
    func confirmOperation(id: String) throws { try base.confirmOperation(id: id) }
    func deleteOperation(id: String) throws { try base.deleteOperation(id: id) }
    func acknowledgeFailedOperation(conversationID: ConversationID) throws { try base.acknowledgeFailedOperation(conversationID: conversationID) }
    func pruneFailedOperations(accountID: AccountID, now: Date) throws -> Int { try base.pruneFailedOperations(accountID: accountID, now: now) }
    func enqueueSend(_ send: PendingSend) throws { try base.enqueueSend(send) }
    func pendingSends() throws -> [PendingSend] { try base.pendingSends() }
    func pendingSendSummaries() throws -> [PendingSendSummary] { try base.pendingSendSummaries() }
    func pendingSend(id: String) throws -> PendingSend? { try base.pendingSend(id: id) }
    func updateSend(_ send: PendingSendSummary) throws { try base.updateSend(send) }
    func deleteSend(id: String) throws { try base.deleteSend(id: id) }
    func observePendingSends(onChange: @escaping @Sendable ([PendingSendSummary]) -> Void) -> StoreObservation {
        base.observePendingSends(onChange: onChange)
    }
    func suggestAddresses(prefix: String, limit: Int) throws -> [EmailAddress] { try base.suggestAddresses(prefix: prefix, limit: limit) }

    // MARK: Calendar

    func calendarEvents(in interval: DateInterval, accountIDs: [AccountID]?) throws -> [CalendarEvent] {
        try base.calendarEvents(in: interval, accountIDs: accountIDs)
    }
    func observeCalendarEvents(in interval: DateInterval,
                               onChange: @escaping @Sendable ([CalendarEvent]) -> Void) -> StoreObservation {
        base.observeCalendarEvents(in: interval, onChange: onChange)
    }
    func replaceCalendarEvents(_ events: [CalendarEvent], accountID: AccountID, window: DateInterval) throws {
        try check(.replaceCalendarEvents)
        try base.replaceCalendarEvents(events, accountID: accountID, window: window)
    }
    func addCalendarEvent(_ event: CalendarEvent) throws { try base.addCalendarEvent(event) }
    func removeCalendarEvent(id: String) throws -> CalendarEvent? { try base.removeCalendarEvent(id: id) }
    func restoreCalendarEvent(_ event: CalendarEvent) throws -> CalendarEvent { try base.restoreCalendarEvent(event) }
    func pendingCalendarEvents(accountID: AccountID) throws -> [CalendarEvent] { try base.pendingCalendarEvents(accountID: accountID) }
    func settleCalendarEvent(id: String, created: CalendarEvent?) throws -> Bool {
        try check(.settleCalendarEvent)
        return try base.settleCalendarEvent(id: id, created: created)
    }
    func failCalendarEvent(id: String) throws { try base.failCalendarEvent(id: id) }
    func answerCalendarEvents(_ response: CalendarEvent.Response, invitationUID uid: String, accountID: AccountID,
                              near occurrence: Date?) throws {
        try base.answerCalendarEvents(response, invitationUID: uid, accountID: accountID, near: occurrence)
    }
    func saveMailTimes(_ times: [MailTime], for message: MessageID) throws { try base.saveMailTimes(times, for: message) }
    func mailTimes(in conversation: ConversationID) throws -> [MailTime] { try base.mailTimes(in: conversation) }
}
