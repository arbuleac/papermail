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
    /// keychain prompt never appears unasked. Returns immediately.
    func checkForMail()

    /// Whether the app is frontmost. The live lane checks for new mail every 5 s while it is and every 30 s
    /// while it is not; the app calls this on activation and resignation.
    func setAppActive(_ isActive: Bool)

    /// Apply a change to every message of a conversation. Local state updates before this returns.
    func perform(_ change: MetadataChange, on conversation: ConversationID) throws
    func perform(_ change: MetadataChange, on messages: [MessageID]) throws

    /// Queue a send held for `undoWindow` seconds. Returns the pending send id.
    func send(_ message: OutgoingMessage, undoWindow: TimeInterval) throws -> String
    /// True when the send was still held and is now cancelled.
    func cancelSend(id: String) throws -> Bool

    /// Returns the stored body, fetching and sanitizing it first when missing.
    func ensureBody(for message: MessageID) async throws -> StoredBody
    func attachmentData(for message: MessageID, attachmentID: String) async throws -> Data

    /// Current status per account, delivered on the main thread, first with the current value.
    func observeStatus(onChange: @escaping @Sendable ([AccountSyncStatus]) -> Void) -> StoreObservation
}
