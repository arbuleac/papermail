import Foundation

/// OAuth client registration the user creates in Google Cloud Console / Microsoft Entra. See docs/OAUTH-SETUP.md.
public struct OAuthClientConfiguration: Codable, Sendable, Hashable {
    public var kind: ProviderKind
    public var clientID: String
    /// Google "Desktop app" clients ship a secret that Google documents as non-confidential. Microsoft public clients have none.
    public var clientSecret: String?
    /// Microsoft only. "common" allows personal and work accounts.
    public var tenant: String?
    public init(kind: ProviderKind, clientID: String, clientSecret: String? = nil, tenant: String? = nil) {
        self.kind = kind
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tenant = tenant
    }
}

public struct OAuthTokens: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?
    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

/// Durable token storage (Keychain in the app, in-memory in tests).
public protocol TokenStore: Sendable {
    func tokens(for accountID: AccountID) throws -> OAuthTokens?
    func save(_ tokens: OAuthTokens, for accountID: AccountID) throws
    func delete(for accountID: AccountID) throws
}

/// Hands providers a valid access token, refreshing when needed. Throws `ProviderError.unauthorized` when
/// refresh is impossible.
public protocol AccessTokenProvider: Sendable {
    func accessToken(for accountID: AccountID) async throws -> String
    /// Called after a provider receives 401 with a token that looked valid; forces a refresh on next call.
    func invalidateAccessToken(for accountID: AccountID) async
}

/// Runs an interactive sign-in and returns tokens. Implemented by `OAuthFlow`; the engine never sees the browser.
public protocol AccountAuthenticator: Sendable {
    /// `loginHint` names the mailbox a reconnect expects, so the provider preselects it.
    func signIn(kind: ProviderKind, loginHint: String?) async throws -> OAuthTokens
}

extension AccountAuthenticator {
    public func signIn(kind: ProviderKind) async throws -> OAuthTokens {
        try await signIn(kind: kind, loginHint: nil)
    }
}
