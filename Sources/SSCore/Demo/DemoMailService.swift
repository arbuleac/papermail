import Foundation

/// The pretend mail servers behind demo mode: one mailbox per account, created the first time a provider for
/// that account asks. Hand `provider(for:)` to `MailEngine` as its provider factory.
///
/// Mailboxes live as long as the service, so every provider the engine makes for an account sees the same
/// state, and an action applied through one is visible to the next bootstrap or metadata call.
public final class DemoMailService: @unchecked Sendable {
    private let lock = NSLock()
    private var mailboxes: [AccountID: DemoMailbox] = [:]
    private let reference: Date
    private let liveInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let restore: (@Sendable (MessageID) -> MessageMetadata?)?

    /// - Parameters:
    ///   - reference: the "today" the generated mailbox is laid out before.
    ///   - liveInterval: seconds between messages that arrive while the app runs.
    ///   - restore: the state an earlier run left for a generated message, usually a read of the demo store.
    ///     The mailbox is regenerated on every launch, but the store outlives it; without this the server
    ///     would forget archives, stars and read state (and move dates to the new "today"), and the next
    ///     change it logs for a message would overwrite the store with the regenerated state.
    public init(
        reference: Date = Date(),
        liveInterval: TimeInterval = 45,
        now: @escaping @Sendable () -> Date = { Date() },
        restore: (@Sendable (MessageID) -> MessageMetadata?)? = nil
    ) {
        self.reference = reference
        self.liveInterval = liveInterval
        self.now = now
        self.restore = restore
    }

    public func provider(for account: Account) -> MailProvider {
        DemoMailProvider(mailbox: mailbox(for: account.id, kind: account.kind))
    }

    func mailbox(for accountID: AccountID, kind: ProviderKind) -> DemoMailbox {
        lock.lock(); defer { lock.unlock() }
        if let existing = mailboxes[accountID] { return existing }
        let mailbox = DemoMailbox(
            profile: DemoProfile.profile(for: kind), accountID: accountID,
            reference: reference, liveInterval: liveInterval, now: now, restore: restore
        )
        mailboxes[accountID] = mailbox
        return mailbox
    }
}
