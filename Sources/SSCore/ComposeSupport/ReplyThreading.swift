import Foundation

/// The headers that tie a reply or forward to the message it answers. Captured from the original when the
/// composer opens and kept with the draft, whichever From the user picks afterwards, so an undone send
/// reopens with them intact; they are applied only when the message leaves from the account that owns
/// the original, because a provider cannot resolve another account's message id.
public struct ReplyThreading: Hashable, Sendable {
    public var inReplyTo: MessageID
    public var inReplyToInternetMessageID: String?
    public var references: [String]

    public init(inReplyTo: MessageID, inReplyToInternetMessageID: String? = nil, references: [String] = []) {
        self.inReplyTo = inReplyTo
        self.inReplyToInternetMessageID = inReplyToInternetMessageID
        self.references = references
    }

    public init(original: MessageMetadata, isReply: Bool) {
        inReplyTo = original.id
        // Forwards start a new conversation for the recipient; only a reply claims to answer the original.
        inReplyToInternetMessageID = isReply ? original.internetMessageID : nil
        var references = original.references
        if let id = original.internetMessageID, !references.contains(id) { references.append(id) }
        self.references = references
    }

    /// The headers to send from `account`, or nil when the original belongs to another account: its id
    /// would not resolve there, so the message starts a fresh thread instead.
    public func applicable(to account: AccountID) -> ReplyThreading? {
        inReplyTo.accountID == account ? self : nil
    }
}
