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
    /// Drops messages, bodies, contacts, sync state and backfill marks for the account but keeps the account row,
    /// its pending operations and its pending sends: user intent the provider has not seen survives a re-bootstrap.
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
    /// Stored bodies without design facts (saved before v3 kept them), newest first: the engine works them out
    /// again from the stored source, off the main thread, and writes them with `saveDesignFacts`.
    func messageIDsMissingDesignFacts(accountID: AccountID, limit: Int) throws -> [MessageID]
    /// Writes the design facts of stored bodies in one transaction, leaving the rest of each body as it is.
    /// Messages without a stored body are skipped.
    func saveDesignFacts(_ facts: [MessageID: BodyDesignFacts]) throws

    // MARK: Backfill (docs/DATA-MODEL.md, "Backfill marks")
    // The backfill lane downloads older mail while the live lane applies changes from the cursor, and a backfill
    // page can be fetched before a live change and written after it. These calls keep such a page from
    // overwriting newer state or bringing a deleted message back, and let a reconciling backfill remove what the
    // provider no longer has without wiping the mailbox. The marks are sync bookkeeping: no observation reads them.

    /// Of `providerIDs`, the ones the backfill should not fetch: those the live lane wrote or deleted since the
    /// backfill began, plus, when `includeStored`, those the account already stores. Advisory, so a backfill can
    /// skip the metadata requests; `writeBackfillMessages` checks again in its own transaction.
    func backfillSkippableIDs(accountID: AccountID, providerIDs: [String], includeStored: Bool) throws -> Set<String>
    /// Writes a backfill page in one transaction: drops every message the live lane wrote or deleted since the
    /// backfill began and, unless `refreshExisting` (a reconciling backfill), every message already stored, then
    /// writes the rest exactly as `upsertMessages` would, pending operations winning. The check and the write
    /// share the transaction so a live write cannot land between them. Returns how many messages it wrote.
    @discardableResult
    func writeBackfillMessages(_ messages: [MessageMetadata], refreshExisting: Bool) throws -> Int
    /// Records that the live lane wrote (`upserted`) or deleted (`deleted`) these messages while a backfill
    /// runs, so the backfill leaves them alone. A later call replaces an id's mark; within one call an id in
    /// both lists is marked deleted, the order the live lane applies a changes page in.
    ///
    /// Call it before the `upsertMessages` / `deleteMessages` it describes, never after: it is its own
    /// transaction, so only a mark that commits first guarantees a backfill write or sweep either sees it (and
    /// skips or keeps the message) or commits before the live write (which then overwrites it). Marking after
    /// leaves a window where a stale page brings back a just-deleted message, overwrites a newer one, or a sweep
    /// removes just-arrived mail. A mark whose live write then fails is harmless: the backfill skips that message
    /// and the live lane writes it when it retries the page, since its cursor moves only after the write.
    func markLiveChanges(accountID: AccountID, upserted: [String], deleted: [String]) throws
    /// Records ids a reconciling backfill's listing returned, which its final sweep keeps.
    func markBackfillSeen(accountID: AccountID, providerIDs: [String]) throws
    /// Ends the account's backfill in one transaction. With `sweepUnseen` (a reconciling backfill that listed
    /// the whole mailbox) it first deletes every stored message of the account that the listing never returned,
    /// the live lane never marked and no live operation targets: the provider no longer has it. Then it drops
    /// the account's marks. Returns how many messages it deleted.
    @discardableResult
    func finishBackfill(accountID: AccountID, sweepUnseen: Bool) throws -> Int

    // MARK: Conversations
    func conversations(_ query: ConversationQuery) throws -> [ConversationSummary]
    func observeConversations(_ query: ConversationQuery, onChange: @escaping @Sendable ([ConversationSummary]) -> Void) -> StoreObservation
    /// As above, and `onError` runs on the main thread if a read fails, which stops the observation: no
    /// `onChange` follows. For a subscriber that would otherwise wait for rows that never come (the list's
    /// `list.search` interval). A store whose reads cannot fail keeps the default, which never calls it.
    func observeConversations(
        _ query: ConversationQuery,
        onChange: @escaping @Sendable ([ConversationSummary]) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) -> StoreObservation
    func observeConversation(_ id: ConversationID, onChange: @escaping @Sendable ([MessageMetadata]) -> Void) -> StoreObservation
    func unreadInboxCount(accountIDs: [AccountID]?) throws -> Int

    // MARK: Operations (outbox)
    /// In one transaction: apply `operation.change` to every target locally, insert the operation as pending,
    /// and record what it replaced on each target, which a give-up puts back (see `updateOperation`).
    func enqueue(_ operation: Operation) throws
    func pendingOperations(accountID: AccountID, limit: Int) throws -> [Operation]
    /// Saves the operation. Writing a live (pending, in-flight or uncertain) operation as `failed` gives it up,
    /// in one transaction: each target it changed goes back to the state the change replaced (as last reported
    /// by the provider), with newer live operations on that target replayed on top, and every conversation it
    /// targets is marked with its kind unless that conversation already shows a newer failure. Writing it out
    /// of `failed` clears marks like a pruned failure (see `deleteOperation`); writing it as `confirmed` clears
    /// them like `confirmOperation`. Neither changes message state.
    func updateOperation(_ operation: Operation) throws
    /// Removes an operation the provider applied (docs/DATA-MODEL.md, "Confirmed operations"), keeping its
    /// local change. Every conversation it targets loses its failed mark unless a failed operation created
    /// after it still targets that conversation: a later success settles an earlier failure.
    func confirmOperation(id: String) throws
    /// Removes the operation without saying it landed, keeping its local change: a live one a poll has settled
    /// changes no failed mark. Deleting a failed one (pruning) ends that failure: each conversation it targets
    /// loses its mark unless another failed operation still targets that conversation.
    func deleteOperation(id: String) throws
    /// Clears the conversation's failed mark (`ConversationSummary.failedOperation`); the failed operation
    /// itself stays until it is pruned. For the app to call once a conversation has been open for 150 ms.
    func acknowledgeFailedOperation(conversationID: ConversationID) throws
    /// Deletes the account's failed operations whose `nextAttemptAt` (for a failed row, its expiry) is at or
    /// before `now`, or that have none, each like `deleteOperation`. Returns how many went.
    @discardableResult
    func pruneFailedOperations(accountID: AccountID, now: Date) throws -> Int
    func enqueueSend(_ send: PendingSend) throws
    func pendingSends() throws -> [PendingSend]
    func updateSend(_ send: PendingSend) throws
    func deleteSend(id: String) throws
    /// Every pending send as `pendingSends` lists them, after every change to the outbox. The first value is read
    /// off the main thread like the later ones (rows carry their attachments), so it may arrive after this returns.
    func observePendingSends(onChange: @escaping @Sendable ([PendingSend]) -> Void) -> StoreObservation

    // MARK: Contacts
    /// Addresses seen in from/to/cc, ranked by how often and how recently they appear. Prefix matches name or address.
    func suggestAddresses(prefix: String, limit: Int) throws -> [EmailAddress]
}

extension MailStoring {
    public func observeConversations(
        _ query: ConversationQuery,
        onChange: @escaping @Sendable ([ConversationSummary]) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) -> StoreObservation {
        observeConversations(query, onChange: onChange)
    }
}
