import AppKit
import SSCore
import UserNotifications
import os

/// Posts a notification for unread inbox conversations that arrive after launch while the app is in the
/// background, and routes a click on one back to that conversation.
@MainActor
final class NewMailNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let log = Logger(subsystem: "io.supersparrow.mac", category: "notifications")
    nonisolated private static let accountKey = "account"
    nonisolated private static let conversationKey = "conversation"
    /// More than this many at once become one summary notification.
    private static let individualLimit = 3

    var onOpenConversation: ((ConversationID) -> Void)?

    private let settings: AppSettings
    private let launchDate = Date()
    private var seenLatest: Set<MessageID> = []
    private var seeded = false

    /// UNUserNotificationCenter raises an exception in a process without a bundle (`swift run`); notifications
    /// are simply off there.
    private let center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }()

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        center?.delegate = self
    }

    /// Asks once, the first time an account is added, so the prompt comes with an obvious reason.
    func requestAuthorizationIfNeeded() {
        guard let center, !settings.hasAskedForNotifications else { return }
        settings.hasAskedForNotifications = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                Self.log.notice("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.log.info("notification authorization granted: \(granted, privacy: .public)")
            }
        }
    }

    /// Called with the unified inbox on every change. The first call only records what is already there.
    func inboxDidChange(_ rows: [ConversationSummary], accounts: [AccountID: Account]) {
        defer { seeded = true }
        var fresh: [ConversationSummary] = []
        for row in rows where seenLatest.insert(row.latestMessageID).inserted {
            // Bootstrap pages land after launch too; only mail dated after launch is new to the user.
            guard seeded, row.unreadCount > 0, row.latestDate > launchDate.addingTimeInterval(-60) else { continue }
            fresh.append(row)
        }
        guard !fresh.isEmpty, settings.notificationsEnabled, !NSApp.isActive, let center else { return }
        if fresh.count > Self.individualLimit {
            post(center, id: "summary-\(UUID().uuidString)", title: "\(fresh.count) new messages", body: nil, conversation: nil)
            return
        }
        for row in fresh {
            let sender = row.participants.last?.shortDisplay ?? "New message"
            let account = accounts[row.id.accountID]?.email
            if settings.showPreviews {
                post(center, id: row.latestMessageID.providerID, title: sender, body: row.subject.isEmpty ? "(no subject)" : row.subject,
                     subtitle: accounts.count > 1 ? account : nil, conversation: row.id)
            } else {
                post(center, id: row.latestMessageID.providerID, title: "New message", body: account, conversation: row.id)
            }
        }
    }

    private func post(
        _ center: UNUserNotificationCenter,
        id: String,
        title: String,
        body: String?,
        subtitle: String? = nil,
        conversation: ConversationID?
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        if let subtitle { content.subtitle = subtitle }
        content.sound = .default
        content.threadIdentifier = conversation?.providerID ?? "summary"
        if let conversation {
            content.userInfo = [Self.accountKey: conversation.accountID.rawValue, Self.conversationKey: conversation.providerID]
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { Self.log.notice("could not post notification: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The app is in front: the list already shows the new row.
        completionHandler([])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let account = info[Self.accountKey] as? String
        let conversation = info[Self.conversationKey] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate()
                if let account, let conversation {
                    self.onOpenConversation?(ConversationID(accountID: AccountID(account), providerID: conversation))
                }
            }
            completionHandler()
        }
    }
}
