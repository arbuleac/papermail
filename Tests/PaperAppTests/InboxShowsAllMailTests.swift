import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// The Inbox always shows all of its mail (spec §5.5): no Focused or Other filter, no ⌥1–⌥3, and no “Other”
/// tag on any row (§5.7), while the provider's category stays on the summaries to round-trip provider state.
@MainActor
final class InboxShowsAllMailTests: XCTestCase {
    func testTheInboxListsFocusedAndOtherMailTogether() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let inboxCount = try harness.environment.store.conversations(ConversationQuery(view: .inbox)).count
        func assertAllOfTheInbox(_ when: String) {
            XCTAssertEqual(harness.list.query.view, .inbox, when)
            XCTAssertNil(harness.list.query.section, when)
            XCTAssertEqual(Set(harness.list.conversations.map(\.inboxSection)), [.focused, .other], "both categories \(when)")
            XCTAssertEqual(harness.list.conversations.count, inboxCount, "every Inbox conversation \(when)")
        }
        assertAllOfTheInbox("in a new window")

        // ⌥1–⌥3 used to pick All, Focused and Other from the View menu. Whatever answers them now (nothing should)
        // is sent to the window, and the Inbox still lists all of its mail.
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["Paper"])))
        for digit in ["2", "3", "1", "3"] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0,
                                                       context: nil, characters: digit, charactersIgnoringModifiers: digit,
                                                       isARepeat: false, keyCode: 18))
            if let item = MainMenuBar.exactItem(for: event, in: bar), let action = item.action,
               harness.controller.responds(to: action) {
                NSApp.sendAction(action, to: harness.controller, from: item)
            }
            ListTestSupport.spin(for: 0.1)
            assertAllOfTheInbox("after ⌥\(digit)")
        }
    }

    /// Nothing in the window keeps a section: every view, a search and a return to the Inbox all ask for none.
    func testNoViewOrSearchEverAsksForASection() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        for view in MailboxView.allCases {
            _ = harness.controller.perform(.goTo(view))
            XCTAssertNil(harness.list.query.section, "\(view)")
        }
        harness.controller.listPane.header.search.query = "project"
        harness.controller.listPane.header.search.onQueryChange?("project")
        harness.spin { harness.list.query.searchText == "project" }
        XCTAssertNil(harness.list.query.section)
        harness.controller.strip.folderTiles[0].performClick(nil)
        XCTAssertEqual(harness.list.query, ConversationQuery(view: .inbox), "back in the Inbox: all of it")
    }

    func testOptionOneTwoThreeDoNothing() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        XCTAssertFalse(harness.controller.responds(to: NSSelectorFromString("selectInboxSection:")), "the filter command is gone")

        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["Paper"])))
        for digit in ["1", "2", "3"] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0,
                                                       context: nil, characters: digit, charactersIgnoringModifiers: digit,
                                                       isARepeat: false, keyCode: 18))
            XCTAssertNil(MainMenuBar.exactItem(for: event, in: bar), "⌥\(digit) matches no menu item")
        }
        let view = try XCTUnwrap(bar.items.first { $0.title == "View" }?.submenu)
        XCTAssertFalse(view.items.contains { ["All", "Focused", "Other"].contains($0.title) }, "no filter items in View")
        // ⌘0…⌘9 and the views are still there.
        XCTAssertTrue(view.items.contains { $0.title == "All Inboxes" && $0.keyEquivalent == "0" })
        XCTAssertTrue(view.items.contains { $0.title.hasPrefix("Inbox") })
    }

    // MARK: Rows

    /// The same newsletter twice, once in each category, newer than the seeded mail so both rows are on screen.
    private func addTwins(to harness: MainWindowHarness) throws -> (focused: ConversationID, other: ConversationID) {
        let account = ListTestSupport.accountA
        let date = Date().addingTimeInterval(-30)
        func twin(_ section: InboxSection) -> MessageMetadata {
            MessageMetadata(id: MessageID(accountID: account.id, providerID: "twin-\(section.rawValue)"),
                            conversationID: ConversationID(accountID: account.id, providerID: "twin-\(section.rawValue)"),
                            subject: "Issue #182: Quiet software", snippet: "This week: the case for fewer notifications.",
                            from: EmailAddress(name: "Northwind Weekly", address: "news@northwind.test"),
                            to: [EmailAddress(name: account.displayName, address: account.email)], date: date, roles: [.inbox],
                            isRead: true, isStarred: false, inboxSection: section, hasAttachments: false)
        }
        try harness.environment.store.upsertMessages([twin(.focused), twin(.other)])
        let ids = (focused: ConversationID(accountID: account.id, providerID: "twin-focused"),
                   other: ConversationID(accountID: account.id, providerID: "twin-other"))
        harness.spin { Set(harness.list.conversations.map(\.id)).isSuperset(of: [ids.focused, ids.other]) }
        return ids
    }

    /// The cell the list itself configured for a conversation.
    private func cell(for id: ConversationID, in list: MessageListViewController) throws -> ConversationCellView {
        let index = try XCTUnwrap(list.conversations.firstIndex { $0.id == id }, "\(id.providerID) is listed")
        let row = try XCTUnwrap(list.layout.row(ofConversation: index))
        list.tableView.scrollRowToVisible(row)
        list.view.window?.displayIfNeeded()
        return try XCTUnwrap(list.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ConversationCellView)
    }

    /// The sender line's right half (the time cluster, where the tag sat) as pixels; the face is left out because
    /// faces render asynchronously the first time.
    private func timeCluster(of cell: ConversationCellView) throws -> Data {
        let region = NSRect(x: cell.bounds.midX, y: 0, width: cell.bounds.width / 2, height: 30)
        let rep = try XCTUnwrap(cell.bitmapImageRepForCachingDisplay(in: region))
        cell.cacheDisplay(in: region, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Rows read through the real list: an Other conversation draws and reads exactly as its Focused twin, in the
    /// Inbox (where the tag used to show), in All Mail and in search results.
    func testNoRowCarriesAnOtherTagInAnyView() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let twins = try addTwins(to: harness)
        harness.list.selectedConversationID = nil
        for view in [MailboxView.inbox, .all, .inbox] {
            _ = harness.controller.perform(.goTo(view))
            harness.spin { harness.list.query.view == view && harness.list.conversations.contains { $0.id == twins.other } }
            let other = try cell(for: twins.other, in: harness.list)
            let focused = try cell(for: twins.focused, in: harness.list)
            let label = try XCTUnwrap(other.accessibilityLabel())
            XCTAssertEqual(label, focused.accessibilityLabel(), "\(view): the row reads the same")
            XCTAssertFalse(label.contains("Other."), "\(view): \(label)")
            XCTAssertEqual(try timeCluster(of: other), try timeCluster(of: focused), "\(view): no tag in the time cluster")
        }
        harness.controller.listPane.header.search.query = "Quiet software"
        harness.controller.listPane.header.search.onQueryChange?("Quiet software")
        harness.spin { harness.list.query.searchText == "Quiet software" && harness.list.conversations.contains { $0.id == twins.other } }
        let other = try cell(for: twins.other, in: harness.list)
        XCTAssertEqual(other.accessibilityLabel(), try cell(for: twins.focused, in: harness.list).accessibilityLabel(), "search results")
    }
}
