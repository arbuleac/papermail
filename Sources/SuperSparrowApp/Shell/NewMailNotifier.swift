import AppKit
import SSCore
import UserNotifications
import os

/// Posts a notification for unread inbox conversations that arrive after launch, and routes a click on one back
/// to that conversation (spec §5.41). macOS draws them; the words come from `NewMailNotificationContent`. No
/// actions in v1. While the app is frontmost they come without sound, and never for the conversation open in
/// a key window, which the user is already reading.
@MainActor
final class NewMailNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// One notification to post.
    struct Post: Equatable {
        var id: String
        var content: NewMailNotificationContent
        var account: AccountID
        var conversation: ConversationID?
        var playsSound: Bool
    }
    nonisolated private static let log = Logger(subsystem: "io.supersparrow.mac", category: "notifications")
    nonisolated private static let accountKey = "account"
    nonisolated private static let conversationKey = "conversation"

    var onOpenConversation: ((ConversationID) -> Void)?
    /// Accounts in their first sync: their mail is not new to the user, so it never notifies.
    var accountsInFirstSync: Set<AccountID> = [] {
        didSet {
            // The first page is the account's newest mail, and its rows can reach the inbox just after the status
            // leaves first sync: from then on only mail dated after that moment is new, as after launch.
            let now = Date()
            for id in oldValue.subtracting(accountsInFirstSync) { firstSyncEndedAt[id] = now }
        }
    }
    /// Set while the Inbox filter is Focused: Other mail then does not notify.
    var hidesOtherMail = false
    /// The app is frontmost: notifications come without sound.
    var isFrontmost: () -> Bool = { NSApp.isActive }
    /// The conversation open in a key window, which never notifies: its new message is already on screen.
    var conversationOpenInKeyWindow: () -> ConversationID? = { nil }

    private let settings: AppSettings
    private let launchDate: Date
    /// When each account's first sync was seen to end this session.
    private var firstSyncEndedAt: [AccountID: Date] = [:]
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

    init(settings: AppSettings, launchDate: Date = Date()) {
        self.settings = settings
        self.launchDate = launchDate
        super.init()
        center?.delegate = self
    }

    /// The accounts whose mail is not yet new to the user: those fetching their first page. One downloading
    /// older mail behind that page is up to date for new mail, which notifies as usual; the older mail itself
    /// predates that page, so its date keeps it quiet.
    nonisolated static func accountsInFirstSync(_ statuses: [AccountSyncStatus]) -> Set<AccountID> {
        Set(statuses.filter { $0.phase == .bootstrapping }.map(\.accountID))
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
        let posts = plan(rows, accounts: accounts, now: Date())
        guard let center else { return }
        for post in posts { self.post(post, to: center) }
    }

    /// What `inboxDidChange` posts for `rows`, recording them as seen. Internal so the rules are tested without a
    /// notification center.
    func plan(_ rows: [ConversationSummary], accounts: [AccountID: Account], now: Date) -> [Post] {
        defer { seeded = true }
        let open = conversationOpenInKeyWindow()
        var fresh: [ConversationSummary] = []
        for row in rows where seenLatest.insert(row.latestMessageID).inserted {
            // Downloaded pages land after launch too; only mail dated after launch, and after its account's first
            // sync ended, is new to the user.
            let newSince = max(launchDate, firstSyncEndedAt[row.id.accountID] ?? launchDate)
            guard seeded, row.unreadCount > 0, row.latestDate > newSince.addingTimeInterval(-60) else { continue }
            guard !accountsInFirstSync.contains(row.id.accountID) else { continue }
            if hidesOtherMail, row.inboxSection == .other { continue }
            if row.id == open { continue }
            fresh.append(row)
        }
        guard !fresh.isEmpty, settings.notificationsEnabled else { return [] }
        let sound = !isFrontmost()
        var posts: [Post] = []
        for (accountID, rows) in Dictionary(grouping: fresh, by: \.id.accountID) {
            let accountName = accounts[accountID].map(AccountLabels.name(for:)) ?? "Mail"
            let window = NewMailNotificationContent.summaryWindow
            var recent = (recentPosts[accountID] ?? []).filter { now.timeIntervalSince($0) < window }
            recent.append(contentsOf: Array(repeating: now, count: rows.count))
            recentPosts[accountID] = recent
            if recent.count > NewMailNotificationContent.summaryThreshold {
                // One summary per account replaces the run: the same identifier updates it in place.
                posts.append(Post(id: "summary-\(accountID.rawValue)", content: .summary(count: recent.count, accountName: accountName),
                                  account: accountID, conversation: nil, playsSound: sound))
                continue
            }
            for row in rows {
                posts.append(Post(id: row.latestMessageID.providerID,
                                  content: .conversation(row, accountName: accountName, showPreviews: settings.showPreviews),
                                  account: accountID, conversation: row.id, playsSound: sound))
            }
        }
        return posts
    }

    private func post(_ post: Post, to center: UNUserNotificationCenter) {
        let made = post.content
        let account = post.account
        let conversation = post.conversation
        let id = post.id
        let content = UNMutableNotificationContent()
        content.title = made.title
        content.subtitle = made.subtitle
        if let body = made.body { content.body = body }
        // Off while the app is frontmost (§5.41); the banner still shows (`willPresent`).
        content.sound = post.playsSound ? .default : nil
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
        // The app is in front: the notification shows, without sound (§5.41). The conversation open in a key
        // window never got one.
        completionHandler([.banner, .list])
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
