import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// The end of a search (spec §5.10, roadmap Q3.1) in the real main window: once every local result is listed the list
/// ends with “Search Gmail for more”, ⌘↩ in the field or the row's link runs it, the row says how it went, the found
/// conversations join the results in date order, and new words start fresh. The engine is replaced by a search the test
/// answers, so nothing reaches a provider.
@MainActor
final class ServerSearchListTests: XCTestCase {
    private var harness: MainWindowHarness!
    private var server: FakeServerSearch!

    // Synchronous on purpose, like the harness: an async setUp or tearDown would hold the main queue that the store's
    // observations and the harness's shutdown deliver on.
    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MainWindowHarness()
        server = FakeServerSearch()
        harness.list.serverSearch.search = server.search
    }

    override func tearDownWithError() throws {
        server.cancelAll()
        harness.close()
        harness = nil
        server = nil
        try super.tearDownWithError()
    }

    private var list: MessageListViewController { harness.list }
    private var pane: ListPaneViewController { harness.controller.listPane }

    /// Types `words` into the search field and waits for their first page.
    private func search(_ words: String, waitForRows: Bool = true) {
        pane.header.search.query = words
        pane.header.search.onQueryChange?(words)
        guard waitForRows else { return }
        pane.sendPendingSearch()
        harness.spin { self.list.query.searchText == words && self.list.hasReceivedFirstPage }
    }

    private var rowView: ServerSearchRowView? {
        guard let row = list.layout.serverSearchRow else { return nil }
        list.view.window?.layoutIfNeeded()
        list.tableView.scrollRowToVisible(row)
        return list.tableView.rowView(atRow: row, makeIfNecessary: true) as? ServerSearchRowView
    }

    private var rowTitle: String? { list.serverSearchRow?.title }

    private func menuItem() -> NSMenuItem {
        NSMenuItem(title: "", action: #selector(MainWindowController.searchServer(_:)), keyEquivalent: "")
    }

    /// Two conversations the server found: stored as the engine would store them, with nothing that says “quarterly”,
    /// read unless `unread` says otherwise.
    private func storeFoundMessages(unread: [Bool] = [false, false]) throws -> [ConversationID] {
        let now = Date()
        let found = [(ListTestSupport.accountA, now.addingTimeInterval(-900)), (ListTestSupport.accountB, now.addingTimeInterval(-40 * 86_400))]
        let messages = found.enumerated().map { index, entry in
            MessageMetadata(
                id: MessageID(accountID: entry.0.id, providerID: "found-\(index)"),
                conversationID: ConversationID(accountID: entry.0.id, providerID: "found-thread-\(index)"),
                subject: "From the archive \(index)", snippet: "Older mail", from: ListTestSupport.senders[index],
                date: entry.1, roles: [], isRead: !unread[index], isStarred: false, hasAttachments: false
            )
        }
        try harness.environment.store.upsertMessages(messages)
        return messages.map(\.conversationID)
    }

    private func unreadCount(_ id: ConversationID) throws -> Int? {
        try harness.environment.store.conversations(ConversationQuery(view: .all)).first { $0.id == id }?.unreadCount
    }

    // MARK: When the row shows, and its words

    func testASearchEndsWithTheRowOnceEveryResultIsListedNamingTheScope() throws {
        XCTAssertNil(list.layout.serverSearchRow, "a mailbox view is not a search")
        search("quarterly")
        XCTAssertEqual(list.layout.items.last, .serverSearch)
        XCTAssertEqual(rowTitle, "Search all accounts for more", "unified, two accounts")
        XCTAssertEqual(rowView?.link.isHidden, false, "the offer is a link")
        XCTAssertEqual(rowView?.link.toolTip, "Search All Accounts for More  ⌘↩")
        XCTAssertFalse(list.tableView(list.tableView, shouldSelectRow: try XCTUnwrap(list.layout.serverSearchRow)))

        harness.controller.strip.select(.account(ListTestSupport.accountA.id), notify: true)
        harness.spin { self.list.query.accountIDs == [ListTestSupport.accountA.id] && self.list.layout.serverSearchRow != nil }
        XCTAssertEqual(rowTitle, "Search Gmail for more")
        harness.controller.strip.select(.account(ListTestSupport.accountB.id), notify: true)
        harness.spin { self.list.query.accountIDs == [ListTestSupport.accountB.id] && self.list.layout.serverSearchRow != nil }
        XCTAssertEqual(rowTitle, "Search Outlook for more")

        // j at the last conversation stays there: the row is not a conversation.
        let last = try XCTUnwrap(list.conversations.last?.id)
        list.selectedConversationID = last
        list.selectNext()
        XCTAssertEqual(list.selectedConversationID, last)
    }

    func testTheRowWaitsForTheLastPage() throws {
        harness.close()
        harness = try MainWindowHarness(threads: 250, spacing: 60)
        harness.list.serverSearch.search = server.search
        search("quarterly")
        XCTAssertNil(list.layout.serverSearchRow, "older results are still to load: the tail ends the list, not the row")
        XCTAssertFalse(list.canRequestServerSearch)
        XCTAssertFalse(harness.controller.validateMenuItem(menuItem()), "⌘↩ waits for the end of the local results too")
    }

    // MARK: ⌘↩ and ↩

    func testCommandReturnRunsItAndReturnStillGoesToTheList() throws {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let commandReturn = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                                           context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                           isARepeat: false, keyCode: 36))
        MainMenuController.shared?.updateForKeyWindow()
        let item = try XCTUnwrap(MainMenuBar.exactItem(for: commandReturn, in: bar), "⌘↩ is an Edit item while no composer is key")
        XCTAssertEqual(item.action, #selector(MainWindowController.searchServer(_:)))
        XCTAssertFalse(harness.controller.validateMenuItem(item), "no words, nothing to search")

        pane.focusSearch()
        search("quarterly")
        XCTAssertTrue(pane.isSearchFocused)
        XCTAssertTrue(harness.controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Search All Accounts for More", "titled by the scope")

        // ↩ in the field keeps giving the keyboard to the list, and searches nothing.
        pane.header.search.onSubmit?("quarterly")
        XCTAssertTrue(harness.controller.window?.firstResponder === list.tableView)
        XCTAssertEqual(server.calls.count, 0)

        pane.focusSearch()
        NSApp.sendAction(try XCTUnwrap(item.action), to: harness.controller, from: item)
        harness.spin { self.server.calls.count == 1 }
        XCTAssertEqual(server.calls.first?.words, "quarterly")
        XCTAssertNil(server.calls.first?.scope, "every account")
        XCTAssertFalse(harness.controller.validateMenuItem(item), "one search at a time")
    }

    /// In the quick reply ⌘↩ sends. A menu item claims its key even while it is disabled, so the quick reply takes ⌘↩
    /// before the menu is asked; from the search field the key goes on to the menu, which searches.
    func testCommandReturnInTheQuickReplySendsAndSearchesNothing() throws {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        MainMenuController.shared?.updateForKeyWindow()
        let window = try XCTUnwrap(harness.controller.window)
        let commandReturn = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                           windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                           charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        let item = try XCTUnwrap(MainMenuBar.exactItem(for: commandReturn, in: bar))
        XCTAssertEqual(item.action, #selector(MainWindowController.searchServer(_:)))
        // The key window's responder chain would find the controller; this window is not key in a test.
        item.target = harness.controller
        // AppKit's order for a key with ⌘: the window's views, then the menu bar, and only then the first responder's keyDown.
        func press() {
            if window.performKeyEquivalent(with: commandReturn) { return }
            if bar.performKeyEquivalent(with: commandReturn) { return }
            window.firstResponder?.keyDown(with: commandReturn)
        }

        search("quarterly")
        let id = try XCTUnwrap(list.conversations.first?.id)
        list.selectedConversationID = id
        list.onSelectionChange?(id)
        harness.spin { !self.harness.reader.currentMessages.isEmpty }
        let reply = harness.reader.quickReplyBar
        var sent: [String] = []
        reply.onSend = { text, _ in sent.append(text) }
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        reply.text = "Tuesday works"
        XCTAssertFalse(harness.controller.validateMenuItem(item), "disabled while another place to type has focus")
        press()
        XCTAssertEqual(sent, ["Tuesday works"], "⌘↩ reaches the quick reply")
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(server.calls.count, 0, "and searches nothing")

        pane.focusSearch()
        XCTAssertTrue(harness.controller.validateMenuItem(item))
        press()
        harness.spin { self.server.calls.count == 1 }
        XCTAssertEqual(server.calls.first?.words, "quarterly")
        XCTAssertEqual(sent.count, 1, "the quick reply does not send from the search field")
    }

    /// ⌘↩ typed before the field's debounce has sent the words: they go now, and the search runs once their local
    /// results are in.
    func testCommandReturnRightAfterTypingRunsOnceTheResultsAreIn() throws {
        pane.focusSearch()
        search("quarterly", waitForRows: false)
        XCTAssertTrue(pane.hasPendingSearch)
        XCTAssertTrue(harness.controller.validateMenuItem(menuItem()))
        harness.controller.searchServer(nil)
        harness.spin { self.server.calls.count == 1 }
        XCTAssertEqual(server.calls.first?.words, "quarterly")
        XCTAssertEqual(rowTitle, "Searching all accounts…")
    }

    // MARK: States

    func testTheRowSaysItIsSearchingThenWhatItFound() throws {
        search("quarterly")
        let local = list.conversations.map(\.id)
        let localCount = try XCTUnwrap(pane.header.search.resultCount)
        XCTAssertTrue(try XCTUnwrap(rowView).link.accessibilityPerformPress(), "a click on the row's link")
        harness.spin { self.server.calls.count == 1 }
        XCTAssertEqual(rowTitle, "Searching all accounts…")
        XCTAssertEqual(rowView?.link.isHidden, true, "nothing to press while it runs")
        XCTAssertFalse(pane.header.search.isSearching, "no spinner in the field, none over the list: the row says it")
        XCTAssertEqual(list.conversations.map(\.id), local, "the local results stay as they are meanwhile")

        let found = try storeFoundMessages()
        server.answer(ServerSearchResult(conversations: Set(found + [local[0]]), downloaded: 2))
        harness.spin { self.rowTitle?.hasPrefix("Found") == true }

        XCTAssertEqual(rowTitle, "Found 2 more in your accounts", "a hit already listed adds nothing")
        let ids = list.conversations.map(\.id)
        XCTAssertTrue(found.allSatisfy(ids.contains), "the found conversations are listed")
        XCTAssertEqual(list.conversations.map(\.latestDate), list.conversations.map(\.latestDate).sorted(by: >), "in their date order")
        XCTAssertEqual(list.layout.items.last, .serverSearch, "the row still ends the list")
        XCTAssertEqual(pane.header.search.resultCount, localCount + 2)
        XCTAssertEqual(rowView?.link.isHidden, true)
        XCTAssertFalse(list.canRequestServerSearch, "a finished search is not offered again for the same words")
    }

    /// Finds that take the results past a page: the list reads on to their end, so it still ends with the row, which
    /// counts and announces every one.
    func testFindsPastAPageAreAllListedAndTheRowStillEndsTheList() throws {
        harness.close()
        harness = try MainWindowHarness(threads: 187, spacing: 600)
        harness.list.serverSearch.search = server.search
        search("quarterly")
        let local = list.conversations.count
        XCTAssertEqual(list.layout.items.last, .serverSearch)
        // 60 found conversations, older than every local result and saying nothing of “quarterly”.
        let oldest = try XCTUnwrap(list.conversations.last?.latestDate)
        let accounts = [ListTestSupport.accountA, ListTestSupport.accountB]
        let messages = (0..<60).map { index in
            MessageMetadata(
                id: MessageID(accountID: accounts[index % 2].id, providerID: "found-\(index)"),
                conversationID: ConversationID(accountID: accounts[index % 2].id, providerID: "found-thread-\(index)"),
                subject: "From the archive \(index)", snippet: "Older mail", from: ListTestSupport.senders[index % 3],
                date: oldest.addingTimeInterval(-Double(index + 1) * 3_600), roles: [.inbox], isRead: true, isStarred: false,
                hasAttachments: false
            )
        }
        try harness.environment.store.upsertMessages(messages)
        XCTAssertGreaterThan(local + messages.count, list.query.limit, "the finds take the results past the first page")

        list.runServerSearch()
        harness.spin { self.server.calls.count == 1 }
        server.answer(ServerSearchResult(conversations: Set(messages.map(\.conversationID)), downloaded: 60))
        harness.spin { self.rowTitle?.hasPrefix("Found") == true && self.list.layout.items.last == .serverSearch }

        XCTAssertEqual(list.conversations.count, local + 60, "every find is listed, with no scrolling")
        XCTAssertEqual(list.layout.items.last, .serverSearch, "the row still ends the list, not an idle footer")
        XCTAssertEqual(rowTitle, "Found 60 more in your accounts")
        XCTAssertEqual(list.announcedServerSearch, .found(60), "VoiceOver hears the whole count")
    }

    func testNothingMore() throws {
        search("quarterly")
        list.runServerSearch()
        harness.spin { self.server.calls.count == 1 }
        server.answer(ServerSearchResult())
        harness.spin { self.rowTitle == "Nothing more in your accounts" }
        XCTAssertEqual(rowTitle, "Nothing more in your accounts")
    }

    func testAFailureShowsInTheRowAndTryAgainRunsIt() throws {
        harness.controller.strip.select(.account(ListTestSupport.accountB.id), notify: true)
        search("quarterly")
        XCTAssertEqual(rowTitle, "Search Outlook for more")
        list.runServerSearch()
        harness.spin { self.server.calls.count == 1 }
        XCTAssertEqual(server.calls.first?.scope, [ListTestSupport.accountB.id])
        server.answer(ServerSearchResult(failedAccounts: [ListTestSupport.accountB.id]))
        harness.spin { self.rowTitle == "Couldn't search Outlook" }

        let row = try XCTUnwrap(rowView)
        XCTAssertEqual(row.link.isHidden, false)
        XCTAssertEqual(row.link.title, "Try again")
        XCTAssertEqual(row.accessibilityLabel(), "Couldn't search Outlook, Try again")
        let keyViews = pane.keyViews
        let linkStop = try XCTUnwrap(keyViews.firstIndex { $0 === row.link }, "the link joins the Tab order")
        let table = try XCTUnwrap(keyViews[linkStop - 1] as? NSTableView, "right after the list")
        XCTAssertTrue(row.link.isDescendant(of: table), "inside it, the case MainWindowKeyLoopTests moves focus through")
        XCTAssertTrue((row.link as ShellKeyHandling).handlesKey(try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))), "↩ on the focused link is its own")

        XCTAssertTrue(row.link.accessibilityPerformPress())
        harness.spin { self.server.calls.count == 2 }
        XCTAssertEqual(rowTitle, "Searching Outlook…")
        server.answer(ServerSearchResult())
        harness.spin { self.rowTitle == "Nothing more on Outlook" }
    }

    func testAFailureInAUnifiedSearchNamesTheAccount() throws {
        search("quarterly")
        list.runServerSearch()
        harness.spin { self.server.calls.count == 1 }
        server.answer(ServerSearchResult(failedAccounts: [ListTestSupport.accountB.id]))
        harness.spin { self.rowTitle?.hasPrefix("Couldn't") == true }
        XCTAssertEqual(rowTitle, "Couldn't search \(AccountLabels.name(for: ListTestSupport.accountB))")
    }

    // MARK: Operators (roadmap Q2.5)

    /// The server is asked the field's text as typed, operators and all, so its own rules decide what it finds; the
    /// operators this Mac tests on the row (here `is:unread`) still narrow the finds, as they narrow the local results.
    func testOperatorsGoToTheServerAsTypedAndStillNarrowItsFinds() throws {
        search("is:unread quarterly")
        XCTAssertEqual(list.conversations.map(\.id.providerID), ["thread-0", "thread-3", "thread-6"])
        XCTAssertEqual(list.layout.items.last, .serverSearch)
        list.runServerSearch()
        harness.spin { self.server.calls.count == 1 }
        XCTAssertEqual(server.calls.first?.words, "is:unread quarterly", "as typed, so Gmail reads its own operators")

        let found = try storeFoundMessages(unread: [true, false])
        server.answer(ServerSearchResult(conversations: Set(found), downloaded: 2))
        harness.spin { self.rowTitle?.hasPrefix("Found") == true }
        XCTAssertEqual(rowTitle, "Found 1 more in your accounts")
        XCTAssertTrue(list.conversations.contains { $0.id == found[0] }, "the unread find is listed")
        XCTAssertFalse(list.conversations.contains { $0.id == found[1] }, "is:unread still tests a find's row")
        XCTAssertEqual(list.layout.items.last, .serverSearch)
    }

    /// An `is:unread` search keeps the conversation the reader shows once it is read: a find as much as a local result.
    /// Keeping it re-observes in place, which is not a new search of the server: the row keeps its count.
    func testAFindReadInAnUnreadSearchStaysWhileItIsOpen() throws {
        search("is:unread quarterly")
        list.runServerSearch()
        harness.spin { self.server.calls.count == 1 }
        let found = try storeFoundMessages(unread: [true, true])
        server.answer(ServerSearchResult(conversations: Set(found), downloaded: 2))
        harness.spin { self.rowTitle == "Found 2 more in your accounts" }

        list.selectedConversationID = found[0]
        list.onSelectionChange?(found[0])
        harness.spin { (try? self.unreadCount(found[0])) == 0 }
        XCTAssertEqual(try unreadCount(found[0]), 0, "the reader read it")
        ListTestSupport.spin(for: 0.8)
        XCTAssertEqual(list.selectedConversationID, found[0], "the selection stays on what the user opened")
        XCTAssertTrue(list.conversations.contains { $0.id == found[0] }, "and its row stays, read")
        XCTAssertEqual(rowTitle, "Found 2 more in your accounts", "the row keeps its count")
        XCTAssertEqual(list.layout.items.last, .serverSearch)
    }

    // MARK: Later (roadmap Q2.1)

    /// A search typed in Later looks through All Mail, as from any view, and offers the server there too.
    func testASearchTypedInLaterOffersTheServer() throws {
        let store = harness.environment.store
        let snoozed = try XCTUnwrap(list.conversations.first?.id)
        let targets = try store.messages(in: snoozed).filter(\.isInInbox).map(\.id)
        try store.setSnoozes([Snooze.Change(conversationID: snoozed, until: Date().addingTimeInterval(86_400))],
                             enqueueing: [SSCore.Operation(accountID: snoozed.accountID, change: .archive, targets: targets)], at: Date())
        harness.spin { self.harness.controller.snoozes.count == 1 }
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { self.list.query.view == .later && self.list.conversations.map(\.id) == [snoozed] }
        XCTAssertNil(list.layout.serverSearchRow, "Later itself is not a search")

        search("quarterly")
        XCTAssertEqual(list.query.view, .all, "the search looks through All Mail")
        XCTAssertEqual(list.layout.items.last, .serverSearch)
        XCTAssertEqual(rowTitle, "Search all accounts for more")
        list.runServerSearch()
        harness.spin { self.server.calls.count == 1 }
        let found = try storeFoundMessages()
        server.answer(ServerSearchResult(conversations: Set(found), downloaded: 2))
        harness.spin { self.rowTitle?.hasPrefix("Found") == true }
        XCTAssertEqual(rowTitle, "Found 2 more in your accounts")
        XCTAssertTrue(found.allSatisfy(list.conversations.map(\.id).contains))
    }

    // MARK: New words

    func testNewWordsCancelTheSearchAndStartFresh() throws {
        search("quarterly")
        list.runServerSearch()
        harness.spin { self.server.calls.count == 1 }
        search("planning")
        harness.spin { self.server.cancellations == 1 }
        XCTAssertEqual(server.cancellations, 1, "the old search is cancelled")
        XCTAssertEqual(rowTitle, "Search all accounts for more", "the row is back at its offer")
        // An answer the old search still gives changes nothing.
        let found = try storeFoundMessages()
        server.answerCancelled(ServerSearchResult(conversations: Set(found)))
        ListTestSupport.spin(for: 0.2)
        XCTAssertFalse(list.conversations.contains { found.contains($0.id) })
        XCTAssertEqual(rowTitle, "Search all accounts for more")
    }

    /// New words after the server answered: the old rows are not redrawn under them first, so the field's spinner waits
    /// for their first page as for any search, and leaving search reads the mailbox once.
    func testNewWordsAfterAnAnswerWaitForTheirOwnRows() throws {
        search("quarterly")
        list.runServerSearch()
        harness.spin { self.server.calls.count == 1 }
        server.answer(ServerSearchResult(conversations: Set(try storeFoundMessages()), downloaded: 2))
        harness.spin { self.rowTitle?.hasPrefix("Found") == true }
        let rowsChanged = list.onRowsChange
        var redraws = 0
        list.onRowsChange = { redraws += 1; rowsChanged?() }

        search("planning", waitForRows: false)
        pane.sendPendingSearch()
        XCTAssertEqual(redraws, 0, "nothing is redrawn before the new words' rows are in")
        XCTAssertTrue(pane.header.search.isSearching, "so the field's spinner shows if they take a while")
        harness.spin { self.list.query.searchText == "planning" && self.list.hasReceivedFirstPage }
        XCTAssertFalse(pane.header.search.isSearching)
        XCTAssertEqual(rowTitle, "Search all accounts for more")

        list.runServerSearch()
        harness.spin { self.server.calls.count == 2 }
        server.answer(ServerSearchResult(conversations: [try XCTUnwrap(list.conversations.first?.id)]))
        harness.spin { self.rowTitle?.hasPrefix("Nothing") == true }
        redraws = 0
        search("", waitForRows: false)
        pane.sendPendingSearch()
        XCTAssertNil(list.query.searchText)
        XCTAssertEqual(redraws, 1, "the mailbox is read and drawn once")
    }

    /// A find the server matched by words only its snippet holds lists again when those words are searched later, its
    /// body still not downloaded: the snippet is indexed until the body arrives, so the find outlives the search.
    func testAFindIsListedAgainByItsSnippetWhenTheWordsComeBack() throws {
        search("older")
        list.runServerSearch()
        harness.spin { self.server.calls.count == 1 }
        let found = try storeFoundMessages()
        server.answer(ServerSearchResult(conversations: Set(found), downloaded: 2))
        harness.spin { Set(self.list.conversations.map(\.id)).isSuperset(of: found) }

        search("", waitForRows: false)
        pane.sendPendingSearch()
        XCTAssertNil(list.query.searchText)
        search("older")
        XCTAssertTrue(list.query.serverMatches.isEmpty, "a new search starts with nothing found")
        XCTAssertTrue(Set(list.conversations.map(\.id)).isSuperset(of: found), "yet the stored finds are found again")
    }

    // MARK: The empty search

    func testAnEmptySearchOffersTheServerInItsEmptyState() throws {
        search("porto")
        XCTAssertFalse(list.emptyView.isHidden)
        XCTAssertEqual(list.emptyView.sentence, "No results for “porto”")
        XCTAssertEqual(list.emptyView.hint, [.text("Not on this Mac?"), .link("Search all accounts")])
        XCTAssertNil(list.layout.serverSearchRow)

        list.emptyView.performLink()
        harness.spin { self.server.calls.count == 1 }
        XCTAssertEqual(server.calls.first?.words, "porto")
        XCTAssertEqual(list.emptyView.hint, [.text("Searching all accounts…")])

        let found = try storeFoundMessages()
        server.answer(ServerSearchResult(conversations: [found[0]], downloaded: 1))
        harness.spin { !self.list.conversations.isEmpty && self.rowTitle?.hasPrefix("Found") == true }
        XCTAssertTrue(list.emptyView.isHidden)
        XCTAssertEqual(list.conversations.map(\.id), [found[0]])
        XCTAssertEqual(rowTitle, "Found 1 more in your accounts")
    }

    func testAnEmptySearchThatFindsNothingSaysSo() throws {
        search("porto")
        list.emptyView.performLink()
        harness.spin { self.server.calls.count == 1 }
        server.answer(ServerSearchResult())
        harness.spin { self.list.emptyView.hint == [.text("Nothing in your accounts either.")] }
        XCTAssertEqual(list.emptyView.hint, [.text("Nothing in your accounts either.")])
    }
}

/// Stands in for `MailClient.searchServer`: records each call and waits for the test to answer it.
@MainActor
private final class FakeServerSearch {
    private(set) var calls: [(words: String, scope: [AccountID]?)] = []
    private(set) var cancellations = 0
    private var pending: [CheckedContinuation<ServerSearchResult, Error>] = []
    /// Continuations of searches that were cancelled, answered later to show a late answer is ignored.
    private var cancelled: [CheckedContinuation<ServerSearchResult, Error>] = []

    var search: ServerSearchController.Search {
        { [weak self] words, scope in
            try await self?.wait(words: words, scope: scope) ?? ServerSearchResult()
        }
    }

    private func wait(words: String, scope: [AccountID]?) async throws -> ServerSearchResult {
        calls.append((words, scope))
        let index = calls.count - 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
                _ = index
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func cancel() {
        cancellations += 1
        // The engine's search goes on to its next checkpoint; the answer may still come, and must be ignored.
        if !pending.isEmpty { cancelled.append(pending.removeFirst()) }
    }

    func answer(_ result: ServerSearchResult) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: result)
    }

    func answerCancelled(_ result: ServerSearchResult) {
        guard !cancelled.isEmpty else { return }
        cancelled.removeFirst().resume(returning: result)
    }

    func cancelAll() {
        for continuation in pending + cancelled { continuation.resume(throwing: CancellationError()) }
        pending = []
        cancelled = []
    }
}
