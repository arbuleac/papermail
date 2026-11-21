import AppKit
import SSCore
import SSDesign
import SwiftUI
import XCTest
@testable import SuperSparrowApp

/// Mute (roadmap Q3.7) and sender rules (Q4.2) in the main window and Settings: M mutes with E's toast and undo where
/// the row leaves the list, the row carries the muted glyph, the Message menu and the context menu name both, a rule set
/// from a message's menu moves that sender's mail and toasts with Undo, Settings › Accounts › Senders… lists and removes
/// rules, and no notification fires for mail a mute or a rule took out of the Inbox. The engine never starts: actions
/// are applied to the store and queued, as before the network answers.
@MainActor
final class MuteAndSenderRulesTests: XCTestCase {
    private let a = ListTestSupport.accountA

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    private func store(_ harness: MainWindowHarness) -> MailStoring { harness.environment.store }

    private func open(_ id: ConversationID, in harness: MainWindowHarness) {
        harness.spin { harness.list.conversations.contains { $0.id == id } }
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentConversationID == id && !harness.reader.currentMessages.isEmpty }
    }

    private func summary(_ id: ConversationID, _ harness: MainWindowHarness) throws -> ConversationSummary? {
        try store(harness).conversations(ConversationQuery(view: .all, limit: 500)).first { $0.id == id }
    }

    private func cell(of id: ConversationID, _ harness: MainWindowHarness) throws -> ConversationCellView {
        harness.spin { harness.list.conversations.contains { $0.id == id } }
        let index = try XCTUnwrap(harness.list.conversations.firstIndex { $0.id == id })
        let row = try XCTUnwrap(harness.list.layout.row(ofConversation: index))
        return try XCTUnwrap(harness.list.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ConversationCellView)
    }

    // MARK: The key

    func testMIsMuteAndCommandMStaysMinimize() {
        XCTAssertEqual(KeyboardRouter.command(characters: "m", keyCode: 46, modifiers: [], pendingG: false, readerFocused: false).command,
                       .toggleMute)
        XCTAssertNil(KeyboardRouter.command(characters: "m", keyCode: 46, modifiers: .command, pendingG: false, readerFocused: false).command,
                     "⌘M is the Window menu's Minimize")
        XCTAssertTrue(Quire.cheatSheet.flatMap(\.rows).contains { $0.keys == "M" && $0.label == "Mute · unmute" }, "the cheat sheet lists it")
    }

    // MARK: Mute

    func testMMutesAndArchivesWithAToastAndZBringsItBackUnmuted() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let first = harness.list.conversations[0].id
        open(first, in: harness)
        XCTAssertEqual({ let menu = item(#selector(MainWindowController.toggleMuteSelection(_:)))
            _ = harness.controller.validateMenuItem(menu); return menu.title }(), "Mute")

        XCTAssertTrue(harness.controller.perform(.toggleMute))
        XCTAssertEqual(try summary(first, harness)?.isMuted, true)
        XCTAssertEqual(try summary(first, harness)?.inInbox, false, "archived with it")
        XCTAssertEqual(try store(harness).pendingOperations(accountID: first.accountID, limit: 10).map(\.change), [.archive])
        harness.spin { !harness.list.conversations.contains { $0.id == first } }
        XCTAssertFalse(harness.list.conversations.contains { $0.id == first }, "the row leaves the Inbox")
        XCTAssertEqual(harness.toastMessage, "Muted")
        XCTAssertEqual(harness.toasts.visibleKind, .undoable)
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Mute")

        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertEqual(try summary(first, harness)?.isMuted, false)
        XCTAssertEqual(try summary(first, harness)?.inInbox, true)
        XCTAssertEqual(harness.toastMessage, "Undid Mute")
        harness.spin { harness.list.conversations.contains { $0.id == first } }
        XCTAssertEqual(harness.list.selectedConversationIDs, [first], "the restored row is selected")
    }

    /// Out of the Inbox the row stays: its glyph says it, so one mute or unmute there has no toast, as a star has none,
    /// and Z still reaches it.
    func testInAllMailTheRowStaysWithItsGlyphAndMAgainUnmutes() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let first = harness.list.conversations[0].id
        _ = harness.controller.perform(.goTo(.all))
        open(first, in: harness)
        XCTAssertTrue(harness.controller.perform(.toggleMute))
        harness.spin { (try? self.cell(of: first, harness).content?.isMuted) == true }
        let muted = try cell(of: first, harness)
        XCTAssertEqual(muted.content?.isMuted, true, "the row carries the muted glyph")
        XCTAssertTrue(muted.content?.accessibilityLabel.contains("Muted.") == true, "VoiceOver reads it")
        XCTAssertNotEqual(harness.toastMessage, "Muted", "the row shows it; no toast")

        let menu = item(#selector(MainWindowController.toggleMuteSelection(_:)))
        XCTAssertTrue(harness.controller.validateMenuItem(menu))
        XCTAssertEqual(menu.title, "Unmute", "all selected are muted")
        XCTAssertTrue(harness.controller.perform(.toggleMute))
        XCTAssertEqual(try summary(first, harness)?.isMuted, false)
        XCTAssertEqual(try summary(first, harness)?.inInbox, false, "unmuting moves nothing")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Unmute")
        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertEqual(try summary(first, harness)?.isMuted, true)
    }

    /// M takes a conversation back from Later out of the Inbox, which ends its mark; Z puts the row back where it was,
    /// first under Today with its mark, as Z after E does, not eight rows down under its old date.
    func testUndoingAMutePutsAReturnedRowBackUnderToday() throws {
        let harness = try MainWindowHarness(threads: 10, spacing: 86_400)
        defer { harness.close() }
        let store = store(harness)
        let old = harness.list.conversations[8].id // eight days back
        let targets = try store.messages(in: old).map(\.id)
        try store.setSnoozes([Snooze.Change(conversationID: old, until: Date().addingTimeInterval(-60))],
                             enqueueing: [SSCore.Operation(accountID: old.accountID, change: .archive, targets: targets)],
                             at: Date().addingTimeInterval(-600))
        let now = Date()
        try store.returnDueSnoozes(at: now, limit: 10) { id, messages in
            [SSCore.Operation(accountID: id.accountID, change: .moveToInbox, targets: messages.map(\.id), createdAt: now)]
        }
        harness.spin { harness.list.conversations.first?.id == old }
        let mark = try XCTUnwrap(harness.list.conversations.first?.returnedAt)

        open(old, in: harness)
        XCTAssertTrue(harness.controller.perform(.toggleMute))
        harness.spin { !harness.list.conversations.contains { $0.id == old } }
        XCTAssertFalse(harness.list.conversations.contains { $0.id == old }, "archived with the mute")
        harness.controller.performUndo(harness.controller.zTarget)
        harness.spin { harness.list.conversations.first?.id == old }
        XCTAssertEqual(harness.list.conversations.first?.id, old, "back first")
        XCTAssertEqual(harness.list.conversations.first?.returnedAt, mark, "with its mark")
        XCTAssertEqual(harness.list.conversations.first?.isMuted, false)
        if case .head(.today)? = harness.list.layout.items.first {} else { XCTFail("under Today") }
    }

    func testSeveralAreMutedAsOneStep() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.selectFirst(3)
        let ids = harness.list.selectedConversationIDs
        XCTAssertTrue(harness.controller.perform(.toggleMute))
        XCTAssertEqual(try ids.compactMap { try summary($0, harness)?.isMuted }, [true, true, true])
        XCTAssertEqual(harness.toastMessage, "Muted 3 conversations")
        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertEqual(try ids.compactMap { try summary($0, harness)?.isMuted }, [false, false, false])
    }

    func testTheMessageMenuAndTheContextMenuNameMute() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let message = try XCTUnwrap(bar.items.first { $0.submenu?.title == "Message" }?.submenu)
        let mute = try XCTUnwrap(message.items.first { $0.action == #selector(MainWindowController.toggleMuteSelection(_:)) })
        XCTAssertEqual(mute.title, "Mute")
        XCTAssertEqual(mute.keyEquivalent, "m")
        XCTAssertEqual(mute.keyEquivalentModifierMask, [], "a single key, shown in the menu, performed by the router")
        XCTAssertNotNil(message.items.first { $0.title == "Always Archive Mail from This Sender" })
        XCTAssertNotNil(message.items.first { $0.title == "Block Sender" })

        open(harness.list.conversations[0].id, in: harness)
        let context = harness.controller.selectionContextMenu()
        XCTAssertEqual(context.items.first { $0.action == #selector(MainWindowController.toggleMuteSelection(_:)) }?.title, "Mute")
    }

    // MARK: Notifications

    /// Mail a mute or a sender rule took out of the Inbox never notifies, with the window's own wiring; mail beside it
    /// does. The rules are the server's: their mail arrives as the server put it (archived, or in the Trash).
    func testNoNotificationFiresForAMutedOrRuledArrival() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.settings.notificationsEnabled = true
        let store = store(harness)
        let rows = harness.list.conversations
        let muted = rows[0].id
        let shared = try XCTUnwrap(rows.first { $0.id.accountID == a.id && $0.id != muted }).id
        open(muted, in: harness)
        XCTAssertTrue(harness.controller.perform(.toggleMute))
        try store.replaceServerSenderRules(accountID: a.id, with: [
            ServerSenderRule(serverID: "f1", address: "deals@shop.example", action: .trash),
            ServerSenderRule(serverID: "f2", address: "news@letter.example", action: .archive),
        ], readAt: Date())

        let notifier = NewMailNotifier(settings: harness.settings, launchDate: Date().addingTimeInterval(-3_600))
        notifier.isFrontmost = { false }
        notifier.newestUnreadInInbox = harness.controller.notifier.newestUnreadInInbox
        let inbox = { try store.conversations(ConversationQuery(view: .inbox, limit: 300)) }
        XCTAssertTrue(notifier.plan(try inbox(), accounts: [a.id: a], now: Date()).isEmpty, "the first delivery only records")

        func arrival(_ id: String, in conversation: ConversationID, from: EmailAddress,
                     roles: Set<MailboxRole> = [.inbox]) -> MessageMetadata {
            MessageMetadata(id: MessageID(accountID: conversation.accountID, providerID: id), conversationID: conversation,
                            subject: "New", snippet: "New mail", from: from, to: [EmailAddress(address: a.email)], date: Date(),
                            roles: roles, isRead: false, isStarred: false, hasAttachments: false)
        }
        // One poll in a fresh conversation: Ben's message, then a minute later one his list's rule archived on the server,
        // the row's newest.
        let mixed = ConversationID(accountID: a.id, providerID: "mixed")
        var ruledAfter = arrival("ruled-after", in: mixed, from: EmailAddress(name: "Weekly", address: "news@letter.example"), roles: [])
        ruledAfter.date = Date().addingTimeInterval(60)
        try store.upsertMessages([
            arrival("ben-first", in: mixed, from: EmailAddress(name: "Ben", address: "ben@example.com")),
            ruledAfter,
            arrival("muted-new", in: muted, from: EmailAddress(name: "Ada", address: "ada@example.com")),
            arrival("blocked-new", in: ConversationID(accountID: a.id, providerID: "blocked"), from: EmailAddress(address: "deals@shop.example"),
                    roles: [.trash]),
            // Archived by its sender's rule on the server, yet the newest message of a conversation the Inbox still holds for
            // older mail.
            arrival("archived-new", in: shared, from: EmailAddress(name: "Weekly", address: "news@letter.example"), roles: []),
            arrival("plain-new", in: ConversationID(accountID: a.id, providerID: "plain"), from: EmailAddress(name: "Ben", address: "ben@example.com")),
        ])
        let posts = notifier.plan(try inbox(), accounts: [a.id: a], now: Date())
        XCTAssertEqual(Set(posts.compactMap(\.conversation)), [ConversationID(accountID: a.id, providerID: "plain"), mixed],
                       "the plain arrivals notify, Ben's too though a ruled message came after it")
        XCTAssertEqual(posts.first { $0.conversation == mixed }?.id, "ben-first", "about Ben's message, not the ruled one")
        XCTAssertEqual(try inbox().first { $0.id == mixed }?.latestMessageID.providerID, "ruled-after", "the row's newest is the ruled one")
        XCTAssertTrue(try inbox().contains { $0.id == shared }, "the shared conversation stays in the Inbox for its older mail")
    }

    // MARK: Sender rules

    func testBlockSenderFromTheContextMenuTrashesTheirMailAndUndoTakesItBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let first = harness.list.conversations[0]
        open(first.id, in: harness)
        let target = try XCTUnwrap(harness.reader.senderRuleTarget)
        let address = try XCTUnwrap(target.from?.address)
        let context = harness.controller.selectionContextMenu()
        let block = try XCTUnwrap(context.items.first { $0.action == #selector(MainWindowController.blockSender(_:)) })
        XCTAssertEqual(block.title, "Block Sender")
        XCTAssertNotNil(context.items.first { $0.action == #selector(MainWindowController.alwaysArchiveSender(_:)) })
        XCTAssertTrue(harness.controller.validateMenuItem(block))

        harness.controller.blockSender(nil)
        XCTAssertEqual(try store(harness).senderRules().map(\.address), [address.lowercased()])
        XCTAssertEqual(try store(harness).senderRules().map(\.action), [.trash])
        XCTAssertEqual(try store(harness).message(target.id)?.roles.contains(.trash), true, "their mail here goes to the Trash")
        XCTAssertEqual(harness.toastMessage, "Blocked \(address.lowercased())", "the toast names whose mail it takes")
        XCTAssertEqual(harness.toasts.visibleKind, .undoable)
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Block Sender")

        // The rule the sender has is checked and has nothing more to do.
        let again = item(#selector(MainWindowController.blockSender(_:)))
        open(first.id, in: harness)
        _ = harness.controller.validateMenuItem(again)
        XCTAssertEqual(again.state, .on)

        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertTrue(try store(harness).senderRules().isEmpty)
        XCTAssertEqual(try store(harness).message(target.id)?.roles, [.inbox])
        XCTAssertEqual(harness.toastMessage, "Undid Block Sender")
    }

    /// A rule removed on this Mac is being deleted on the server, and is no longer the sender's: the menus offer both
    /// rules again rather than mark the one on its way out.
    func testARuleBeingDeletedOnTheServerIsNoLongerTheSenders() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        open(harness.list.conversations[0].id, in: harness)
        let target = try XCTUnwrap(harness.reader.senderRuleTarget)
        let address = try XCTUnwrap(target.from?.address)
        try store(harness).replaceServerSenderRules(accountID: target.id.accountID,
                                                    with: [ServerSenderRule(serverID: "f1", address: address, action: .trash)],
                                                    readAt: Date())
        XCTAssertEqual(harness.reader.senderRule(for: target), .trash, "the server's rule is the sender's")
        try store(harness).setSenderRule(nil, for: address, accountID: target.id.accountID, enqueueing: [], at: Date())
        XCTAssertEqual(try store(harness).senderRules().map(\.sync), [.deleting])
        XCTAssertNil(harness.reader.senderRule(for: target))
    }

    /// From the message's More menu: Always Archive takes that sender's mail in the Inbox at once, and the rule waits to be
    /// saved on the server, whose filter keeps their next message out of the Inbox before this Mac sees it.
    func testAlwaysArchiveFromAMessageAndTheirNextMailSkipsTheInbox() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let first = harness.list.conversations[0]
        open(first.id, in: harness)
        let target = try XCTUnwrap(harness.reader.senderRuleTarget)
        let sender = try XCTUnwrap(target.from)
        harness.controller.handle(.senderRule(.archive, target.id))
        XCTAssertEqual(try store(harness).senderRules().map(\.action), [.archive])
        XCTAssertEqual(try store(harness).senderRules().map(\.sync), [.creating], "on its way to the server")
        XCTAssertEqual(try store(harness).message(target.id)?.roles.contains(.inbox), false)
        XCTAssertEqual(harness.toastMessage, "Always archiving \(sender.address.lowercased())")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Always Archive Mail from This Sender")

        let next = MessageMetadata(id: MessageID(accountID: target.id.accountID, providerID: "next"),
                                   conversationID: ConversationID(accountID: target.id.accountID, providerID: "next-thread"),
                                   subject: "Next", snippet: "Again", from: sender, date: Date(), roles: [], isRead: false,
                                   isStarred: false, hasAttachments: false)
        try store(harness).upsertMessages([next])
        ListTestSupport.spin(for: 0.1)
        XCTAssertFalse(harness.list.conversations.contains { $0.id == next.conversationID }, "never in the Inbox")
    }

    /// The message's More menu (§5.14) offers both rules only for mail someone else sent, the rule the sender has checked
    /// and disabled and the other one enabled to replace it; each item is its own command.
    func testTheMoreMenuOffersBothRulesAndChecksTheSendersOwn() throws {
        var chosen: [MessageMoreMenu.Command] = []
        let more = MessageMoreMenu { chosen.append($0) }
        func menu(offers: Bool, rule: SenderRule.Action?) -> NSMenu {
            more.menu(MessageMoreMenu.Options(isStarred: false, imagesBlocked: false, offersOriginal: false, showsOriginal: false,
                                              hasSenderAddress: true, offersSenderRules: offers, senderRule: rule))
        }
        let archive = MailActionCopy.senderRuleCommand(.archive), block = MailActionCopy.senderRuleCommand(.trash)
        XCTAssertEqual(archive, "Always Archive Mail from This Sender")
        XCTAssertEqual(block, "Block Sender")
        XCTAssertFalse(menu(offers: false, rule: nil).items.contains { [archive, block].contains($0.title) }, "hidden, not disabled")

        let titles = menu(offers: true, rule: nil).items.map { $0.isSeparatorItem ? "—" : $0.title }
        XCTAssertEqual(Array(titles.suffix(4)), ["—", archive, block, "Copy Sender Address"], "beside the sender's other items")
        for (rule, expected) in [(nil, [archive: (NSControl.StateValue.off, true), block: (.off, true)]),
                                 (SenderRule.Action.archive, [archive: (.on, false), block: (.off, true)]),
                                 (.trash, [archive: (.off, true), block: (.on, false)])] as [(SenderRule.Action?, [String: (NSControl.StateValue, Bool)])] {
            let items = menu(offers: true, rule: rule).items
            for (title, (state, enabled)) in expected {
                let item = try XCTUnwrap(items.first { $0.title == title })
                XCTAssertEqual(item.state, state, "\(title) with \(String(describing: rule))")
                XCTAssertEqual(item.isEnabled, enabled, "\(title) with \(String(describing: rule))")
            }
        }

        for title in [archive, block] {
            let item = try XCTUnwrap(menu(offers: true, rule: nil).items.first { $0.title == title })
            _ = (item.target as AnyObject?)?.perform(try XCTUnwrap(item.action), with: item)
        }
        XCTAssertEqual(chosen, [.alwaysArchiveSender, .blockSender])
    }

    /// The reader's own More menu reads the rule the sender has, and its Block Sender sets the rule for the target
    /// message's sender, replacing the other one, with the toast that names the address.
    func testBlockSenderFromTheReadersMoreMenu() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        open(harness.list.conversations[0].id, in: harness)
        let target = try XCTUnwrap(harness.reader.senderRuleTarget)
        let address = try XCTUnwrap(target.from?.address).lowercased()
        try store(harness).setSenderRule(.archive, for: address, accountID: target.id.accountID, enqueueing: [], at: Date())

        let menu = harness.reader.makeMoreMenu(for: target.id, shellState: [:])
        let archive = try XCTUnwrap(menu.items.first { $0.title == MailActionCopy.senderRuleCommand(.archive) })
        XCTAssertEqual(archive.state, .on, "the rule the sender has")
        XCTAssertFalse(archive.isEnabled)
        let block = try XCTUnwrap(menu.items.first { $0.title == MailActionCopy.senderRuleCommand(.trash) })
        XCTAssertTrue(block.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(block.action), to: block.target, from: block))

        XCTAssertEqual(try store(harness).senderRules().map(\.address), [address])
        XCTAssertEqual(try store(harness).senderRules().map(\.action), [.trash], "Block replaced Always Archive")
        XCTAssertEqual(try store(harness).message(target.id)?.roles.contains(.trash), true)
        XCTAssertEqual(harness.toastMessage, "Blocked \(address)")
        harness.controller.performUndo(harness.controller.zTarget)
        XCTAssertEqual(try store(harness).senderRules().map(\.action), [.archive], "the undo puts back the rule it had")
    }

    /// Rules are set from someone else's mail, one conversation at a time.
    func testTheRuleItemsNeedOneConversationWithMailFromSomeoneElse() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let block = item(#selector(MainWindowController.blockSender(_:)))
        XCTAssertFalse(harness.controller.validateMenuItem(block), "nothing open")

        let own = ConversationID(accountID: a.id, providerID: "own")
        try store(harness).upsertMessages([MessageMetadata(
            id: MessageID(accountID: a.id, providerID: "own-1"), conversationID: own, subject: "Note to self", snippet: "Me",
            from: EmailAddress(name: a.displayName, address: a.email), date: Date(), roles: [.inbox], isRead: true, isStarred: false,
            hasAttachments: false)])
        open(own, in: harness)
        XCTAssertNil(harness.reader.senderRuleTarget, "the account's own address")
        XCTAssertFalse(harness.controller.validateMenuItem(block))
        XCTAssertFalse(harness.controller.selectionContextMenu().items.contains { $0.action == #selector(MainWindowController.blockSender(_:)) })

        harness.selectFirst(3)
        XCTAssertFalse(harness.controller.validateMenuItem(block), "several selected")
    }

    // MARK: Settings

    /// Settings › Accounts › Senders… lists the account's rules, kept current by the store's observation, and its −
    /// removes one.
    func testTheSendersSheetListsTheAccountsRulesAndRemovesOne() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MuteAndSenderRulesTests-\(UUID().uuidString)")
        let environment = try AppEnvironment.makeScratch(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try environment.store.upsertAccount(a)
        try environment.store.upsertAccount(ListTestSupport.accountB)
        let controller = SettingsWindowController(environment: environment, settings: ListTestSupport.settings(), mailtoHandler: FakeMailtoHandler(),
                                                  loginItem: FakeLoginItem())
        defer { controller.tearDown() }
        let model = controller.model
        var removed: [SenderRule] = []
        model.removeSenderRule = { rule in
            removed.append(rule)
            try? environment.engine.setSenderRule(nil, for: rule.address, accountID: rule.accountID, performing: [])
        }

        try environment.engine.setSenderRule(.trash, for: "deals@shop.example", accountID: a.id, performing: [])
        try environment.engine.setSenderRule(.archive, for: "news@letter.example", accountID: a.id, performing: [])
        try environment.engine.setSenderRule(.trash, for: "other@b.example", accountID: ListTestSupport.accountB.id, performing: [])
        XCTAssertTrue(ListTestSupport.spin(until: { model.senderRules.count == 3 }, timeout: 3))
        XCTAssertEqual(model.senderRules(for: a).map(\.address), ["deals@shop.example", "news@letter.example"], "this account's, by address")

        let sheet = SendersSheet(model: model, account: a, onDone: {})
        XCTAssertEqual(sheet.rows, [
            QuireRemovableList.Row(id: "deals@shop.example", title: "deals@shop.example", detail: "Blocked"),
            QuireRemovableList.Row(id: "news@letter.example", title: "news@letter.example", detail: "Always archived"),
        ], "another account's rule is not listed")
        let hosting = NSHostingView(rootView: sheet)
        XCTAssertEqual(hosting.fittingSize.width, Quire.Layout.Settings.sendersWidth)

        sheet.remove(sheet.rows[0])
        XCTAssertEqual(removed.map(\.address), ["deals@shop.example"])
        XCTAssertTrue(ListTestSupport.spin(until: { model.senderRules(for: self.a).map(\.address) == ["news@letter.example"] }, timeout: 3))
        XCTAssertEqual(try environment.store.senderRules().count, 2, "the other account's rule stays")
    }

    /// The account's detail form opens the sheet from “Senders…”, its one entrance.
    func testTheDetailFormOffersSenders() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MuteAndSenderRulesTests-\(UUID().uuidString)")
        let environment = try AppEnvironment.makeScratch(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try environment.store.upsertAccount(a)
        let controller = SettingsWindowController(environment: environment, settings: ListTestSupport.settings(), mailtoHandler: FakeMailtoHandler(),
                                                  loginItem: FakeLoginItem())
        defer { controller.tearDown() }
        let form = NSHostingView(rootView: AccountDetailForm(model: controller.model, account: a))
        // Colour, Monogram, the 82 pt Signature row, Rules and Remove…: one 40 pt row more than before.
        let s = Quire.Layout.Settings.self
        XCTAssertEqual(form.fittingSize.height, 4 * s.detailRow + (s.detailRow + (s.signatureFieldHeight - s.fieldHeight)), accuracy: 2)
    }
}
