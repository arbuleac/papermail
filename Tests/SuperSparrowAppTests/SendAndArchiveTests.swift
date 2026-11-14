import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// Send and Archive (spec §5.23): the default send action, changed from the Send button's drop-down in the composer and
/// the quick reply; ⌘↩ following it and ⇧⌘↩ always archiving; the archive stored and queued as E's when the send is
/// queued; and the send's undo taking it back with the send, a snooze in Later included. Drafts go to a temporary folder,
/// settings to throwaway defaults, and the windows are a throwaway store's.
@MainActor
final class SendAndArchiveTests: XCTestCase {
    private var folder: URL!
    private var suites: [String] = []
    private var savedUndoWindows: (composer: TimeInterval, reader: TimeInterval) = (5, 5)

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowSendAndArchive-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            ComposeDraftStore.shared.useDirectory(folder)
            savedUndoWindows = (ComposeWindowController.undoWindow, ConversationViewController.undoWindow)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            ComposeWindowController.undoWindow = savedUndoWindows.composer
            ConversationViewController.undoWindow = savedUndoWindows.reader
            for panel in ComposeWindowRegistry.shared.livePanels { panel.orderOut(nil); ComposeWindowRegistry.shared.unregister(panel) }
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            suites = []
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Helpers

    private func throwawayDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "SuperSparrowAppTests.SendAndArchive.\(UUID().uuidString)"
        suites.append(suite)
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    /// A window over a throwaway store whose settings choose `action`.
    private func harness(_ action: SendAction = .sendAndArchive) throws -> (harness: MainWindowHarness, settings: AppSettings, suite: String) {
        let (defaults, suite) = try throwawayDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.sendAction = action
        let harness = try MainWindowHarness(settings: settings)
        return (harness, settings, suite)
    }

    /// Opens `providerID`'s conversation, as a click on its row does.
    @discardableResult
    private func open(_ providerID: String, _ harness: MainWindowHarness) throws -> ConversationID {
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == providerID }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { !harness.reader.currentMessages.isEmpty && harness.reader.currentConversationID == id }
        return id
    }

    private func inInbox(_ id: ConversationID, _ harness: MainWindowHarness) throws -> Bool {
        try harness.environment.store.messages(in: id).contains(where: \.isInInbox)
    }

    private func operations(_ harness: MainWindowHarness) throws -> [SSCore.Operation] {
        let store = harness.environment.store
        return try [ListTestSupport.accountA, ListTestSupport.accountB].flatMap { try store.pendingOperations(accountID: $0.id, limit: 50) }
    }

    /// ⌘↩, or ⇧⌘↩ with `shift`, as the keyboard delivers it to `window`: key equivalents first, then the first responder.
    private func pressSend(shift: Bool, in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : .command,
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                   charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        if !window.performKeyEquivalent(with: event) { window.firstResponder?.keyDown(with: event) }
    }

    /// Types `text` into the quick reply of the open conversation, focused as R focuses it.
    private func typeQuickReply(_ text: String, _ harness: MainWindowHarness) {
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        harness.reader.quickReplyBar.text = text
    }

    /// A reply composer to `original`, its original folded in and its recipient filled, with `text` typed.
    private func replyComposer(to original: String, typing text: String, _ harness: MainWindowHarness) throws -> ComposeWindowController {
        let id = MessageID(accountID: ListTestSupport.accountA.id, providerID: original)
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: "<p>The plan is attached.</p>", text: "The plan is attached."),
                                                          renderedHTML: "<p>The plan is attached.</p>", plainText: "The plan is attached."),
                                               for: id)
        let accounts = harness.controller.accounts
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: .reply(id, all: false))
        XCTAssertTrue(ListTestSupport.spin(until: { composer.contents.quoted != nil && !composer.contents.to.isEmpty }, timeout: 5),
                      "the original folds in")
        let editor = composer.bodyEditor
        composer.window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText(text, replacementRange: editor.selectedRange())
        return composer
    }

    /// The undo-send panel a composer's send leaves, once its attachments are read and the send is queued.
    private func panel(_ harness: MainWindowHarness) throws -> UndoSendPanel {
        harness.spin { !ComposeWindowRegistry.shared.livePanels.isEmpty }
        return try XCTUnwrap(ComposeWindowRegistry.shared.livePanels.first, "the send was queued")
    }

    private func choose(_ index: Int, in menu: NSMenu) throws {
        let item = menu.items[index]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    // MARK: The default

    func testSendAndArchiveIsTheDefaultAndTheChoiceIsKept() throws {
        let (defaults, suite) = try throwawayDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.sendAction, .sendAndArchive, "a fresh domain sends and archives")
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["sendAction"], "nothing is written until the user chooses")
        settings.sendAction = .send
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["sendAction"] as? String, "send")
        XCTAssertEqual(AppSettings(defaults: defaults).sendAction, .send, "kept across launches")
        defaults.set("archiveOnly", forKey: "sendAction")
        XCTAssertEqual(AppSettings(defaults: defaults).sendAction, .sendAndArchive, "an unknown value is the default")
    }

    /// The drop-down lists both actions with the default checked; choosing one makes it the default for every Send button at
    /// once (each open composer's and the quick reply's tooltip and VoiceOver name follow), keeps it, and sends nothing.
    func testTheDropDownChangesTheDefaultEverywhereAndNeverSends() throws {
        let (harness, settings, suite) = try harness()
        defer { harness.close() }
        let thread = try open("thread-2", harness)
        let bar = harness.reader.quickReplyBar
        let composer = try replyComposer(to: "msg-2-2", typing: "Thanks", harness)
        let other = try replyComposer(to: "msg-0-0", typing: "Noted", harness)
        for open in [composer, other] {
            XCTAssertEqual(open.sendButtonHelp.toolTip, "Send and Archive  ⌘↩", "the tooltip says what Send does")
            XCTAssertEqual(open.sendButtonHelp.label, "Send and Archive", "and VoiceOver hears it; the label stays “Send”")
        }
        XCTAssertEqual(bar.sendAction, .sendAndArchive)
        XCTAssertEqual(bar.sendButtonHelp.toolTip, "Send and Archive  ⌘↩")
        XCTAssertEqual(bar.sendButtonHelp.label, "Send and Archive")

        // The two choices lead the menu; Send Later's times follow them (SendLaterTests).
        let menu = composer.sendOptionsMenu()
        XCTAssertEqual(menu.items.prefix(2).map(\.title), ["Send and Archive", "Send"])
        XCTAssertEqual(menu.items.prefix(2).map(\.state), [.on, .off], "the default is checked")
        XCTAssertTrue(menu.items.allSatisfy { $0.keyEquivalent.isEmpty }, "choices, not commands: no key equivalents")
        try choose(1, in: menu)

        XCTAssertEqual(settings.sendAction, .send)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["sendAction"] as? String, "send", "kept")
        XCTAssertTrue(try harness.environment.store.pendingSends().isEmpty, "choosing never sends")
        XCTAssertTrue(ComposeWindowRegistry.shared.livePanels.isEmpty)
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.count, 2, "both composers stay open")
        for open in [composer, other] {
            XCTAssertEqual(open.sendButtonHelp.toolTip, "Send  ⌘↩", "every open composer follows at once")
            XCTAssertEqual(open.sendButtonHelp.label, "Send")
        }
        XCTAssertEqual(bar.sendAction, .send, "and the quick reply")
        XCTAssertEqual(bar.sendButtonHelp.toolTip, "Send  ⌘↩")
        XCTAssertEqual(other.sendOptionsMenu().items.prefix(2).map(\.state), [.off, .on])

        // The quick reply's drop-down: the same choice, back to Send and Archive.
        let barMenu = bar.sendOptionsMenu()
        XCTAssertEqual(barMenu.items.prefix(2).map(\.title), ["Send and Archive", "Send"])
        XCTAssertEqual(barMenu.items.prefix(2).map(\.state), [.off, .on])
        try choose(0, in: barMenu)
        XCTAssertEqual(settings.sendAction, .sendAndArchive)
        XCTAssertEqual(AppSettings(defaults: defaults).sendAction, .sendAndArchive)
        XCTAssertEqual(composer.sendButtonHelp.toolTip, "Send and Archive  ⌘↩")
        XCTAssertTrue(try harness.environment.store.pendingSends().isEmpty, "still nothing sent")
        XCTAssertTrue(try inInbox(thread, harness), "and nothing archived")
        XCTAssertTrue(try operations(harness).isEmpty)
    }

    // MARK: The quick reply

    /// ⌘↩ with the default: the reply is queued and its conversation archived as E would, in the store with the ordinary
    /// archive queued; the selection moves on as after E while the strip counts down, saying so. Undo (⌘Z) cancels the
    /// send and brings the conversation back to the Inbox, selected, with the reply back in its box.
    func testCommandReturnInTheQuickReplySendsAndArchivesAndUndoBringsItBack() throws {
        let (harness, _, _) = try harness()
        defer { harness.close() }
        let thread = try open("thread-2", harness)
        let store = harness.environment.store
        typeQuickReply("Thanks, sounds good", harness)
        try pressSend(shift: false, in: try XCTUnwrap(harness.controller.window))

        let sends = try store.pendingSends()
        XCTAssertEqual(sends.count, 1, "the reply is queued")
        XCTAssertTrue(sends[0].message.text.hasPrefix("Thanks, sounds good"))
        XCTAssertFalse(try inInbox(thread, harness), "archived as the send is queued")
        let queued = try operations(harness)
        XCTAssertEqual(queued.map(\.change), [.archive], "E's archive, queued")
        XCTAssertEqual(Set(queued.first?.targets.map(\.providerID) ?? []), ["msg-2-0", "msg-2-1", "msg-2-2"])
        let bar = harness.reader.quickReplyBar
        XCTAssertEqual(bar.stripLead, "Archived \u{00b7} sending in 5 s", "the strip says it went")
        XCTAssertFalse(harness.toasts.isVisible, "no toast: the strip's one Undo takes back both")
        let target = harness.controller.commandZTarget(textCanUndo: false)
        XCTAssertEqual(target, harness.reader.liveQuickSend.map { .send($0.id) })
        XCTAssertEqual(harness.controller.undoMenuTitle(for: target), "Undo Send and Archive")
        XCTAssertEqual(harness.controller.zTarget, .nothing, "nothing in the undo history: Z never takes half")
        harness.spin { !harness.list.conversations.contains { $0.id == thread } }
        XCTAssertFalse(harness.list.conversations.contains { $0.id == thread }, "the row leaves the Inbox")
        XCTAssertNotEqual(harness.list.selectedConversationID, thread, "the selection moves on, as after E")
        XCTAssertNotNil(harness.reader.liveQuickSend, "the countdown stays in the bar")

        harness.controller.performUndo(target)
        XCTAssertTrue(try store.pendingSends().isEmpty, "the send is cancelled")
        XCTAssertTrue(try inInbox(thread, harness), "and the conversation is back in the Inbox")
        XCTAssertEqual(try operations(harness).map(\.change), [.archive, .moveToInbox], "as Z after E: the inverse, queued")
        XCTAssertEqual(harness.reader.currentConversationID, thread, "open again")
        XCTAssertEqual(bar.text, "Thanks, sounds good", "with the reply back in its box")
        harness.spin { harness.list.conversations.contains { $0.id == thread } }
        XCTAssertEqual(harness.list.selectedConversationID, thread, "and selected, as an undo of an archive is")
        XCTAssertNil(harness.reader.liveQuickSend)
    }

    /// With Send chosen, ⌘↩ only sends; ⇧⌘↩ sends and archives all the same.
    func testCommandReturnFollowsSendAndShiftCommandReturnAlwaysArchives() throws {
        let (harness, _, _) = try harness(.send)
        defer { harness.close() }
        let store = harness.environment.store
        let window = try XCTUnwrap(harness.controller.window)
        let first = try open("thread-2", harness)
        XCTAssertEqual(harness.reader.quickReplyBar.sendButtonHelp.toolTip, "Send  ⌘↩")
        typeQuickReply("On my way", harness)
        try pressSend(shift: false, in: window)
        XCTAssertEqual(try store.pendingSends().count, 1)
        XCTAssertTrue(try inInbox(first, harness), "Send only sends")
        XCTAssertTrue(try operations(harness).isEmpty)
        XCTAssertEqual(harness.reader.quickReplyBar.stripLead, "Sending in 5 s")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.commandZTarget(textCanUndo: false)), "Undo Send")
        harness.controller.performUndo(harness.controller.commandZTarget(textCanUndo: false))
        XCTAssertTrue(try store.pendingSends().isEmpty)

        let second = try open("thread-4", harness)
        typeQuickReply("Done, thanks", harness)
        try pressSend(shift: true, in: window)
        XCTAssertEqual(try store.pendingSends().count, 1)
        XCTAssertFalse(try inInbox(second, harness), "⇧⌘↩ archives whatever Send does")
        XCTAssertEqual(try operations(harness).map(\.change), [.archive])
        XCTAssertTrue(try inInbox(first, harness))
        XCTAssertEqual(harness.reader.quickReplyBar.stripLead, "Archived \u{00b7} sending in 5 s")
    }

    // MARK: The composer

    /// ⌘↩ in a reply composer with the default: queued, then its conversation archived and the archive queued; the panel
    /// says so first on its second line, and its Undo brings the conversation back to the Inbox as it reopens the reply.
    func testCommandReturnInTheComposerSendsAndArchivesAndItsUndoBringsItBack() throws {
        let (harness, _, _) = try harness()
        defer { harness.close() }
        let thread = try open("thread-2", harness)
        let composer = try replyComposer(to: "msg-2-2", typing: "Thanks, looks good", harness)
        XCTAssertEqual(composer.sendAction, .sendAndArchive)
        try pressSend(shift: false, in: try XCTUnwrap(composer.window))
        let panel = try panel(harness)

        XCTAssertEqual(try harness.environment.store.pendingSends().count, 1)
        XCTAssertFalse(try inInbox(thread, harness), "archived as the send is queued")
        XCTAssertEqual(try operations(harness).map(\.change), [.archive])
        XCTAssertTrue(panel.summary.hasPrefix("Archived \u{00b7} Re: Project update 2"), panel.summary)
        XCTAssertEqual(panel.undoMenuTitle, "Undo Send and Archive")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.commandZTarget(textCanUndo: false)), "Undo Send and Archive")
        XCTAssertFalse(harness.toasts.isVisible)
        harness.spin { !harness.list.conversations.contains { $0.id == thread } }

        panel.undo()
        XCTAssertTrue(try harness.environment.store.pendingSends().isEmpty, "the send is cancelled")
        XCTAssertTrue(try inInbox(thread, harness), "the conversation is back in the Inbox")
        let reopened = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first, "the reply reopens")
        XCTAssertTrue(reopened.bodyText.hasPrefix("Thanks, looks good"))
        harness.spin { harness.list.conversations.contains { $0.id == thread } }
        XCTAssertEqual(harness.list.selectedConversationID, thread, "selected again: the archive had taken it off the screen")
    }

    /// With Send chosen, ⌘↩ in the composer only sends; ⇧⌘↩ there archives all the same.
    func testTheComposerFollowsSendAndItsShiftCommandReturnAlwaysArchives() throws {
        let (harness, _, _) = try harness(.send)
        defer { harness.close() }
        let first = harness.list.conversations.first { $0.id.providerID == "thread-2" }!.id
        let second = harness.list.conversations.first { $0.id.providerID == "thread-0" }!.id
        let sending = try replyComposer(to: "msg-2-2", typing: "Thanks", harness)
        XCTAssertEqual(sending.sendButtonHelp.toolTip, "Send  ⌘↩")
        try pressSend(shift: false, in: try XCTUnwrap(sending.window))
        let sent = try panel(harness)
        XCTAssertFalse(sent.summary.hasPrefix("Archived"), sent.summary)
        XCTAssertTrue(try inInbox(first, harness), "Send only sends")
        XCTAssertTrue(try operations(harness).isEmpty)

        let archiving = try replyComposer(to: "msg-0-0", typing: "Noted", harness)
        try pressSend(shift: true, in: try XCTUnwrap(archiving.window))
        harness.spin { ComposeWindowRegistry.shared.livePanels.count == 2 }
        XCTAssertEqual(try harness.environment.store.pendingSends().count, 2)
        XCTAssertFalse(try inInbox(second, harness), "⇧⌘↩ archives whatever Send does")
        XCTAssertEqual(try operations(harness).map(\.change), [.archive])
        XCTAssertTrue(ComposeWindowRegistry.shared.livePanels.contains { $0.summary.hasPrefix("Archived \u{00b7} ") })
    }

    /// A new message answers no conversation: Send says it only sends, and ⌘↩ or ⇧⌘↩ archives nothing.
    func testANewMessageOnlySends() throws {
        let (harness, _, _) = try harness()
        defer { harness.close() }
        let inbox = harness.list.conversations.map(\.id)
        let draft = ComposeDraft(id: UUID(), mode: .new, account: ListTestSupport.accountA, to: [EmailAddress(name: "Ben Carter", address: "ben@contoso.test")],
                                 cc: [], bcc: [], subject: "Lisbon", body: ComposeTextView.plainBody("See you there"), attachments: [],
                                 quoted: nil, threading: nil)
        let composer = ComposeWindowController.present(client: harness.environment.engine, accounts: harness.controller.accounts, draft: draft)
        XCTAssertEqual(composer.sendAction, .send)
        XCTAssertEqual(composer.sendButtonHelp.toolTip, "Send  ⌘↩", "nothing to archive, so it says Send")
        XCTAssertEqual(composer.sendOptionsMenu().items.prefix(2).map(\.state), [.on, .off], "the default it would use elsewhere stays checked")
        try pressSend(shift: true, in: try XCTUnwrap(composer.window))
        let panel = try panel(harness)
        XCTAssertEqual(panel.summary, "Lisbon \u{00b7} to Ben Carter", "no archive to mention")
        XCTAssertEqual(panel.undoMenuTitle, "Undo Send")
        XCTAssertEqual(try harness.environment.store.pendingSends().count, 1)
        XCTAssertTrue(try operations(harness).isEmpty, "nothing archived")
        for id in inbox { XCTAssertTrue(try inInbox(id, harness)) }
    }

    // MARK: Later

    /// In Later a conversation is archived already: Send and Archive ends its snooze and leaves it archived, as E does there,
    /// and Undo puts the snooze back at its time.
    func testSendAndArchiveInLaterEndsTheSnoozeAndUndoPutsItBack() throws {
        let (harness, _, _) = try harness()
        defer { harness.close() }
        let store = harness.environment.store
        let due = Date().addingTimeInterval(86_400)
        let ids = try ["thread-2", "thread-4"].map { providerID in try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == providerID }?.id) }
        for id in ids {
            let targets = try store.messages(in: id).filter(\.isInInbox).map(\.id)
            try store.setSnoozes([Snooze.Change(conversationID: id, until: due)],
                                 enqueueing: [SSCore.Operation(accountID: id.accountID, change: .archive, targets: targets)], at: Date())
        }
        harness.spin { harness.controller.snoozes.count == 2 }
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.conversations.count == 2 }
        let thread = try open("thread-2", harness)
        let before = try operations(harness)
        typeQuickReply("Booked", harness)
        try pressSend(shift: false, in: try XCTUnwrap(harness.controller.window))

        XCTAssertEqual(try store.pendingSends().count, 1)
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [ids[1]], "its snooze ends")
        XCTAssertFalse(try inInbox(thread, harness), "and it stays archived")
        XCTAssertEqual(try operations(harness).map(\.id), before.map(\.id), "nothing more to queue: it was archived already")
        XCTAssertEqual(harness.reader.quickReplyBar.stripLead, "Archived \u{00b7} sending in 5 s")
        harness.spin { harness.list.conversations.map(\.id) == [ids[1]] }

        let target = harness.controller.commandZTarget(textCanUndo: false)
        XCTAssertEqual(harness.controller.undoMenuTitle(for: target), "Undo Send and Archive")
        harness.controller.performUndo(target)
        XCTAssertTrue(try store.pendingSends().isEmpty)
        let restored = try XCTUnwrap(try store.snoozes().first { $0.conversationID == thread }, "snoozed again")
        XCTAssertEqual(restored.dueAt.timeIntervalSince1970, due.timeIntervalSince1970, accuracy: 1, "at its time")
        XCTAssertFalse(try inInbox(thread, harness))
        harness.spin { harness.list.conversations.count == 2 }
        XCTAssertEqual(harness.list.query.view, .later)
        XCTAssertEqual(harness.list.selectedConversationID, thread)
        XCTAssertEqual(harness.reader.quickReplyBar.text, "Booked")
    }

    // MARK: Words and keys

    /// The archive is said first where it never truncates: the strip's lead at the narrowest reader, and the panel's
    /// second line, which is cut at its tail.
    func testTheArchiveFitsTheStripAndThePanel() throws {
        let column = ReaderColumn.frame(readerWidth: Quire.Layout.Window.readerMinWidth)
        let strip = QuickReplyStripView(frame: NSRect(x: 0, y: 0, width: column.width - 2, height: Quire.Layout.QuickReply.field - 2))
        strip.showsKeycaps = false
        strip.apply(.counting(endsAt: Date().addingTimeInterval(20), duration: 20, recipient: "Tomás Ortega and 2 others", archived: true))
        strip.layoutSubtreeIfNeeded()
        strip.layout()
        XCTAssertEqual(strip.leadText, "Archived \u{00b7} sending in 20 s")
        XCTAssertTrue(strip.showsLeadWhole, "whole in a \(column.width) pt column")

        let draft = ComposeDraft(id: UUID(), mode: .new, account: ListTestSupport.accountA, to: [EmailAddress(name: "Ben Carter", address: "ben@contoso.test")],
                                 cc: [], bcc: [], subject: "Re: Contoso rollout", body: NSAttributedString(), attachments: [], quoted: nil, threading: nil)
        let summary = UndoSendPanel.summary(for: draft, archived: true)
        XCTAssertEqual(summary, "Archived \u{00b7} Re: Contoso rollout \u{00b7} to Ben Carter")
        let slip = QuireUndoPanelView(state: .counting(secondsLeft: 20), summary: summary)
        slip.layoutSubtreeIfNeeded()
        slip.layout()
        let action = try XCTUnwrap(slip.actionButton)
        let u = Quire.Layout.UndoPanel.self
        let line = action.alignmentRect(forFrame: action.frame).minX - u.actionGap - (u.padLeft + u.glyph + u.glyphGap)
        let lead = QuireFont.attributedString("Archived \u{00b7} Re:", role: .meta, color: .qOnSlip2).size().width
        XCTAssertLessThan(lead, line, "“Archived” always shows")
    }

    /// Message › Send and Archive carries ⇧⌘↩ next to Send's ⌘↩ while a composer is key, and validates as Send does.
    func testTheMessageMenuOffersSendAndArchive() throws {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let message = try XCTUnwrap(bar.items.first { $0.submenu?.title == "Message" }?.submenu)
        let send = try XCTUnwrap(message.items.firstIndex { $0.action == #selector(ComposeWindowController.send(_:)) })
        let both = message.items[send + 1]
        XCTAssertEqual(both.title, "Send and Archive", "next to Send")
        XCTAssertEqual(both.action, #selector(ComposeWindowController.sendAndArchive(_:)))
        XCTAssertEqual([message.items[send].keyEquivalent, both.keyEquivalent], ["\r", "\r"])
        XCTAssertEqual(message.items[send].keyEquivalentModifierMask, .command)
        XCTAssertEqual(both.keyEquivalentModifierMask, [.command, .shift])
        // Shown while a composer is key, so ⇧⌘↩ is found there.
        for item in message.items where item.isHidden && item.action == both.action { item.isHidden = false }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                   isARepeat: false, keyCode: 36))
        XCTAssertEqual(MainMenuBar.exactItem(for: event, in: bar), both)
        // The cheat sheet lists it beside ⌘↩, in Write (§5.32).
        let write = try XCTUnwrap(Quire.cheatSheet.first { $0.title == "Write" }?.rows)
        let sendRow = try XCTUnwrap(write.firstIndex { $0.keys == "⌘↩" })
        XCTAssertEqual(write[sendRow + 1].keys, "⇧⌘↩")
        XCTAssertEqual(write[sendRow + 1].label, "Send and archive")

        let (harness, _, _) = try harness()
        defer { harness.close() }
        let composer = try replyComposer(to: "msg-2-2", typing: "Thanks", harness)
        let item = NSMenuItem(title: "", action: #selector(ComposeWindowController.sendAndArchive(_:)), keyEquivalent: "")
        XCTAssertTrue(composer.validateMenuItem(item))
    }
}
