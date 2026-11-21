import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// The account scope remembered across launches (roadmap Q1.7g): saved whenever it changes, restored by the next
/// window before its list's first query, forgotten when its account is gone, and kept apart for the demo. Every
/// test writes to a throwaway defaults domain of its own, removed afterwards; none touches the app's.
@MainActor
final class AccountScopeMemoryTests: XCTestCase {
    private let a = ListTestSupport.accountA.id
    private let b = ListTestSupport.accountB.id
    private var suites: [String] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            suites = []
        }
        super.tearDown()
    }

    private func throwawaySettings() throws -> (settings: AppSettings, defaults: UserDefaults) {
        let suite = "SuperSparrowAppTests.Scope.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        suites.append(suite)
        return (AppSettings(defaults: defaults), defaults)
    }

    /// The window the next launch builds: the old one torn down, a new one over the same store and defaults.
    private func relaunch(_ harness: MainWindowHarness, remembersScope: Bool = true) -> MainWindowController {
        harness.controller.tearDown()
        let controller = MainWindowController(environment: harness.environment, settings: harness.settings, remembersScope: remembersScope)
        controller.window?.setFrameAutosaveName("")
        controller.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        return controller
    }

    private func close(_ controller: MainWindowController) {
        controller.tearDown()
        controller.close()
    }

    func testAChosenScopeIsSavedAndTheNextLaunchOpensOnIt() throws {
        let (settings, defaults) = try throwawaySettings()
        let harness = try MainWindowHarness(settings: settings)
        defer { harness.close() }
        XCTAssertEqual(harness.controller.strip.scope, .unified)
        XCTAssertNil(defaults.object(forKey: "accountScope"), "nothing is saved until the scope changes")

        try XCTUnwrap(harness.controller.strip.tile(for: .account(a))).performClick(nil)
        XCTAssertEqual(defaults.string(forKey: "accountScope"), a.rawValue, "a click on the account's tile")
        harness.controller.selectAccountShortcut(NSMenuItem.tagged(0))
        XCTAssertEqual(defaults.string(forKey: "accountScope"), "unified", "⌘0 saves All Inboxes")
        // Minimal mode's title menu picks a scope through the same state as the rail.
        harness.controller.listPane.onSelectAccountShortcut?(2)
        XCTAssertEqual(harness.controller.strip.scope, .account(b))
        XCTAssertEqual(defaults.string(forKey: "accountScope"), b.rawValue)
        XCTAssertEqual(settings.savedAccountScope(demo: false), .account(b))

        let next = relaunch(harness)
        defer { close(next) }
        // Checked before the run loop turns: the list's first query is already narrowed, so the first page it
        // shows is the account's, never All Inboxes'.
        XCTAssertEqual(next.strip.scope, .account(b))
        XCTAssertEqual(try XCTUnwrap(next.strip.tile(for: .account(b))).isSelected, true)
        XCTAssertEqual(try XCTUnwrap(next.strip.tile(for: .unified)).isSelected, false)
        XCTAssertEqual(next.list.query.accountIDs, [b])
        XCTAssertEqual(next.listPane.header.address, ListTestSupport.accountB.email)
        ListTestSupport.spin(until: { !next.list.conversations.isEmpty }, timeout: 5)
        XCTAssertFalse(next.list.conversations.isEmpty)
        XCTAssertTrue(next.list.conversations.allSatisfy { $0.id.accountID == b }, "only the account's conversations")
        // Selected before the window had its size, the tile still sits where it belongs: the stack is not scrolled.
        next.strip.view.layoutSubtreeIfNeeded()
        XCTAssertNil(next.strip.clipEdges.top)
        let clip = next.strip.accountClipFrame
        XCTAssertTrue(next.strip.accountTileRects.allSatisfy { clip.contains($0) }, "\(next.strip.accountTileRects) inside \(clip)")
        // The rail's Inbox badge counts the narrowed account's unread mail, not every account's.
        let unified = try XCTUnwrap(next.strip.tile(for: .unified))
        ListTestSupport.spin(until: { unified.unreadCount > 0 }, timeout: 5)
        let inbox = try XCTUnwrap(next.strip.folderTiles.first)
        XCTAssertGreaterThan(inbox.unreadCount, 0)
        XCTAssertLessThan(inbox.unreadCount, unified.unreadCount)
        XCTAssertEqual(inbox.unreadCount, try XCTUnwrap(next.strip.tile(for: .account(b))).unreadCount)
    }

    /// The restore runs before the window has a size (or the user's saved frame), so the rail must not be scrolled
    /// then: the launch opens the rail as choosing the account with ⌘N in that window would leave it. At the
    /// default height accounts that fit stay put, nothing above them hidden; in a shorter saved window a tile
    /// that does not fit is scrolled into view, not left below the clip.
    func testARestoredAccountLeavesTheRailAsChoosingItWouldAtTheWindowsSize() throws {
        let (settings, _) = try throwawaySettings()
        let harness = try MainWindowHarness(settings: settings)
        defer { harness.close() }
        for n in 1...6 {
            try harness.environment.store.upsertAccount(Account(id: AccountID("acct-extra-\(n)"), kind: .gmail, email: "alex@extra\(n).test",
                                                                displayName: "Alex Morgan", addedAt: Date(timeIntervalSince1970: Double(10 + n)),
                                                                inkSlot: 1 + n))
        }
        harness.controller.refreshAccounts()
        let order = harness.controller.strip.accounts.map(\.id)
        XCTAssertEqual(order.count, 8)
        harness.controller.tearDown()

        for (index, height) in [(1, 800.0), (4, 800.0), (6, 600.0)] {
            settings.saveAccountScope(.account(order[index]), demo: false)
            let controller = MainWindowController(environment: harness.environment, settings: settings, remembersScope: true)
            defer { close(controller) }
            controller.window?.setFrameAutosaveName("")
            // As the frame autosave (or a replaced window's frame) sizes the window after init, then the app shows it.
            controller.window?.setContentSize(NSSize(width: MainWindowController.defaultSize.width, height: height))
            controller.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            controller.showWindow(nil)
            let strip = controller.strip
            strip.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(strip.scope, .account(order[index]))
            XCTAssertEqual(try XCTUnwrap(strip.tile(for: .account(order[index]))).isSelected, true)
            let clip = strip.accountClipFrame
            let rects = strip.accountTileRects
            XCTAssertTrue(clip.contains(rects[index]), "account \(index + 1) at \(height): \(rects[index]) inside \(clip)")
            if height == 800 {
                XCTAssertNil(strip.clipEdges.top, "account \(index + 1) fits: the stack is not scrolled")
                XCTAssertTrue(rects[...index].allSatisfy { clip.contains($0) }, "account \(index + 1): every tile above it shows")
            }
        }
    }

    func testASavedAccountThatIsGoneFallsBackToAllInboxesAndIsForgotten() throws {
        let (settings, defaults) = try throwawaySettings()
        settings.saveAccountScope(.account(AccountID("removed-meanwhile")), demo: false)
        let harness = try MainWindowHarness(settings: settings)
        defer { harness.close() }
        XCTAssertEqual(harness.controller.strip.scope, .unified)
        XCTAssertNil(harness.list.query.accountIDs)
        XCTAssertNil(harness.controller.listPane.header.address)
        XCTAssertNil(defaults.object(forKey: "accountScope"), "the saved value is cleared")
    }

    func testRemovingTheScopedAccountResetsToAllInboxesAndSavesThat() throws {
        let (settings, defaults) = try throwawaySettings()
        let harness = try MainWindowHarness(settings: settings)
        defer { harness.close() }
        try XCTUnwrap(harness.controller.strip.tile(for: .account(b))).performClick(nil)
        XCTAssertEqual(defaults.string(forKey: "accountScope"), b.rawValue)

        // What Settings › Remove leaves behind: the account gone from the store, and the window told.
        try harness.environment.store.deleteAccount(b)
        harness.controller.refreshAccounts()
        XCTAssertEqual(harness.controller.strip.scope, .unified)
        XCTAssertNil(harness.list.query.accountIDs)
        XCTAssertEqual(defaults.string(forKey: "accountScope"), "unified")
    }

    func testTheDemoKeepsAScopeOfItsOwn() throws {
        let (settings, defaults) = try throwawaySettings()
        settings.saveAccountScope(.account(a), demo: false)
        let demo = try MainWindowHarness(settings: settings, demo: true)
        XCTAssertEqual(demo.controller.strip.scope, .unified, "the demo does not open on the real choice")
        demo.controller.listPane.onSelectAccountShortcut?(2)
        XCTAssertEqual(defaults.string(forKey: "accountScope.demo"), b.rawValue)
        XCTAssertEqual(defaults.string(forKey: "accountScope"), a.rawValue, "the real choice is untouched")

        let nextDemo = relaunch(demo)
        XCTAssertEqual(nextDemo.strip.scope, .account(b), "the demo remembers its own")
        close(nextDemo)
        demo.close()

        let real = try MainWindowHarness(settings: settings)
        defer { real.close() }
        XCTAssertEqual(real.controller.strip.scope, .account(a), "the real accounts open on the real choice")
        XCTAssertEqual(real.list.query.accountIDs, [a])
    }

    /// The saved scope is checked against the first accounts the window reads. A first read that finds none (one
    /// that failed) says nothing about it, so the same accounts read later still restore it.
    func testAFirstReadWithNoAccountsLeavesTheSavedScopeForTheAccountsReadLater() throws {
        let (settings, defaults) = try throwawaySettings()
        settings.saveAccountScope(.account(b), demo: false)
        let harness = try MainWindowHarness(accounts: false, settings: settings)
        defer { harness.close() }
        XCTAssertEqual(harness.controller.strip.scope, .unified)
        XCTAssertEqual(defaults.string(forKey: "accountScope"), b.rawValue, "no accounts read yet: nothing to judge it against")

        try MainWindowHarness.seed(harness.environment.store)
        harness.controller.refreshAccounts()
        XCTAssertEqual(harness.controller.strip.scope, .account(b))
        XCTAssertEqual(harness.list.query.accountIDs, [b])
        XCTAssertEqual(harness.controller.listPane.header.address, ListTestSupport.accountB.email)
        XCTAssertEqual(defaults.string(forKey: "accountScope"), b.rawValue)
    }

    /// A demo seeded after its window opens (its first launch, or after its data was wiped) cannot get its saved
    /// account back: the seeder signs every account in afresh, under a new id. The saved account is gone, so the
    /// demo opens on All Inboxes and forgets it.
    func testADemoReseededAfterItsWindowOpensForgetsItsSavedAccount() throws {
        let (settings, defaults) = try throwawaySettings()
        settings.saveAccountScope(.account(b), demo: true)
        let demo = try MainWindowHarness(accounts: false, settings: settings, demo: true)
        defer { demo.close() }
        for profile in [ListTestSupport.accountA, ListTestSupport.accountB] {
            var account = profile
            account.id = AccountID(UUID().uuidString)
            try demo.environment.store.upsertAccount(account)
        }
        demo.controller.refreshAccounts()
        XCTAssertEqual(demo.controller.strip.accounts.count, 2)
        XCTAssertEqual(demo.controller.strip.scope, .unified)
        XCTAssertNil(demo.list.query.accountIDs)
        XCTAssertNil(defaults.object(forKey: "accountScope.demo"), "the previous demo's account is forgotten")
    }

    func testASnapshotWindowNeitherReadsNorWritesTheScope() throws {
        let (settings, defaults) = try throwawaySettings()
        settings.saveAccountScope(.account(b), demo: false)
        let harness = try MainWindowHarness(settings: settings, remembersScope: false)
        defer { harness.close() }
        XCTAssertEqual(harness.controller.strip.scope, .unified, "a render depends on the build alone")
        harness.controller.listPane.onSelectAccountShortcut?(1)
        XCTAssertEqual(defaults.string(forKey: "accountScope"), b.rawValue, "the user's choice is untouched")

        settings.saveAccountScope(.account(AccountID("removed-meanwhile")), demo: false)
        let next = relaunch(harness, remembersScope: false)
        defer { close(next) }
        XCTAssertEqual(defaults.string(forKey: "accountScope"), "removed-meanwhile", "not even a stale value is cleared")

        XCTAssertFalse(LaunchOptions(arguments: ["SuperSparrow"]).isSnapshot)
        XCTAssertFalse(LaunchOptions(arguments: ["SuperSparrow", "--demo", "--reset-demo"]).isSnapshot)
        #if DEBUG
        for option in ["--snapshot=/tmp/x.png", "--snapshot-compose=/tmp/x.png", "--snapshot-welcome=/tmp/x.png",
                       "--snapshot-welcome-states=/tmp/x.png", "--snapshot-settings=/tmp/x.png", "--snapshot-settings-states=/tmp/x.png",
                       "--snapshot-senders=/tmp/x.png", "--snapshot-cheatsheet=/tmp/x.png", "--snapshot-hud=/tmp/x.png", "--snapshot-alerts=/tmp/x.png",
                       "--snapshot-gallery=/tmp/x.png"] {
            XCTAssertTrue(LaunchOptions(arguments: ["SuperSparrow", "--demo", option]).isSnapshot, option)
        }
        #endif
    }

    /// Minimal mode's new-mail dot (§5.3) counts from the moment the scope was chosen; for a restored scope that is
    /// the launch, so mail already unread in another account does not light it, and mail that comes after does.
    func testARestoredScopeCountsNewMailFromTheLaunch() throws {
        let (settings, _) = try throwawaySettings()
        settings.saveAccountScope(.account(a), demo: false)
        let harness = try MainWindowHarness(settings: settings)
        defer { harness.close() }
        let controller = harness.controller
        XCTAssertEqual(controller.strip.scope, .account(a))
        let other = try XCTUnwrap(controller.strip.tile(for: .account(b)))
        harness.spin { other.unreadCount > 0 }
        XCTAssertGreaterThan(other.unreadCount, 0, "the other account has unread mail from before the launch")

        controller.toggleAccountStrip(nil)
        defer { controller.toggleAccountStrip(nil) }
        let header = controller.listPane.header
        XCTAssertFalse(header.showsNewMailDot, "nothing new since the launch")

        let before = other.unreadCount
        let conversation = ConversationID(accountID: b, providerID: "thread-new")
        try harness.environment.store.upsertMessages([MessageMetadata(
            id: MessageID(accountID: b, providerID: "msg-new"), conversationID: conversation, subject: "Fresh", snippet: "New",
            from: ListTestSupport.senders[0], to: [], date: Date(), roles: [.inbox], isRead: false, isStarred: false,
            inboxSection: .focused, hasAttachments: false)])
        harness.spin { other.unreadCount > before }
        XCTAssertTrue(header.showsNewMailDot, "mail that came after the launch lights the dot")
    }
}

private extension NSMenuItem {
    /// A View menu account item, as `selectAccountShortcut(_:)` receives it.
    static func tagged(_ tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.tag = tag
        return item
    }
}
