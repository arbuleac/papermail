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

    /// - Parameters:
    ///   - reference: the "today" the generated mailbox is laid out before.
    ///   - liveInterval: seconds between messages that arrive while the app runs.
    public init(
        reference: Date = Date(),
        liveInterval: TimeInterval = 45,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reference = reference
        self.liveInterval = liveInterval
        self.now = now
    }

    public func provider(for account: Account) -> MailProvider {
        DemoMailProvider(mailbox: mailbox(for: account.id, kind: account.kind))
    }

    func mailbox(for accountID: AccountID, kind: ProviderKind) -> DemoMailbox {
        lock.lock(); defer { lock.unlock() }
        if let existing = mailboxes[accountID] { return existing }
        let mailbox = DemoMailbox(
            profile: DemoProfile.profile(for: kind), accountID: accountID,
            reference: reference, liveInterval: liveInterval, now: now
        )
        mailboxes[accountID] = mailbox
        return mailbox
    }
}
