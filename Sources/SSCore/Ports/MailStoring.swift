import Foundation

/// A cancellation token for a store observation.
public final class StoreObservation: @unchecked Sendable {
    private let onCancel: () -> Void
    private var cancelled = false
    private let lock = NSLock()
    public init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        onCancel()
    }
    deinit { cancel() }
}

/// The local mailbox. All reads the UI performs go through here and never touch the network.
///
/// Thread-safety: every method may be called from any thread. Observation callbacks are delivered on the
/// main thread, first with the current value, then after every change to the underlying rows.
public protocol MailStoring: AnyObject, Sendable {
    // MARK: Accounts
    func accounts() throws -> [Account]
    func upsertAccount(_ account: Account) throws
    /// Removes the account and every row that belongs to it.
    func deleteAccount(_ id: AccountID) throws
    /// Moves the account to another palette slot. Throws `StoreError.notFound` for an unknown account and
    /// `StoreError.conflict` for a slot outside `AccountInkSlot`'s range.
    func setInkSlot(_ slot: Int, for accountID: AccountID) throws
    /// Stores the monogram the user typed, normalized by `Account.normalizedMonogram`; nil (or blank) goes
    /// back to the derived one. Throws `StoreError.notFound` for an unknown account.
    func setMonogram(_ monogram: String?, for accountID: AccountID) throws

    // MARK: Sync state
    func syncCursor(for accountID: AccountID) throws -> String?
    func setSyncCursor(_ cursor: String?, for accountID: AccountID) throws
    func bootstrapState(for accountID: AccountID) throws -> BootstrapState?
    func setBootstrapState(_ state: BootstrapState?, for accountID: AccountID) throws
    /// Drops messages, bodies, contacts and sync state for the account but keeps the account row, its pending
    /// operations and its pending sends: user intent the provider has not seen survives a re-bootstrap.
    func wipeMailData(for accountID: AccountID) throws

    // MARK: Messages
    /// Insert or replace metadata, then refresh the summary rows of every touched conversation.
    /// Must not overwrite fields a pending local operation changed (read/starred/roles) with older provider state;
    /// see docs/DATA-MODEL.md "Pending operations win".
    func upsertMessages(_ messages: [MessageMetadata]) throws
    func deleteMessages(_ ids: [MessageID]) throws
    func message(_ id: MessageID) throws -> MessageMetadata?
    /// Messages of a conversation, oldest first.
    func messages(in conversation: ConversationID) throws -> [MessageMetadata]
    func saveBody(_ body: StoredBody, for id: MessageID) throws
    func body(for id: MessageID) throws -> StoredBody?
    /// Messages without a stored body, inbox and newest first, so hydration follows what the user will open.
    func messageIDsMissingBodies(accountID: AccountID, limit: Int) throws -> [MessageID]

    // MARK: Conversations
    func conversations(_ query: ConversationQuery) throws -> [ConversationSummary]
    func observeConversations(_ query: ConversationQuery, onChange: @escaping @Sendable ([ConversationSummary]) -> Void) -> StoreObservation
    func observeConversation(_ id: ConversationID, onChange: @escaping @Sendable ([MessageMetadata]) -> Void) -> StoreObservation
    func unreadInboxCount(accountIDs: [AccountID]?) throws -> Int

    // MARK: Operations (outbox)
    /// In one transaction: apply `operation.change` to every target locally and insert the operation as pending.
    func enqueue(_ operation: Operation) throws
    func pendingOperations(accountID: AccountID, limit: Int) throws -> [Operation]
    /// Saves the operation. Writing it as `failed` (from any other status) marks every conversation it targets
    /// with its kind in the same transaction, unless that conversation already shows a newer failure.
    /// Writing it out of `failed`, or as `confirmed`, settles it like `deleteOperation`.
    func updateOperation(_ operation: Operation) throws
    /// Removes the operation. A confirmed operation is deleted (docs/DATA-MODEL.md), so deleting one settles it:
    /// every conversation it targets loses its failed mark unless a failed operation newer than it still
    /// targets that conversation. Deleting a failed operation (pruning) settles it the same way.
    func deleteOperation(id: String) throws
    /// Clears the conversation's failed mark (`ConversationSummary.failedOperation`); the failed operation
    /// itself stays until it is pruned. The app calls it once a conversation has been open for 150 ms.
    func acknowledgeFailedOperation(conversationID: ConversationID) throws
    /// Deletes the account's failed operations whose `nextAttemptAt` (for a failed row, its expiry) is at or
    /// before `now`, or that have none, settling each like `deleteOperation`. Returns how many went.
    @discardableResult
    func pruneFailedOperations(accountID: AccountID, now: Date) throws -> Int
    func enqueueSend(_ send: PendingSend) throws
    func pendingSends() throws -> [PendingSend]
    func updateSend(_ send: PendingSend) throws
    func deleteSend(id: String) throws

    // MARK: Contacts
    /// Addresses seen in from/to/cc, ranked by how often and how recently they appear. Prefix matches name or address.
    func suggestAddresses(prefix: String, limit: Int) throws -> [EmailAddress]
}
