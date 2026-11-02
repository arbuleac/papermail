import Foundation

/// Whether the composer's Send is enabled and what its tooltip says (spec §5.23). Send is disabled only while
/// the message has no valid recipient: “Add a recipient”, or “Fix the address …” when every recipient is
/// invalid. A valid recipient beside an invalid one leaves Send enabled, as the specimen draws it; pressing it
/// commits and validates, and lands on the address to fix instead of sending.
public struct ComposeSendReadiness: Equatable, Sendable {
    public var isEnabled: Bool
    public var tooltip: String

    public init(isEnabled: Bool, tooltip: String) {
        self.isEnabled = isEnabled
        self.tooltip = tooltip
    }

    public static let sendTooltip = "Send  ⌘↩"

    /// `tokens` are every recipient field's tokens; `pendingText` the text still being typed in each field.
    /// Typed text counts once it parses as a valid address; until then it is not shown as invalid either,
    /// because the user is still writing it.
    public static func evaluate(tokens: [EmailAddress], pendingText: [String]) -> ComposeSendReadiness {
        let typedValid = pendingText.flatMap(AddressListParser.validAddresses(in:))
        let invalid = AddressListParser.invalidEntries(in: tokens)
        if tokens.count - invalid.count + typedValid.count > 0 {
            return ComposeSendReadiness(isEnabled: true, tooltip: sendTooltip)
        }
        if let bad = invalid.first {
            return ComposeSendReadiness(isEnabled: false, tooltip: "Fix the address \(bad.address)")
        }
        return ComposeSendReadiness(isEnabled: false, tooltip: "Add a recipient")
    }
}
