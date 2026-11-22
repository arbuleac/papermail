import Foundation

/// One rule on the server that this app can show as a sender rule (`RuleProvider.serverRules()`): a Gmail filter or an
/// Outlook inbox rule of exactly the shape the app creates, for one address. Each server rule is listed on its own; the
/// store folds several for one address into one row (`MailStoring.replaceServerSenderRules`).
public struct ServerSenderRule: Hashable, Sendable {
    /// The provider's id of the rule.
    public var serverID: String
    /// Normalized as `SenderRule.normalizedAddress`.
    public var address: String
    public var action: SenderRule.Action

    public init(serverID: String, address: String, action: SenderRule.Action) {
        self.serverID = serverID
        self.address = SenderRule.normalizedAddress(address)
        self.action = action
    }

    /// The address a server rule's condition names, normalized, when it names exactly one address and nothing else; nil
    /// for anything a provider would read as more (several addresses, `OR`, a group in braces or brackets, quotes, a
    /// wildcard, a negation, a display name, a bare domain). Gmail's `from` and Outlook's `fromAddresses` are both read
    /// through this, so a rule this app would not have made is never shown as one it did.
    public static func singleAddress(_ text: String) -> String? {
        let address = SenderRule.normalizedAddress(text)
        guard !address.isEmpty, address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              address.rangeOfCharacter(from: forbidden) == nil, !address.hasPrefix("-") else { return nil }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else {
            return nil
        }
        return address
    }

    /// Characters that make a condition more than one plain address in Gmail's search grammar or a mail header.
    private static let forbidden = CharacterSet(charactersIn: "\"(){}[]<>*,;:|\\")
}
