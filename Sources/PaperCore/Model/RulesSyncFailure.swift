import Foundation

/// Why the account's sender rules could not be read or saved (`RulesSyncState.failed`), in words the app shows
/// (`words(for:)`).
public enum RulesSyncFailure: String, Hashable, Sendable {
    /// The server's cap on rules: Gmail's on filters, Exchange's on the size of the inbox rules. A rule set on this Mac
    /// was given up.
    case limitReached
    /// The server refused a rule for good (a refusal that is no limit, no permission and no throttle). A rule set on this
    /// Mac was given up, or one removed is back.
    case refused
    /// The server could not be read for now (the network, the service, a throttle, the token): the lane tries again
    /// after its backoff, and the rules stored stay shown.
    case unreachable

    /// One sentence for Settings › Senders, naming the provider's own word for its rules.
    public func words(for kind: ProviderKind) -> String {
        switch (self, kind) {
        case (.limitReached, .gmail): return "Gmail has too many filters to save this one."
        case (.limitReached, .microsoft): return "Outlook has too many rules to save this one."
        case (.refused, .gmail): return "Gmail didn’t accept this filter."
        case (.refused, .microsoft): return "Outlook didn’t accept this rule."
        case (.unreachable, .gmail): return "Couldn’t reach Gmail. Trying again soon."
        case (.unreachable, .microsoft): return "Couldn’t reach Outlook. Trying again soon."
        }
    }
}
