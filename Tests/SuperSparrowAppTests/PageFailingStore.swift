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
    func body(for id: MessageID) throws -> StoredBody? { try base.body(for: id) }
    func messageIDsMissingBodies(accountID: AccountID, limit: Int) throws -> [MessageID] {
        try base.messageIDsMissingBodies(accountID: accountID, limit: limit)
    }
    func observeConversations(_ query: ConversationQuery, onChange: @escaping @Sendable ([ConversationSummary]) -> Void) -> StoreObservation {
        base.observeConversations(query, onChange: onChange)
    }
    func observeConversation(_ id: ConversationID, onChange: @escaping @Sendable ([MessageMetadata]) -> Void) -> StoreObservation {
        base.observeConversation(id, onChange: onChange)
    }
    func unreadInboxCount(accountIDs: [AccountID]?) throws -> Int { try base.unreadInboxCount(accountIDs: accountIDs) }
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
    func suggestAddresses(prefix: String, limit: Int) throws -> [EmailAddress] { try base.suggestAddresses(prefix: prefix, limit: limit) }
}
