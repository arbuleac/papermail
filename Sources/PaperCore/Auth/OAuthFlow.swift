import CoreServices
import Foundation
import os

/// Interactive sign-in: PKCE authorization code flow through the system browser with a loopback redirect
/// (RFC 8252 §7.3). The engine only ever sees the resulting `OAuthTokens`.
public final class OAuthFlow: AccountAuthenticator, Sendable {
    /// How long the browser may take before the sign-in is abandoned.
    public static let defaultTimeout: TimeInterval = 5 * 60

    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "auth")

    private let configurations: ClientConfigurationStore
    private let session: URLSession
    private let opener: @Sendable (URL) -> Void
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date

    /// `opener` receives the authorization URL; the default hands it to the user's browser through
    /// LaunchServices, which keeps PaperCore free of AppKit. The app may pass `NSWorkspace.shared.open` instead.
    public convenience init(
        configurations: ClientConfigurationStore,
        session: URLSession = .shared,
        opener: @escaping @Sendable (URL) -> Void = { OAuthFlow.openInDefaultBrowser($0) }
    ) {
        self.init(configurations: configurations, session: session, opener: opener, timeout: OAuthFlow.defaultTimeout, now: { Date() })
    }

    init(
        configurations: ClientConfigurationStore,
        session: URLSession,
        opener: @escaping @Sendable (URL) -> Void,
        timeout: TimeInterval,
        now: @escaping @Sendable () -> Date
    ) {
        self.configurations = configurations
        self.session = session
        self.opener = opener
        self.timeout = timeout
        self.now = now
    }

    public func signIn(kind: ProviderKind, loginHint: String?) async throws -> OAuthTokens {
        try await signIn(kind: kind, loginHint: loginHint, permissions: [])
    }

    public func signIn(kind: ProviderKind, loginHint: String?, permissions: Set<AccountPermission>) async throws -> OAuthTokens {
        try await signIn(kind: kind, loginHint: loginHint, permissions: permissions, tenant: nil)
    }

    public func signIn(kind: ProviderKind, loginHint: String?, permissions: Set<AccountPermission>, tenant: String?) async throws -> OAuthTokens {
        var configuration = try configurations.configuration(for: kind)
        let tenant = kind == .microsoft ? tenant : nil
        if let tenant { configuration.tenant = tenant }
        let pkce = PKCE()
        let state = Data.secureRandom(count: 16).base64URLEncodedString()
        let listener = LoopbackRedirectListener(expectedState: state, callbackPath: OAuthEndpoints.redirectPath(for: kind))
        defer { listener.stop() }

        let port = try await listener.start()
        try Task.checkCancellation()
        let redirectURI = OAuthEndpoints.redirectURI(for: kind, port: port)
        let authorizationURL = OAuthEndpoints.authorizationRequestURL(
            configuration: configuration,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: pkce.challenge,
            loginHint: loginHint,
            permissions: permissions
        )
        Self.logger.debug("Starting \(kind.rawValue, privacy: .public) sign-in on loopback port \(port, privacy: .public)")
        opener(authorizationURL)

        let callback = try await waitForCallback(on: listener)
        // The listener already matched state; checking again here keeps the guarantee local to this function.
        guard callback.state == state else {
            throw AuthError.invalidResponse("Authorization response state did not match the request")
        }
        var tokens = try await exchange(code: callback.code, verifier: pkce.verifier, redirectURI: redirectURI, configuration: configuration)
        tokens.tenant = tenant
        return tokens
    }

    /// Opens `url` with the default handler via LaunchServices.
    public static func openInDefaultBrowser(_ url: URL) {
        let status = LSOpenCFURLRef(url as CFURL, nil)
        if status != noErr {
            logger.error("LaunchServices could not open the authorization URL (status \(status, privacy: .public))")
        }
    }

    private func waitForCallback(on listener: LoopbackRedirectListener) async throws -> LoopbackCallback {
        let timeout = self.timeout
        do {
            return try await withThrowingTaskGroup(of: LoopbackCallback.self) { group in
                group.addTask { try await listener.callback() }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    // Treated as the user walking away: nothing arrived, nothing to retry automatically.
                    throw AuthError.userCancelled
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw AuthError.userCancelled
                }
                return first
            }
        } catch is CancellationError {
            // Whichever child noticed the cancellation first, callers see one error for "the user gave up".
            throw AuthError.userCancelled
        }
    }

    private func exchange(code: String, verifier: String, redirectURI: String, configuration: OAuthClientConfiguration) async throws -> OAuthTokens {
        var form: [(name: String, value: String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", configuration.clientID),
            ("code_verifier", verifier),
        ]
        // Google desktop clients carry a (non-confidential) secret the token endpoint still insists on;
        // Entra public clients must not send one.
        if configuration.kind == .gmail, let secret = configuration.clientSecret, !secret.isEmpty {
            form.append(("client_secret", secret))
        }
        let url = OAuthEndpoints.tokenURL(for: configuration.kind, tenant: configuration.tenant)
        do {
            let response = try await TokenEndpoint.post(form: form, to: url, session: session)
            return response.tokens(issuedAt: now())
        } catch is CancellationError {
            throw AuthError.userCancelled
        } catch let error as TokenEndpointError {
            throw AuthError.tokenExchangeFailed(error.message)
        }
    }
}
