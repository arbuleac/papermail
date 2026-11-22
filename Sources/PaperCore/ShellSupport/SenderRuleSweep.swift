import Foundation

/// What setting a sender rule does to the mail already stored (spec §5.52), worked out before the one transaction that
/// sets it. A server rule acts only on mail that arrives after it exists, so the app applies the rule's change once,
/// itself: Block Sender to the sender's mail in the conversation it was set from, and Always Archive Mail from This Sender
/// to their mail in the Inbox of every account (`MailStoring.inboxMessages(from:)`), so no Inbox keeps mail from a sender
/// the user never wants there. Each message passes `SenderRule.Action.change(for:)`, so Spam, the user's own sent mail
/// and drafts are never taken, and neither is an account's mail from its own address (the user's own, which a rule set
/// in another account for that address must leave alone, as the menus never offer a rule for it there).
public struct SenderRuleSweep: Sendable {
    public var action: SenderRule.Action
    /// The conversation the rule was set from.
    public var conversation: ConversationID
    /// What the change takes and its undo (nil when it takes nothing): its targets, every account's, and the inverse
    /// steps that put each one back.
    public var record: MailActionRecord?
    /// The conversations whose mail it takes, the one it was set from first, then as the messages came.
    public var conversations: [ConversationID]

    /// `conversationMessages` are the messages of `conversation`; `inboxMessages` the sender's mail in every Inbox, read
    /// for Always Archive alone; `ownAddresses` each account's own address.
    public init(_ action: SenderRule.Action, address: String, setFrom conversation: ConversationID,
                conversationMessages: [MessageMetadata], inboxMessages: [MessageMetadata], ownAddresses: [AccountID: String]) {
        self.action = action
        self.conversation = conversation
        let sender = SenderRule.normalizedAddress(address)
        let candidates = conversationMessages + (action == .archive ? inboxMessages : [])
        var seen: Set<MessageID> = []
        let taken = candidates.filter { message in
            guard let from = message.from.map({ SenderRule.normalizedAddress($0.address) }), from == sender, !sender.isEmpty,
                  action.change(for: message) == action.change, seen.insert(message.id).inserted else { return false }
            return ownAddresses[message.id.accountID].map(SenderRule.normalizedAddress) != sender
        }
        record = MailActionRecord.make(action.change, on: taken, conversation: conversation)
        let changed = Set(record?.targets ?? [])
        var distinct: Set<ConversationID> = []
        conversations = taken.filter { changed.contains($0.id) }.map(\.conversationID).filter { distinct.insert($0).inserted }
    }

    /// The steps the rule's transaction performs: its change on every message it takes.
    public var steps: [MailActionRecord.Step] {
        record.map { [MailActionRecord.Step(change: action.change, targets: $0.targets)] } ?? []
    }

    /// The steps its undo performs, in that transaction's order.
    public var inverse: [MailActionRecord.Step] {
        record?.inverse ?? []
    }

    /// Every account whose mail the change takes, besides the rule's own: the undo writes to each of them.
    public var accounts: Set<AccountID> {
        Set((record?.targets ?? []).map(\.accountID))
    }

    /// Whether it takes the mail of the conversation it was set from, which the undo then selects again.
    public var takesItsConversation: Bool {
        conversations.contains(conversation)
    }

    /// Whether it takes mail beyond the conversation it was set from: the toast then counts the conversations.
    public var reachesBeyondItsConversation: Bool {
        conversations.contains { $0 != conversation }
    }
}
