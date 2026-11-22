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
public protocol MailStoring: CalendarStoring, AnyObject, Sendable {
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
    /// Stores the face the user chose in Settings (Quire §5.55); `.automatic` (or a paper face with no id) clears the
    /// choice. Throws `StoreError.notFound` for an unknown account.
    func setFace(_ face: AccountFace, for accountID: AccountID) throws

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
    /// The newest unread message in the Inbox (not in the Trash or Spam) of each of `conversations` that has one, in one
    /// read: what a new-mail notification is about, which the conversation's newest message may not be (a sender rule
    /// archived it as it arrived, or it is the user's own reply).
    func newestUnreadInboxMessages(in conversations: [ConversationID]) throws -> [ConversationID: MessageMetadata]
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
    /// The stored body as it is kept, evicted or not; nil when there is none. An evicted body (`evictBodies`) comes back as
    /// the eviction left it: no source, rendered HTML or invitation, but its plain text, attachment list and design facts.
    /// What reader mode shows of an evicted body while the download that brings the rest back runs (spec §5.59).
    func keptBody(for id: MessageID) throws -> StoredBody?
    /// `keptBody(for:)` for each of `ids` that has a row, read at once: reader mode reads the kept bodies of every message
    /// a render has no body for (spec §5.59).
    func keptBodies(for ids: [MessageID]) throws -> [MessageID: StoredBody]
    /// The invitation the stored body carries (`StoredBody.invitation`), nil without one or when the body was evicted:
    /// what the calendar looks for on every selection, read without decompressing the body (the default reads it whole).
    func invitation(for id: MessageID) throws -> CalendarInvitation?
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
    /// Trash, and its mail from others not all in the Trash or Spam); the window asks the same of its selection first, so
    /// it never offers a snooze this would drop. `now` is its `createdAt`.
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

    // MARK: Mute and sender rules (docs/DATA-MODEL.md, "Arrival rules" and "Sender rules")
    // Mail new to the store in a muted conversation is archived in the write that stores it, through the ordinary
    // operation queued in that transaction, on every write path (`upsertMessages` and `writeBackfillMessages`). The mute
    // lives on this Mac; what it does round-trips. Sender rules live on the server (Gmail filters, Outlook inbox rules),
    // which acts on the sender's mail before this Mac sees it: the store keeps their mirror and the user's changes on
    // their way there, which the engine's rules lane sends.

    /// In one transaction: applies and queues `operations` as `enqueue` does (muting archives what is in the Inbox, an
    /// undo passes the inverse steps), then marks the conversations muted, or not, and puts back each of `returnMarks`
    /// as `setSnoozes` puts back a `Snooze.Change.returnedAt` (an undo of a mute that took a conversation back from Later
    /// out of the Inbox): only where the conversation is now in the Inbox and its newest mail is older. A conversation
    /// the store holds no summary row for is left alone.
    func setMuted(_ muted: Bool, conversations: [ConversationID], enqueueing operations: [Operation],
                  returnMarks: [ConversationID: Date]) throws
    /// Whether `conversation` is muted (`conversations.muted`): a reader window asks for its one conversation, which the
    /// list may no longer hold (spec, Reader window (Q3.5)). False for a conversation the store holds no summary of.
    func isMuted(_ conversation: ConversationID) throws -> Bool
    /// Every sender rule row, by account and then address, whatever its `sync`: the server's rules as last read
    /// (`saved`) and the user's changes on their way there (`creating`, `replacing`, `deleting`, which the UI shows as
    /// such; a `deleting` row is no longer the user's rule, `SenderRule.isActive`).
    func senderRules() throws -> [SenderRule]
    /// In one transaction: applies and queues `operations` as `enqueue` does (the rule's change on the sender's mail in
    /// the conversation it was set from, or an undo's inverse steps), then sets the account's rule for `address` to
    /// `action`, or removes it when `action` is nil, as a change on its way to the server: a new rule is `creating`; the
    /// other action for a rule the server has is `replacing`; removing a rule the server has makes it `deleting`, and one
    /// the server never had goes at once; setting a rule on a `deleting` row makes it `replacing` (the engine adopts what
    /// the server has when it is the same). The same action again changes nothing. `now` is the row's `createdAt`, the
    /// order the engine sends pending rows in.
    func setSenderRule(_ action: SenderRule.Action?, for address: String, accountID: AccountID,
                       enqueueing operations: [Operation], at now: Date) throws
    /// The account's rows waiting for the server (`creating`, `replacing`, `deleting`), oldest `createdAt` first, then by
    /// address: what the engine sends.
    func pendingSenderRules(accountID: AccountID) throws -> [SenderRule]
    /// Writes what one read of the account's server rules found, in one transaction: the `saved` rows become `rules`,
    /// several for one address folded into one row (the block winning, every id kept), each new address `saved` at
    /// `readAt`; rows on their way stay as they are, except that a `creating` row whose identical rule (same address and
    /// action) the server now has becomes `saved` with its ids, and a `deleting` row none of whose ids the server still
    /// has goes (or becomes the rule the server has for the address now). Nothing is written for an account the store no
    /// longer has.
    func replaceServerSenderRules(accountID: AccountID, with rules: [ServerSenderRule], readAt: Date) throws
    /// Records what the engine's write did on the server (`SenderRuleOutcome`) on the row for `address` as it stands now,
    /// in one transaction: a rule written is `saved` under its ids when the row still wants that action and holds no
    /// other ids, and otherwise stays pending with the ids it now has to deal with (`replacing`, or `deleting` when the
    /// user removed it meanwhile); ids deleted leave the row (a `deleting` row with none left goes; a `replacing` or
    /// `saved` one with none left is `creating` again); a refusal gives a create up (the row goes) and puts a delete or a
    /// replacement back as the server has it. Returns false, changing nothing, when there is no row: the engine then
    /// deletes what it just wrote.
    @discardableResult
    func settleSenderRule(for address: String, accountID: AccountID, _ outcome: SenderRuleOutcome) throws -> Bool
    /// `senderRules()` after every change to them, delivered on the main thread, the current value first.
    func observeSenderRules(onChange: @escaping @Sendable ([SenderRule]) -> Void) -> StoreObservation

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
    /// Every send in the outbox, whole (attachments included), oldest first. Nothing that looks at the outbox often reads
    /// this: a Send Later message waits there for days with its attachments; `pendingSendSummaries` leaves them out.
    func pendingSends() throws -> [PendingSend]
    /// Every send in the outbox as `pendingSends` lists them, without the message's HTML, references and attachments.
    func pendingSendSummaries() throws -> [PendingSendSummary]
    /// One send, whole, or nil once it has gone: what the runner delivers, and what a draft is made from.
    func pendingSend(id: String) throws -> PendingSend?
    /// Writes a send's state (`sendAfter`, `status`, `attempts`, `lastError`) over its row; its message, draft and creation
    /// time stay as queued, so a status change never rewrites the attachments. Does nothing once the row has gone.
    func updateSend(_ send: PendingSendSummary) throws
    func deleteSend(id: String) throws
    /// Every pending send as `pendingSendSummaries` lists them, after every change to the outbox. The first value is read
    /// off the main thread like the later ones, so it may arrive after this returns.
    func observePendingSends(onChange: @escaping @Sendable ([PendingSendSummary]) -> Void) -> StoreObservation

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

    /// The body `body(for:)` reads, for a store that keeps nothing of an evicted body (the test doubles that wrap a real
    /// store); both stores override it with the evicted row.
    public func keptBody(for id: MessageID) throws -> StoredBody? {
        try body(for: id)
    }

    /// One `keptBody(for:)` per id, for a store with no read of many (the test doubles and `InMemoryMailStore`, where each
    /// is a lookup); `SQLiteMailStore` overrides it with one query.
    public func keptBodies(for ids: [MessageID]) throws -> [MessageID: StoredBody] {
        var kept: [MessageID: StoredBody] = [:]
        for id in ids { if let body = try keptBody(for: id) { kept[id] = body } }
        return kept
    }

    /// The whole body's invitation, for a store that cannot read it alone (the test doubles that wrap a real store);
    /// `SQLiteMailStore` overrides it with one column.
    public func invitation(for id: MessageID) throws -> CalendarInvitation? {
        try body(for: id)?.invitation
    }

    /// `setMuted(_:conversations:enqueueing:returnMarks:)` with no return mark to put back.
    public func setMuted(_ muted: Bool, conversations: [ConversationID], enqueueing operations: [Operation]) throws {
        try setMuted(muted, conversations: conversations, enqueueing: operations, returnMarks: [:])
    }

    /// One conversation at a time, for a store that cannot do better (the test doubles that wrap a real store); both
    /// stores override it with one read.
    public func newestUnreadInboxMessages(in conversations: [ConversationID]) throws -> [ConversationID: MessageMetadata] {
        var newest: [ConversationID: MessageMetadata] = [:]
        for id in conversations {
            newest[id] = try messages(in: id).last { $0.isInInbox && !$0.isRead }
        }
        return newest
    }

    /// One at a time, for a store that cannot do better (the test doubles that wrap a real store); both stores
    /// override it with one transaction.
    public func enqueue(_ operations: [Operation]) throws {
        for operation in operations { try enqueue(operation) }
    }

    /// `updateSend` for a whole send: only its state is written.
    public func updateSend(_ send: PendingSend) throws {
        try updateSend(PendingSendSummary(send))
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
