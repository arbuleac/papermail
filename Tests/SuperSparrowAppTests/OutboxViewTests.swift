import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The Outbox (spec §5.53): it shows only while a send in the scope waits to go, as Later shows only while something is
/// snoozed (§5.2): its rail tile after Drafts, its title-menu item, View › Outbox and G O with its HUD row, all gone, and
/// the window back in the Inbox, once the last send in view has gone. It lists every send the provider has not taken yet,
/// built from the outbox alone, follows the outbox as it changes and drops a send the moment it is taken; an empty one says
/// so; no mail action applies to its rows; a held Send Later message continues and cancels as from Drafts, and every other
/// row only shows; Drafts lists what it listed before. The engine never runs here (the outbox is moved by hand), and drafts
/// go to a temporary folder.
@MainActor
final class OutboxViewTests: XCTestCase {
    private var folder: URL!
    private let ben = EmailAddress(name: "Ben Carter", address: "ben@example.com")

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowOutbox-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder) }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Helpers

    private func message(_ subject: String = "Lisbon", account: Account = ListTestSupport.accountA) -> OutgoingMessage {
        OutgoingMessage(accountID: account.id, to: [ben], subject: subject, html: "<p>See you there</p>", text: "See you there")
    }

    /// A send from a composer, counting down a window the test never sees end: the engine does not run.
    @discardableResult
    private func send(_ subject: String = "Lisbon", account: Account = ListTestSupport.accountA, in harness: MainWindowHarness) throws -> String {
        try harness.environment.engine.send(message(subject, account: account), undoWindow: 600)
    }

    /// A Send Later message, as a composer leaves it: its draft kept on this Mac, its send in the outbox.
    private func schedule(_ subject: String, at date: Date, _ harness: MainWindowHarness) throws -> (sendID: String, draft: ComposeDraft) {
        let draft = ComposeDraft(id: UUID(), mode: .new, account: ListTestSupport.accountA, to: [ben], cc: [], bcc: [], subject: subject,
                                 body: ComposeTextView.plainBody("See you there"), attachments: [], quoted: nil, threading: nil)
        ComposeDraftStore.shared.saveNow(draft)
        let id = try harness.environment.engine.scheduleSend(message(subject), at: date, draftID: draft.id)
        return (id, draft)
    }

    private func row(_ sendID: String, account: Account = ListTestSupport.accountA) -> ConversationID {
        SendLaterConversation.conversationID(sendID: sendID, account: account.id)
    }

    /// G O, once the window has heard of the sends: until then the Outbox does not show, and G O does nothing.
    private func showOutbox(listing ids: [ConversationID], _ harness: MainWindowHarness) {
        harness.spin { harness.controller.showsOutbox }
        XCTAssertTrue(harness.controller.showsOutbox)
        XCTAssertTrue(harness.controller.perform(.goTo(.outbox)))
        harness.spin { harness.list.query.view == .outbox && harness.list.conversations.map(\.id) == ids }
        XCTAssertEqual(harness.list.conversations.map(\.id), ids)
    }

    private func select(_ id: ConversationID, in harness: MainWindowHarness) {
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
    }

    private func cell(forConversation index: Int, _ harness: MainWindowHarness) throws -> ConversationCellView {
        let row = try XCTUnwrap(harness.list.layout.row(ofConversation: index))
        return try XCTUnwrap(harness.list.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ConversationCellView)
    }

    private func update(_ sendID: String, _ harness: MainWindowHarness, _ change: (inout PendingSendSummary) -> Void) throws {
        var summary = try XCTUnwrap(try harness.environment.store.pendingSendSummaries().first { $0.id == sendID })
        change(&summary)
        try harness.environment.store.updateSend(summary)
    }

    private func viewMenu() throws -> NSMenu {
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        return try XCTUnwrap(bar.items.first { $0.title == "View" }?.submenu)
    }

    /// The View menu as it opens over this window: Later and Outbox listed only while the rail shows their tiles.
    private func openedViewMenu(_ harness: MainWindowHarness) throws -> NSMenu {
        let menu = try viewMenu()
        MainMenuController.showConditionalViews(in: menu, later: harness.controller.showsLater, outbox: harness.controller.showsOutbox)
        return menu
    }

    private func goOutbox(in menu: NSMenu) throws -> NSMenuItem {
        // A G-sequence item's title is its attributed title's text: the name, a tab and the keys.
        try XCTUnwrap(menu.items.first { $0.title.hasPrefix("Outbox") })
    }

    private var outboxTile: (MainWindowHarness) -> AccountStripButton {
        { harness in
            let index = TitleMenu.entries.firstIndex { $0.view == .outbox }!
            return harness.controller.strip.folderTiles[index]
        }
    }

    /// The title menu's view items as minimal mode builds it now.
    private func titleMenu(_ harness: MainWindowHarness) throws -> [String] {
        let model = try XCTUnwrap(harness.controller.listPane.titleMenuModel?())
        let action = #selector(MainWindowController.goToMailboxView(_:))
        return TitleMenu.build(model, target: self, viewAction: action, scopeAction: action).items
            .filter { !$0.isSeparatorItem && $0.action == action && $0.keyEquivalent.isEmpty }
            .map { $0.title.components(separatedBy: "\t")[0] }
    }

    /// The G-sequence HUD's rows as the window would show them now.
    private func hudKeys(_ harness: MainWindowHarness) throws -> [String] {
        let router = KeyboardRouter(target: harness.controller)
        router.showSequenceHUDNow()
        defer { router.disarmSequence(animated: false) }
        let hud = try XCTUnwrap(Self.views(in: harness.controller.listPane.view).compactMap { $0 as? QuireSequenceHUDView }.first)
        return hud.rows.map(\.keys)
    }

    private static func views(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func typeSearch(_ text: String, _ harness: MainWindowHarness) {
        harness.controller.listPane.header.search.query = text
        harness.controller.listPane.header.search.onQueryChange?(text)
        harness.spin { harness.list.query.searchText == text && !harness.list.conversations.isEmpty }
    }

    private func clearSearch(_ harness: MainWindowHarness) {
        harness.controller.listPane.header.search.query = ""
        harness.controller.listPane.header.search.onQueryChange?("")
        harness.spin { harness.list.query.searchText == nil }
    }

    // MARK: Getting there

    /// View › Outbox, with its symbol and G O, lists a send from the moment Send is pressed, and the row follows the
    /// outbox: “Sending…”, “Retrying shortly”, “Couldn't send” in danger, then gone once taken, and the window with it.
    func testTheViewMenuOpensTheOutboxWhichFollowsASendUntilItIsTaken() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let built = try goOutbox(in: try viewMenu())
        XCTAssertEqual(built.action, #selector(MainWindowController.goToMailboxView(_:)))
        XCTAssertEqual(built.tag, MailboxView.allCases.firstIndex(of: .outbox))
        XCTAssertNotNil(built.image, "its symbol, as the other views have theirs")
        XCTAssertEqual(built.attributedTitle?.string, "Outbox\tG O")
        XCTAssertTrue(built.isHidden, "nothing waits to go: not listed")
        XCTAssertFalse(harness.controller.validateMenuItem(built), "and refused")
        let titles = try viewMenu().items.filter { $0.action == #selector(MainWindowController.goToMailboxView(_:)) }
            .map { $0.title.components(separatedBy: "\t")[0] }
        XCTAssertEqual(titles, ["Inbox", "Later", "Starred", "Sent", "Drafts", "Outbox", "Trash", "All Mail"], "in the rail's order")

        let sendID = try send(in: harness)
        harness.spin { harness.controller.showsOutbox }
        let item = try goOutbox(in: try openedViewMenu(harness))
        XCTAssertFalse(item.isHidden, "listed while a send waits to go")
        XCTAssertTrue(harness.controller.validateMenuItem(item))
        harness.controller.goToMailboxView(item)
        harness.spin { harness.list.conversations.map(\.id) == [self.row(sendID)] }
        XCTAssertEqual(harness.list.query.view, .outbox)
        XCTAssertEqual(harness.controller.listPane.header.masthead.title, "Outbox")
        XCTAssertEqual(harness.controller.listPane.header.searchPlaceholder, "Search Outbox")
        XCTAssertEqual(harness.controller.strip.mailboxView, .outbox)
        XCTAssertEqual(harness.controller.strip.folderTiles.map(\.isSelected), [false, false, false, false, false, true, false, false],
                       "its own tile is raised")
        item.state = .off
        _ = harness.controller.validateMenuItem(item)
        XCTAssertEqual(item.state, .on)
        XCTAssertFalse(harness.list.layout.items.contains { if case .head = $0 { return true } else { return false } }, "no running heads")
        let row = try XCTUnwrap(harness.list.conversations.first)
        XCTAssertEqual(row.outbox, .sending)
        XCTAssertEqual(row.subject, "Lisbon")
        XCTAssertEqual(try cell(forConversation: 0, harness).content?.time.string, "Sending\u{2026}")
        XCTAssertTrue(try XCTUnwrap(cell(forConversation: 0, harness).content?.sender.string).hasPrefix("To Ben"))

        try update(sendID, harness) {
            $0.status = .scheduled
            $0.attempts = 1
            $0.lastError = "throttled (retry after 30 s)"
        }
        harness.spin { harness.list.conversations.first?.outbox == .retrying(lastError: "throttled (retry after 30 s)", isSendLater: false) }
        XCTAssertEqual(try cell(forConversation: 0, harness).content?.time.string, "Retrying shortly")

        // A live undo-send panel answers for it (§5.31), so it stays listed as failed until that panel has kept its draft;
        // one nobody answers for leaves for Drafts at once (`FailedSendAppTests`).
        SendOwnership.claim(sendID)
        defer { SendOwnership.release(sendID) }
        try update(sendID, harness) {
            $0.status = .failed
            $0.lastError = "HTTP 400"
        }
        harness.spin { harness.list.conversations.first?.outbox == .failed(lastError: "HTTP 400") }
        let failed = try XCTUnwrap(cell(forConversation: 0, harness).content?.time)
        XCTAssertEqual(failed.string, "Couldn't send")
        XCTAssertEqual(failed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .qDanger, "in danger")

        try update(sendID, harness) { $0.status = .sending }
        harness.spin { harness.list.conversations.first?.outbox == .sending }
        try update(sendID, harness) { $0.status = .sent }
        // Taken: it leaves at once, before the runner deletes the row, and with nothing else waiting the Outbox goes and the
        // window goes back to the Inbox.
        harness.spin { harness.list.query.view == .inbox }
        XCTAssertEqual(harness.list.query.view, .inbox)
        XCTAssertFalse(harness.controller.showsOutbox)
        XCTAssertTrue(outboxTile(harness).isHidden)
        XCTAssertTrue(try goOutbox(in: try openedViewMenu(harness)).isHidden)
        XCTAssertFalse(harness.controller.validateMenuItem(item))
    }

    /// G O goes there from any view while a send waits; the HUD and the cheat sheet list it after Drafts.
    func testGOGoesToTheOutboxAndTheSheetsListIt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        XCTAssertEqual(KeyboardRouter.sequenceView(characters: "o"), .outbox)
        XCTAssertEqual(KeyboardRouter.sequenceView(characters: "O"), .outbox)
        try send(in: harness)
        harness.spin { harness.controller.showsOutbox }
        XCTAssertTrue(harness.controller.perform(.goTo(.trash)))
        XCTAssertTrue(harness.controller.perform(.goTo(KeyboardRouter.sequenceView(characters: "o")!)))
        harness.spin { harness.list.query.view == .outbox }
        XCTAssertEqual(harness.list.query.view, .outbox)
        let go = try XCTUnwrap(Quire.cheatSheet.first { $0.title == "Go" })
        XCTAssertEqual(go.rows.map(\.keys), ["G then I", "G then L", "G then S", "G then T", "G then D", "G then O", "G then #", "G then A",
                                             "⌘0 … ⌘9", "[ ] T"])
        XCTAssertEqual(go.rows.first { $0.keys == "G then O" }?.label, "Outbox")
        XCTAssertEqual(QuireSequenceHUDView.sequenceRows().map(\.keys), ["I", "L", "S", "T", "D", "O", "#", "A"])
    }

    /// An empty Outbox says so, in the empty state's two lines, whatever the accounts are doing: the list's, for the moment
    /// before the window, whose Outbox shows only while a send waits, goes back to the Inbox.
    func testAnEmptyOutboxSaysSo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.list.query = ConversationQuery(view: .outbox)
        harness.spin { harness.list.query.view == .outbox && !harness.list.emptyView.isHidden }
        XCTAssertFalse(harness.list.emptyView.isHidden)
        XCTAssertEqual(harness.list.emptyView.sentence, "Nothing waiting to send")
        XCTAssertEqual(harness.list.emptyView.hint, [.text("Messages you send wait here until they have gone.")])
        XCTAssertNil(harness.list.emptyView.glyph)
    }

    /// The scope applies: narrowed to one account, the Outbox lists that account's sends alone.
    func testTheOutboxFollowsTheScope() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let fromA = try send("From A", in: harness)
        let fromB = try send("From B", account: ListTestSupport.accountB, in: harness)
        harness.spin { harness.controller.localDrafts.outboxSummaries.count == 2 }
        XCTAssertTrue(harness.controller.perform(.goTo(.outbox)))
        harness.spin { harness.list.conversations.count == 2 }
        XCTAssertEqual(Set(harness.list.conversations.map(\.id)), [row(fromA), row(fromB, account: ListTestSupport.accountB)])
        harness.controller.strip.selectShortcut(2)
        harness.spin { harness.list.conversations.map(\.id) == [self.row(fromB, account: ListTestSupport.accountB)] }
        XCTAssertEqual(harness.list.conversations.map(\.id), [row(fromB, account: ListTestSupport.accountB)])
        XCTAssertEqual(harness.list.query.view, .outbox, "the view stays")
    }

    // MARK: Nothing applies

    /// E, S, U, #, !, L, M, ⇧I, R, A and F are spent on an Outbox row and change nothing: no operation, no send moved, no
    /// composer; the menus' mail items are disabled, no folder takes the row, and ⌘O opens no window.
    func testMailActionsDoNothingOnOutboxRows() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let sendID = try send(in: harness)
        let id = row(sendID)
        showOutbox(listing: [id], harness)
        select(id, in: harness)
        let before = try harness.environment.store.pendingSendSummaries()
        let commands: [KeyCommand] = [.archive, .toggleStar, .toggleRead, .trash, .markSpam, .later, .toggleMute, .moveToInbox, .reply,
                                      .replyAll, .forward]
        for command in commands {
            XCTAssertTrue(harness.controller.perform(command), "\(command): spent, with a beep")
        }
        for account in [ListTestSupport.accountA, ListTestSupport.accountB] {
            XCTAssertTrue(try harness.environment.store.pendingOperations(accountID: account.id, limit: 10).isEmpty, "nothing queued")
        }
        XCTAssertEqual(try harness.environment.store.pendingSendSummaries(), before, "the send is as it was")
        XCTAssertTrue(ComposeWindowRegistry.shared.openControllers.isEmpty, "no reply to a message on its way")
        XCTAssertEqual(harness.list.conversations.map(\.id), [id])
        // Nothing changed, so nothing joins the undo history for ⌘Z to walk back to (§6.1).
        XCTAssertTrue(harness.controller.undoCenter.history.groups.isEmpty, "no step from an Outbox row")

        let actions: [Selector] = [
            #selector(MainWindowController.archiveSelection(_:)), #selector(MainWindowController.trashSelection(_:)),
            #selector(MainWindowController.toggleStarSelection(_:)), #selector(MainWindowController.markSelectionUnread(_:)),
            #selector(MainWindowController.markSelectionSpam(_:)), #selector(MainWindowController.moveSelectionToInbox(_:)),
            #selector(MainWindowController.laterSelection(_:)), #selector(MainWindowController.toggleMuteSelection(_:)),
            #selector(MainWindowController.replyToSelection(_:)), #selector(MainWindowController.forwardSelection(_:)),
            #selector(MainWindowController.openSelectionInNewWindow(_:)),
        ]
        for action in actions {
            XCTAssertFalse(harness.controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")), "\(action)")
        }
        let context = harness.controller.selectionContextMenu()
        for item in context.items where !item.isSeparatorItem && item.submenu == nil {
            XCTAssertFalse(harness.controller.validateMenuItem(item), "context menu: \(item.title)")
        }
        for tile in MailboxView.allCases {
            XCTAssertFalse(harness.controller.acceptsDrop(of: [id], onto: tile), "\(tile) takes no Outbox row")
        }
        XCTAssertNil(harness.controller.openInNewWindow(id))
        XCTAssertTrue(harness.controller.readerWindows.isEmpty)
    }

    // MARK: Opening

    /// A row going now shows read-only, its sheet saying so, with no action to take; ↩, → and a double-click only show it,
    /// in the main window's reader, where on any other view's row ↩ and a double-click open a reader window (§5.49, §5.53).
    func testARowOnItsWayOnlyShows() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let sendID = try send(in: harness)
        let id = row(sendID)
        showOutbox(listing: [id], harness)
        select(id, in: harness)
        XCTAssertEqual(harness.reader.selection, .one(id))
        XCTAssertEqual(harness.reader.currentMessages.map(\.subject), ["Lisbon"])
        XCTAssertEqual(harness.reader.currentMessages.first?.to, [ben])
        XCTAssertEqual(harness.reader.header.content.kicker?.lead, "Outbox")
        XCTAssertTrue(harness.reader.header.content.actions.all.isEmpty, "nothing applies to a message on its way")
        XCTAssertTrue(harness.reader.quickReplyBar.isHidden)

        XCTAssertTrue(harness.controller.perform(.openInWindow), "↩")
        XCTAssertTrue(harness.controller.perform(.open), "→")
        harness.list.rowDoubleClicked(try XCTUnwrap(harness.list.layout.row(ofConversation: 0)))
        XCTAssertTrue(ComposeWindowRegistry.shared.openControllers.isEmpty, "no composer")
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "no reader window for a message on its way")
        XCTAssertEqual(try harness.environment.store.pendingSendSummaries().map(\.id), [sendID], "the send goes on")
        XCTAssertEqual(harness.reader.selection, .one(id))
    }

    /// The reader follows the send: a Send Later message offers Continue Editing while it waits, and nothing once its
    /// time has come; once taken, the row and the sheet go.
    func testTheReaderFollowsTheSend() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (sendID, _) = try schedule("Lisbon", at: Date().addingTimeInterval(86_400), harness)
        let id = row(sendID)
        showOutbox(listing: [id], harness)
        select(id, in: harness)
        XCTAssertEqual(harness.reader.header.content.actions.all, [.continueEditing])
        try update(sendID, harness) { $0.status = .sending }
        harness.spin { harness.reader.header.content.actions.all.isEmpty }
        XCTAssertTrue(harness.reader.header.content.actions.all.isEmpty, "on its way: it only shows")
        XCTAssertEqual(harness.list.conversations.first?.outbox, .sending)
        XCTAssertTrue(harness.controller.perform(.openInWindow))
        XCTAssertTrue(ComposeWindowRegistry.shared.openControllers.isEmpty, "↩ shows it, where Drafts would beep")
        XCTAssertTrue(harness.controller.readerWindows.isEmpty)
        try update(sendID, harness) { $0.status = .sent }
        harness.spin { harness.list.query.view == .inbox && harness.reader.selection != .one(id) }
        XCTAssertEqual(harness.list.query.view, .inbox, "the last send went: back in the Inbox")
        XCTAssertFalse(harness.list.conversations.contains { $0.id == id })
        XCTAssertNotEqual(harness.reader.selection, .one(id))
    }

    /// A Send Later message offers what Drafts offers it: Continue Editing (↩) cancels the schedule and opens its draft.
    func testAHeldSendLaterMessageContinuesAsFromDrafts() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (sendID, draft) = try schedule("Lisbon", at: Date().addingTimeInterval(86_400), harness)
        let id = row(sendID)
        showOutbox(listing: [id], harness)
        XCTAssertEqual(harness.list.conversations.first?.outbox, .waiting(until: try XCTUnwrap(
            try harness.environment.store.pendingSendSummaries().first?.sendAfter)))
        XCTAssertTrue(try XCTUnwrap(cell(forConversation: 0, harness).content?.time.string).hasPrefix("Sends "))
        select(id, in: harness)
        XCTAssertEqual(harness.reader.header.content.actions, ReaderActionSet(primary: [.continueEditing], replies: []))

        XCTAssertTrue(harness.controller.perform(.openInWindow), "↩")
        harness.spin { !ComposeWindowRegistry.shared.openControllers.isEmpty }
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.map(\.draftID), [draft.id], "its own draft, once")
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "never a reader window")
        XCTAssertTrue(try harness.environment.store.pendingSendSummaries().isEmpty, "the schedule is cancelled first")
        harness.spin { harness.list.query.view == .inbox }
        XCTAssertFalse(harness.controller.showsOutbox, "it leaves the Outbox, which goes with it")
        XCTAssertEqual(harness.list.query.view, .inbox)
    }

    /// A double-click on a held Send Later message's row continues editing it too, as on its Drafts row: never a reader
    /// window, which a double-click opens on any other view's row (§5.49, §5.53).
    func testADoubleClickOnAHeldSendLaterMessageContinuesEditing() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (sendID, draft) = try schedule("Lisbon", at: Date().addingTimeInterval(86_400), harness)
        let id = row(sendID)
        showOutbox(listing: [id], harness)

        harness.list.rowDoubleClicked(try XCTUnwrap(harness.list.layout.row(ofConversation: 0)))
        harness.spin { !ComposeWindowRegistry.shared.openControllers.isEmpty }
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.map(\.draftID), [draft.id], "its own draft")
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "never a reader window")
        XCTAssertTrue(try harness.environment.store.pendingSendSummaries().isEmpty, "the schedule is cancelled first")
    }

    /// A Send Later message a throttle or a lost connection put back reads “Retrying shortly”, and ↩ takes it back and opens
    /// its draft, as ↩ on its Drafts row does: it is not on its way until the runner claims it again.
    func testASendLaterMessageWaitingToRetryContinuesAsFromDrafts() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (sendID, draft) = try schedule("Lisbon", at: Date().addingTimeInterval(86_400), harness)
        try update(sendID, harness) {
            $0.status = .scheduled
            $0.attempts = 1
            $0.sendAfter = Date().addingTimeInterval(30)
            $0.lastError = "network: The Internet connection appears to be offline."
        }
        let id = row(sendID)
        showOutbox(listing: [id], harness)
        XCTAssertEqual(try cell(forConversation: 0, harness).content?.time.string, "Retrying shortly")
        select(id, in: harness)
        XCTAssertEqual(harness.reader.header.content.actions, ReaderActionSet(primary: [.continueEditing], replies: []))

        XCTAssertTrue(harness.controller.perform(.openInWindow), "↩")
        harness.spin { !ComposeWindowRegistry.shared.openControllers.isEmpty }
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.map(\.draftID), [draft.id])
        XCTAssertTrue(try harness.environment.store.pendingSendSummaries().isEmpty, "the retry is cancelled first")
    }

    /// Cancel beside its time takes the schedule back and leaves the draft, which is in Drafts, not here.
    func testCancelInTheOutboxKeepsTheDraft() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (sendID, draft) = try schedule("Lisbon", at: Date().addingTimeInterval(86_400), harness)
        let other = try send("Porto", in: harness)
        showOutbox(listing: [row(other), row(sendID)], harness)
        select(row(sendID), in: harness)
        harness.controller.cancelSendLater(row(sendID))
        XCTAssertEqual(harness.toastMessage, "Send Later cancelled")
        harness.spin { harness.list.conversations.map(\.id) == [self.row(other)] }
        XCTAssertEqual(harness.list.conversations.map(\.id), [row(other)])
        XCTAssertNotEqual(harness.list.selectedConversationID, LocalDraftConversation.conversationID(draftID: draft.id, account: draft.account.id),
                          "the draft is not selected where it is not listed")
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: draft.id))
    }

    // MARK: Only while a send waits (§5.2)

    /// With nothing waiting to go there is no Outbox anywhere: no rail tile, no title-menu item, View › Outbox hidden and
    /// refused, no O row in the HUD, and G O does nothing, as G L does with nothing snoozed (§5.2, §5.32).
    func testWithNothingWaitingTheOutboxDoesNotShow() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        XCTAssertFalse(harness.controller.showsOutbox)
        harness.controller.strip.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(outboxTile(harness).isHidden)
        XCTAssertEqual(try titleMenu(harness), ["Inbox", "Starred", "Sent", "Drafts", "Trash", "All Mail"])
        let item = try goOutbox(in: try openedViewMenu(harness))
        XCTAssertTrue(item.isHidden)
        XCTAssertFalse(harness.controller.validateMenuItem(item))
        XCTAssertEqual(try hudKeys(harness), ["I", "S", "T", "D", "#", "A"], "neither L nor O")

        XCTAssertTrue(harness.controller.perform(.goTo(.starred)))
        XCTAssertTrue(harness.controller.perform(.goTo(.outbox)), "G O is spent")
        XCTAssertEqual(harness.list.query.view, .starred, "and does nothing")
        harness.controller.goToMailboxView(item)
        XCTAssertEqual(harness.list.query.view, .starred, "nor does the View menu's item")
        XCTAssertEqual(harness.controller.strip.mailboxView, .starred)
    }

    /// A send queued shows the Outbox everywhere at once: its tile after Drafts at 238 (Trash, the hairline and All Mail one
    /// pitch lower), its title-menu item in the same place with G O, View › Outbox, the HUD's O row after D, and G O.
    func testASendWaitingShowsTheOutboxTileMenusAndKeys() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let strip = harness.controller.strip
        let sendID = try send(in: harness)
        harness.spin { harness.controller.showsOutbox }
        XCTAssertTrue(harness.controller.showsOutbox)
        strip.view.layoutSubtreeIfNeeded()
        let tile = outboxTile(harness)
        XCTAssertFalse(tile.isHidden)
        XCTAssertEqual(tile.content, .folder(symbol: Quire.Icon.viewOutbox))
        XCTAssertEqual(tile.toolTip, "Outbox  G O")
        XCTAssertEqual(tile.unreadCount, 0, "no badge")
        let tops = strip.folderTiles.filter { !$0.isHidden }.map { $0.convert($0.tileRect, to: strip.view).minY }
        XCTAssertEqual(tops, [62, 106, 150, 194, 238, 282, 338], "the Outbox at 238 after Drafts; Trash and All Mail a pitch lower")
        XCTAssertEqual(strip.folderDividerRect.minY, 329, "the hairline moves with them")

        XCTAssertEqual(try titleMenu(harness), ["Inbox", "Starred", "Sent", "Drafts", "Outbox", "Trash", "All Mail"], "in the rail's place")
        let model = try XCTUnwrap(harness.controller.listPane.titleMenuModel?())
        let menuItem = try XCTUnwrap(TitleMenu.build(model, target: self, viewAction: #selector(MainWindowController.goToMailboxView(_:)),
                                                     scopeAction: #selector(MainWindowController.goToMailboxView(_:)))
            .items.first { $0.title.hasPrefix("Outbox") })
        XCTAssertEqual(menuItem.attributedTitle?.string, "Outbox\tG O")
        XCTAssertEqual(menuItem.tag, MailboxView.allCases.firstIndex(of: .outbox))
        let item = try goOutbox(in: try openedViewMenu(harness))
        XCTAssertFalse(item.isHidden)
        XCTAssertTrue(harness.controller.validateMenuItem(item))
        XCTAssertEqual(try hudKeys(harness), ["I", "S", "T", "D", "O", "#", "A"])

        XCTAssertTrue(harness.controller.perform(.goTo(.outbox)))
        harness.spin { harness.list.conversations.map(\.id) == [self.row(sendID)] }
        XCTAssertEqual(harness.list.query.view, .outbox)
        XCTAssertTrue(tile.isSelected, "its tile is raised")
        // A click on the tile goes there too, as on any folder.
        XCTAssertTrue(harness.controller.perform(.goTo(.sent)))
        XCTAssertFalse(tile.isSelected)
        tile.performClick(nil)
        XCTAssertEqual(harness.list.query.view, .outbox)
        XCTAssertTrue(tile.isSelected)
    }

    /// The last send in view goes while the Outbox is shown: the window goes back to the Inbox and everything naming the
    /// Outbox goes with it; a tile that had the keyboard hands it to the Inbox tile. One send of two going leaves it be.
    func testTheWindowLeavesTheOutboxAsTheLastSendGoes() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        let strip = harness.controller.strip
        let first = try send("Lisbon", in: harness)
        let second = try send("Porto", in: harness)
        harness.spin { harness.controller.localDrafts.outboxSummaries.count == 2 }
        XCTAssertTrue(harness.controller.perform(.goTo(.outbox)))
        harness.spin { harness.list.query.view == .outbox && harness.list.conversations.count == 2 }
        let tile = outboxTile(harness)
        XCTAssertTrue(window.makeFirstResponder(tile), "the Outbox tile has the keyboard")

        try update(first, harness) { $0.status = .sent }
        harness.spin { harness.list.conversations.map(\.id) == [self.row(second)] }
        XCTAssertEqual(harness.list.query.view, .outbox, "one still waits: the Outbox stays")
        XCTAssertFalse(tile.isHidden)

        try update(second, harness) { $0.status = .sent }
        harness.spin { harness.list.query.view == .inbox }
        XCTAssertEqual(harness.list.query.view, .inbox)
        XCTAssertEqual(harness.controller.listPane.header.masthead.title, "Inbox")
        XCTAssertEqual(strip.mailboxView, .inbox)
        XCTAssertTrue(strip.folderTiles[0].isSelected)
        XCTAssertFalse(harness.controller.showsOutbox)
        XCTAssertTrue(tile.isHidden)
        XCTAssertTrue(window.firstResponder === strip.folderTiles[0], "the Inbox tile, not \(String(describing: window.firstResponder))")
        XCTAssertEqual(try titleMenu(harness), ["Inbox", "Starred", "Sent", "Drafts", "Trash", "All Mail"])
        XCTAssertEqual(try hudKeys(harness), ["I", "S", "T", "D", "#", "A"])
        XCTAssertTrue(harness.controller.perform(.goTo(.outbox)))
        XCTAssertEqual(harness.list.query.view, .inbox, "G O does nothing again")
    }

    /// A search typed in the Outbox looks through All Mail, so when the last send goes the window goes back to the Inbox
    /// under the search, which stays with its results; clearing it lands in the Inbox, as from Later (§5.45).
    func testASearchTypedInTheOutboxOutlivesItEmptying() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let sendID = try send(in: harness)
        showOutbox(listing: [row(sendID)], harness)
        typeSearch("Project", harness)
        // The query takes the search at once and its rows come after: wait for All Mail's, in place of the Outbox's row.
        harness.spin { !harness.list.conversations.isEmpty && !harness.list.conversations.contains { $0.id == self.row(sendID) } }
        let results = harness.list.conversations.map(\.id)
        XCTAssertFalse(results.isEmpty)
        XCTAssertFalse(results.contains(row(sendID)), "the search's rows, not the Outbox's")

        try update(sendID, harness) { $0.status = .sent }
        harness.spin { !harness.controller.showsOutbox && harness.controller.listPane.header.masthead.title == "Inbox" }
        XCTAssertEqual(harness.controller.listPane.header.masthead.title, "Inbox")
        XCTAssertEqual(harness.list.query.searchText, "Project", "the search stays")
        XCTAssertEqual(harness.controller.listPane.header.search.query, "Project", "and its field")
        XCTAssertEqual(harness.list.conversations.map(\.id), results, "and its results")
        clearSearch(harness)
        XCTAssertEqual(harness.list.query.view, .inbox, "cleared, the search lands in the Inbox")
    }

    /// Narrowed to an account with nothing waiting (⌘2), the Outbox goes and the window goes back to the Inbox; back in All
    /// Inboxes (⌘0) the tile shows again, and the window stays where it went.
    func testNarrowingToAnAccountWithNothingWaitingLeavesTheOutbox() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let sendID = try send(in: harness)
        showOutbox(listing: [row(sendID)], harness)

        harness.controller.strip.selectShortcut(2)
        XCTAssertFalse(harness.controller.showsOutbox)
        XCTAssertTrue(outboxTile(harness).isHidden)
        harness.spin { harness.list.query.view == .inbox }
        XCTAssertEqual(harness.list.query.view, .inbox)
        XCTAssertEqual(harness.list.query.accountIDs, [ListTestSupport.accountB.id])
        XCTAssertTrue(harness.controller.perform(.goTo(.outbox)))
        XCTAssertEqual(harness.list.query.view, .inbox, "nothing of this account's waits: G O does nothing")

        harness.controller.strip.selectShortcut(0)
        XCTAssertTrue(harness.controller.showsOutbox, "All Inboxes: the first account's send counts")
        XCTAssertFalse(outboxTile(harness).isHidden)
        XCTAssertEqual(harness.list.query.view, .inbox, "the window stays where it went")
        harness.controller.strip.selectShortcut(1)
        XCTAssertTrue(harness.controller.showsOutbox, "narrowed to the account with the send")
    }

    /// Later and the Outbox at once: Later below Inbox, the Outbox after Drafts, Trash two pitches lower and the hairline and
    /// All Mail with it, no two hit squares overlapping and the account group clear of All Mail; ↑/↓ step through the shown
    /// folders; each tile goes on its own and the folders close up.
    func testLaterAndTheOutboxShowTogetherWithoutOverlap() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let strip = harness.controller.strip
        let store = harness.environment.store
        let snoozed = harness.list.conversations[0].id
        let targets = try store.messages(in: snoozed).filter(\.isInInbox).map(\.id)
        try store.setSnoozes([Snooze.Change(conversationID: snoozed, until: Date().addingTimeInterval(86_400))],
                             enqueueing: [SSCore.Operation(accountID: snoozed.accountID, change: .archive, targets: targets)], at: Date())
        let sendID = try send(in: harness)
        harness.spin { harness.controller.showsLater && harness.controller.showsOutbox }
        strip.view.layoutSubtreeIfNeeded()
        func shownTops() -> [CGFloat] {
            strip.folderTiles.filter { !$0.isHidden }.map { $0.convert($0.tileRect, to: strip.view).minY }
        }
        XCTAssertEqual(strip.folderTiles.map(\.isHidden), Array(repeating: false, count: 8))
        XCTAssertEqual(shownTops(), [62, 106, 150, 194, 238, 282, 326, 382], "Later at 106, the Outbox at 282, Trash at 326")
        XCTAssertEqual(strip.folderDividerRect.minY, 373, "the hairline two pitches lower")
        let squares = strip.folderTiles.map { $0.convert($0.hitRect, to: strip.view) }
        for (upper, lower) in zip(squares, squares.dropFirst()) {
            XCTAssertGreaterThanOrEqual(lower.minY, upper.maxY - 0.5, "\(upper) and \(lower) do not overlap")
        }
        let allMail = try XCTUnwrap(squares.last)
        XCTAssertLessThan(strip.folderDividerRect.minY, allMail.minY)
        XCTAssertGreaterThan(strip.folderDividerRect.minY, squares[6].maxY - 0.5, "the hairline between Trash and All Mail")
        let unified = try XCTUnwrap(strip.tile(for: .unified))
        let unifiedRect = unified.convert(unified.tileRect, to: strip.view)
        let allMailTile = strip.folderTiles[7].convert(strip.folderTiles[7].tileRect, to: strip.view)
        XCTAssertGreaterThanOrEqual(unifiedRect.minY, allMailTile.maxY + Quire.Layout.Rail.groupGap - 0.5, "the accounts stay clear")
        XCTAssertGreaterThan(strip.accountClipFrame.minY, allMail.maxY)
        XCTAssertEqual(try titleMenu(harness), ["Inbox", "Later", "Starred", "Sent", "Drafts", "Outbox", "Trash", "All Mail"])
        XCTAssertEqual(try hudKeys(harness), ["I", "L", "S", "T", "D", "O", "#", "A"])

        // ↓ from Drafts reaches the Outbox, then Trash.
        strip.folderTiles[4].onArrow?(1)
        XCTAssertEqual(harness.list.query.view, .outbox)
        strip.folderTiles[5].onArrow?(1)
        XCTAssertEqual(harness.list.query.view, .trash)

        // The send goes: the Outbox closes up and Later stays.
        try update(sendID, harness) { $0.status = .sent }
        harness.spin { !harness.controller.showsOutbox }
        XCTAssertTrue(harness.controller.showsLater)
        XCTAssertEqual(shownTops(), [62, 106, 150, 194, 238, 282, 338])
        XCTAssertEqual(strip.folderDividerRect.minY, 329)
        // ↓ from Drafts steps over the hidden Outbox.
        XCTAssertTrue(harness.controller.perform(.goTo(.drafts)))
        strip.folderTiles[4].onArrow?(1)
        XCTAssertEqual(harness.list.query.view, .trash)

        // The snooze ends too: the six views in their places.
        try store.setSnoozes([Snooze.Change(conversationID: snoozed, until: nil)], enqueueing: [], at: Date())
        harness.spin { !harness.controller.showsLater }
        XCTAssertEqual(shownTops(), [62, 106, 150, 194, 238, 294])
        XCTAssertEqual(strip.folderDividerRect.minY, 285)
    }

    /// One word of the outbox in which a send leaves and another arrives never hides the tile: the window stays in the
    /// Outbox, on the new row, and the tile never went (§5.53).
    func testASendLeavingAsAnotherArrivesKeepsTheTile() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let first = try send("Lisbon", in: harness)
        showOutbox(listing: [row(first)], harness)
        let tile = outboxTile(harness)
        final class Seen { var hidden: [Bool] = [] }
        let seen = Seen()
        let observation = tile.observe(\.isHidden, options: [.new]) { tile, _ in
            MainActor.assumeIsolated { seen.hidden.append(tile.isHidden) }
        }
        defer { observation.invalidate() }

        // The store goes from the first alone to both to the second alone: never empty.
        let second = try send("Porto", in: harness)
        try harness.environment.store.deleteSend(id: first)
        // The word the window hears in one pass: the first gone, the second arrived.
        let word = try harness.environment.store.pendingSendSummaries()
        XCTAssertEqual(word.map(\.id), [second])
        harness.controller.sendLaterOutbox.sendsChanged(word)
        XCTAssertEqual(harness.list.query.view, .outbox, "the window stays in the Outbox")
        XCTAssertFalse(tile.isHidden)
        harness.spin { harness.list.conversations.map(\.id) == [self.row(second)] }
        XCTAssertEqual(harness.list.conversations.map(\.id), [row(second)])
        XCTAssertEqual(harness.list.query.view, .outbox)
        XCTAssertFalse(seen.hidden.contains(true), "the tile never went")
    }

    /// Cancel on the last send in view empties the Outbox and the window goes back to the Inbox; Z schedules it again, the
    /// Outbox shows again and the window goes back to it, on the row, as an undo of a step in Later brings Later back. Once
    /// the user has gone elsewhere themselves, an undo leaves them there.
    func testAnUndoOfACancelThatEmptiedTheOutboxBringsItBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (sendID, draft) = try schedule("Lisbon", at: Date().addingTimeInterval(86_400), harness)
        showOutbox(listing: [row(sendID)], harness)
        select(row(sendID), in: harness)
        harness.controller.cancelSendLater(row(sendID))
        XCTAssertEqual(harness.toastMessage, "Send Later cancelled")
        harness.spin { harness.list.query.view == .inbox }
        XCTAssertEqual(harness.list.query.view, .inbox)
        XCTAssertFalse(harness.controller.showsOutbox)

        XCTAssertTrue(harness.controller.perform(.undo))
        harness.spin {
            harness.list.query.view == .outbox && harness.list.conversations.count == 1
                && harness.list.selectedConversationID == harness.list.conversations.first?.id
        }
        XCTAssertTrue(harness.controller.showsOutbox)
        XCTAssertEqual(harness.list.query.view, .outbox, "back in the Outbox")
        let restored = try XCTUnwrap(harness.list.conversations.first).id
        XCTAssertEqual(harness.list.selectedConversationID, restored, "on the row")
        XCTAssertEqual(try harness.environment.store.pendingSendSummaries().map(\.draftID), [draft.id], "the same draft waits again")

        // Cancelled again, then G S: Z leaves the window in Starred.
        harness.controller.cancelSendLater(restored)
        harness.spin { harness.list.query.view == .inbox }
        XCTAssertTrue(harness.controller.perform(.goTo(.starred)))
        XCTAssertTrue(harness.controller.perform(.undo))
        harness.spin { harness.controller.showsOutbox }
        XCTAssertTrue(harness.controller.showsOutbox, "the message waits again")
        XCTAssertEqual(harness.list.query.view, .starred, "the view the user chose")
    }

    /// A reader window goes by the main window's answer: G O there and View › Outbox from it do nothing until a send waits,
    /// then bring the main window forward on the Outbox (§5.49).
    func testAReaderWindowGoesByTheMainWindow() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let reader = try XCTUnwrap(harness.controller.openInNewWindow(harness.list.conversations[0].id))
        let item = NSMenuItem(title: "Outbox", action: #selector(MainWindowController.goToMailboxView(_:)), keyEquivalent: "")
        item.tag = try XCTUnwrap(MailboxView.allCases.firstIndex(of: .outbox))
        XCTAssertFalse(reader.showsOutbox)
        XCTAssertFalse(reader.validateMenuItem(item))
        XCTAssertTrue(reader.perform(.goTo(.outbox)))
        XCTAssertEqual(harness.list.query.view, .inbox, "nothing waits: G O does nothing")

        let sendID = try send(in: harness)
        harness.spin { harness.controller.showsOutbox }
        XCTAssertTrue(reader.showsOutbox)
        XCTAssertTrue(reader.validateMenuItem(item))
        XCTAssertTrue(reader.perform(.goTo(.outbox)))
        harness.spin { harness.list.conversations.map(\.id) == [self.row(sendID)] }
        XCTAssertEqual(harness.list.query.view, .outbox)
    }

    /// At launch the window may read the outbox before its accounts: a send already waiting shows the Outbox once the window
    /// knows its account, not before, since the Outbox lists only the sends of accounts it knows (§5.53).
    func testASendWaitingAtLaunchShowsTheOutboxOnceTheAccountsAreRead() throws {
        let harness = try MainWindowHarness(accounts: false)
        defer { harness.close() }
        // In the store, not yet read by the window.
        try harness.environment.store.upsertAccount(ListTestSupport.accountA)
        XCTAssertTrue(harness.controller.accounts.isEmpty)
        let sendID = try harness.environment.engine.scheduleSend(message(), at: Date().addingTimeInterval(86_400), draftID: nil)
        harness.controller.sendLaterOutbox.refresh()
        XCTAssertEqual(harness.controller.localDrafts.outboxSends.map(\.id), [sendID], "the window has the send")
        XCTAssertFalse(harness.controller.showsOutbox, "but not its account yet")
        XCTAssertFalse(harness.controller.strip.showsOutbox)

        harness.controller.refreshAccounts()
        XCTAssertTrue(harness.controller.showsOutbox)
        XCTAssertTrue(harness.controller.strip.showsOutbox)
        harness.controller.strip.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(outboxTile(harness).isHidden)
        XCTAssertTrue(harness.controller.perform(.goTo(.outbox)))
        harness.spin { harness.list.conversations.map(\.id) == [self.row(sendID)] }
        XCTAssertEqual(harness.list.query.view, .outbox)
    }

    // MARK: Drafts

    /// Drafts lists its Send Later messages exactly as before, and never an undo-send; the Outbox lists both.
    func testDraftsIsUnchanged() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (laterID, draft) = try schedule("Lisbon", at: Date().addingTimeInterval(86_400), harness)
        let undoID = try send("Porto", in: harness)
        showOutbox(listing: [row(undoID), row(laterID)], harness)

        XCTAssertTrue(harness.controller.perform(.goTo(.drafts)))
        harness.spin { harness.list.query.view == .drafts && harness.list.conversations.contains { $0.id == self.row(laterID) } }
        let later = try XCTUnwrap(harness.list.conversations.first { $0.id == row(laterID) })
        XCTAssertNotNil(later.sendLater)
        XCTAssertNil(later.outbox, "a Drafts row as before")
        XCTAssertFalse(harness.list.conversations.contains { $0.id == row(undoID) }, "an undo-send is no draft")
        XCTAssertFalse(harness.list.conversations.contains { $0.id == LocalDraftConversation.conversationID(draftID: draft.id, account: draft.account.id) })
        let index = try XCTUnwrap(harness.list.conversations.firstIndex { $0.id == row(laterID) })
        XCTAssertTrue(try XCTUnwrap(cell(forConversation: index, harness).content?.sender.string).hasPrefix("Draft to"))
        select(row(laterID), in: harness)
        XCTAssertEqual(harness.reader.header.content.actions, ReaderActionSet(primary: [.continueEditing, .discardDraft], replies: []))
        XCTAssertEqual(harness.reader.header.content.kicker?.lead, "Draft")
    }
}
