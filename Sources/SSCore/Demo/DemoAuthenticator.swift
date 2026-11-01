import Foundation

/// Signs in to a demo mailbox without a browser. The provider kind picks the profile (there is one per kind),
/// so the tokens only need to look plausible; `DemoMailProvider.profile()` answers with the same identity.
public struct DemoAuthenticator: AccountAuthenticator {
    public init() {}

    public func signIn(kind: ProviderKind) async throws -> OAuthTokens {
        let profile = DemoProfile.profile(for: kind)
        return OAuthTokens(
            accessToken: "demo-access-\(kind.rawValue)",
            refreshToken: "demo-refresh-\(profile.email)",
            expiresAt: Date().addingTimeInterval(365 * 86_400),
            scope: "demo"
        )
    }
}
