import Foundation

/// One of the two sender rules (docs/DATA-MODEL.md, "Sender rules"): mail from one address to one account is archived, or
/// moved to the Trash, as it arrives. The rule lives on the server, as a Gmail filter or an Outlook inbox rule, which the
/// provider runs whether or not this Mac is on; there is no rule engine on this Mac. A `SenderRule` is a row of the
/// store's mirror of those server rules (`sync == .saved`), or a change the user made on this Mac on its way to the
/// server (`creating`, `replacing`, `deleting`), which the engine's rules lane sends.
public struct SenderRule: Hashable, Sendable {
    public enum Action: String, Codable, Sendable, CaseIterable {
        /// “Always Archive Mail from Sender”: out of the Inbox as it arrives. Stored raw value; never rename it.
        case archive
        /// “Block Sender”: to the Trash as it arrives. Stored raw value; never rename it.
        case trash

        /// The ordinary change the rule stands for on a message.
        public var change: MetadataChange {
            switch self {
            case .archive: return .archive
            case .trash: return .trash
            }
        }

        /// What setting the rule now does to one message already stored, nil when it leaves it alone: a server rule only
        /// acts on mail that arrives after it exists, so the app applies it once, itself, to the sender's mail already
        /// here (`SenderRuleSweep`): Always Archive to their mail in the Inbox of every account (`MailStoring.inboxMessages`),
        /// Block to their mail in the conversation it was set from. Spam is left where the provider put it, and neither rule
        /// takes the user's own sent mail or drafts (a rule for one's own address would otherwise throw them away); the
        /// block takes what is not in the Trash already, the archive only what is in the Inbox, so a snoozed conversation,
        /// archived until its time, keeps its snooze.
        public func change(for message: MessageMetadata) -> MetadataChange? {
            guard !message.roles.contains(.spam), !message.roles.contains(.sent), !message.roles.contains(.drafts) else {
                return nil
            }
            switch self {
            case .trash: return message.roles.contains(.trash) ? nil : .trash
            case .archive: return message.isInInbox ? .archive : nil
            }
        }
    }

    /// Where the row stands against the server (`sender_rules.sync`). Stored raw values; never rename them.
    public enum Sync: String, Codable, Sendable, CaseIterable {
        /// As the server has it: the last read of the server's rules listed it under `serverIDs`.
        case saved
        /// Set on this Mac and not on the server yet: the engine creates it (adopting an identical rule the server has
        /// already, so a create whose reply was lost is never made twice).
        case creating
        /// The other action chosen for a rule the server has under `serverIDs`: the engine creates the new rule, then
        /// deletes the old.
        case replacing
        /// Removed on this Mac, still on the server under `serverIDs`: the engine deletes it there.
        case deleting
    }

    public var accountID: AccountID
    /// Trimmed and lowercased (`normalizedAddress`): a rule matches a From address whatever its case.
    public var address: String
    /// What the rule does, or, for a `replacing` row, what the user chose and the server does not do yet.
    public var action: Action
    /// When the row took its current state on this Mac (set, changed or removed), or when a read first found it on the
    /// server. Pending rows go to the server in this order.
    public var createdAt: Date
    /// The server's ids of the rules behind the row (a Gmail filter id, an Outlook rule id); several when the server holds
    /// more than one rule for the address (a Gmail archive filter beside a trash filter, shown as the block). Empty for a
    /// `creating` row.
    public var serverIDs: [String]
    public var sync: Sync

    public init(accountID: AccountID, address: String, action: Action, createdAt: Date, serverIDs: [String] = [],
                sync: Sync = .saved) {
        self.accountID = accountID
        self.address = SenderRule.normalizedAddress(address)
        self.action = action
        self.createdAt = createdAt
        self.serverIDs = serverIDs
        self.sync = sync
    }

    /// Whether the rule stands as far as the user is concerned: every row but one removed on this Mac and still being
    /// deleted on the server. The menus mark the rule a sender has from these alone.
    public var isActive: Bool {
        sync != .deleting
    }

    /// Whether the row waits for the engine to send it to the server.
    public var isPending: Bool {
        sync != .saved
    }

    /// How a rule's address is kept and looked up: addresses are compared without case, and nothing else is folded,
    /// so a rule for one address never takes another's mail (Gmail's dots and +tags name different senders).
    public static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
