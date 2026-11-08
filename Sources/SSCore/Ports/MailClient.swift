import Foundation

/// The facade the UI talks to. Reads come from `store`; everything here is a command or a network fetch.
public protocol MailClient: AnyObject {
    var store: MailStoring { get }

    func accounts() throws -> [Account]
    /// Runs the OAuth flow in the system browser, creates the account, and starts its first sync.
    func addAccount(kind: ProviderKind) async throws -> Account
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

    /// Queue a send held for `undoWindow` seconds. Returns the pending send id.
    func send(_ message: OutgoingMessage, undoWindow: TimeInterval) throws -> String
    /// True when the send was still held and is now cancelled.
    func cancelSend(id: String) throws -> Bool

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
}

extension MailClient {
    /// The attachment's bytes, for a caller that shows no progress.
    public func attachmentData(for message: MessageID, attachmentID: String) async throws -> Data {
        try await attachmentData(for: message, attachmentID: attachmentID, expectedSize: 0, progress: nil)
    }
}
