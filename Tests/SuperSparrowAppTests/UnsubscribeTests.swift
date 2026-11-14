import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// Unsubscribe in the main window (roadmap Q2.4, spec §5.14, §5.30, §5.35, §6): one click (the link, the More menu
/// or ⇧⌘U), no alert, the request and the conversation's archive stored together, the toast naming both, and its Undo
/// bringing the conversation back while the request stays queued; in Later it ends the snooze instead of archiving.
/// The engine never starts and pages open through a stand-in, so nothing leaves the process.
@MainActor
final class UnsubscribeTests: XCTestCase {
    private let a = ListTestSupport.accountA
    private let oneClickHeader = "<https://news.example.com/u/42>, <mailto:leave@news.example.com>"

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    /// A two-message newsletter thread in account A, newer than every other row; the latest message carries `list`.
    @discardableResult
    private func seedNewsletter(_ harness: MainWindowHarness, list: String?, post: String? = nil,
                                roles: Set<MailboxRole> = [.inbox], name: String = "news") throws -> ConversationID {
        let conversation = ConversationID(accountID: a.id, providerID: name)
        let sender = EmailAddress(name: "Frontend Weekly", address: "hello@frontendweekly.test")
        func issue(_ n: Int, list: String?, post: String?) -> MessageMetadata {
            MessageMetadata(id: MessageID(accountID: a.id, providerID: "\(name)-\(n)"), conversationID: conversation,
                            subject: "Frontend Weekly #12\(n)", snippet: "This week", from: sender,
                            to: [EmailAddress(name: a.displayName, address: a.email)],
                            date: Date().addingTimeInterval(Double(n) - 10), roles: roles, isRead: true, isStarred: false,
                            hasAttachments: false, listUnsubscribe: list, listUnsubscribePost: post)
        }
        try harness.environment.store.upsertMessages([issue(1, list: nil, post: nil), issue(2, list: list, post: post)])
        return conversation
    }

    private func open(_ id: ConversationID, in harness: MainWindowHarness) {
        harness.spin { harness.list.conversations.contains { $0.id == id } }
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentConversationID == id && !harness.reader.currentMessages.isEmpty }
    }

    private func operations(_ harness: MainWindowHarness) throws -> [SSCore.Operation] {
        try harness.environment.store.pendingOperations(accountID: a.id, limit: 50)
    }

    private func latest(_ name: String = "news") -> MessageID { MessageID(accountID: a.id, providerID: "\(name)-2") }

    private func inInbox(_ id: ConversationID, _ harness: MainWindowHarness) throws -> Bool {
        try harness.environment.store.messages(in: id).contains { $0.roles.contains(.inbox) }
    }

    // MARK: ⇧⌘U

    func testCommandShiftUUnsubscribesAndArchivesAndUndoBringsTheConversationBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let news = try seedNewsletter(harness, list: oneClickHeader, post: "List-Unsubscribe=One-Click")
        open(news, in: harness)
        XCTAssertEqual(harness.reader.unsubscribeTarget, latest(), "the latest message that offers it")
        XCTAssertTrue(harness.controller.validateMenuItem(item(#selector(MainWindowController.unsubscribeFromConversation(_:)))))

        // ⇧⌘U is Message › Unsubscribe's key equivalent, and it reaches the window.
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "U", charactersIgnoringModifiers: "u",
                                                   isARepeat: false, keyCode: 32))
        let menuItem = try XCTUnwrap(MainMenuBar.exactItem(for: event, in: bar))
        XCTAssertEqual(menuItem.title, "Unsubscribe")
        XCTAssertEqual(menuItem.menu?.title, "Message")
        let action = try XCTUnwrap(menuItem.action)
        XCTAssertTrue(NSApp.sendAction(action, to: harness.controller, from: menuItem))

        // Store first, one call: the archive of the whole conversation, then the request with its method.
        let queued = try operations(harness)
        XCTAssertEqual(queued.map(\.change), [.archive, .unsubscribe(.oneClick(URL(string: "https://news.example.com/u/42")!))])
        XCTAssertEqual(Set(queued[0].targets.map(\.providerID)), ["news-1", "news-2"])
        XCTAssertFalse(try inInbox(news, harness))
        harness.spin { !harness.list.conversations.contains { $0.id == news } }
        XCTAssertFalse(harness.list.conversations.contains { $0.id == news }, "the row leaves the Inbox at once")

        // No alert: the toast says what became of the request, then the archive Undo takes back.
        XCTAssertEqual(harness.toastMessage, "Unsubscribe sent \u{00B7} Archived")
        XCTAssertEqual(harness.toasts.visibleKind, .undoable)
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Archive")

        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertTrue(try inInbox(news, harness), "Undo brings the conversation back")
        XCTAssertEqual(harness.toastMessage, "Undid Archive \u{00B7} Unsubscribe stays sent", "and says what it did not take back")
        let after = try operations(harness).map(\.change)
        XCTAssertTrue(after.contains(.unsubscribe(.oneClick(URL(string: "https://news.example.com/u/42")!))), "the request stays")
        XCTAssertEqual(after.last, .moveToInbox)
        harness.spin { harness.list.conversations.contains { $0.id == news } }
        XCTAssertEqual(harness.list.selectedConversationIDs, [news], "the restored row is selected")
    }

    func testTheMenuItemNeedsOneOpenConversationThatOffersIt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let unsubscribe = item(#selector(MainWindowController.unsubscribeFromConversation(_:)))
        XCTAssertFalse(harness.controller.validateMenuItem(unsubscribe), "nothing open")

        let plain = harness.list.conversations[0].id
        open(plain, in: harness)
        XCTAssertNil(harness.reader.unsubscribeTarget)
        XCTAssertFalse(harness.controller.validateMenuItem(unsubscribe), "a conversation with no list headers")
        harness.controller.unsubscribeFromConversation(nil)
        XCTAssertTrue(try operations(harness).isEmpty, "the command does nothing there")

        let news = try seedNewsletter(harness, list: "<ftp://news.example.com/u>")
        open(news, in: harness)
        XCTAssertFalse(harness.controller.validateMenuItem(unsubscribe), "headers that offer nothing usable")

        let usable = try seedNewsletter(harness, list: oneClickHeader, name: "usable")
        open(usable, in: harness)
        XCTAssertTrue(harness.controller.validateMenuItem(unsubscribe))
        harness.selectFirst(3)
        XCTAssertFalse(harness.controller.validateMenuItem(unsubscribe), "several selected")
    }

    // MARK: The three ways

    func testAMailtoRequestIsQueuedLikeAOneClickOne() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let news = try seedNewsletter(harness, list: "<mailto:leave@news.example.com?subject=unsubscribe>, <https://news.example.com/page>")
        open(news, in: harness)
        var opened: [URL] = []
        harness.controller.openUnsubscribePage = { opened.append($0) }
        harness.controller.handle(.unsubscribe(latest()))
        XCTAssertEqual(try operations(harness).map(\.change),
                       [.archive, .unsubscribe(.mailto(URL(string: "mailto:leave@news.example.com?subject=unsubscribe")!))])
        XCTAssertEqual(harness.toastMessage, "Unsubscribe sent \u{00B7} Archived")
        XCTAssertTrue(opened.isEmpty, "a request opens nothing")
    }

    func testAPageOpensInTheBrowserAndOnlyTheArchiveIsQueued() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let news = try seedNewsletter(harness, list: "<http://news.example.com/plain>, <https://news.example.com/page>")
        open(news, in: harness)
        var opened: [URL] = []
        harness.controller.openUnsubscribePage = { opened.append($0) }
        harness.controller.handle(.unsubscribe(latest()))
        XCTAssertEqual(opened, [URL(string: "https://news.example.com/page")!], "https before http, opened at once")
        XCTAssertEqual(try operations(harness).map(\.change), [.archive], "no engine for a page")
        XCTAssertEqual(harness.toastMessage, "Opened in browser \u{00B7} Archived")
        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertTrue(try inInbox(news, harness))
        XCTAssertEqual(harness.toastMessage, "Undid Archive", "a page sent nothing")
    }

    func testNothingToArchiveLeavesTheRequestsWordsAndNothingToUndo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        _ = harness.controller.perform(.goTo(.all))
        let news = try seedNewsletter(harness, list: oneClickHeader, post: "List-Unsubscribe=One-Click", roles: [])
        open(news, in: harness)
        harness.controller.unsubscribeFromConversation(nil)
        harness.controller.unsubscribeFromConversation(nil)
        XCTAssertEqual(try operations(harness).map(\.change), [.unsubscribe(.oneClick(URL(string: "https://news.example.com/u/42")!))],
                       "asked again while its toast is up, the request is not sent twice")
        XCTAssertEqual(harness.toastMessage, "Unsubscribe sent")
        XCTAssertEqual(harness.toasts.visibleKind, .confirmation)
        XCTAssertEqual(harness.controller.zTarget, .nothing, "the request cannot be undone, and nothing else happened")
    }

    // MARK: Asked twice

    /// A double-click on the link, or ⇧⌘U pressed again, where the archived row stays listed (All, Starred, a search):
    /// while the toast is up the same request is not sent twice, and the toast keeps its Undo. Once it has gone, asking
    /// again is a new request.
    func testAskingAgainWhileTheToastIsUpSendsNothingMoreAndKeepsTheUndo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        _ = harness.controller.perform(.goTo(.all))
        let news = try seedNewsletter(harness, list: "<mailto:leave@news.example.com>")
        open(news, in: harness)
        let request = SSCore.MetadataChange.unsubscribe(.mailto(URL(string: "mailto:leave@news.example.com")!))

        harness.controller.handle(.unsubscribe(latest()))
        let toast = harness.toasts.visibleID
        harness.controller.handle(.unsubscribe(latest()))  // a double-click's second click
        harness.controller.unsubscribeFromConversation(nil)
        XCTAssertEqual(harness.reader.currentConversationID, news, "the row stays listed here, and the link with it")
        XCTAssertEqual(try operations(harness).map(\.change), [.archive, request], "one request, one archive")
        XCTAssertEqual(harness.toasts.visibleID, toast, "the same toast")
        XCTAssertEqual(harness.toastMessage, "Unsubscribe sent \u{00B7} Archived")
        XCTAssertEqual(harness.toasts.visibleKind, .undoable, "its Undo still on screen")
        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertTrue(try inInbox(news, harness), "and it brings the conversation back")

        harness.toasts.dismiss()
        harness.controller.handle(.unsubscribe(latest()))
        XCTAssertEqual(try operations(harness).map(\.change).filter { $0 == request }.count, 2, "asked again later, it is sent again")
    }

    // MARK: Undo and the toast

    /// The unsubscribe's toast keeps its words: an archive right after it gets a toast of its own, and each Undo
    /// reverts its own archive.
    func testAnArchiveRightAfterGetsItsOwnToast() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let news = try seedNewsletter(harness, list: oneClickHeader)
        open(news, in: harness)
        harness.controller.unsubscribeFromConversation(nil)
        XCTAssertEqual(harness.toastMessage, "Unsubscribe sent \u{00B7} Archived")
        harness.spin { !harness.list.conversations.contains { $0.id == news } }
        let other = harness.list.conversations[0].id
        harness.list.selectedConversationID = other
        harness.list.onSelectionChange?(other)
        _ = harness.controller.perform(.archive)
        XCTAssertEqual(harness.toastMessage, "Archived", "not “Archived 2 conversations”")
        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertTrue(try inInbox(other, harness))
        XCTAssertFalse(try inInbox(news, harness), "Z reverts the latest archive only")
        XCTAssertEqual(harness.toastMessage, "Undid Archive", "a plain archive's undo says nothing of the request")
        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertTrue(try inInbox(news, harness))
        XCTAssertEqual(harness.toastMessage, "Undid Archive \u{00B7} Unsubscribe stays sent")
    }

    // MARK: In Later

    /// Snoozes `ids` straight in the store, archiving them, until `due`; the window hears of it through its observation.
    private func snoozeInStore(_ ids: [ConversationID], until due: Date, _ harness: MainWindowHarness) throws {
        let store = harness.environment.store
        for id in ids {
            let targets = try store.messages(in: id).filter(\.isInInbox).map(\.id)
            try store.setSnoozes([Snooze.Change(conversationID: id, until: due)],
                                 enqueueing: [SSCore.Operation(accountID: id.accountID, change: .archive, targets: targets)], at: Date())
        }
        harness.spin { harness.controller.snoozes.count >= ids.count }
    }

    private func snoozedIDs(_ harness: MainWindowHarness) throws -> Set<ConversationID> {
        Set(try harness.environment.store.snoozes().map(\.conversationID))
    }

    /// A snoozed newsletter is archived already (spec §5.14, §5.45): Unsubscribe sends its request and ends the snooze,
    /// as E does in Later, so the issue never comes back to the Inbox, with the toast it has everywhere. An E in Later
    /// right after, named Archive like it, gets a toast of its own, and each Undo puts back its own snooze, the request
    /// staying sent.
    func testInLaterItEndsTheSnoozeAndNoEJoinsItsToast() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let news = try seedNewsletter(harness, list: oneClickHeader, post: "List-Unsubscribe=One-Click")
        harness.spin { harness.list.conversations.contains { $0.id == news } }
        let other = try XCTUnwrap(harness.list.conversations.first { $0.id != news }).id
        let due = Date().addingTimeInterval(7 * 86_400)
        try snoozeInStore([news, other], until: due, harness)
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.query.view == .later && harness.list.conversations.count == 2 }
        open(news, in: harness)
        XCTAssertTrue(harness.controller.validateMenuItem(item(#selector(MainWindowController.unsubscribeFromConversation(_:)))))

        harness.controller.unsubscribeFromConversation(nil)
        let request = SSCore.MetadataChange.unsubscribe(.oneClick(URL(string: "https://news.example.com/u/42")!))
        XCTAssertEqual(try snoozedIDs(harness), [other], "the snooze ends: the issue does not come back at its time")
        XCTAssertFalse(try inInbox(news, harness), "and it stays archived")
        XCTAssertEqual(try operations(harness).map(\.change).filter { $0 == request }.count, 1, "the request is queued")
        XCTAssertEqual(harness.toastMessage, "Unsubscribe sent \u{00B7} Archived")
        XCTAssertEqual(harness.toasts.visibleKind, .undoable)
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Archive")
        let toast = harness.toasts.visibleID
        harness.spin { harness.list.conversations.map(\.id) == [other] }

        open(other, in: harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertEqual(harness.toastMessage, "Archived", "E in Later right after: not “Archived 2 conversations”")
        XCTAssertNotEqual(harness.toasts.visibleID, toast)
        XCTAssertTrue(try snoozedIDs(harness).isEmpty)
        // Later emptied, so the window went back to the Inbox (§5.2), once the snoozes' observation said so.
        harness.spin { harness.list.query.view == .inbox }

        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(try snoozedIDs(harness), [other], "Z reverts the latest step only")
        XCTAssertEqual(harness.toastMessage, "Undid Archive")
        // The undo brings Later back with its row, as for E alone.
        harness.spin { harness.list.query.view == .later && harness.list.conversations.map(\.id) == [other] }
        XCTAssertEqual(harness.list.selectedConversationIDs, [other])
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(try snoozedIDs(harness), [news, other], "back in Later")
        let restored = try XCTUnwrap(try harness.environment.store.snoozes().first { $0.conversationID == news })
        XCTAssertEqual(restored.dueAt.timeIntervalSince1970, due.timeIntervalSince1970, accuracy: 0.001, "at its time, as before")
        XCTAssertEqual(harness.toastMessage, "Undid Archive \u{00B7} Unsubscribe stays sent")
        XCTAssertEqual(try operations(harness).map(\.change).filter { $0 == request }.count, 1, "the request stays sent")
        harness.spin { harness.list.conversations.count == 2 }
        XCTAssertEqual(harness.list.query.view, .later)
        XCTAssertEqual(harness.list.selectedConversationIDs, [news], "the restored row is selected in Later")
    }

    /// Both undoable toasts fit the default list whole (spec §5.30), so the archive Undo takes back is never the part
    /// cut off, in either face of the system font.
    func testTheToastsFitTheDefaultListWhole() {
        let room = Quire.Layout.List.defaultWidth - 2 * Quire.Layout.Toast.sideMargin
        let methods: [UnsubscribeMethod] = [.oneClick(URL(string: "https://news.example.com/u")!),
                                            .browser(URL(string: "https://news.example.com/page")!)]
        for method in methods {
            let words = MailActionCopy.unsubscribeToast(for: method, archived: true)
            let slip = QuireSlipView(kind: .undoable, message: words, symbolName: Quire.Icon.archive)
            _ = slip.setAction("Undo", keycap: "Z", target: nil, action: nil)
            XCTAssertLessThanOrEqual(slip.intrinsicContentSize.width, room, words)
            let undone = MailActionCopy.unsubscribeUndoConfirmation(for: method)
            let confirmation = QuireSlipView(kind: .confirmation, message: undone, symbolName: Quire.Icon.undone)
            XCTAssertLessThanOrEqual(confirmation.intrinsicContentSize.width, room, undone)
        }
    }

    // MARK: The context menu

    /// A right-click on a newsletter's row or on its sheet (spec §5.35) offers Unsubscribe after the selection's
    /// commands; on mail that is no list's the item is not there at all.
    func testTheContextMenuOffersUnsubscribeOnAConversationThatOffersIt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let news = try seedNewsletter(harness, list: oneClickHeader, post: "List-Unsubscribe=One-Click")
        harness.spin { harness.list.conversations.contains { $0.id == news } }
        let plain = try XCTUnwrap(harness.list.conversations.first { $0.id != news }).id
        open(plain, in: harness)
        let plainSheet = try XCTUnwrap(harness.reader.messageMenu?())
        XCTAssertFalse(plainSheet.items.contains { $0.title == "Unsubscribe" }, "mail that is no list's")

        // The row, right-clicked while another conversation is open: selected and opened first, so the menu knows.
        let index = try XCTUnwrap(harness.list.conversations.firstIndex { $0.id == news })
        let row = try XCTUnwrap(harness.list.layout.row(ofConversation: index))
        let rowMenu = try XCTUnwrap(harness.list.contextMenu(forRow: row))
        XCTAssertEqual(harness.list.selectedConversationIDs, [news])
        XCTAssertEqual(harness.reader.unsubscribeTarget, latest())
        // Beside the sender rules: all three are about who sent it (spec, Sender rules (Q4.2)).
        XCTAssertEqual(Array(rowMenu.items.suffix(7).map { $0.isSeparatorItem ? "—" : $0.title }),
                       ["—", "Move to Trash", "Mark as Spam", "—", "Unsubscribe", "Always Archive Mail from This Sender", "Block Sender"])

        // The sheet's right-click (the card's `messageMenu`) shows the same menu.
        let sheetMenu = try XCTUnwrap(harness.reader.messageMenu?())
        sheetMenu.update()
        let entry = try XCTUnwrap(sheetMenu.items.first { $0.title == "Unsubscribe" })
        XCTAssertTrue(entry.isEnabled)
        XCTAssertEqual(entry.keyEquivalent, "u")
        XCTAssertEqual(entry.keyEquivalentModifierMask, [.command, .shift])
        let action = try XCTUnwrap(entry.action)
        XCTAssertTrue(NSApp.sendAction(action, to: entry.target, from: entry))
        XCTAssertEqual(try operations(harness).map(\.change),
                       [.archive, .unsubscribe(.oneClick(URL(string: "https://news.example.com/u/42")!))])
        XCTAssertEqual(harness.toastMessage, "Unsubscribe sent \u{00B7} Archived")
    }

    // MARK: The More menu

    func testTheMoreMenuOffersUnsubscribeOnlyOnAMessageThatOffersIt() {
        var chosen: [MessageMoreMenu.Command] = []
        let more = MessageMoreMenu { chosen.append($0) }
        let without = more.menu(MessageMoreMenu.Options(isStarred: false, imagesBlocked: false, offersOriginal: false,
                                                        showsOriginal: false, hasSenderAddress: true))
        XCTAssertFalse(without.items.contains { $0.title == "Unsubscribe" }, "hidden, not disabled (§5.14)")

        let with = more.menu(MessageMoreMenu.Options(isStarred: false, imagesBlocked: false, offersOriginal: false,
                                                     showsOriginal: false, hasSenderAddress: true, canUnsubscribe: true))
        let titles = with.items.map { $0.isSeparatorItem ? "—" : $0.title }
        XCTAssertEqual(Array(titles.suffix(3)), ["—", "Unsubscribe", "Copy Sender Address"])
        let entry = try? XCTUnwrap(with.items.first { $0.title == "Unsubscribe" })
        XCTAssertEqual(entry?.keyEquivalent, "u")
        XCTAssertEqual(entry?.keyEquivalentModifierMask, [.command, .shift])
        if let entry, let action = entry.action { _ = (entry.target as AnyObject?)?.perform(action, with: entry) }
        XCTAssertEqual(chosen, [.unsubscribe])
    }
}
