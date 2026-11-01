import Foundation

public struct Account: Hashable, Codable, Sendable, Identifiable {
    public var id: AccountID
    public var kind: ProviderKind
    public var email: String
    public var displayName: String
    /// Hex color (e.g. "#4A90E2") used for the account dot in the unified list and the account strip.
    public var colorHex: String
    public var addedAt: Date

    public init(id: AccountID, kind: ProviderKind, email: String, displayName: String, colorHex: String, addedAt: Date) {
        self.id = id
        self.kind = kind
        self.email = email
        self.displayName = displayName
        self.colorHex = colorHex
        self.addedAt = addedAt
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
