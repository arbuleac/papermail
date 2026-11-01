import Foundation

/// Which mail service an account lives on.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case gmail
    case microsoft
}

/// Stable local identifier for an account (a UUID string created when the account is added).
public struct AccountID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }
}

/// A provider message id (Gmail message id or Graph message id), scoped to the account it came from.
public struct MessageID: Hashable, Codable, Sendable {
    public let accountID: AccountID
    public let providerID: String
    public init(accountID: AccountID, providerID: String) {
        self.accountID = accountID
        self.providerID = providerID
    }
}

/// A provider thread id (Gmail threadId or Graph conversationId), scoped to the account it came from.
/// Conversations are never merged across accounts or providers.
public struct ConversationID: Hashable, Codable, Sendable {
    public let accountID: AccountID
    public let providerID: String
    public init(accountID: AccountID, providerID: String) {
        self.accountID = accountID
        self.providerID = providerID
    }
}
