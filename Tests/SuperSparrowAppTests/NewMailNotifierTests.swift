import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// New-mail notifications (spec §5.41): while the app is frontmost they come without sound, and the
/// conversation open in a key window never notifies.
@MainActor
final class NewMailNotifierTests: XCTestCase {
    private let account = ListTestSupport.accountA

    private func row(_ n: Int, message: Int = 0, date: Date = Date()) -> ConversationSummary {
        ConversationSummary(
            id: ConversationID(accountID: account.id, providerID: "t\(n)"), subject: "Subject \(n)", snippet: "Snippet",
            participants: [EmailAddress(name: "Ben Carter", address: "ben@example.com")], latestDate: date, messageCount: 1,
            unreadCount: 1, isStarred: false, hasAttachments: false, inInbox: true, inboxSection: .focused,
            latestMessageID: MessageID(accountID: account.id, providerID: "m\(n)-\(message)"), hasPendingOperations: false)
    }

    private func notifier(launchedAt launchDate: Date = Date()) -> NewMailNotifier {
        let settings = ListTestSupport.settings()
        settings.notificationsEnabled = true
        let notifier = NewMailNotifier(settings: settings, launchDate: launchDate)
        // The first delivery only records what is there.
        XCTAssertTrue(notifier.plan([row(0)], accounts: [account.id: account], now: Date()).isEmpty)
        return notifier
    }

    func testInTheBackgroundNewMailNotifiesWithSound() {
        let notifier = notifier()
        notifier.isFrontmost = { false }
        let posts = notifier.plan([row(0), row(1)], accounts: [account.id: account], now: Date())
        XCTAssertEqual(posts.map(\.conversation), [row(1).id])
        XCTAssertEqual(posts.first?.playsSound, true)
    }

    func testWhileFrontmostTheSoundIsOff() {
        let notifier = notifier()
        notifier.isFrontmost = { true }
        let posts = notifier.plan([row(0), row(1)], accounts: [account.id: account], now: Date())
        XCTAssertEqual(posts.count, 1, "it still notifies")
        XCTAssertEqual(posts.first?.playsSound, false)
    }

    func testTheConversationOpenInAKeyWindowNeverNotifies() {
        let notifier = notifier()
        notifier.isFrontmost = { true }
        notifier.conversationOpenInKeyWindow = { self.row(0).id }
        // A new message in the open conversation, and a new conversation.
        let posts = notifier.plan([row(0, message: 1), row(2)], accounts: [account.id: account], now: Date())
        XCTAssertEqual(posts.map(\.conversation), [row(2).id])
    }

    // MARK: First sync

    func testOnlyTheFirstPageIsAFirstSyncNotOlderMailBehindIt() {
        let other = ListTestSupport.accountB
        let statuses = [
            AccountSyncStatus(accountID: account.id, phase: .idle, lastSuccessfulSyncAt: Date(), backfillProgress: 3_412, backfillTotal: 8_120),
            AccountSyncStatus(accountID: other.id, phase: .bootstrapping, bootstrapProgress: 120),
        ]
        XCTAssertEqual(NewMailNotifier.accountsInFirstSync(statuses), [other.id])
        // So new mail on the account downloading older mail notifies.
        let notifier = notifier()
        notifier.isFrontmost = { false }
        notifier.accountsInFirstSync = NewMailNotifier.accountsInFirstSync(statuses)
        let posts = notifier.plan([row(0), row(1)], accounts: [account.id: account], now: Date())
        XCTAssertEqual(posts.map(\.conversation), [row(1).id])
    }

    /// An account adopted mid-download (or past its first page before launch) is never in first sync, so the launch
    /// time alone keeps the older mail the backfill writes behind the live lane quiet: unread and in the inbox, but
    /// dated before launch.
    func testOlderMailBackfilledAfterLaunchStaysQuiet() {
        let notifier = notifier()
        notifier.isFrontmost = { false }
        let backfilled = [row(1, date: Date().addingTimeInterval(-3 * 86_400)), row(2, date: Date().addingTimeInterval(-5 * 60))]
        XCTAssertTrue(notifier.plan([row(0)] + backfilled, accounts: [account.id: account], now: Date()).isEmpty)
    }

    func testMailDuringTheFirstPageNeverNotifies() {
        let notifier = notifier()
        notifier.accountsInFirstSync = [account.id]
        XCTAssertTrue(notifier.plan([row(0), row(1)], accounts: [account.id: account], now: Date()).isEmpty)
    }

    func testTheFirstPageReachingTheInboxAfterItsSyncEndedStaysQuiet() {
        // Added an hour after launch: the first page holds mail from that hour, which is not new to the user even
        // when its rows arrive just after the status has left first sync.
        let notifier = notifier(launchedAt: Date().addingTimeInterval(-3_600))
        notifier.isFrontmost = { false }
        notifier.accountsInFirstSync = [account.id]
        notifier.accountsInFirstSync = []
        let firstPage = notifier.plan([row(0), row(1, date: Date().addingTimeInterval(-600))], accounts: [account.id: account], now: Date())
        XCTAssertTrue(firstPage.isEmpty)
        let arriving = notifier.plan([row(0), row(1, date: Date().addingTimeInterval(-600)), row(2, date: Date().addingTimeInterval(1))],
                                     accounts: [account.id: account], now: Date())
        XCTAssertEqual(arriving.map(\.conversation), [row(2).id], "mail after the first sync notifies")
    }
}
