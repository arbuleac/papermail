import Foundation
import SSCore

/// An in-memory store whose older pages (`query.before` set) fail while `failsPages` is on, for the list tail's
/// failed state and its Retry. Every other call goes straight to the wrapped store.
final class PageFailingStore: MailStoring, @unchecked Sendable {
    struct PageError: Error {}

    let base: InMemoryMailStore
    private let lock = NSLock()
    private var failing = true

    var failsPages: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    init(base: InMemoryMailStore) {
        self.base = base
    }

    func conversations(_ query: ConversationQuery) throws -> [ConversationSummary] {
        if query.before != nil, failsPages { throw PageError() }
        return try base.conversations(query)
    }

    func accounts() throws -> [Account] { try base.accounts() }
    func upsertAccount(_ account: Account) throws { try base.upsertAccount(account) }
    func deleteAccount(_ id: AccountID) throws { try base.deleteAccount(id) }
    func setInkSlot(_ slot: Int, for accountID: AccountID) throws { try base.setInkSlot(slot, for: accountID) }
    func setMonogram(_ monogram: String?, for accountID: AccountID) throws { try base.setMonogram(monogram, for: accountID) }
    func setSignature(_ signature: String?, for accountID: AccountID) throws { try base.setSignature(signature, for: accountID) }
    func syncCursor(for accountID: AccountID) throws -> String? { try base.syncCursor(for: accountID) }
    func setSyncCursor(_ cursor: String?, for accountID: AccountID) throws { try base.setSyncCursor(cursor, for: accountID) }
    func bootstrapState(for accountID: AccountID) throws -> BootstrapState? { try base.bootstrapState(for: accountID) }
    func setBootstrapState(_ state: BootstrapState?, for accountID: AccountID) throws { try base.setBootstrapState(state, for: accountID) }
    func wipeMailData(for accountID: AccountID) throws { try base.wipeMailData(for: accountID) }
    func upsertMessages(_ messages: [MessageMetadata]) throws { try base.upsertMessages(messages) }
    func deleteMessages(_ ids: [MessageID]) throws { try base.deleteMessages(ids) }
    func message(_ id: MessageID) throws -> MessageMetadata? { try base.message(id) }
    func messages(in conversation: ConversationID) throws -> [MessageMetadata] { try base.messages(in: conversation) }
    func saveBody(_ body: StoredBody, for id: MessageID) throws { try base.saveBody(body, for: id) }
    func saveBody(_ body: StoredBody, for id: MessageID, evictingIfReceivedBefore cutoff: Date) throws -> Bool {
        try base.saveBody(body, for: id, evictingIfReceivedBefore: cutoff)
    }
    func body(for id: MessageID) throws -> StoredBody? { try base.body(for: id) }
    func attachments(of id: MessageID) throws -> [AttachmentInfo]? { try base.attachments(of: id) }
    func evictBodies(from start: Date?, limit: Int,
                     rules: () -> (cutoff: Date, excluding: Set<MessageID>)?) throws -> (evicted: Int, next: Date?) {
        try base.evictBodies(from: start, limit: limit, rules: rules)
    }
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

    func storedProviderIDs(accountID: AccountID, inFolder folderID: String) throws -> [String] {
        try base.storedProviderIDs(accountID: accountID, inFolder: folderID)
    }
    func writeBackfillMessages(_ messages: [MessageMetadata], refreshExisting: Bool) throws -> Int {
        try base.writeBackfillMessages(messages, refreshExisting: refreshExisting)
    }
    func markLiveChanges(accountID: AccountID, upserted: [String], deleted: [String]) throws {
        try base.markLiveChanges(accountID: accountID, upserted: upserted, deleted: deleted)
    }
    func markBackfillSeen(accountID: AccountID, providerIDs: [String]) throws {
        try base.markBackfillSeen(accountID: accountID, providerIDs: providerIDs)
    }
    func finishBackfill(accountID: AccountID, sweepUnseen: Bool) throws -> Int {
        try base.finishBackfill(accountID: accountID, sweepUnseen: sweepUnseen)
    }
    func observeConversations(_ query: ConversationQuery, onChange: @escaping @Sendable ([ConversationSummary]) -> Void) -> StoreObservation {
        base.observeConversations(query, onChange: onChange)
    }
    func observeConversation(_ id: ConversationID, onChange: @escaping @Sendable ([MessageMetadata]) -> Void) -> StoreObservation {
        base.observeConversation(id, onChange: onChange)
    }
    func unreadInboxCount(accountIDs: [AccountID]?) throws -> Int { try base.unreadInboxCount(accountIDs: accountIDs) }
    func snoozes() throws -> [Snooze] { try base.snoozes() }
    func setSnoozes(_ changes: [Snooze.Change], enqueueing operations: [SSCore.Operation], at now: Date) throws {
        try base.setSnoozes(changes, enqueueing: operations, at: now)
    }
    func returnDueSnoozes(at now: Date, dueBy: [AccountID: Date], limit: Int,
                          operations: (ConversationID, [MessageMetadata]) -> [SSCore.Operation]) throws -> [ConversationID] {
        try base.returnDueSnoozes(at: now, dueBy: dueBy, limit: limit, operations: operations)
    }
    func observeSnoozes(onChange: @escaping @Sendable ([Snooze]) -> Void) -> StoreObservation {
        base.observeSnoozes(onChange: onChange)
    }
    func enqueue(_ operation: SSCore.Operation) throws { try base.enqueue(operation) }
    func pendingOperations(accountID: AccountID, limit: Int) throws -> [SSCore.Operation] {
        try base.pendingOperations(accountID: accountID, limit: limit)
    }
    func updateOperation(_ operation: SSCore.Operation) throws { try base.updateOperation(operation) }
    func confirmOperation(id: String) throws { try base.confirmOperation(id: id) }
    func deleteOperation(id: String) throws { try base.deleteOperation(id: id) }
    func acknowledgeFailedOperation(conversationID: ConversationID) throws { try base.acknowledgeFailedOperation(conversationID: conversationID) }
    func pruneFailedOperations(accountID: AccountID, now: Date) throws -> Int { try base.pruneFailedOperations(accountID: accountID, now: now) }
    func enqueueSend(_ send: PendingSend) throws { try base.enqueueSend(send) }
    func pendingSends() throws -> [PendingSend] { try base.pendingSends() }
    func updateSend(_ send: PendingSend) throws { try base.updateSend(send) }
    func deleteSend(id: String) throws { try base.deleteSend(id: id) }
    func observePendingSends(onChange: @escaping @Sendable ([PendingSend]) -> Void) -> StoreObservation {
        base.observePendingSends(onChange: onChange)
    }
    func suggestAddresses(prefix: String, limit: Int) throws -> [EmailAddress] { try base.suggestAddresses(prefix: prefix, limit: limit) }
}
