import Foundation

public struct Account: Hashable, Codable, Sendable, Identifiable {
    public var id: AccountID
    public var kind: ProviderKind
    public var email: String
    public var displayName: String
    /// TEMPORARY(quire): the pre-Quire dot colour (e.g. "#4A90E2"), still drawn by the list, the account strip
    /// and Settings. `inkSlot` replaces it; remove this (and stop writing `accounts.color_hex`) once the app
    /// draws `NSColor.qAccount(inkSlot)`.
    public var colorHex: String
    public var addedAt: Date
    /// The account's palette slot, 0 to `AccountInkSlot.count - 1`. The engine assigns it when the account is
    /// added; Settings can move it. The colour itself comes from the design layer.
    public var inkSlot: Int
    /// The monogram the user typed in Settings, at most `Account.monogramMaxLength` characters. Nil means the
    /// UI derives one from the address's domain.
    public var monogram: String?

    /// Settings caps an edited monogram at two characters, and the store enforces the same limit.
    public static let monogramMaxLength = 2

    public init(
        id: AccountID,
        kind: ProviderKind,
        email: String,
        displayName: String,
        colorHex: String,
        addedAt: Date,
        inkSlot: Int = 0,
        monogram: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.email = email
        self.displayName = displayName
        self.colorHex = colorHex
        self.addedAt = addedAt
        self.inkSlot = inkSlot
        self.monogram = monogram
    }

    /// How the store keeps a monogram: trimmed, at most `monogramMaxLength` characters, and nil when nothing
    /// is left, so "derived" has one representation.
    public static func normalizedMonogram(_ monogram: String?) -> String? {
        guard let trimmed = monogram?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(monogramMaxLength))
    }
}

/// What a provider reports about the signed-in mailbox.
public struct AccountProfile: Hashable, Codable, Sendable {
    public var email: String
    public var displayName: String
    public init(email: String, displayName: String) {
        self.email = email
        self.displayName = displayName
    }
}
