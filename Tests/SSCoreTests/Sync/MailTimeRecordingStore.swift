import Foundation
@testable import SSCore

/// An in-memory store that records every `saveMailTimes` call, for the hydrator's hook that stores the times found in
/// a body (`Hydrator.saveMailTimes`), whatever the wrapped store makes of them. Every call goes to the wrapped store.
final class MailTimeRecordingStore: MailStoring, @unchecked Sendable {
    let base: InMemoryMailStore
    private let lock = NSLock()
    private var saved: [(message: MessageID, times: [MailTime])] = []

    init(base: InMemoryMailStore) {
        self.base = base
    }

    /// Every `saveMailTimes` call, in order.
    var savedMailTimes: [(message: MessageID, times: [MailTime])] {
        lock.withLock { saved }
    }

    func saveMailTimes(_ times: [MailTime], for message: MessageID) throws {
        lock.withLock { saved.append((message, times)) }
        try base.saveMailTimes(times, for: message)
    }

    func mailTimes(in conversation: ConversationID) throws -> [MailTime] { try base.mailTimes(in: conversation) }

    // MARK: Forwarded

    func setSyncCursor(_ cursor: String?, for accountID: AccountID) throws { try base.setSyncCursor(cursor, for: accountID) }
    func setBootstrapState(_ state: BootstrapState?, for accountID: AccountID) throws { try base.setBootstrapState(state, for: accountID) }
    func upsertMessages(_ messages: [MessageMetadata]) throws { try base.upsertMessages(messages) }
    func markBackfillSeen(accountID: AccountID, providerIDs: [String]) throws {
        try base.markBackfillSeen(accountID: accountID, providerIDs: providerIDs)
    }
    func finishBackfill(accountID: AccountID, sweepUnseen: Bool) throws -> Int {
        try base.finishBackfill(accountID: accountID, sweepUnseen: sweepUnseen)
    }
    func saveBody(_ body: StoredBody, for id: MessageID, evictingIfReceivedBefore cutoff: Date) throws -> Bool {
        try base.saveBody(body, for: id, evictingIfReceivedBefore: cutoff)
    }
    func body(for id: MessageID) throws -> StoredBody? { try base.body(for: id) }
    func evictBodies(from start: Date?, limit: Int,
                     rules: () -> (cutoff: Date, excluding: Set<MessageID>)?) throws -> (evicted: Int, next: Date?) {
        try base.evictBodies(from: start, limit: limit, rules: rules)
    }
    func accounts() throws -> [Account] { try base.accounts() }
    func upsertAccount(_ account: Account) throws { try base.upsertAccount(account) }
    func deleteAccount(_ id: AccountID) throws { try base.deleteAccount(id) }
    func setInkSlot(_ slot: Int, for accountID: AccountID) throws { try base.setInkSlot(slot, for: accountID) }
    func setMonogram(_ monogram: String?, for accountID: AccountID) throws { try base.setMonogram(monogram, for: accountID) }
    func setSignature(_ signature: String?, for accountID: AccountID) throws { try base.setSignature(signature, for: accountID) }
    func setFace(_ face: AccountFace, for accountID: AccountID) throws { try base.setFace(face, for: accountID) }
    func syncCursor(for accountID: AccountID) throws -> String? { try base.syncCursor(for: accountID) }
    func bootstrapState(for accountID: AccountID) throws -> BootstrapState? { try base.bootstrapState(for: accountID) }
    func wipeMailData(for accountID: AccountID) throws { try base.wipeMailData(for: accountID) }
    func deleteMessages(_ ids: [MessageID]) throws { try base.deleteMessages(ids) }
    func message(_ id: MessageID) throws -> MessageMetadata? { try base.message(id) }
    func messages(in conversation: ConversationID) throws -> [MessageMetadata] { try base.messages(in: conversation) }
    func saveBody(_ body: StoredBody, for id: MessageID) throws { try base.saveBody(body, for: id) }
    func attachments(of id: MessageID) throws -> [AttachmentInfo]? { try base.attachments(of: id) }
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
    func pendingSenderRules(accountID: AccountID) throws -> [SenderRule] { try base.pendingSenderRules(accountID: accountID) }
    func replaceServerSenderRules(accountID: AccountID, with rules: [ServerSenderRule], readAt: Date) throws {
        try base.replaceServerSenderRules(accountID: accountID, with: rules, readAt: readAt)
    }
    func settleSenderRule(for address: String, accountID: AccountID, _ outcome: SenderRuleOutcome) throws -> Bool {
        try base.settleSenderRule(for: address, accountID: accountID, outcome)
    }
    func observeSenderRules(onChange: @escaping @Sendable ([SenderRule]) -> Void) -> StoreObservation {
        base.observeSenderRules(onChange: onChange)
    }
    func enqueue(_ operation: Operation) throws { try base.enqueue(operation) }
    func enqueue(_ operations: [Operation]) throws { try base.enqueue(operations) }
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
}
