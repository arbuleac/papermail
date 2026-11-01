import Foundation

/// Access tokens for demo accounts. The demo provider never checks them; the engine only needs someone to ask.
public struct DemoTokenProvider: AccessTokenProvider {
    public init() {}

    public func accessToken(for accountID: AccountID) async throws -> String {
        "demo-access-\(accountID.rawValue)"
    }

    public func invalidateAccessToken(for accountID: AccountID) async {}
}
