import Foundation

/// The server rules' own refusals, apart from `ProviderError` (the network, a throttle, the token, the service), so the
/// engine can say what the user can do about them.
public enum RuleProviderError: Error, Sendable, Equatable {
    /// The token lacks the rules scope (Google's 403 `insufficientPermissions`, Graph's 403 `ErrorAccessDenied` on the
    /// rules): a reconnect asks for it.
    case permissionMissing
    /// The server's cap on rules (Gmail's on filters, Exchange's on the size of the inbox rules): this one cannot be
    /// created until some are removed.
    case limitReached
    /// Any other permanent refusal of the request (a 4xx that is no throttle, scope or token).
    case refused
}
