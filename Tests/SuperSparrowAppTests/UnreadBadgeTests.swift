import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The unread count's bubbles (spec §5.28): the Dock badge, the rail's tiles and the title menu read one formatter,
/// so they agree (“99+” above 99, nothing at zero); the Dock shows All Inboxes' count of the newest running window,
/// and a window torn down after its successor has counted leaves that count showing. No test writes to the real
/// Dock tile: each gives its monitor or window a stand-in.
@MainActor
final class UnreadBadgeTests: XCTestCase {
    private let a = ListTestSupport.accountA
    private let b = ListTestSupport.accountB

    /// A Dock tile that records what it is told.
    private final class FakeDockTile: DockBadgeTile {
        var writes: [String?] = []
        var badgeLabel: String? {
            didSet { writes.append(badgeLabel) }
        }
    }

    /// `count` messages in one Inbox conversation of `account`, unread unless `read`; the same ids every time, so a
    /// larger pile takes in a smaller one and a read pile reads it.
    private func pile(_ count: Int, in account: Account, read: Bool = false) -> [MessageMetadata] {
        let now = Date()
        return (0..<count).map { index in
            MessageMetadata(
                id: MessageID(accountID: account.id, providerID: "pile-\(index)"),
                conversationID: ConversationID(accountID: account.id, providerID: "pile"),
                subject: "Weekly digest",
                snippet: "Everything that happened this week.",
                from: ListTestSupport.senders[index % ListTestSupport.senders.count],
                to: [EmailAddress(name: account.displayName, address: account.email)],
                date: now.addingTimeInterval(-Double(index) * 60),
                roles: [.inbox],
                isRead: read,
                isStarred: false,
                inboxSection: .focused,
                hasAttachments: false
            )
        }
    }

    private func store(unread: Int = 0) throws -> InMemoryMailStore {
        let store = InMemoryMailStore()
        try store.upsertAccount(a)
        try store.upsertAccount(b)
        if unread > 0 { try store.upsertMessages(pile(unread, in: a)) }
        return store
    }

    private func spin(until condition: () -> Bool) {
        ListTestSupport.spin(until: condition, timeout: 5)
    }

    // MARK: The monitor's label

    func testTheDockShowsAllInboxesUnreadCountInTheRailsWords() throws {
        let store = try store()
        let tile = FakeDockTile()
        let monitor = InboxMonitor(store: store, dockBadge: DockBadge(tile: tile))
        var counted: Int?
        monitor.onCounts = { unified, _ in counted = unified }
        monitor.start(accounts: [a.id, b.id])
        defer { monitor.stop() }

        spin { counted == 0 }
        XCTAssertEqual(counted, 0)
        XCTAssertNil(tile.badgeLabel, "an empty inbox has no badge")
        XCTAssertTrue(tile.writes.isEmpty, "and the Dock is never told “0”")

        for (count, label) in [(1, "1"), (99, "99"), (100, "99+"), (1_234, "99+")] {
            try store.upsertMessages(pile(count, in: a))
            spin { counted == count }
            XCTAssertEqual(counted, count)
            XCTAssertEqual(tile.badgeLabel, label, "\(count) unread")
            XCTAssertEqual(tile.badgeLabel, QuireBadge.unreadText(count), "the words the rail's badges use")
        }
        XCTAssertEqual(tile.writes, ["1", "99", "99+"], "a count past the cap that reads the same writes nothing")

        // Every account counts: the Dock is All Inboxes, whatever the window is narrowed to.
        try store.upsertMessages(pile(1_234, in: a, read: true))
        try store.upsertMessages(pile(3, in: b))
        spin { counted == 3 }
        XCTAssertEqual(tile.badgeLabel, "3")
        try store.upsertMessages(pile(2, in: a))
        spin { counted == 5 }
        XCTAssertEqual(tile.badgeLabel, "5")

        try store.upsertMessages(pile(2, in: a, read: true))
        try store.upsertMessages(pile(3, in: b, read: true))
        spin { counted == 0 }
        XCTAssertNil(tile.badgeLabel, "reading the last unread message clears the badge")
        XCTAssertEqual(tile.writes.last, .some(nil))
    }

    func testStoppingClearsTheBadge() throws {
        let tile = FakeDockTile()
        let monitor = InboxMonitor(store: try store(unread: 12), dockBadge: DockBadge(tile: tile))
        monitor.start(accounts: [a.id, b.id])
        spin { tile.badgeLabel == "12" }
        XCTAssertEqual(tile.badgeLabel, "12")
        monitor.stop()
        XCTAssertNil(tile.badgeLabel)
    }

    /// The demo and the real mailbox cross-fade (§5.43): the new window counts while the old one is still on screen,
    /// and the old one is torn down after.
    func testAWindowTornDownAfterItsReplacementLeavesTheNewCount() throws {
        let tile = FakeDockTile()
        let badge = DockBadge(tile: tile)
        let demo = try store(unread: 7)
        let old = InboxMonitor(store: demo, dockBadge: badge)
        var oldCount: Int?
        old.onCounts = { unified, _ in oldCount = unified }
        old.start(accounts: [a.id, b.id])
        spin { tile.badgeLabel == "7" }
        XCTAssertEqual(tile.badgeLabel, "7")

        let new = InboxMonitor(store: try store(unread: 150), dockBadge: badge)
        new.start(accounts: [a.id, b.id])
        spin { tile.badgeLabel == "99+" }
        XCTAssertEqual(tile.badgeLabel, "99+", "the newer window's count")

        try demo.upsertMessages(pile(8, in: a))
        spin { oldCount == 8 }
        XCTAssertEqual(oldCount, 8)
        XCTAssertEqual(tile.badgeLabel, "99+", "the old window still counts, but no longer shows")

        old.stop()
        XCTAssertEqual(tile.badgeLabel, "99+", "tearing the old window down leaves the new count")
        new.stop()
        XCTAssertNil(tile.badgeLabel)
    }

    func testTheNewestHolderThatHasCountedIsShown() {
        let tile = FakeDockTile()
        let badge = DockBadge(tile: tile)
        let first = NSObject()
        let second = NSObject()
        badge.claim(first)
        badge.show(unread: 12, for: first)
        XCTAssertEqual(badge.text, "12")

        badge.claim(second)
        XCTAssertEqual(badge.text, "12", "a holder that has not counted yet leaves the last count")
        badge.show(unread: 0, for: second)
        XCTAssertNil(badge.text, "the newest holder's zero clears the badge")
        badge.show(unread: 40, for: first)
        XCTAssertNil(badge.text, "an older holder's count does not show over it")

        badge.release(second)
        XCTAssertEqual(badge.text, "40", "with the newest gone, the one before it shows again")
        badge.show(unread: 5, for: NSObject())
        XCTAssertEqual(badge.text, "40", "a count from something that never claimed the badge is ignored")

        do {
            let freed = NSObject()
            badge.claim(freed)
            badge.show(unread: 300, for: freed)
            XCTAssertEqual(badge.text, "99+")
        }
        badge.show(unread: 41, for: first)
        XCTAssertEqual(badge.text, "41", "a holder freed without stopping leaves nothing behind")

        badge.release(first)
        XCTAssertNil(badge.text)
    }

    // MARK: The rail, the title menu and the Dock together

    func testTheRailsTilesTheTitleMenuAndTheDockAgree() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        // The harness's own window badges the app's tile; this one gets a stand-in.
        harness.controller.tearDown()
        // The badge is not a notification: Settings' New mail switch leaves it. Only macOS's own Badges switch (or
        // notifications denied) hides it, and the app sets it all the same.
        harness.settings.notificationsEnabled = false
        let dock = FakeDockTile()
        let controller = MainWindowController(environment: harness.environment, settings: harness.settings, remembersScope: false,
                                              dockBadge: DockBadge(tile: dock))
        defer {
            controller.tearDown()
            controller.close()
        }
        controller.window?.setFrameAutosaveName("")
        controller.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        let store = harness.environment.store
        let strip = controller.strip
        let unified = try XCTUnwrap(strip.tile(for: .unified))
        let tileA = try XCTUnwrap(strip.tile(for: .account(a.id)))
        let tileB = try XCTUnwrap(strip.tile(for: .account(b.id)))
        let inbox = try XCTUnwrap(strip.folderTiles.first)

        try store.upsertMessages(pile(120, in: a))
        let countA = try store.unreadInboxCount(accountIDs: [a.id])
        let countB = try store.unreadInboxCount(accountIDs: [b.id])
        XCTAssertGreaterThan(countA, 99)
        XCTAssertGreaterThan(countB, 0)
        XCTAssertLessThan(countB, 100)
        spin { unified.unreadCount == countA + countB && tileA.unreadCount == countA }

        XCTAssertEqual(unified.unreadBadgeText, "99+")
        XCTAssertEqual(inbox.unreadBadgeText, "99+", "All Inboxes is in scope: the Inbox tile counts every account")
        XCTAssertEqual(tileA.unreadBadgeText, "99+")
        XCTAssertEqual(tileB.unreadBadgeText, QuireBadge.unreadText(countB))
        XCTAssertEqual(dock.badgeLabel, "99+", "the Dock reads as All Inboxes does")
        XCTAssertEqual(tileA.accessibilityHelp(), QuireBadge.unreadAccessibilityText(countA), "VoiceOver hears the real count")
        XCTAssertNil(strip.folderTiles.dropFirst().first { $0.unreadBadgeText != nil }, "no other folder has a badge")

        // Minimal mode's title menu stands in for the rail and carries the same words.
        var model = try XCTUnwrap(controller.listPane.titleMenuModel?())
        model.showsAccounts = true
        let action = #selector(MainWindowController.goToMailboxView(_:))
        let menu = TitleMenu.build(model, target: self, viewAction: action, scopeAction: action)
        // View items carry their G-sequence in the title after a tab; the scope items are found by their ⌘ number.
        func menuBadge(view: String? = nil, key: String? = nil) -> String? {
            menu.items.first { item in view.map { item.title.hasPrefix($0 + "\t") } ?? (item.keyEquivalent == key) }?.badge?.stringValue
        }
        XCTAssertEqual(menuBadge(view: "Inbox"), inbox.unreadBadgeText)
        XCTAssertNil(menuBadge(view: "All Mail"))
        XCTAssertEqual(menuBadge(key: "0"), unified.unreadBadgeText)
        XCTAssertEqual(menuBadge(key: "1"), tileA.unreadBadgeText)
        XCTAssertEqual(menuBadge(key: "2"), tileB.unreadBadgeText)

        // Narrowed, the Inbox tile counts that account's mail; the Dock stays on All Inboxes.
        tileB.performClick(nil)
        XCTAssertEqual(strip.scope, .account(b.id))
        XCTAssertEqual(inbox.unreadBadgeText, tileB.unreadBadgeText)
        XCTAssertEqual(inbox.unreadBadgeText, QuireBadge.unreadText(countB))
        XCTAssertEqual(dock.badgeLabel, "99+")

        // Everything read: no bubble anywhere, and the Dock badge is cleared, not “0”.
        var read = pile(120, in: a, read: true)
        read += ListTestSupport.messages(threads: 8, spacing: 600).map { message in
            var message = message
            message.isRead = true
            return message
        }
        try store.upsertMessages(read)
        spin { unified.unreadCount == 0 && dock.badgeLabel == nil }
        for tile in [unified, inbox, tileA, tileB] {
            XCTAssertNil(tile.unreadBadgeText)
            XCTAssertNil(tile.accessibilityHelp())
        }
        XCTAssertNil(dock.badgeLabel)
        XCTAssertFalse(dock.writes.contains("0"))
        XCTAssertNil(TitleMenu.unreadBadge(0))
    }

    func testTitleMenuBadgesCapAsTheRailDoes() {
        XCTAssertNil(TitleMenu.unreadBadge(0))
        XCTAssertNil(TitleMenu.unreadBadge(-1))
        XCTAssertEqual(TitleMenu.unreadBadge(1)?.stringValue, "1")
        XCTAssertEqual(TitleMenu.unreadBadge(99)?.stringValue, "99")
        XCTAssertEqual(TitleMenu.unreadBadge(100)?.stringValue, "99+")
        XCTAssertEqual(TitleMenu.unreadBadge(1_234)?.stringValue, "99+")
    }
}
