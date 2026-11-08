import SSCore
import UserNotifications

/// What the user asked for from a new-mail notification (spec §5.41): a click, or one of its actions. Read from
/// the response's action identifier and the conversation the notification carries, so the rules are tested
/// without building a `UNNotificationResponse`.
enum NewMailNotificationResponse: Equatable, Sendable {
    /// A click: opens and selects the conversation. A summary names none; a click on it only brings the app forward.
    case open(ConversationID?)
    case archive(ConversationID)
    case markRead(ConversationID)
    case reply(ConversationID)

    private static let accountKey = "account"
    private static let conversationKey = "conversation"

    /// What a notification for `conversation` carries, for the response to name it.
    static func userInfo(for conversation: ConversationID) -> [String: String] {
        [accountKey: conversation.accountID.rawValue, conversationKey: conversation.providerID]
    }

    /// Nil for a dismissal, an identifier this app never registered, or an action without a conversation.
    init?(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        let conversation: ConversationID? = {
            guard let account = userInfo[Self.accountKey] as? String, let id = userInfo[Self.conversationKey] as? String else { return nil }
            return ConversationID(accountID: AccountID(account), providerID: id)
        }()
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            self = .open(conversation)
            return
        }
        guard let action = NewMailNotificationAction(rawValue: actionIdentifier), let conversation else { return nil }
        switch action {
        case .archive: self = .archive(conversation)
        case .markRead: self = .markRead(conversation)
        case .reply: self = .reply(conversation)
        }
    }

    /// A click and Reply bring the app forward; Archive and Mark as Read leave it where it is.
    var bringsAppForward: Bool {
        switch self {
        case .open, .reply: return true
        case .archive, .markRead: return false
        }
    }
}
