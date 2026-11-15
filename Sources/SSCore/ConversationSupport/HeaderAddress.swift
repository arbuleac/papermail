import Foundation

/// One address in a sheet header (spec §5.14, “Copying an address”), named as the shell names it: by field and position
/// (`from:0`, `to:1`, `cc:2`), never by the address itself, so no address travels through a script message and none can
/// reach a log from there. The app reads the address back from the store.
public struct HeaderAddress: Hashable, Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case from, to, cc, bcc
    }

    /// What a copy writes: the address alone (a click, ↩, Space, ⌘C, Copy Address), since that is what any field anywhere
    /// takes, or “Name <address>” (Copy Name and Address).
    public enum Form: String, Sendable {
        case address
        case nameAndAddress
    }

    public var field: Field
    public var index: Int

    /// The sender's address on the name line.
    public static let sender = HeaderAddress(field: .from, index: 0)

    public init(field: Field, index: Int) {
        self.field = field
        self.index = index
    }

    /// Reads the shell's `field:index`. Anything else is nil: the page is not trusted to name more than a position.
    public init?(_ value: String) {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let field = Field(rawValue: String(parts[0])),
              !parts[1].isEmpty, parts[1].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isNumber),
              parts[1].count <= 6, let index = Int(parts[1]) else { return nil }
        // There is one sender.
        guard field != .from || index == 0 else { return nil }
        self.init(field: field, index: index)
    }

    /// What the shell sends: `cc:2`.
    public var value: String {
        field.rawValue + ":" + String(index)
    }

    /// The address as stored, or nil when the position names nothing the header shows. Bcc counts only on mail the user
    /// sent, as `RenderPayloadBuilder.recipientFields` builds the list; an index past the list is a click that raced a
    /// re-render, and an entry with no address (an empty group) is plain text in the list, never a target.
    public func address(in message: MessageMetadata, ownAddresses: Set<String>) -> EmailAddress? {
        let list: [EmailAddress]
        switch field {
        case .from:
            list = message.from.map { [$0] } ?? []
        case .to:
            list = message.to
        case .cc:
            list = message.cc
        case .bcc:
            let isFromMe = message.from.map { ownAddresses.contains($0.address.lowercased()) } ?? false
            list = isFromMe ? message.bcc : []
        }
        guard list.indices.contains(index) else { return nil }
        let address = list[index]
        return address.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : address
    }

    /// What the pasteboard takes: the address as stored, or `AddressListParser.format` of it, the name quoted where it
    /// needs to be, as the composer's tokens copy. The user's own address carries the name the header gives, never “me”.
    public static func text(of address: EmailAddress, form: Form) -> String {
        switch form {
        case .address: return address.address
        case .nameAndAddress: return AddressListParser.format(address)
        }
    }

    /// The header gives a name apart from the address: only then does the person menu offer Copy Name and Address, which
    /// would otherwise copy the address alone a second way.
    public static func hasName(_ address: EmailAddress) -> Bool {
        guard let name = displayName(of: address) else { return false }
        return name != address.address
    }

    /// What VoiceOver says once the pasteboard has it: “Copied ben@contoso.test.”, “Copied Ben Carter, ben@contoso.test.”
    public static func announcement(of address: EmailAddress, form: Form) -> String {
        if form == .nameAndAddress, hasName(address), let name = displayName(of: address) {
            return "Copied \(name), \(address.address)."
        }
        return "Copied \(address.address)."
    }

    /// Show Mail from This Person: the search field's words, `from:ben@contoso.test`, quoted only when the address holds
    /// a space, which would otherwise end the term.
    public static func fromQuery(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains(where: \.isWhitespace) ? "from:\"" + trimmed + "\"" : "from:" + trimmed
    }

    private static func displayName(of address: EmailAddress) -> String? {
        guard let name = address.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}
