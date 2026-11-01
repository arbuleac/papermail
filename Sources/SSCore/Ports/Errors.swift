import Foundation

/// Errors a provider adapter reports to the engine. The engine decides policy (retry, back off, re-auth, reset).
public enum ProviderError: Error, Sendable {
    /// Token invalid or revoked. The engine marks the account `needsReauth`.
    case unauthorized
    /// Rate limited. `retryAfter` is honored when present.
    case throttled(retryAfter: TimeInterval?)
    /// The change cursor is no longer valid (Gmail history expired, Graph delta token gone).
    /// The engine wipes the account's local data and bootstraps again.
    case resetRequired
    case notFound
    case network(String)
    case decoding(String)
    case server(status: Int, message: String)
    case cancelled
}

public enum StoreError: Error, Sendable {
    case notFound
    case conflict(String)
    case underlying(String)
}

public enum AuthError: Error, Sendable {
    case missingClientConfiguration(ProviderKind)
    case userCancelled
    case invalidResponse(String)
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case keychain(status: Int32)
}
