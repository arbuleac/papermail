import AppKit
import SSCore
import UserNotifications
import os

/// Posts a notification for unread inbox conversations that arrive after launch while the app is in the
/// background, and routes a click on one back to that conversation (spec §5.41). macOS draws them; the words
/// come from `NewMailNotificationContent`. No actions in v1.
@MainActor
final class NewMailNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let log = Logger(subsystem: "io.supersparrow.mac", category: "notifications")
    nonisolated private static let accountKey = "account"
    nonisolated private static let conversationKey = "conversation"

    var onOpenConversation: ((ConversationID) -> Void)?
    /// Accounts in their first sync: their mail is not new to the user, so it never notifies.
    var accountsInFirstSync: Set<AccountID> = []
    /// Set while the Inbox filter is Focused: Other mail then does not notify.
    var hidesOtherMail = false

    private let settings: AppSettings
    private let launchDate = Date()
    private var seenLatest: Set<MessageID> = []
    private var seeded = false
    /// When each account's recent notifications were posted, for the summary rule.
    private var recentPosts: [AccountID: [Date]] = [:]

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
            guard !accountsInFirstSync.contains(row.id.accountID) else { continue }
            if hidesOtherMail, row.inboxSection == .other { continue }
            fresh.append(row)
        }
        guard !fresh.isEmpty, settings.notificationsEnabled, !NSApp.isActive, let center else { return }
        let now = Date()
        for (accountID, rows) in Dictionary(grouping: fresh, by: \.id.accountID) {
            let accountName = accounts[accountID].map(AccountLabels.name(for:)) ?? "Mail"
            let window = NewMailNotificationContent.summaryWindow
            var recent = (recentPosts[accountID] ?? []).filter { now.timeIntervalSince($0) < window }
            recent.append(contentsOf: Array(repeating: now, count: rows.count))
            recentPosts[accountID] = recent
            if recent.count > NewMailNotificationContent.summaryThreshold {
                // One summary per account replaces the run: the same identifier updates it in place.
                post(center, id: "summary-\(accountID.rawValue)",
                     content: .summary(count: recent.count, accountName: accountName), account: accountID, conversation: nil)
                continue
            }
            for row in rows {
                post(center, id: row.latestMessageID.providerID,
                     content: .conversation(row, accountName: accountName, showPreviews: settings.showPreviews),
                     account: accountID, conversation: row.id)
            }
        }
    }

    private func post(_ center: UNUserNotificationCenter, id: String, content made: NewMailNotificationContent, account: AccountID,
                      conversation: ConversationID?) {
        let content = UNMutableNotificationContent()
        content.title = made.title
        content.subtitle = made.subtitle
        if let body = made.body { content.body = body }
        content.sound = .default
        // Grouped per account; a click opens and selects the conversation.
        content.threadIdentifier = account.rawValue
        if let conversation {
            content.targetContentIdentifier = conversation.providerID
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
        // The app is in front: the list already shows the new row, and sound is off while frontmost.
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
