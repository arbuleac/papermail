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
    func body(for id: MessageID) throws -> StoredBody? { try base.body(for: id) }
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
    func enqueue(_ operation: Operation) throws { try base.enqueue(operation) }
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
    func updateSend(_ send: PendingSend) throws { try base.updateSend(send) }
    func deleteSend(id: String) throws { try base.deleteSend(id: id) }
    func observePendingSends(onChange: @escaping @Sendable ([PendingSend]) -> Void) -> StoreObservation {
        base.observePendingSends(onChange: onChange)
    }
    func suggestAddresses(prefix: String, limit: Int) throws -> [EmailAddress] { try base.suggestAddresses(prefix: prefix, limit: limit) }
}
