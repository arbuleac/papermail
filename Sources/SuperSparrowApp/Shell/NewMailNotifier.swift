import AppKit
import SSCore
import UserNotifications
import os

/// Posts a notification for unread inbox conversations that arrive after launch (spec §5.41). macOS draws them; the
/// words come from `NewMailNotificationContent`, and each one for a single conversation offers Archive, Mark as
/// Read and Reply (`NewMailNotificationAction`); `NewMailNotificationResponder` answers a click or an action. While
/// the app is frontmost they come without sound, and never for the conversation open in a key window, which the
/// user is already reading.
@MainActor
final class NewMailNotifier {
    /// One notification to post.
    struct Post: Equatable {
        var id: String
        var content: NewMailNotificationContent
        var account: AccountID
        var conversation: ConversationID?
        var playsSound: Bool
    }
    nonisolated private static let log = Logger(subsystem: "io.supersparrow.mac", category: "notifications")

    /// Accounts in their first sync: their mail is not new to the user, so it never notifies.
    var accountsInFirstSync: Set<AccountID> = [] {
        didSet {
            // The first page is the account's newest mail, and its rows can reach the inbox just after the status
            // leaves first sync: from then on only mail dated after that moment is new, as after launch.
            let now = Date()
            for id in oldValue.subtracting(accountsInFirstSync) { firstSyncEndedAt[id] = now }
        }
    }
    /// The app is frontmost: notifications come without sound.
    var isFrontmost: () -> Bool = { NSApp.isActive }
    /// The conversation open in a key window, which never notifies: its new message is already on screen.
    var conversationOpenInKeyWindow: () -> ConversationID? = { nil }
    /// The newest unread message in the Inbox of each conversation, read in one go and only for rows that would otherwise
    /// notify, and only while notifications are on. A notification is about that message, which may not be the row's
    /// newest: mail a sender rule archived as it arrived can be the newest of a conversation the Inbox still holds for
    /// other mail, and it never notifies (spec, Sender rules (Q4.2)), nor does the user's own reply, while an arrival
    /// beside it does. Nil (no store, or a read that failed) takes each row's newest message as the arrival.
    var newestUnreadInInbox: ([ConversationID]) -> [ConversationID: MessageMetadata]? = { _ in nil }

    private let settings: AppSettings
    private let launchDate: Date
    /// When each account's first sync was seen to end this session.
    private var firstSyncEndedAt: [AccountID: Date] = [:]
    private var seenLatest: Set<MessageID> = []
    /// Inbox messages notified about that were not their row's newest when they were (an arrival beside a ruled one).
    private var notified: Set<MessageID> = []
    private var seeded = false
    /// When each account's recent notifications were posted, for the summary rule.
    private var recentPosts: [AccountID: [Date]] = [:]

    /// UNUserNotificationCenter raises an exception in a process without a bundle (`swift run`, the tests);
    /// notifications are simply off there.
    static var systemCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    private let center = NewMailNotifier.systemCenter

    init(settings: AppSettings, launchDate: Date = Date()) {
        self.settings = settings
        self.launchDate = launchDate
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
        let seenBefore = seenLatest
        // Every row's newest message counts as seen, notifications on or off; the rest is judged only while they are on.
        var candidates: [ConversationSummary] = []
        for row in rows where seenLatest.insert(row.latestMessageID).inserted {
            guard seeded, settings.notificationsEnabled, row.unreadCount > 0 else { continue }
            // Back from Later is not new mail: the Inbox badge and the row's Back tag say it came back (§5.41).
            guard row.returnedAt == nil else { continue }
            guard !accountsInFirstSync.contains(row.id.accountID) else { continue }
            if row.id == open { continue }
            // A muted conversation's mail is archived as it arrives; one moved back to the Inbox stays quiet too (spec,
            // Mute (Q3.7)).
            guard !row.isMuted else { continue }
            candidates.append(row)
        }
        guard !candidates.isEmpty else { return [] }
        let newest = newestUnreadInInbox(candidates.map(\.id))
        var fresh: [ConversationSummary] = []
        for row in candidates {
            // The message the notification is about: the row's newest, or with the store's word the newest unread one in
            // the Inbox, which must be new too: never one seen as a row's newest before, nor one already notified.
            var shown = row
            if let newest {
                guard let message = newest[row.id] else { continue }
                if message.id != row.latestMessageID {
                    guard !seenBefore.contains(message.id), notified.insert(message.id).inserted else { continue }
                    shown.latestMessageID = message.id
                    shown.latestDate = message.date
                    shown.snippet = message.snippet
                    if let from = message.from { shown.participants = [from] }
                }
            }
            // Downloaded pages land after launch too; only mail dated after launch, and after its account's first sync
            // ended, is new to the user.
            let newSince = max(launchDate, firstSyncEndedAt[row.id.accountID] ?? launchDate)
            guard shown.latestDate > newSince.addingTimeInterval(-60) else { continue }
            fresh.append(shown)
        }
        guard !fresh.isEmpty else { return [] }
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
        center.add(Self.request(for: post)) { error in
            if let error { Self.log.notice("could not post notification: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// The request `post` becomes. Internal so the app's tests check what is posted without a notification center.
    static func request(for post: Post) -> UNNotificationRequest {
        let made = post.content
        let content = UNMutableNotificationContent()
        content.title = made.title
        content.subtitle = made.subtitle
        if let body = made.body { content.body = body }
        // Off while the app is frontmost (§5.41); the banner still shows (`willPresent`).
        content.sound = post.playsSound ? .default : nil
        // Grouped per account.
        content.threadIdentifier = post.account.rawValue
        if let conversation = post.conversation {
            // A click opens and selects the conversation, and its actions act on it; the summary has neither.
            content.targetContentIdentifier = conversation.providerID
            content.userInfo = NewMailNotificationResponse.userInfo(for: conversation)
            content.categoryIdentifier = NewMailNotificationAction.categoryIdentifier
        }
        return UNNotificationRequest(identifier: post.id, content: content, trigger: nil)
    }
}
