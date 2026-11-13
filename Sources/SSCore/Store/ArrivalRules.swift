import Foundation
import GRDB

/// SQL for the mute (`conversations.muted`, v16). The flag lives on the summary row, which the refresh carries over, so
/// it lasts as long as the conversation has a row: a conversation whose every message is gone (or in Spam) loses it.
enum MuteTable {
    /// Writes the flag on the conversations' summary rows; a conversation without one (not stored) is left alone.
    static func set(_ muted: Bool, conversations: [ConversationID], in db: Database) throws {
        let write = try db.cachedStatement(sql: "UPDATE conversations SET muted = ? WHERE account_id = ? AND provider_id = ?")
        for conversation in conversations {
            try write.execute(arguments: [muted, conversation.accountID.rawValue, conversation.providerID])
        }
    }

    /// The accounts with anything muted, from the partial index `conversations_muted`: a few entries at most.
    static func accounts(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db.cachedStatement(sql: "SELECT DISTINCT account_id FROM conversations WHERE muted = 1")))
    }

    /// One primary-key probe.
    static func isMuted(_ conversation: ConversationID, in db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: "SELECT muted FROM conversations WHERE account_id = ? AND provider_id = ?"),
                          arguments: [conversation.accountID.rawValue, conversation.providerID]) ?? false
    }
}

/// SQL for `sender_rules` (v17).
enum SenderRuleTable {
    /// Every rule, by account and then address, as Settings lists them.
    static func all(_ db: Database) throws -> [SenderRule] {
        try Row.fetchAll(db.cachedStatement(sql: """
            SELECT account_id, address, action, created_at FROM sender_rules ORDER BY account_id, address
            """)).compactMap { row in
            // A rule a later build wrote with an action this one does not know is left out rather than guessed at.
            guard let action = SenderRule.Action(rawValue: row[2]) else { return nil }
            return SenderRule(accountID: AccountID(row[0]), address: row[1], action: action, createdAt: MailStoreCodec.date(row[3]))
        }
    }

    /// Sets the rule for the address (replacing another action and its time), or removes it when `action` is nil.
    static func set(_ action: SenderRule.Action?, for address: String, accountID: AccountID, now: Date, in db: Database) throws {
        let address = SenderRule.normalizedAddress(address)
        guard !address.isEmpty else { return }
        guard let action else {
            try db.cachedStatement(sql: "DELETE FROM sender_rules WHERE account_id = ? AND address = ?")
                .execute(arguments: [accountID.rawValue, address])
            return
        }
        try db.cachedStatement(sql: """
            INSERT INTO sender_rules (account_id, address, action, created_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(account_id, address) DO UPDATE SET action = excluded.action, created_at = excluded.created_at
            """).execute(arguments: [accountID.rawValue, address, action.rawValue, MailStoreCodec.milliseconds(now)])
    }

    /// The accounts with any rule: the table is a few rows, read once per write.
    static func accounts(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db.cachedStatement(sql: "SELECT DISTINCT account_id FROM sender_rules")))
    }

    /// One primary-key probe; `address` already normalized.
    static func action(accountID: String, address: String, in db: Database) throws -> SenderRule.Action? {
        try String.fetchOne(db.cachedStatement(sql: "SELECT action FROM sender_rules WHERE account_id = ? AND address = ?"),
                            arguments: [accountID, address]).flatMap(SenderRule.Action.init(rawValue:))
    }
}

/// The arrival rules of one upsert (docs/DATA-MODEL.md, "Arrival rules"): mail new to the store in a muted conversation,
/// or from a sender with a rule, is archived or trashed in the transaction that stores it, through the ordinary
/// operation, so the row never reaches the Inbox, its observers never see it there, and the outbox replays the change.
///
/// The cost is per write, not per message, wherever nothing is muted and no rule is set: two reads of a few index entries.
/// Otherwise each message new to the store in an account that has some costs a primary-key probe for each kind.
struct ArrivalRules {
    private let mutedAccounts: Set<String>
    private let ruledAccounts: Set<String>
    private var hits: [Hit] = []

    private struct Hit {
        var message: MessageID
        var conversation: ConversationID
        var change: MetadataChange
        var muted: Bool
    }

    /// `senderRules` false for the backfill and a search of the server, whose mail is old, not arriving: a rule set
    /// today is not a reason to move mail on every device that came years ago. The mute applies on every path, since a
    /// muted conversation's older mail still in the provider's Inbox would otherwise bring it back.
    init(in db: Database, senderRules: Bool) throws {
        mutedAccounts = try MuteTable.accounts(db)
        ruledAccounts = senderRules ? try SenderRuleTable.accounts(db) : []
    }

    /// Looks at one message the upsert has just stored for the first time, as stored (live operations replayed).
    mutating func consider(_ message: MessageMetadata, in db: Database) throws {
        let account = message.id.accountID.rawValue
        let checksMute = mutedAccounts.contains(account)
        let checksSender = ruledAccounts.contains(account)
        guard checksMute || checksSender else { return }
        let muted = try checksMute && MuteTable.isMuted(message.conversationID, in: db)
        var senderRule: SenderRule.Action?
        if checksSender, let from = message.from {
            senderRule = try SenderRuleTable.action(accountID: account, address: SenderRule.normalizedAddress(from.address), in: db)
        }
        guard let change = ArrivalRule.change(for: message, inMutedConversation: muted, senderRule: senderRule) else { return }
        hits.append(Hit(message: message.id, conversation: message.conversationID, change: change, muted: muted && change == .archive))
    }

    /// Queues what the rules found, before the upsert's summary refresh: per account one Move to Trash and one Archive.
    /// A muted conversation's archive takes every message of it in the Inbox, older ones too (one moved back with ⇧I, or
    /// one the backfill lists), so the conversation stays out of the Inbox whoever wrote; a sender's archive takes only
    /// that sender's message. Enqueued as a user action is, so each target keeps what the provider reported as the
    /// change's prior, and a given-up operation puts the message back where the provider has it.
    func enqueue(at now: Date, in db: Database) throws {
        guard !hits.isEmpty else { return }
        var order: [AccountID] = []
        var trashed: [AccountID: [MessageID]] = [:]
        var archived: [AccountID: [MessageID]] = [:]
        var mutedConversations: [AccountID: [ConversationID]] = [:]
        for hit in hits {
            let account = hit.message.accountID
            if !order.contains(account) { order.append(account) }
            if hit.change == .trash {
                trashed[account, default: []].append(hit.message)
            } else if hit.muted {
                if !(mutedConversations[account] ?? []).contains(hit.conversation) {
                    mutedConversations[account, default: []].append(hit.conversation)
                }
            } else {
                archived[account, default: []].append(hit.message)
            }
        }
        for account in order {
            let toTrash = Self.unique(trashed[account] ?? [])
            var toArchive = archived[account] ?? []
            for conversation in mutedConversations[account] ?? [] {
                toArchive += try Self.inboxMessages(of: conversation, in: db)
            }
            let skipped = Set(toTrash)
            toArchive = Self.unique(toArchive).filter { !skipped.contains($0) }
            if !toArchive.isEmpty {
                try OperationTable.enqueue(Operation(accountID: account, change: .archive, targets: toArchive, createdAt: now), in: db)
            }
            if !toTrash.isEmpty {
                // A millisecond after, so the outbox lists them in a fixed order.
                try OperationTable.enqueue(Operation(accountID: account, change: .trash, targets: toTrash,
                                                     createdAt: now.addingTimeInterval(0.001)), in: db)
            }
        }
    }

    /// Through `messages_by_conversation`.
    private static func inboxMessages(of conversation: ConversationID, in db: Database) throws -> [MessageID] {
        let inbox = MailStoreCodec.inboxBit
        let away = MailStoreCodec.trashBit | MailStoreCodec.spamBit
        return try String.fetchAll(db.cachedStatement(sql: """
            SELECT provider_id FROM messages
            WHERE account_id = ? AND conversation_provider_id = ? AND (roles & \(inbox)) != 0 AND (roles & \(away)) = 0
            ORDER BY date_ms, provider_id
            """), arguments: [conversation.accountID.rawValue, conversation.providerID])
            .map { MessageID(accountID: conversation.accountID, providerID: $0) }
    }

    private static func unique(_ ids: [MessageID]) -> [MessageID] {
        var seen: Set<MessageID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
