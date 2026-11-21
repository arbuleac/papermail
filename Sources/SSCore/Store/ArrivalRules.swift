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

/// The arrival rules of one upsert (docs/DATA-MODEL.md, "Arrival rules"): mail new to the store in a muted conversation
/// is archived in the transaction that stores it, through the ordinary operation, so the row never reaches the Inbox, its
/// observers never see it there, and the outbox replays the change. Sender rules take no part: they live on the server,
/// which archives or trashes the sender's mail before this Mac sees it. Their mirror is read only to leave a snooze alone
/// (`ArrivalRule.keepsSnooze`).
///
/// The cost is per write, not per message, wherever nothing is muted and no rule is set: two reads of a few index entries.
/// Otherwise each message new to the store in an account that has some costs a primary-key probe for each kind.
struct ArrivalRules {
    private let mutedAccounts: Set<String>
    private let ruledAccounts: Set<String>
    /// The muted conversations mail arrived in, in the order met.
    private var hits: [ConversationID] = []

    /// `senderRules` false for the backfill and a search of the server, whose mail is old, not arriving: a snooze set
    /// since is the summary refresh's to judge. The mute applies on every path, since a muted conversation's older mail
    /// still in the provider's Inbox would otherwise bring it back.
    init(in db: Database, senderRules: Bool) throws {
        mutedAccounts = try MuteTable.accounts(db)
        ruledAccounts = senderRules ? try SenderRuleTable.accounts(db) : []
    }

    /// Looks at one message the upsert has just stored for the first time, as stored (live operations replayed). Returns
    /// whether the mute or a sender rule covers it (`ArrivalRule.keepsSnooze`), which the caller asks before ending its
    /// conversation's snooze.
    mutating func consider(_ message: MessageMetadata, in db: Database) throws -> Bool {
        let account = message.id.accountID.rawValue
        let checksMute = mutedAccounts.contains(account)
        let checksSender = ruledAccounts.contains(account)
        guard checksMute || checksSender else { return false }
        let muted = try checksMute && MuteTable.isMuted(message.conversationID, in: db)
        var senderRule: SenderRule.Action?
        if checksSender, let from = message.from {
            senderRule = try SenderRuleTable.action(accountID: account, address: SenderRule.normalizedAddress(from.address), in: db)
        }
        if ArrivalRule.change(for: message, inMutedConversation: muted) != nil, !hits.contains(message.conversationID) {
            hits.append(message.conversationID)
        }
        return ArrivalRule.keepsSnooze(inMutedConversation: muted, senderRule: senderRule)
    }

    /// Queues what the mute found, before the upsert's summary refresh: per account one Archive of every message of the
    /// muted conversations still in the Inbox, older ones too (one moved back with ⇧I, or one the backfill lists), so the
    /// conversation stays out of the Inbox whoever wrote. Enqueued as a user action is, so each target keeps what the
    /// provider reported as the change's prior, and a given-up operation puts the message back where the provider has it.
    func enqueue(at now: Date, in db: Database) throws {
        guard !hits.isEmpty else { return }
        var order: [AccountID] = []
        var archived: [AccountID: [MessageID]] = [:]
        for conversation in hits {
            let account = conversation.accountID
            if !order.contains(account) { order.append(account) }
            archived[account, default: []] += try Self.inboxMessages(of: conversation, in: db)
        }
        for account in order {
            let toArchive = Self.unique(archived[account] ?? [])
            guard !toArchive.isEmpty else { continue }
            try OperationTable.enqueue(Operation(accountID: account, change: .archive, targets: toArchive, createdAt: now), in: db)
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
