import UserNotifications

/// The actions a new-mail notification offers (spec §5.41), in the order macOS lists them. Archive and Mark as
/// Read act in the background, so a notification can be dealt with without leaving what the user is doing; Reply
/// needs a composer, so it brings the app forward. Only a notification for one conversation carries them: the
/// summary names none to act on.
enum NewMailNotificationAction: String, CaseIterable, Sendable {
    case archive
    case markRead
    case reply

    /// The category every per-conversation notification is posted with.
    static let categoryIdentifier = "newMail"

    var identifier: String { rawValue }

    /// Title case, as the Message menu names the same actions.
    var title: String {
        switch self {
        case .archive: return "Archive"
        case .markRead: return "Mark as Read"
        case .reply: return "Reply"
        }
    }

    var options: UNNotificationActionOptions {
        switch self {
        case .archive, .markRead: return []
        case .reply: return [.foreground]
        }
    }

    /// What the app registers with the notification center at launch.
    static var categories: Set<UNNotificationCategory> {
        let actions = allCases.map { UNNotificationAction(identifier: $0.identifier, title: $0.title, options: $0.options) }
        return [UNNotificationCategory(identifier: categoryIdentifier, actions: actions, intentIdentifiers: [], options: [])]
    }
}
