import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// Builds mailboxes and hosts the message list for the list's tests.
@MainActor
enum ListTestSupport {
    nonisolated static let accountA = Account(id: AccountID("acct-a"), kind: .gmail, email: "alex@contoso.test", displayName: "Alex Morgan",
                                  addedAt: Date(timeIntervalSince1970: 0), inkSlot: 0)
    nonisolated static let accountB = Account(id: AccountID("acct-b"), kind: .microsoft, email: "alex@fabrikam.test", displayName: "Alex Morgan",
                                  addedAt: Date(timeIntervalSince1970: 1), inkSlot: 1)

    nonisolated static let senders: [EmailAddress] = {
        let first = ["Ada", "Grace", "Linus", "Margaret", "Dennis", "Barbara", "Ken", "Radia", "Alan", "Hedy", "Priya", "Ben"]
        let last = ["Lovelace", "Hopper", "Torvalds", "Hamilton", "Ritchie", "Raman", "Carter"]
        var people: [EmailAddress] = []
        for f in first {
            for l in last {
                people.append(EmailAddress(name: "\(f) \(l)", address: "\(f.lowercased()).\(l.lowercased())@example.com"))
            }
        }
        return people
    }()

    /// `count` threads of one to three messages, newest first, one every `spacing` seconds back from `now`,
    /// alternating between the two accounts; every third unread, every fifth starred, every seventh in Other.
    static func messages(threads count: Int, now: Date = Date(), spacing: TimeInterval = 3_600,
                         accounts: [Account] = [accountA, accountB]) -> [MessageMetadata] {
        var result: [MessageMetadata] = []
        result.reserveCapacity(count * 2)
        for index in 0..<count {
            let account = accounts[index % accounts.count]
            let conversation = ConversationID(accountID: account.id, providerID: "thread-\(index)")
            let size = index % 3 + 1
            let latest = now.addingTimeInterval(-Double(index) * spacing - 60)
            for part in 0..<size {
                let fromUser = part == 1
                let sender = fromUser ? EmailAddress(name: account.displayName, address: account.email) : senders[(index + part) % senders.count]
                result.append(MessageMetadata(
                    id: MessageID(accountID: account.id, providerID: "msg-\(index)-\(part)"),
                    conversationID: conversation,
                    subject: index % 11 == 5 ? "" : "Project update \(index) and the quarterly planning document",
                    snippet: "Just following up on the thread from last week. Let me know if Tuesday works for the review.",
                    from: sender,
                    to: [EmailAddress(name: account.displayName, address: account.email)],
                    date: latest.addingTimeInterval(-Double(size - 1 - part) * 120),
                    roles: [.inbox],
                    isRead: !(index % 3 == 0 && part == size - 1),
                    isStarred: index % 5 == 0,
                    inboxSection: index % 7 == 3 ? .other : .focused,
                    hasAttachments: index % 4 == 1
                ))
            }
        }
        return result
    }

    static func store(threads: Int, now: Date = Date(), spacing: TimeInterval = 3_600) throws -> InMemoryMailStore {
        let store = InMemoryMailStore()
        try store.upsertAccount(accountA)
        try store.upsertAccount(accountB)
        try store.upsertMessages(messages(threads: threads, now: now, spacing: spacing))
        return store
    }

    static func settings(density: AppSettings.ListDensity = .standard, initials: Bool = false) -> AppSettings {
        let defaults = UserDefaults(suiteName: "SuperSparrowAppTests.\(UUID().uuidString)") ?? .standard
        let settings = AppSettings(defaults: defaults)
        settings.listDensity = density
        settings.showAccountInitials = initials
        return settings
    }

    /// The list in a window off screen, sized like the app's list pane, with its first page delivered.
    static func host(store: MailStoring, query: ConversationQuery = ConversationQuery(), settings: AppSettings,
                     size: NSSize = NSSize(width: 380, height: 700)) -> (list: MessageListViewController, window: NSWindow) {
        let list = MessageListViewController(store: store, query: query, settings: settings)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        window.setContentSize(size)
        list.accountsByID = [accountA.id: accountA, accountB.id: accountB]
        spin(until: { list.layout.rowCount > 0 || !list.emptyView.isHidden }, timeout: 5)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return (list, window)
    }

    /// Runs the main run loop until `condition` holds or `timeout` passes; observations and timers deliver there.
    @discardableResult
    static func spin(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    static func spin(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }
}
