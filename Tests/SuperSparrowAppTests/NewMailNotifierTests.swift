import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// New-mail notifications (spec §5.41): while the app is frontmost they come without sound, and the
/// conversation open in a key window never notifies.
@MainActor
final class NewMailNotifierTests: XCTestCase {
    private let account = ListTestSupport.accountA

    private func row(_ n: Int, message: Int = 0) -> ConversationSummary {
        ConversationSummary(
            id: ConversationID(accountID: account.id, providerID: "t\(n)"), subject: "Subject \(n)", snippet: "Snippet",
            participants: [EmailAddress(name: "Ben Carter", address: "ben@example.com")], latestDate: Date(), messageCount: 1,
            unreadCount: 1, isStarred: false, hasAttachments: false, inInbox: true, inboxSection: .focused,
            latestMessageID: MessageID(accountID: account.id, providerID: "m\(n)-\(message)"), hasPendingOperations: false)
    }

    private func notifier() -> NewMailNotifier {
        let settings = ListTestSupport.settings()
        settings.notificationsEnabled = true
        let notifier = NewMailNotifier(settings: settings)
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
}
