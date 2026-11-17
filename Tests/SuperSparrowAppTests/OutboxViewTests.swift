import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The Outbox (spec §5.53): View › Outbox and G O open it; it lists every send the provider has not taken yet, built from
/// the outbox alone, follows the outbox as it changes and drops a send the moment it is taken; an empty one says so; no
/// mail action applies to its rows; a held Send Later message continues and cancels as from Drafts, and every other row
/// only shows; Drafts lists what it listed before. The engine never runs here (the outbox is moved by hand), and drafts go
/// to a temporary folder.
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

    private func showOutbox(listing ids: [ConversationID], _ harness: MainWindowHarness) {
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

    // MARK: Getting there

    /// View › Outbox, always listed and enabled with its symbol and G O, lists a send from the moment Send is pressed, and
    /// the row follows the outbox: “Sending…”, “Retrying shortly”, “Couldn't send” in danger, then gone once taken.
    func testTheViewMenuOpensTheOutboxWhichFollowsASendUntilItIsTaken() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        // A G-sequence item's title is its attributed title's text: the name, a tab and the keys.
        let item = try XCTUnwrap(try viewMenu().items.first { $0.title.hasPrefix("Outbox") })
        XCTAssertEqual(item.action, #selector(MainWindowController.goToMailboxView(_:)))
        XCTAssertEqual(item.tag, MailboxView.allCases.firstIndex(of: .outbox))
        XCTAssertNotNil(item.image, "its symbol, as the other views have theirs")
        XCTAssertEqual(item.attributedTitle?.string, "Outbox\tG O")
        XCTAssertFalse(item.isHidden)
        XCTAssertTrue(harness.controller.validateMenuItem(item), "always enabled, with nothing in it too")
        let titles = try viewMenu().items.filter { $0.action == #selector(MainWindowController.goToMailboxView(_:)) }
            .map { $0.title.components(separatedBy: "\t")[0] }
        XCTAssertEqual(titles, ["Inbox", "Later", "Starred", "Sent", "Drafts", "Outbox", "Trash", "All Mail"])

        let sendID = try send(in: harness)
        harness.controller.goToMailboxView(item)
        harness.spin { harness.list.conversations.map(\.id) == [self.row(sendID)] }
        XCTAssertEqual(harness.list.query.view, .outbox)
        XCTAssertEqual(harness.controller.listPane.header.masthead.title, "Outbox")
        XCTAssertEqual(harness.controller.listPane.header.searchPlaceholder, "Search Outbox")
        XCTAssertEqual(harness.controller.strip.mailboxView, .outbox)
        XCTAssertFalse(harness.controller.strip.folderTiles.contains(where: \.isSelected), "no tile is raised: it has none")
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
        harness.spin { harness.list.conversations.isEmpty }
        XCTAssertTrue(harness.list.conversations.isEmpty, "taken: it leaves at once, before the runner deletes the row")
        XCTAssertFalse(harness.list.emptyView.isHidden)
    }

    /// G O goes there from any view; the HUD and the cheat sheet list it after Drafts.
    func testGOGoesToTheOutboxAndTheSheetsListIt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        XCTAssertEqual(KeyboardRouter.sequenceView(characters: "o"), .outbox)
        XCTAssertEqual(KeyboardRouter.sequenceView(characters: "O"), .outbox)
        XCTAssertTrue(harness.controller.perform(.goTo(.trash)))
        XCTAssertTrue(harness.controller.perform(.goTo(KeyboardRouter.sequenceView(characters: "o")!)))
        harness.spin { harness.list.query.view == .outbox }
        XCTAssertEqual(harness.list.query.view, .outbox)
        let go = try XCTUnwrap(Quire.cheatSheet.first { $0.title == "Go" })
        XCTAssertEqual(go.rows.map(\.keys), ["G then I", "G then L", "G then S", "G then T", "G then D", "G then O", "G then #", "G then A",
                                             "⌘0 … ⌘9"])
        XCTAssertEqual(go.rows.first { $0.keys == "G then O" }?.label, "Outbox")
        XCTAssertEqual(QuireSequenceHUDView.sequenceRows().map(\.keys), ["I", "L", "S", "T", "D", "O", "#", "A"])
    }

    /// An empty Outbox says so, in the empty state's two lines, whatever the accounts are doing.
    func testAnEmptyOutboxSaysSo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        showOutbox(listing: [], harness)
        harness.spin { !harness.list.emptyView.isHidden }
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
        harness.spin { harness.list.conversations.isEmpty && harness.reader.selection != .one(id) }
        XCTAssertTrue(harness.list.conversations.isEmpty)
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
        harness.spin { harness.list.conversations.isEmpty }
        XCTAssertTrue(harness.list.conversations.isEmpty, "it leaves the Outbox")
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
