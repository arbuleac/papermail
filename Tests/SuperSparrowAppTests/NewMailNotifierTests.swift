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

    // MARK: The store's word

    /// With notifications off nothing is read from the store, however many rows arrive (a wake brings hundreds); with them
    /// on, the rows that could notify are read together, once. Each row was read on its own, before the setting was looked at.
    func testTheStoreIsReadOnceAndOnlyWhileNotificationsAreOn() {
        let settings = ListTestSupport.settings()
        settings.notificationsEnabled = true
        let notifier = NewMailNotifier(settings: settings)
        XCTAssertTrue(notifier.plan([row(0)], accounts: [account.id: account], now: Date()).isEmpty)
        var reads: [[ConversationID]] = []
        notifier.newestUnreadInInbox = { ids in
            reads.append(ids)
            return nil
        }
        settings.notificationsEnabled = false
        XCTAssertTrue(notifier.plan((1...200).map { row($0) }, accounts: [account.id: account], now: Date()).isEmpty)
        XCTAssertTrue(reads.isEmpty, "notifications off: no store read")
        settings.notificationsEnabled = true
        XCTAssertTrue(notifier.plan((1...200).map { row($0) }, accounts: [account.id: account], now: Date()).isEmpty, "seen while off")
        XCTAssertTrue(reads.isEmpty)
        let posts = notifier.plan([row(201), row(202), row(203)], accounts: [account.id: account], now: Date())
        XCTAssertEqual(posts.count, 3)
        XCTAssertEqual(reads, [[row(201).id, row(202).id, row(203).id]], "one read for the rows that could notify")
    }

    /// One poll brings Alice's message and, a minute later in the same conversation, one a sender rule archives: the row's
    /// newest is the ruled one, yet Alice's arrival is in the Inbox and unread, so it notifies, in her words. The row was
    /// judged by its newest message alone and stayed quiet. A ruled message after mail already notified adds nothing.
    func testAnArrivalBesideANewerRuledMessageNotifies() {
        let notifier = notifier()
        notifier.isFrontmost = { false }
        let alice = MessageMetadata(id: MessageID(accountID: account.id, providerID: "m1-0"), conversationID: row(1).id, subject: "Subject 1",
                                    snippet: "Lunch on Friday?", from: EmailAddress(name: "Alice", address: "alice@example.com"),
                                    to: [], date: Date(), roles: [.inbox], isRead: false, isStarred: false, hasAttachments: false)
        notifier.newestUnreadInInbox = { ids in Dictionary(uniqueKeysWithValues: ids.filter { $0 == self.row(1).id }.map { ($0, alice) }) }
        // The row's newest is the ruled newsletter, m1-1.
        let posts = notifier.plan([row(1, message: 1)], accounts: [account.id: account], now: Date())
        XCTAssertEqual(posts.map(\.conversation), [row(1).id])
        XCTAssertEqual(posts.first?.id, "m1-0", "about Alice's message")
        XCTAssertEqual(posts.first?.content.title, "Alice")
        XCTAssertEqual(posts.first?.content.body, "Lunch on Friday?")
        // Another ruled message later: Alice's was notified already.
        XCTAssertTrue(notifier.plan([row(1, message: 2)], accounts: [account.id: account], now: Date()).isEmpty)
        // A row with no unread mail in the Inbox (only a ruled message, or the user's reply) stays quiet.
        XCTAssertTrue(notifier.plan([row(3)], accounts: [account.id: account], now: Date()).isEmpty)
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
