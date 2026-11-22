import Foundation

public struct Account: Hashable, Codable, Sendable, Identifiable {
    public var id: AccountID
    public var kind: ProviderKind
    public var email: String
    public var displayName: String
    public var addedAt: Date
    /// The account's palette slot, 0 to `AccountInkSlot.count - 1`. The engine assigns it when the account is
    /// added; Settings can move it. The colour itself comes from the design layer.
    public var inkSlot: Int
    /// The monogram the user typed in Settings, at most `Account.monogramMaxLength` characters. Nil means the
    /// UI derives one from the address's domain.
    public var monogram: String?
    /// The signature the user set in Settings, as the composer's own HTML subset (`ComposerHTMLExporter`): what the
    /// composer inserts on new messages, replies and forwards. Nil means none, the default. A local setting: it is
    /// never read from or written to the provider.
    public var signature: String?
    /// The face the user chose in Settings (Quire §5.55); `automatic` until they choose one.
    public var face: AccountFace

    /// Settings caps an edited monogram at two characters, and the store enforces the same limit.
    public static let monogramMaxLength = 2

    public init(
        id: AccountID,
        kind: ProviderKind,
        email: String,
        displayName: String,
        addedAt: Date,
        inkSlot: Int = 0,
        monogram: String? = nil,
        signature: String? = nil,
        face: AccountFace = .automatic
    ) {
        self.id = id
        self.kind = kind
        self.email = email
        self.displayName = displayName
        self.addedAt = addedAt
        self.inkSlot = inkSlot
        self.monogram = monogram
        self.signature = signature
        self.face = face
    }

    /// How the store keeps a monogram: trimmed, at most `monogramMaxLength` characters, and nil when nothing
    /// is left, so "derived" has one representation.
    public static func normalizedMonogram(_ monogram: String?) -> String? {
        guard let monogram else { return nil }
        // Trimmed again after the cut: "A B" cut to two characters ends in a space, which would draw an
        // off-centre one-letter monogram.
        let cut = String(monogram.trimmingCharacters(in: .whitespacesAndNewlines).prefix(monogramMaxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? nil : cut
    }

    /// How the store keeps a signature: nil when it is nil or only white space, so "none" has one representation.
    /// The HTML itself is kept as Settings exported it; only the white space around it goes.
    public static func normalizedSignature(_ signature: String?) -> String? {
        guard let trimmed = signature?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// What a provider reports about the signed-in mailbox.
public struct AccountProfile: Hashable, Codable, Sendable {
    public var email: String
    public var displayName: String
    /// The mailbox's own id where the provider has one (Graph's `/me` id): one address can be a work and a personal
    /// Microsoft account, two mailboxes, and only this tells them apart. Nil where the address is the mailbox (Gmail).
    public var userID: String?
    public init(email: String, displayName: String, userID: String? = nil) {
        self.email = email
        self.displayName = displayName
        self.userID = userID
    }
}
