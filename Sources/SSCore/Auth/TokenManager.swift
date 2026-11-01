import Foundation
import os

/// Hands providers a usable access token, refreshing through the token endpoint when the stored one is about
/// to expire. One refresh runs per account at a time; concurrent callers share its result.
public actor TokenManager: AccessTokenProvider {
    /// Tokens expiring sooner than this are refreshed up front so a request never leaves with a token that
    /// dies in flight.
    public static let refreshLeeway: TimeInterval = 60

    private static let logger = Logger(subsystem: "io.supersparrow.mac", category: "auth")

    private let tokenStore: TokenStore
    private let configurations: ClientConfigurationStore
    private let kinds: @Sendable (AccountID) -> ProviderKind?
    private let session: URLSession
    private let now: @Sendable () -> Date

    private struct Refresh {
        var generation: Int
        var task: Task<OAuthTokens, Error>
    }

    private var cache: [AccountID: OAuthTokens] = [:]
    private var invalidated: Set<AccountID> = []
    private var refreshes: [AccountID: Refresh] = [:]
    private var refreshGeneration = 0

    /// `kinds` resolves an account to its provider so the right endpoint and client registration are used.
    public init(
        tokenStore: TokenStore,
        configurations: ClientConfigurationStore,
        kinds: @escaping @Sendable (AccountID) -> ProviderKind?,
        session: URLSession = .shared
    ) {
        self.init(tokenStore: tokenStore, configurations: configurations, kinds: kinds, session: session, now: { Date() })
    }

    init(
        tokenStore: TokenStore,
        configurations: ClientConfigurationStore,
        kinds: @escaping @Sendable (AccountID) -> ProviderKind?,
        session: URLSession,
        now: @escaping @Sendable () -> Date
    ) {
        self.tokenStore = tokenStore
        self.configurations = configurations
        self.kinds = kinds
        self.session = session
        self.now = now
    }

    // MARK: AccessTokenProvider

    public func accessToken(for accountID: AccountID) async throws -> String {
        if let inFlight = refreshes[accountID] {
            return try await inFlight.task.value.accessToken
        }
        guard let current = try currentTokens(for: accountID) else {
            throw ProviderError.unauthorized
        }
        if !invalidated.contains(accountID), current.expiresAt.timeIntervalSince(now()) > Self.refreshLeeway {
            return current.accessToken
        }
        return try await startRefresh(for: accountID).value.accessToken
    }

    public func invalidateAccessToken(for accountID: AccountID) {
        cache[accountID] = nil
        invalidated.insert(accountID)
    }

    // MARK: Store coordination

    /// Persists tokens from a fresh sign-in and primes the cache, so the first request after adding an
    /// account does not go back to the store.
    public func store(_ tokens: OAuthTokens, for accountID: AccountID) throws {
        try tokenStore.save(tokens, for: accountID)
        cache[accountID] = tokens
        invalidated.remove(accountID)
    }

    /// Deletes the account's tokens everywhere. An in-flight refresh finishes but its result is dropped, even
    /// when the token endpoint has already answered.
    public func removeTokens(for accountID: AccountID) throws {
        refreshes[accountID]?.task.cancel()
        refreshes[accountID] = nil
        cache[accountID] = nil
        invalidated.remove(accountID)
        try tokenStore.delete(for: accountID)
    }

    // MARK: Refresh

    private func currentTokens(for accountID: AccountID) throws -> OAuthTokens? {
        if let cached = cache[accountID] {
            return cached
        }
        let stored = try tokenStore.tokens(for: accountID)
        cache[accountID] = stored
        return stored
    }

    private func startRefresh(for accountID: AccountID) -> Task<OAuthTokens, Error> {
        if let inFlight = refreshes[accountID] {
            return inFlight.task
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        // The closure inherits this actor's isolation, so the bookkeeping below runs serialized with callers.
        let task = Task { [self] in
            defer { finishRefresh(for: accountID, generation: generation) }
            let tokens = try await performRefresh(for: accountID)
            // The reply can land after `removeTokens` ran while the actor was busy elsewhere: the slot is then
            // gone (or a newer refresh owns it) and saving would put the deleted credentials back in the Keychain.
            guard !Task.isCancelled, refreshes[accountID]?.generation == generation else {
                throw ProviderError.cancelled
            }
            try tokenStore.save(tokens, for: accountID)
            cache[accountID] = tokens
            invalidated.remove(accountID)
            return tokens
        }
        refreshes[accountID] = Refresh(generation: generation, task: task)
        return task
    }

    /// Clears only this refresh's slot: `removeTokens` may already have dropped it and a newer refresh may
    /// have taken its place.
    private func finishRefresh(for accountID: AccountID, generation: Int) {
        guard refreshes[accountID]?.generation == generation else { return }
        refreshes[accountID] = nil
    }

    private func performRefresh(for accountID: AccountID) async throws -> OAuthTokens {
        guard let kind = kinds(accountID) else {
            throw ProviderError.notFound
        }
        // The store, not the cache, is the authority on refresh tokens: a re-authorization elsewhere may have
        // replaced them since this actor last looked.
        guard let stored = try tokenStore.tokens(for: accountID) else {
            throw ProviderError.unauthorized
        }
        guard let refreshToken = stored.refreshToken, !refreshToken.isEmpty else {
            throw ProviderError.unauthorized
        }
        let configuration = try configurations.configuration(for: kind)
        var form: [(name: String, value: String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", configuration.clientID),
        ]
        switch kind {
        case .gmail:
            if let secret = configuration.clientSecret, !secret.isEmpty {
                form.append(("client_secret", secret))
            }
        case .microsoft:
            // Entra mints the access token for the audience named here; omitting it can yield a token Graph rejects.
            form.append(("scope", stored.scope ?? OAuthEndpoints.microsoftScope))
        }
        let url = OAuthEndpoints.tokenURL(for: kind, tenant: configuration.tenant)
        do {
            let response = try await TokenEndpoint.post(form: form, to: url, session: session)
            Self.logger.debug("Refreshed access token for account \(accountID.rawValue, privacy: .public)")
            return response.tokens(issuedAt: now(), previous: stored)
        } catch is CancellationError {
            throw ProviderError.cancelled
        } catch let error as TokenEndpointError {
            if error.requiresReauthorization {
                Self.logger.info("Refresh token for account \(accountID.rawValue, privacy: .public) was rejected; sign-in required")
                throw ProviderError.unauthorized
            }
            if case let .transport(message) = error {
                throw ProviderError.network(message)
            }
            throw AuthError.refreshFailed(error.message)
        }
    }
}
