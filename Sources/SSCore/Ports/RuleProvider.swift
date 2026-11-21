import Foundation

/// The account's server rules, where sender rules live (docs/ARCHITECTURE.md, "Rules"), beside `MailProvider`: Gmail's
/// provider reads and writes Gmail filters, Graph's the inbox rules of Outlook. A provider without server rules (a test
/// double) does not adopt it, and the engine then keeps no rules lane for that account.
///
/// Only the sender's address and the action ever reach the provider. Every call needs `AccountPermission.rules`; the
/// engine asks `hasRulesPermission()` first, which costs no request (the granted scopes come with the token).
public protocol RuleProvider: Sendable {
    /// Whether the account's token holds the rules scope.
    func hasRulesPermission() async -> Bool

    /// Every rule on the server, every page read: those of exactly the shape this app makes for one sender (one address,
    /// archive or Move to Trash, nothing else) as `senderRules`, one entry per server rule, and a count of the rest.
    /// Throws `RuleProviderError` for the rules' own refusals, `ProviderError` for the rest.
    func serverRules() async throws -> ServerRuleListing

    /// Creates the rule for mail from `address` (already normalized) and returns its server id. The lane reads the server
    /// before it creates and adopts an identical rule already there, so a create whose reply was lost is not made twice.
    func createSenderRule(address: String, action: SenderRule.Action) async throws -> String

    /// Deletes the rule. A rule the server no longer has counts as deleted (no throw).
    func deleteRule(serverID: String) async throws
}
