import Foundation

/// An apply that changed some of its messages and not others (`MailProvider.apply`). `unapplied` are the ids the
/// provider did not change, or may not have; the rest it did. `error` is why, as the call would have thrown it whole.
/// The outbox keeps only those ids as the operation's targets, so a retry sends them alone and a give-up puts back
/// only them, never a message the provider took. A provider that changed nothing throws `error` itself.
public struct PartialApplyError: Error, Sendable {
    public var unapplied: [String]
    public var error: ProviderError

    public init(unapplied: [String], error: ProviderError) {
        self.unapplied = unapplied
        self.error = error
    }
}
