import Foundation

/// The facade the UI talks to. Reads come from `store`; everything here is a command or a network fetch.
public protocol MailClient: AnyObject {
    var store: MailStoring { get }

    func accounts() throws -> [Account]
    /// Runs the OAuth flow in the system browser, creates the account, and starts its first sync.
    /// `tenant` (Microsoft) is the one `MicrosoftAccountType` chose; nil signs in through the configured tenant.
    func addAccount(kind: ProviderKind, tenant: String?) async throws -> Account
    /// Signs `account` in again (it is in `needsReauth`), steering the browser to its mailbox. Throws
    /// `AuthError.wrongAccount` when the user signs in to another mailbox; nothing is added then.
    func reconnect(_ account: Account) async throws -> Account
    func removeAccount(_ id: AccountID) async throws

    /// Trigger a change poll now (all accounts when nil), because the user asked: an account waiting for sign-in
    /// tries its token again. Returns immediately.
    func syncNow(accountID: AccountID?)

    /// Check every account now because the moment suggests new mail (the app came to the front, the Mac woke, the
    /// network came back), not because the user asked: an account waiting for sign-in keeps waiting, so its
    /// keychain prompt never appears unasked. The outbox is looked at too, so a send that fell due while the Mac
    /// slept goes at once. Returns immediately.
    func checkForMail()

    /// Whether the app is frontmost. The live lane checks for new mail every 5 s while it is and every 30 s
    /// while it is not; the app calls this on activation and resignation.
    func setAppActive(_ isActive: Bool)

    /// Apply a change to every message of a conversation. Local state updates before this returns.
    func perform(_ change: MetadataChange, on conversation: ConversationID) throws
    func perform(_ change: MetadataChange, on messages: [MessageID]) throws

    /// Snoozes, reschedules or ends snoozes (Later; `Snooze.Change.until` nil ends one) together with `steps`, in one
    /// store transaction: the steps are applied and queued as operations, as `perform` queues them, and the snooze timer
    /// looks again. Snoozing archives (the caller passes the archive step); ending a snooze from Later may move the
    /// conversation back (⇧I) or leave it archived (E); an undo passes the inverse steps with the snoozes and return
    /// marks the action ended (`Snooze.Change.returnedAt`). Local state updates before this returns.
    func setSnoozes(_ changes: [Snooze.Change], performing steps: [MailActionRecord.Step]) throws

    /// Mutes or unmutes `conversations` together with `steps`, in one store transaction: the steps are applied and queued
    /// as `perform` queues them (muting passes the archive of what is in the Inbox; an undo passes the inverse, and the
    /// return marks the mute's archive ended, `MailActionRecord.returnedAt`). While a conversation is muted, mail
    /// arriving in it is archived in the write that stores it, so it never reaches the Inbox and no notification fires.
    /// Local state updates before this returns.
    func setMuted(_ muted: Bool, conversations: [ConversationID], performing steps: [MailActionRecord.Step],
                  returnMarks: [ConversationID: Date]) throws

    /// Sets the account's rule for mail from `address` (nil removes it) together with `steps`, in one store transaction:
    /// the steps are applied and queued as `perform` queues them (the rule's change on that sender's mail in the
    /// conversation it was set from; an undo passes the inverse and the rule the address had). From then on mail from the
    /// address is archived or moved to the Trash in the write that stores it. Local state updates before this returns.
    func setSenderRule(_ action: SenderRule.Action?, for address: String, accountID: AccountID,
                       performing steps: [MailActionRecord.Step]) throws

    /// Unsubscribes as the user asked (spec §5.14), in one transaction: archives `messages` (the conversation's
    /// messages the archive changes; empty when it changes none), ends the snoozes of `snoozed` (a snoozed conversation
    /// is archived already, and unsubscribing leaves it so rather than bringing it back at its time, as E does in Later)
    /// and, for a one-click or mailto method, queues the request, which the engine sends. A `browser` method queues no
    /// request: the app opens the page itself. Local state updates before this returns.
    func unsubscribe(_ method: UnsubscribeMethod, accountID: AccountID, archiving messages: [MessageID],
                     endingSnoozesOf snoozed: [ConversationID]) throws

    /// Answer the invitation `message` carries: the answer is recorded on the message at once (the card shows it) and
    /// queued as an operation the engine replays to the provider. Throws `StoreError.notFound` when the message has no
    /// stored invitation and `StoreError.conflict` when it cannot be answered (a cancellation, the user's own event, an
    /// invitation that does not name the account, one a later message in the conversation updates). An answer changed
    /// before the earlier one went out replaces it: only the latest reaches the organizer.
    /// An account without permission to update its calendar keeps the answer waiting and asks to reconnect
    /// (`AccountSyncStatus.permissionsNeeded`); once granted, the answer goes out.
    func answerInvitation(_ response: InvitationResponse, to message: MessageID) throws

    /// Queue a send held for `undoWindow` seconds. Returns the pending send id.
    func send(_ message: OutgoingMessage, undoWindow: TimeInterval) throws -> String
    /// True when the send was still held (in its undo window, or waiting for its Send Later time) and is now cancelled.
    func cancelSend(id: String) throws -> Bool
    /// Send Later (spec §5.23): queue a send held until `date` on the wall clock, sent then while the engine runs, with
    /// `draftID`, the draft kept on this Mac it was written in. A time that passes while the engine is stopped (the app
    /// closed) is not sent when it starts again: it becomes `missed` and waits for `sendNow` or `cancelSend`. A delivered
    /// send that carries a draft id stays in the outbox as `sent` until the caller deletes it (`MailStoring.deleteSend`),
    /// once it has removed the draft. Returns the pending send id.
    func scheduleSend(_ message: OutgoingMessage, at date: Date, draftID: UUID?) throws -> String
    /// Sends these Send Later messages now, waiting or missed: the user said Send Now. Returns the ids still held.
    @discardableResult
    func sendNow(_ ids: [String]) throws -> [String]

    /// Asks the providers of `accountIDs` (every account when nil) to search for `text` as typed, under their own search
    /// rules (Gmail's `from:` and `subject:`, Outlook's KQL), for mail this Mac does not have yet: during a first
    /// download, or for bodies Keep mail on this Mac evicted. Hits the store lacks are written as metadata, one
    /// transaction per account, so they list and search like any other mail; their bodies download when opened. Hits
    /// already stored change nothing. Charged to each account's quota as live spend. An account whose search fails is
    /// named in the result rather than thrown, so the others' hits still arrive; cancelling the task ends the search
    /// (throwing `CancellationError`) without changing what it already stored.
    func searchServer(for text: String, accountIDs: [AccountID]?) async throws -> ServerSearchResult

    /// Returns the stored body, fetching and sanitizing it first when missing.
    func ensureBody(for message: MessageID) async throws -> StoredBody
    /// The reader is showing these messages, with a body or not: Keep mail on this Mac leaves their bodies whole until
    /// the app quits, so a conversation on screen keeps its body when a clean-up runs and a backfill fetching one stores
    /// it whole. Call it before reading the bodies: a clean-up batch reads the marks inside its write. Cheap and
    /// synchronous.
    func keepBodies(of messages: [MessageID])
    /// The attachment's bytes, from this Mac's cache or downloaded once (callers asking at the same time share the
    /// download). `expectedSize` is the size the body listed (`AttachmentInfo.sizeBytes`, 0 when unknown), which lets
    /// a provider that streams say how far it has got; `progress` then hears fractions from 0 to 1, rising, at most
    /// about ten a second, on no particular thread. It hears nothing for a file already cached, and nothing until
    /// the end for a download whose size is unknown.
    func attachmentData(for message: MessageID, attachmentID: String, expectedSize: Int,
                        progress: (@Sendable (Double) -> Void)?) async throws -> Data

    /// Current status per account, delivered on the main thread, first with the current value.
    func observeStatus(onChange: @escaping @Sendable ([AccountSyncStatus]) -> Void) -> StoreObservation

    // MARK: Calendar (docs/ARCHITECTURE.md, "Calendar")

    /// Sets time aside (B, a row dropped on the calendar): `event` is stored at once as `creating` and the engine
    /// creates it on the provider of its account. Throws `StoreError.conflict` when its id is taken.
    func addCalendarEvent(_ event: CalendarEvent) throws
    /// Removes an event (Remove in its details, or the undo of a block): it leaves the calendar at once and the engine
    /// deletes it on the provider. Returns the event as it was, for an undo.
    @discardableResult
    func removeCalendarEvent(id: String) throws -> CalendarEvent?
    /// Puts back an event `removeCalendarEvent` returned (its undo); the engine creates it again if it must. Returns
    /// the row as it now stands (it may have a new id).
    @discardableResult
    func restoreCalendarEvent(_ event: CalendarEvent) throws -> CalendarEvent
    /// Reads the calendars of `accountID` (every account when nil) at their next chance instead of waiting for the
    /// calendar's own interval: at once when an account's calendar lane is idle, after the turn it is taking otherwise,
    /// and once the account may send again while it waits for sign-in or its first live cycle (a failure's backoff is
    /// waited out too). For when the calendar was just shown, or a day outside the stored window was asked for. Returns
    /// immediately.
    func refreshCalendars(accountID: AccountID?)
    /// Signs `account` in again asking for the calendar scope too (Connect, from the calendar's foot); once granted,
    /// its calendar is read. Throws as `reconnect` does.
    func connectCalendar(_ account: Account) async throws -> Account
}

extension MailClient {
    public func addCalendarEvent(_ event: CalendarEvent) throws {
        try store.addCalendarEvent(event)
    }

    @discardableResult
    public func removeCalendarEvent(id: String) throws -> CalendarEvent? {
        try store.removeCalendarEvent(id: id)
    }

    @discardableResult
    public func restoreCalendarEvent(_ event: CalendarEvent) throws -> CalendarEvent {
        try store.restoreCalendarEvent(event)
    }

    public func refreshCalendars(accountID: AccountID?) {}

    public func connectCalendar(_ account: Account) async throws -> Account {
        try await reconnect(account)
    }
}

extension MailClient {
    /// `setMuted(_:conversations:performing:returnMarks:)` with no return mark to put back.
    public func setMuted(_ muted: Bool, conversations: [ConversationID], performing steps: [MailActionRecord.Step]) throws {
        try setMuted(muted, conversations: conversations, performing: steps, returnMarks: [:])
    }

    /// `unsubscribe(_:accountID:archiving:endingSnoozesOf:)` for a conversation that is not snoozed.
    public func unsubscribe(_ method: UnsubscribeMethod, accountID: AccountID, archiving messages: [MessageID]) throws {
        try unsubscribe(method, accountID: accountID, archiving: messages, endingSnoozesOf: [])
    }

    /// The attachment's bytes, for a caller that shows no progress.
    public func attachmentData(for message: MessageID, attachmentID: String) async throws -> Data {
        try await attachmentData(for: message, attachmentID: attachmentID, expectedSize: 0, progress: nil)
    }
}

extension MailClient {
    /// Through the configured tenant (Gmail, the demo, and Microsoft before the user chose a kind of account).
    public func addAccount(kind: ProviderKind) async throws -> Account {
        try await addAccount(kind: kind, tenant: nil)
    }
}
