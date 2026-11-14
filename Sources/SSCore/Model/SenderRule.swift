import Foundation

/// One of the two sender rules (roadmap Q4.2, docs/DATA-MODEL.md "Arrival rules"): mail from one address to one
/// account is archived, or moved to the Trash, as it arrives. Set from a message's menu, listed and removed only in
/// Settings › Accounts › Senders…. Only the rule lives on this Mac; what it does to a message is the ordinary archive
/// or trash operation, queued in the poll's own write, so the phone and the web see the same state.
public struct SenderRule: Hashable, Sendable {
    public enum Action: String, Codable, Sendable, CaseIterable {
        /// “Always Archive Mail from Sender”: out of the Inbox as it arrives. Stored raw value; never rename it.
        case archive
        /// “Block Sender”: to the Trash as it arrives. Stored raw value; never rename it.
        case trash

        /// The ordinary change the rule queues for a message it takes.
        public var change: MetadataChange {
            switch self {
            case .archive: return .archive
            case .trash: return .trash
            }
        }
    }

    public var accountID: AccountID
    /// Trimmed and lowercased (`normalizedAddress`): a rule matches a From address whatever its case.
    public var address: String
    public var action: Action
    public var createdAt: Date

    public init(accountID: AccountID, address: String, action: Action, createdAt: Date) {
        self.accountID = accountID
        self.address = SenderRule.normalizedAddress(address)
        self.action = action
        self.createdAt = createdAt
    }

    /// How a rule's address is kept and looked up: addresses are compared without case, and nothing else is folded,
    /// so a rule for one address never takes another's mail (Gmail's dots and +tags name different senders).
    public static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
