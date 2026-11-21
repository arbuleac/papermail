import Foundation

/// One read of the account's server rules (`RuleProvider.serverRules()`).
public struct ServerRuleListing: Hashable, Sendable {
    /// The rules this app can show, one per server rule, in the server's order.
    public var senderRules: [ServerSenderRule]
    /// The server's other rules, which the app counts and never changes.
    public var otherCount: Int
    /// The requests the read made, which the engine charges to the account.
    public var requestCount: Int

    public init(senderRules: [ServerSenderRule], otherCount: Int, requestCount: Int) {
        self.senderRules = senderRules
        self.otherCount = otherCount
        self.requestCount = requestCount
    }
}
