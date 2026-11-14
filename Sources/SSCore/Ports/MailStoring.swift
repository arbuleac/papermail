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
    /// Stores the signature the user set in Settings (the composer's HTML subset), normalized by
    /// `Account.normalizedSignature`; nil (or blank) means none. Throws `StoreError.notFound` for an unknown account.
    func setSignature(_ signature: String?, for accountID: AccountID) throws

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
    /// Stores the body render-ready. A body that was evicted is whole again: it leaves the evicted state.
    func saveBody(_ body: StoredBody, for id: MessageID) throws
    /// Stores the body as `saveBody` does, except that one `evictBodies` would take for `cutoff` (the message received
    /// before it, not a draft, no live operation targeting it) is stored already evicted: its plain text, attachment
    /// list, design facts and full-text row, never its source or rendered HTML. For the backfill, so bodies outside the
    /// Keep mail window never take their full size on disk. Returns whether it stored the body evicted.
    @discardableResult
    func saveBody(_ body: StoredBody, for id: MessageID, evictingIfReceivedBefore cutoff: Date) throws -> Bool
    /// The stored body; nil when there is none or it was evicted (`evictBodies`), which both mean "fetch it".
    func body(for id: MessageID) throws -> StoredBody?
    /// The attachment list of the stored body, evicted or not (an eviction keeps it); nil when there is no body. What
    /// the reader's chips, Quick Look and scheme handlers read: a page renders from the body it read, so a body evicted
    /// in the instant it went on screen must still answer them.
    func attachments(of id: MessageID) throws -> [AttachmentInfo]?
    /// Messages without a stored body, inbox and newest first, so hydration follows what the user will open. An
    /// evicted body still has its row, so it is never offered again: it comes back only when the message is opened.
    func messageIDsMissingBodies(accountID: AccountID, limit: Int) throws -> [MessageID]
    /// Evicts, in one transaction, up to `limit` bodies of messages received before the cutoff and not before `start`,
    /// oldest first (docs/DATA-MODEL.md, `bodies.evicted`): their source and rendered HTML go, while their plain text,
    /// attachment list and full-text row stay, so the list, snippets and search are unchanged. Drafts, messages a live
    /// (pending, in-flight or uncertain) operation targets, and the messages `rules` excludes are left alone.
    ///
    /// `rules` gives the cutoff and the messages to leave alone, or nil to evict nothing. The store asks it again
    /// inside the write transaction, just before the bodies go, so a message marked kept or a window widened while the
    /// batch looked for candidates is honoured. Returns how many bodies it evicted and `next`, the `start` of the next
    /// batch of the same sweep (nil once nothing is left to look at): a sweep walks the mailbox once, never again from
    /// the oldest message for every batch. The caller asks batch by batch, so live writes never wait behind one long
    /// transaction.
    @discardableResult
    func evictBodies(from start: Date?, limit: Int,
                     rules: () -> (cutoff: Date, excluding: Set<MessageID>)?) throws -> (evicted: Int, next: Date?)
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
    /// The roles of the account's stored messages among `providerIDs`; an id it does not store is absent. For a
    /// reconcile, which keeps mail the enumeration leaves out (Gmail's Trash and Spam) only where the store already
    /// shows it there.
    func storedRoles(accountID: AccountID, providerIDs: [String]) throws -> [String: Set<MailboxRole>]
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

    // MARK: Queued lookups (docs/DATA-MODEL.md, `queued_lookups`)
    // A folder the provider reports gone (`ChangesPage.goneFolders`) takes its mail with it if it was purged, and no
    // delta reports that. Its stored messages are queued, and the live lane looks them up a few per poll, so the work
    // survives a failed poll or a quit and no poll has to look up a whole folder. Sync bookkeeping: no observation
    // reads it.

    /// Queues a lookup of every stored message of the account in `folderIDs` (`MessageMetadata.folderID`); one already
    /// queued keeps its tries. Rare, so it scans rather than keep an index every write pays. Returns how many it queued.
    @discardableResult
    func queueLookups(accountID: AccountID, inFolders folderIDs: [String]) throws -> Int
    /// Up to `limit` of the account's queued lookups, with the tries each has failed so far.
    func queuedLookups(accountID: AccountID, limit: Int) throws -> [String: Int]
    /// Ends the queued lookups in `settled` and counts a failed try against each of `retried`, in one transaction.
    func settleQueuedLookups(accountID: AccountID, settled: [String], retried: [String]) throws

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

    // MARK: Snoozes (docs/DATA-MODEL.md, "Snoozes")
    // Later archives a conversation now and moves it back to the Inbox at a time. The two halves are ordinary
    // operations; the store keeps the timer (`snoozes`) and ends a snooze on its own when the conversation is back in
    // the Inbox, in the Trash or gone, or when mail arrives in it after it was snoozed.

    /// Every snooze whose conversation is stored, soonest first.
    func snoozes() throws -> [Snooze]
    /// In one transaction: applies and queues `operations` as `enqueue` does, then writes each change: a date snoozes
    /// the conversation (or moves its time), nil ends its snooze, and a `returnedAt` puts back a return mark (an undo)
    /// where the conversation is now in the Inbox with older mail. A date is kept only for a conversation whose messages,
    /// once the operations are applied, stand for mail put away (`Snooze.canHold`: stored, out of the Inbox, out of the
    /// Trash, and its mail from others not all in the Trash); the window asks the same of its selection first, so it
    /// never offers a snooze this would drop. `now` is its `createdAt`.
    func setSnoozes(_ changes: [Snooze.Change], enqueueing operations: [Operation], at now: Date) throws
    /// Brings back, in one transaction, up to `limit` conversations whose snooze is due by `now`, soonest first: each
    /// snooze is deleted, the operations `operations` makes from the conversation's messages (oldest first) are applied
    /// and queued, and the conversation, once back in the Inbox, is marked returned at `now` (`returned_at`). An account
    /// in `dueBy` brings back only its snoozes due by that date (the engine holds back a time its account has not checked
    /// for mail past yet). A due snooze whose conversation is gone is just deleted. Returns the conversations it brought
    /// back.
    @discardableResult
    func returnDueSnoozes(at now: Date, dueBy: [AccountID: Date], limit: Int,
                          operations: (ConversationID, [MessageMetadata]) -> [Operation]) throws -> [ConversationID]
    /// `snoozes()` after every change to it, delivered on the main thread, the current value first.
    func observeSnoozes(onChange: @escaping @Sendable ([Snooze]) -> Void) -> StoreObservation

    // MARK: Operations (outbox)
    /// In one transaction: apply `operation.change` to every target locally, insert the operation as pending,
    /// and record what it replaced on each target, which a give-up puts back (see `updateOperation`).
    func enqueue(_ operation: Operation) throws
    /// Enqueues every operation as `enqueue(_:)` does, in order and in one transaction, so a user action made of
    /// several (an unsubscribe request and the archive beside it) is stored whole or not at all.
    func enqueue(_ operations: [Operation]) throws
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
    /// `returnDueSnoozes(at:dueBy:limit:operations:)` holding nothing back.
    @discardableResult
    public func returnDueSnoozes(at now: Date, limit: Int,
                                 operations: (ConversationID, [MessageMetadata]) -> [Operation]) throws -> [ConversationID] {
        try returnDueSnoozes(at: now, dueBy: [:], limit: limit, operations: operations)
    }

    /// One at a time, for a store that cannot do better (the test doubles that wrap a real store); both stores
    /// override it with one transaction.
    public func enqueue(_ operations: [Operation]) throws {
        for operation in operations { try enqueue(operation) }
    }

    /// One batch of `evictBodies(from:limit:rules:)` from the oldest message, with fixed rules.
    @discardableResult
    public func evictBodies(receivedBefore cutoff: Date, excluding: Set<MessageID>, limit: Int) throws -> Int {
        try evictBodies(from: nil, limit: limit) { (cutoff, excluding) }.evicted
    }

    public func observeConversations(
        _ query: ConversationQuery,
        onChange: @escaping @Sendable ([ConversationSummary]) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) -> StoreObservation {
        observeConversations(query, onChange: onChange)
    }
}
