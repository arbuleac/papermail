import Foundation

/// Errors a provider adapter reports to the engine. The engine decides policy (retry, back off, re-auth, reset).
public enum ProviderError: Error, Sendable {
    /// Token invalid or revoked. The engine marks the account `needsReauth`.
    case unauthorized
    /// Rate limited. `retryAfter` is honored when present.
    case throttled(retryAfter: TimeInterval?)
    /// The change cursor is no longer valid (Gmail history expired, Graph delta token gone).
    /// The engine keeps local mail, takes a fresh cursor from a new head page and reconciles the stored mail
    /// behind the live lane (docs/DATA-MODEL.md, "Backfill marks"): a full listing of the mailbox.
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
    /// A reconnect signed in to a different mailbox than the account being reconnected.
    case wrongAccount(expected: String, actual: String)
}

extension AuthError {
    /// The user refused (or dismissed) the keychain prompt, or no prompt could be shown.
    public var isKeychainDenial: Bool {
        guard case .keychain(let status) = self else { return false }
        // errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed; spelled out so this file needs no Security import.
        return [-25293, -128, -25308].contains(status)
    }
}
