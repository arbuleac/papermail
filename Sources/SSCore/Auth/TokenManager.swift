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
    /// Refreshes still running that a sign-in replaced (`replaceTokens`): their replies are handed to their callers only.
    private var superseded: Set<Int> = []

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

    /// From the cached tokens, else the store; a refresh keeps the scope the reply lists (or the previous one).
    public func grantedScopes(for accountID: AccountID) async -> String? {
        (try? currentTokens(for: accountID))??.scope
    }

    /// A healthy account keeps its cached token for up to an hour, so without this a reconnect that added a scope
    /// would leave answers waiting on the old grant. A refresh still in flight was started with the old refresh
    /// token: its callers still get the token it brings (failing them would read as a cancelled sync), but it is
    /// neither saved nor cached, so it cannot write the old grant over the new, and later callers read the store.
    /// The save runs here, with no suspension around it: a refresh's reply, whose save also runs on this actor, lands
    /// wholly before it (and is overwritten) or wholly after (and is dropped), never between the keychain write and
    /// the bookkeeping. Declared `async`: a synchronous one would lose overload resolution to the protocol's default.
    public func replaceTokens(for accountID: AccountID, saving save: @Sendable () throws -> Void) async throws {
        try save()
        if let inFlight = refreshes[accountID] {
            superseded.insert(inFlight.generation)
            refreshes[accountID] = nil
        }
        cache[accountID] = nil
        invalidated.remove(accountID)
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
            // A sign-in stored new tokens meanwhile (`replaceTokens`): this reply belongs to the old grant.
            if superseded.contains(generation), !Task.isCancelled { return tokens }
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
        superseded.remove(generation)
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
