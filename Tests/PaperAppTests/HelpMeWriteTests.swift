import AppKit
import PaperCore
@testable import PaperDesign
import XCTest
@testable import PaperApp

/// Help me write in the app, in place (spec §5.56): ⌘J writes into the quick reply or a reply composer's body from the
/// user's notes (or the thread alone, or a selection), in pencil while it streams, then in ink as one undo step; Try again
/// writes again from the same notes; ⇧⌘J's prompt line says how, with its chips; Esc puts the notes back; failures stay in
/// the text, under the caret's line; no permission sheet anywhere in the write path. The marks themselves (the ghost, the
/// pill, the blocks' room) are `HelpMeWriteCaretTests`'. Every write goes to the demo writer: nothing here reaches the
/// network, a CLI or the Keychain.
@MainActor
final class HelpMeWriteTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperHelpMeWrite-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder) }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
            QuireAccessibility.observer = nil
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Support

    /// A main window on thread-2 (three messages), `provider` chosen in Settings › AI and turned on (`turnedOn`), the demo
    /// writer quick and scripted. Any sheet the write path tried to show would be recorded in `sheets`.
    private func harness(provider: AIProviderKind? = .claudeAPI, turnedOn: Bool = true,
                         reply: String = "Tuesday at ten works. See you then.") throws -> (MainWindowHarness, DemoAIScript) {
        let harness = try MainWindowHarness()
        harness.settings.aiProvider = provider
        if let provider, turnedOn { harness.settings.setAIConsent(true, for: provider, demo: false) }
        harness.environment.helpMeWrite.presentAlert = { [weak self] alert, _, done in
            self?.sheets.append(alert)
            done(0)
        }
        let script = try XCTUnwrap(harness.environment.helpMeWrite.demoScript)
        script.delay = .milliseconds(1)
        script.reply = reply
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentMessages.count == 3 }
        return (harness, script)
    }

    /// Sheets something tried to show while writing: there must be none (§5.56).
    private var sheets: [AppAlert] = []

    /// The quick reply focused with `text` typed, as R and typing leave it, its marks drawn as in the key window (the
    /// test window never is).
    @discardableResult
    private func type(_ text: String, _ harness: MainWindowHarness) -> NSTextView {
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        harness.reader.quickReplyWriteSession?.assumesKeyWindow = true
        let field = harness.reader.quickReplyBar.writingTextView
        field.insertText(text, replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        return field
    }

    private func session(_ harness: MainWindowHarness) throws -> WriteSession {
        try XCTUnwrap(harness.reader.quickReplyWriteSession)
    }

    private func layer(_ harness: MainWindowHarness) -> WriteInlineLayer {
        harness.reader.quickReplyBar.writeLayer
    }

    /// Presses one of the afterline's actions as a click does.
    private func press(_ action: WriteAfterline.Action, in layer: WriteInlineLayer) {
        layer.afterline.layoutSubtreeIfNeeded()
        layer.afterline.actions[action]?.performClick(nil)
    }

    /// Whether anything titled Write (1.12's control) shows in `view`'s tree.
    private func showsAWriteButton(in view: NSView) -> Bool {
        if !view.isHiddenOrHasHiddenAncestor, let button = view as? QuireButton, button.title == "Write" { return true }
        if !view.isHiddenOrHasHiddenAncestor, view.accessibilityLabel() == "Write with Help Me Write" { return true }
        return view.subviews.contains { showsAWriteButton(in: $0) }
    }

    private func item(_ action: Selector, _ key: String = "j") -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: key)
    }

    private var writeItem: NSMenuItem { item(#selector(ConversationViewController.helpMeWrite(_:))) }
    private var instructionsItem: NSMenuItem { item(#selector(ConversationViewController.helpMeWriteWithInstructions(_:))) }

    /// ⌘J, as the menu sends it once it validates.
    private func commandJ(_ harness: MainWindowHarness) {
        XCTAssertTrue(harness.reader.validateMenuItem(writeItem), "⌘J applies")
        harness.reader.helpMeWrite(nil)
    }

    private func until(_ condition: () -> Bool, _ message: String = "") {
        XCTAssertTrue(ListTestSupport.spin(until: condition, timeout: 5), message)
    }

    private func replyComposer(_ harness: MainWindowHarness) -> ComposeWindowController {
        let accounts = harness.controller.accounts
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2")
        return ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                               mode: .reply(original, all: false))
    }

    private func color(of field: NSTextView, at index: Int) -> NSColor? {
        field.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    // MARK: Keys and menus

    func testTheEditMenuHasBothItemsAndTheCheatSheetsRow() {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["Paper"])))
        let edit = bar.items.first { $0.title == "Edit" }?.submenu
        let write = edit?.items.first { $0.action == #selector(ConversationViewController.helpMeWrite(_:)) }
        XCTAssertEqual(write?.title, "Help Me Write")
        XCTAssertEqual(write?.keyEquivalent, "j")
        XCTAssertEqual(write?.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]), [.command])
        XCTAssertNil(write?.target, "the focused reader or composer answers it")
        let instructions = edit?.items.first { $0.action == #selector(ConversationViewController.helpMeWriteWithInstructions(_:)) }
        XCTAssertEqual(instructions?.title, "Help Me Write with Instructions\u{2026}")
        XCTAssertEqual(instructions?.keyEquivalent, "j")
        XCTAssertEqual(instructions?.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]), [.command, .shift])
        // ⇧⌘J is free: no other item of the menu bar claims it.
        let all = bar.items.compactMap(\.submenu).flatMap { Self.items(in: $0) }
        XCTAssertEqual(all.filter { $0.keyEquivalent.lowercased() == "j" && $0.keyEquivalentModifierMask.contains(.shift) }.count, 1)
        XCTAssertTrue(Quire.cheatSheet.first { $0.title == "Write" }?.rows
            .contains { $0.keys == "⌘J ⇧⌘J" && $0.label == "Write at caret · say how" } ?? false)
    }

    private static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items + menu.items.compactMap(\.submenu).flatMap { items(in: $0) }
    }

    func testTheMenuTitlesSayWhatCommandJDoesThere() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        harness.controller.window?.makeFirstResponder(harness.list.tableView)
        let write = writeItem
        XCTAssertFalse(harness.reader.validateMenuItem(write), "the list has no text to write in")
        XCTAssertEqual(write.title, "Help Me Write")
        let field = type("", harness)
        XCTAssertTrue(harness.reader.validateMenuItem(write))
        XCTAssertEqual(write.title, "Write Reply")
        type("tue 10 ok", harness)
        XCTAssertTrue(harness.reader.validateMenuItem(write))
        XCTAssertEqual(write.title, "Write Reply from Notes")
        let instructions = instructionsItem
        XCTAssertTrue(harness.reader.validateMenuItem(instructions))
        XCTAssertEqual(instructions.title, "Write Reply with Instructions\u{2026}")
        field.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertTrue(harness.reader.validateMenuItem(write))
        XCTAssertEqual(write.title, "Rewrite Selection")
        XCTAssertTrue(harness.reader.validateMenuItem(instructions))
        XCTAssertEqual(instructions.title, "Rewrite Selection with Instructions\u{2026}")
        field.setSelectedRange(NSRange(location: 9, length: 0))
        commandJ(harness)
        until({ try! self.session(harness).phase == .written }, "the reply lands")
        XCTAssertTrue(harness.reader.validateMenuItem(write))
        XCTAssertEqual(write.title, "Try Again")
    }

    func testCommandJAppliesToReplyComposersOnly() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let accounts = harness.controller.accounts
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2")
        let reply = replyComposer(harness)
        reply.window?.makeFirstResponder(reply.bodyEditor)
        let item = writeItem
        XCTAssertTrue(reply.validateMenuItem(item))
        XCTAssertNil(item.toolTip)
        reply.content.layoutSubtreeIfNeeded()
        XCTAssertFalse(showsAWriteButton(in: reply.content.bottomBar), "no Write in a reply's bar: it is in the text")
        for mode in [ComposeMode.new, .forward(original)] {
            let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                           mode: mode)
            composer.window?.makeFirstResponder(composer.bodyEditor)
            XCTAssertFalse(composer.validateMenuItem(item), "\(mode) answers no one")
            XCTAssertEqual(item.toolTip, "Help Me Write works on replies")
            XCTAssertFalse(showsAWriteButton(in: composer.content.bottomBar), "and shows no Write control")
        }
    }

    // MARK: Off, not turned on, needs setup

    func testOffShowsNothingAndCommandJSaysSo() throws {
        let (harness, script) = try harness(provider: nil)
        defer { harness.close() }
        var opened = 0
        harness.environment.helpMeWrite.openSettings = { opened += 1 }
        let field = type("Tuesday works", harness)
        try session(harness).showNotesGhostNow()
        let layer = layer(harness)
        XCTAssertNil(layer.state.ghost, "with AI off nothing shows in the text")
        XCTAssertTrue(try session(harness).contextMenuItems().isEmpty, "and the text's menu has no group")
        commandJ(harness)
        XCTAssertEqual(try session(harness).phase, .failed(reason: "Help Me Write is off", offersSettings: true))
        XCTAssertFalse(layer.afterline.isHidden, "⌘J says why under the caret's line")
        XCTAssertEqual(layer.afterline.lineWords, "Help Me Write is off \u{00b7} Try again \u{2318}J \u{00b7} Settings\u{2026}")
        press(.settings, in: layer)
        XCTAssertEqual(opened, 1, "Settings… opens Settings › AI")
        XCTAssertEqual(field.string, "Tuesday works")
        XCTAssertTrue(script.requests.isEmpty)
        XCTAssertTrue(sheets.isEmpty)
    }

    /// A provider chosen before 1.12 and never confirmed: the control is dimmed with the reason, ⌘J says it inline with
    /// Settings…, and nothing is sent. No sheet is shown here, ever: permission is Settings' to ask (§5.40).
    func testNoPermissionSheetAnywhereInTheWritePath() throws {
        let (harness, script) = try harness(turnedOn: false)
        defer { harness.close() }
        let field = type("tue 10 ok", harness)
        let writeSession = try session(harness)
        XCTAssertEqual(writeSession.availability, .unavailable(reason: "Turn it on in Settings \u{203a} AI"))
        writeSession.showNotesGhostNow()
        XCTAssertNil(writeSession.layer.state.ghost, "no ghost while it cannot write")
        XCTAssertFalse(writeSession.contextMenuItems().isEmpty, "the text's menu offers it, to say why")
        commandJ(harness)
        XCTAssertEqual(try session(harness).phase, .failed(reason: "Turn it on in Settings \u{203a} AI", offersSettings: true))
        ListTestSupport.spin(for: 0.2)
        XCTAssertTrue(script.requests.isEmpty, "nothing is sent")
        XCTAssertTrue(sheets.isEmpty, "and no sheet asks")
        XCTAssertNil(harness.controller.window?.attachedSheet)
        XCTAssertEqual(field.string, "tue 10 ok")

        // Turned on (in Settings), the same ⌘J writes, with no sheet either.
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        until({ writeSession.availability == .ready(writer: "Claude", source: "Claude Opus 5.5 \u{00b7} Anthropic") },
              "Settings' change reaches the reply")
        type("tue 10 ok", harness)
        commandJ(harness)
        until({ try! self.session(harness).phase == .written })
        XCTAssertTrue(sheets.isEmpty)
        XCTAssertEqual(script.requests.count, 1)
    }

    func testANeedsSetupProviderSaysItsReasonOnCommandJ() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        script.health = .needsSetup(reason: "Add your API key")
        type("tue 10 ok", harness)
        XCTAssertEqual(try session(harness).availability, .unavailable(reason: "Add your API key"))
        commandJ(harness)
        XCTAssertEqual(try session(harness).phase, .failed(reason: "Add your API key", offersSettings: true))
        XCTAssertTrue(script.requests.isEmpty)
    }

    // MARK: Undo, redo and the selection

    /// ⌘Z after a draft brings the notes back with the caret where it was before ⌘J, never the notes selected, which ⌘J
    /// would then rewrite as a selection; ⌘⇧Z brings the draft back with the caret after it, still a Try again. The line's
    /// Undo, and Esc during Try again, do the same.
    func testUndoAndRedoPutTheCaretBackAndKeepTryAgain() throws {
        let (harness, script) = try harness(reply: "First draft of the reply.")
        defer { harness.close() }
        let field = type("tue 10 ok", harness)
        XCTAssertEqual(field.selectedRange(), NSRange(location: 9, length: 0))
        commandJ(harness)
        let session = try session(harness)
        until({ session.phase == .written })
        let undo = try XCTUnwrap(field.undoManager)

        undo.undo()
        XCTAssertEqual(field.string, "tue 10 ok")
        XCTAssertEqual(field.selectedRange(), NSRange(location: 9, length: 0), "the caret, not the notes selected")
        XCTAssertEqual(session.plan, .fromNotes)
        let write = writeItem
        XCTAssertTrue(harness.reader.validateMenuItem(write))
        XCTAssertEqual(write.title, "Write Reply from Notes")

        undo.redo()
        XCTAssertEqual(field.string, "First draft of the reply.")
        XCTAssertEqual(field.selectedRange(), NSRange(location: 25, length: 0), "the caret after the draft")
        XCTAssertEqual(session.plan, .tryAgain, "a redone draft is tried again from its notes")
        XCTAssertTrue(harness.reader.validateMenuItem(write))
        XCTAssertEqual(write.title, "Try Again")
        script.reply = "Second draft."
        commandJ(harness)
        until({ script.requests.count == 2 && session.phase == .written })
        XCTAssertTrue(script.requests[1].task.contains("tue 10 ok"), "from the notes")
        XCTAssertFalse(script.requests[1].task.contains("First draft"), "never from the draft")
        XCTAssertFalse(script.requests[1].task.contains("SELECTION"), "and never as a selection")

        // The afterline's Undo.
        XCTAssertFalse(layer(harness).afterline.isHidden)
        press(.undo, in: layer(harness))
        XCTAssertEqual(field.string, "tue 10 ok")
        XCTAssertEqual(field.selectedRange(), NSRange(location: 9, length: 0))
        XCTAssertEqual(session.plan, .fromNotes)

        // Try again, stopped: the notes and the caret, as before the first ⌘J.
        undo.redo()
        XCTAssertEqual(field.string, "Second draft.")
        script.reply = "Third draft, a longer one with more words in it."
        script.holdsAfter = 1
        commandJ(harness)
        XCTAssertEqual(session.phase, .writing)
        until({ field.string.hasPrefix("Third") }, "the new draft starts")
        field.cancelOperation(nil)
        XCTAssertEqual(field.string, "tue 10 ok")
        XCTAssertEqual(field.selectedRange(), NSRange(location: 9, length: 0), "Esc puts the caret back, not a selection")
        XCTAssertEqual(session.plan, .fromNotes)
    }

    /// A selection of spaces or line breaks alone is no selection: ⌘J writes from the notes, as its menu title says.
    func testABlankSelectionIsNoSelection() throws {
        let (harness, script) = try harness(reply: "A whole reply.")
        defer { harness.close() }
        let field = type("Hi Ben,\n\nsee you Tuesday", harness)
        field.setSelectedRange(NSRange(location: 7, length: 2))
        let session = try session(harness)
        XCTAssertEqual(session.plan, .fromNotes)
        let write = writeItem
        XCTAssertTrue(harness.reader.validateMenuItem(write))
        XCTAssertEqual(write.title, "Write Reply from Notes")
        XCTAssertNil(layer(harness).state.pill, "no pill for a gap")
        commandJ(harness)
        until({ session.phase == .written })
        let request = try XCTUnwrap(script.requests.first)
        XCTAssertTrue(request.task.contains("see you Tuesday"), "the notes around it are the brief")
        XCTAssertFalse(request.task.contains("SELECTION"))
        XCTAssertEqual(field.string, "A whole reply.", "the reply replaces the notes, not the gap")
    }

    /// With text selected the pill offers to rewrite it, following the selection, and the open prompt line's placeholder
    /// says so too.
    func testThePillAndThePromptFollowTheSelection() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let field = type("tue 10 works, I'll bring the budget", harness)
        let layer = layer(harness)
        XCTAssertNil(layer.state.pill)
        field.setSelectedRange(NSRange(location: 25, length: 10))
        XCTAssertEqual(layer.state.pill, NSRange(location: 25, length: 10))
        harness.reader.helpMeWriteWithInstructions(nil)
        let prompt = layer.prompt
        XCTAssertTrue(prompt.rewritesSelection)
        XCTAssertEqual(prompt.placeholder, "Tell Claude how to rewrite it\u{2026}")
        XCTAssertNil(layer.state.pill, "the prompt line takes the selection's place under it")
        field.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertFalse(prompt.rewritesSelection, "the prompt's placeholder follows the selection while it is open")
        XCTAssertEqual(prompt.placeholder, "Tell Claude what to write\u{2026}")
        try session(harness).closePrompt(focusText: true)
        field.setSelectedRange(NSRange(location: 13, length: 1))
        XCTAssertNil(layer.state.pill, "a space alone is no selection")
    }

    /// Text set from outside while the keyboard stays in the field (a send undone puts the draft back) is read for the ghost.
    func testTextPutBackFromOutsideIsReadForTheGhost() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        type("", harness)
        let bar = harness.reader.quickReplyBar
        let layer = layer(harness)
        XCTAssertEqual(layer.state.ghost?.words, WriteWords.ghostAfterPlaceholder, "an empty reply: the ghost after the placeholder")
        bar.restoreDraft("hi there friend")
        XCTAssertTrue(harness.controller.window?.firstResponder === bar.writingTextView, "the keyboard stayed")
        XCTAssertNil(layer.state.ghost, "the notes ghost waits for a pause")
        until({ layer.state.ghost?.words == WriteWords.ghostNotes }, "three words put back: the notes ghost, after the pause")
        bar.text = ""
        XCTAssertEqual(layer.state.ghost?.words, WriteWords.ghostAfterPlaceholder)
    }

    /// Edit › Help Me Write's titles start over each time the menu opens: with the keyboard where nothing answers ⌘J (the
    /// list), the disabled item reads Help Me Write, not the last field's “Rewrite Selection”.
    func testTheEditMenusTitlesStartOverAsItOpens() throws {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["Paper"])))
        let edit = try XCTUnwrap(bar.items.first { $0.title == "Edit" }?.submenu)
        XCTAssertTrue(edit.delegate === MainMenuController.shared)
        let write = try XCTUnwrap(edit.items.first { $0.action == #selector(ConversationViewController.helpMeWrite(_:)) })
        let instructions = try XCTUnwrap(edit.items.first {
            $0.action == #selector(ConversationViewController.helpMeWriteWithInstructions(_:))
        })
        write.title = "Rewrite Selection"
        instructions.title = "Rewrite Selection with Instructions\u{2026}"
        MainMenuController.shared?.menuNeedsUpdate(edit)
        XCTAssertEqual(write.title, MainMenu.helpMeWriteTitle)
        XCTAssertEqual(instructions.title, MainMenu.helpMeWriteWithInstructionsTitle)
    }

    /// ⇧⌘J is found from the reply itself: the text's menu offers Say How…, and a draft's afterline offers Say how, which
    /// opens the prompt line under the draft; Shorter on the afterline runs at once, from the same notes.
    func testSayHowIsFoundFromTheReply() throws {
        let (harness, script) = try harness(reply: "Tuesday at ten works.")
        defer { harness.close() }
        let field = type("tue 10 ok", harness)
        let session = try session(harness)
        let items = session.contextMenuItems()
        XCTAssertEqual(items.map(\.title), ["Write Reply from Notes", "Say How\u{2026}", ""])
        XCTAssertEqual(items[1].keyEquivalent, "j")
        XCTAssertEqual(items[1].keyEquivalentModifierMask, [.command, .shift])
        commandJ(harness)
        until({ session.phase == .written })
        // Shorter, from the afterline: at once, from the notes.
        press(.shorter, in: layer(harness))
        until({ script.requests.count == 2 && session.phase == .written })
        XCTAssertTrue(script.requests[1].task.hasSuffix("Shorter"))
        XCTAssertTrue(script.requests[1].task.contains("tue 10 ok"))
        XCTAssertEqual(field.string, "Tuesday at ten works.")
        press(.sayHow, in: layer(harness))
        XCTAssertTrue(session.isPromptShown, "the afterline's Say how opens the prompt line")
        XCTAssertTrue(layer(harness).prompt.fieldHoldsFocus)
        XCTAssertEqual(layer(harness).prompt.instruction, "Shorter", "the prompt remembers the last instruction")
        XCTAssertTrue(layer(harness).afterline.isHidden, "one block at a time")

        let composer = replyComposer(harness)
        composer.window?.makeFirstResponder(composer.bodyEditor)
        composer.bodyEditor.insertText("will read", replacementRange: NSRange(location: 0, length: 0))
        composer.helpMeWrite(nil)
        let composed = try XCTUnwrap(composer.writeSession)
        until({ composed.phase == .written })
        composer.bodyWriteLayer.afterline.layoutSubtreeIfNeeded()
        XCTAssertFalse(composer.bodyWriteLayer.afterline.actions[.sayHow]?.isHidden ?? true, composer.bodyWriteLayer.afterline.shownWords)
        composer.bodyWriteLayer.afterline.actions[.sayHow]?.performClick(nil)
        XCTAssertTrue(composer.bodyWriteLayer.prompt.fieldHoldsFocus, "the composer's prompt line, the keyboard in it")
    }

    // MARK: Writing in place

    func testCommandJWritesFromTheNotesInPencilThenInkAsOneUndoStep() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight nine ten")
        defer { harness.close() }
        var announced: [String] = []
        QuireAccessibility.observer = { _, text in if let text { announced.append(text) } }
        script.delay = .milliseconds(80)
        let field = type("tue 10 ok", harness)
        let bar = harness.reader.quickReplyBar
        commandJ(harness)
        let session = try session(harness)
        XCTAssertEqual(session.phase, .writing, "no card, no extra step: it starts at once")
        until({ field.string.hasPrefix("One two") }, "the reply streams into the field")
        XCTAssertEqual(color(of: field, at: 0), .qInk2, "in pencil while it streams")
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(layer(harness).pencil.isHidden, "the pencil in the caret's place")
        XCTAssertEqual(bar.sendControlsEnabled.send, false, "Send waits")
        XCTAssertFalse(field.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x"), "typing waits")
        XCTAssertTrue(WriteSession.isStreaming(in: field.window))

        until({ session.phase == .written }, "the reply lands")
        XCTAssertEqual(field.string, "One two three four five six seven eight nine ten")
        XCTAssertEqual(color(of: field, at: 0), .qInk, "and turns to ink")
        XCTAssertEqual(layer(harness).afterline.lineWords,
                       "Written by Claude \u{00b7} Try again \u{2318}J \u{00b7} Shorter \u{00b7} Say how \u{21e7}\u{2318}J \u{00b7} Undo \u{2318}Z")
        XCTAssertTrue(layer(harness).pencil.isHidden)
        XCTAssertTrue(field.window?.firstResponder === field)
        XCTAssertTrue(announced.contains("Reply written by Claude"), "\(announced)")
        let request = try XCTUnwrap(script.requests.first)
        XCTAssertEqual(request.promptVersion, "write-reply-2")
        XCTAssertTrue(request.task.contains("tue 10 ok"), "the typed text goes as the brief")
        XCTAssertTrue(request.transcript.contains("newest message first"))
        XCTAssertFalse(request.userTurn.contains("@"), "no address is sent")
        XCTAssertTrue(sheets.isEmpty)

        let undo = try XCTUnwrap(field.undoManager)
        XCTAssertEqual(undo.undoMenuItemTitle, "Undo Help Me Write")
        undo.undo()
        XCTAssertEqual(field.string, "tue 10 ok", "⌘Z brings the notes back in one step")
        XCTAssertEqual(session.phase, .idle, "and the afterline goes")
        undo.redo()
        XCTAssertEqual(field.string, "One two three four five six seven eight nine ten", "⌘⇧Z brings the reply back")
    }

    func testCommandJOnAnEmptyFieldWritesFromTheThreadAlone() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        let field = type("", harness)
        commandJ(harness)
        until({ try! self.session(harness).phase == .written })
        XCTAssertEqual(field.string, "Tuesday at ten works. See you then.")
        let request = try XCTUnwrap(script.requests.first)
        XCTAssertFalse(request.task.contains("NOTES"))
        XCTAssertTrue(request.task.hasSuffix("Write my reply."))
    }

    func testTryAgainWritesFromTheSameNotesNeverTheDraft() throws {
        let (harness, script) = try harness(reply: "First draft of the reply.")
        defer { harness.close() }
        let field = type("tue 10 ok", harness)
        commandJ(harness)
        let session = try session(harness)
        until({ session.phase == .written })
        XCTAssertEqual(field.string, "First draft of the reply.")

        script.reply = "Second draft, from the same notes."
        script.delay = .milliseconds(60)
        XCTAssertEqual(session.plan, .tryAgain)
        commandJ(harness)
        XCTAssertEqual(session.phase, .writing)
        XCTAssertEqual(field.string, "First draft of the reply.", "the draft stays in sight, in pencil, until the new words come")
        XCTAssertEqual(color(of: field, at: 0), .qInk2)
        until({ session.phase == .written })
        XCTAssertEqual(field.string, "Second draft, from the same notes.")
        XCTAssertEqual(script.requests.count, 2)
        XCTAssertTrue(script.requests[1].task.contains("tue 10 ok"), "from the notes")
        XCTAssertFalse(script.requests[1].task.contains("First draft"), "never from the draft: trying again never compounds")
        field.undoManager?.undo()
        XCTAssertEqual(field.string, "tue 10 ok", "one ⌘Z still brings the notes back")
    }

    func testTryAgainFromTheLineAndStoppedPutsTheNotesBack() throws {
        let (harness, script) = try harness(reply: "First draft of the reply.")
        defer { harness.close() }
        let field = type("tue 10 ok", harness)
        commandJ(harness)
        let session = try session(harness)
        until({ session.phase == .written })
        script.holdsAfter = 1
        press(.tryAgain, in: layer(harness))
        XCTAssertEqual(session.phase, .writing)
        until({ field.string.hasPrefix("Tuesday") || field.string.hasPrefix("First") })
        field.cancelOperation(nil)
        XCTAssertEqual(field.string, "tue 10 ok", "Esc puts the notes back exactly")
        XCTAssertEqual(session.phase, .idle)
        field.undoManager?.redo()
        XCTAssertEqual(field.string, "First draft of the reply.", "and the first draft is still a ⌘⇧Z away")
    }

    func testAfterAnEditCommandJTakesTheTextAsTheNewNotes() throws {
        let (harness, script) = try harness(reply: "Tuesday at ten works.")
        defer { harness.close() }
        let field = type("tue 10 ok", harness)
        commandJ(harness)
        let session = try session(harness)
        until({ session.phase == .written })
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
        field.insertText(" Bring snacks.", replacementRange: field.selectedRange())
        XCTAssertEqual(session.phase, .idle, "typing ends the afterline")
        XCTAssertEqual(session.plan, .fromNotes)
        commandJ(harness)
        until({ session.phase == .written })
        XCTAssertTrue(script.requests[1].task.contains("Tuesday at ten works. Bring snacks."), "the edited draft is the brief")
    }

    func testCommandJWithASelectionRewritesOnlyIt() throws {
        let (harness, script) = try harness(reply: "Thursday")
        defer { harness.close() }
        let field = type("See you Tuesday, Ben", harness)
        field.setSelectedRange(NSRange(location: 8, length: 7))
        commandJ(harness)
        until({ try! self.session(harness).phase == .written })
        XCTAssertEqual(field.string, "See you Thursday, Ben")
        XCTAssertEqual(script.requests.first?.task.contains("<<<SELECTION"), true)
        field.undoManager?.undo()
        XCTAssertEqual(field.string, "See you Tuesday, Ben")
    }

    // MARK: The prompt line (⇧⌘J)

    func testThePromptLineSaysHowAndRemembersItsInstruction() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        let field = type("tue 10 ok", harness)
        let bar = harness.reader.quickReplyBar
        let heightBefore = bar.barHeight
        XCTAssertTrue(harness.reader.validateMenuItem(instructionsItem))
        harness.reader.helpMeWriteWithInstructions(nil)
        let session = try session(harness)
        let prompt = layer(harness).prompt
        XCTAssertTrue(session.isPromptShown)
        XCTAssertFalse(prompt.isHidden)
        XCTAssertTrue(prompt.fieldHoldsFocus, "the keyboard goes to the prompt line")
        XCTAssertEqual(prompt.placeholder, "Tell Claude what to write\u{2026}")
        XCTAssertEqual(prompt.chips.map(\.title), ["Shorter", "Friendlier", "Say no politely"])
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.barHeight, heightBefore + WritePromptLine.blockHeight, accuracy: 0.5, "in the reply's text: the field grows by it")
        XCTAssertTrue(prompt.isDescendant(of: field), "in the text, under the caret's line")
        XCTAssertTrue(harness.reader.validateMenuItem(writeItem), "⌘J still applies from the prompt line")

        prompt.instruction = "Warmer"
        let editor = try XCTUnwrap(prompt.field.currentEditor() as? NSTextView)
        XCTAssertTrue(prompt.control(prompt.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(session.isPromptShown, "running closes the line")
        XCTAssertTrue(field.window?.firstResponder === field, "and gives the keyboard back to the text")
        until({ session.phase == .written })
        XCTAssertTrue(script.requests.first?.task.hasSuffix("Write my reply from these notes. Warmer") == true)

        // ⇧⌘J brings it back with the instruction kept; a chip runs, from the same notes.
        harness.reader.helpMeWriteWithInstructions(nil)
        XCTAssertEqual(prompt.instruction, "Warmer", "remembered for this reply until it is sent")
        prompt.chips[0].performClick(nil)
        until({ script.requests.count == 2 && session.phase == .written })
        XCTAssertEqual(prompt.instruction, "Shorter")
        XCTAssertTrue(script.requests[1].task.contains("tue 10 ok"))
        XCTAssertTrue(script.requests[1].task.hasSuffix("Shorter"))

        // Esc closes it, the keyboard back in the text.
        harness.reader.helpMeWriteWithInstructions(nil)
        let promptEditor = try XCTUnwrap(prompt.field.currentEditor() as? NSTextView)
        XCTAssertTrue(prompt.control(prompt.field, textView: promptEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(session.isPromptShown)
        XCTAssertTrue(field.window?.firstResponder === field, "and the keyboard goes back to the text")

        // With a selection, it says how to rewrite the selection.
        field.setSelectedRange(NSRange(location: 0, length: 4))
        harness.reader.helpMeWriteWithInstructions(nil)
        XCTAssertTrue(prompt.rewritesSelection)
        XCTAssertEqual(prompt.placeholder, "Tell Claude how to rewrite it\u{2026}")
    }

    func testEscStopsAWriteThenBehavesAsBefore() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight nine ten eleven twelve")
        defer { harness.close() }
        script.holdsAfter = 2
        let field = type("my notes", harness)
        commandJ(harness)
        let session = try session(harness)
        until({ field.string == "One two three four " }, "text streams into the field")
        XCTAssertFalse(harness.reader.validateMenuItem(writeItem), "one write at a time")
        field.window?.makeFirstResponder(field)
        field.cancelOperation(nil)
        XCTAssertEqual(field.string, "my notes", "the notes back exactly")
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(WriteSession.isStreaming(in: field.window))
        XCTAssertTrue(field.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x"))
        XCTAssertNotEqual(field.undoManager?.undoMenuItemTitle, "Undo Help Me Write", "a stopped write leaves no undo step")
        XCTAssertFalse(session.escape(), "a second Esc is the field's own again")
    }

    // MARK: Failures stay inline

    func testAFailureStaysInTheTextWithTryAgainAndSettings() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        var opened = 0
        harness.environment.helpMeWrite.openSettings = { opened += 1 }
        script.failure = .keyRefused
        script.failsAfter = 2
        let field = type("my notes", harness)
        commandJ(harness)
        let session = try session(harness)
        until({ if case .failed = session.phase { return true } else { return false } })
        XCTAssertEqual(field.string, "my notes", "the notes are untouched")
        XCTAssertEqual(session.phase, .failed(reason: "The Anthropic API key was refused", offersSettings: true))
        let layer = layer(harness)
        layer.afterline.layoutSubtreeIfNeeded()
        XCTAssertFalse(layer.afterline.isHidden, "under the caret's line")
        XCTAssertFalse(layer.afterline.actions[.tryAgain]?.isHidden ?? true)
        XCTAssertFalse(layer.afterline.actions[.settings]?.isHidden ?? true, "the fix is in Settings › AI")
        XCTAssertEqual(layer.afterline.content, .failed(reason: "The Anthropic API key was refused", offersSettings: true))
        XCTAssertFalse(layer.afterline.lineWords.contains("my notes"), "no words from the field in the failure")
        XCTAssertNil(harness.controller.window?.attachedSheet, "no sheet")
        XCTAssertTrue(sheets.isEmpty)

        script.failure = nil
        press(.tryAgain, in: layer)
        until({ session.phase == .written })
        XCTAssertEqual(field.string, "Tuesday at ten works. See you then.")
        script.failure = .keyRefused
        type("again", harness)
        commandJ(harness)
        until({ if case .failed = session.phase { return true } else { return false } })
        press(.settings, in: layer)
        XCTAssertEqual(opened, 1)
    }

    func testMovingAwayEndsTheAfterlineAndClosesThePromptLine() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let field = type("tue 10 ok", harness)
        commandJ(harness)
        let session = try session(harness)
        until({ session.phase == .written })
        field.window?.makeFirstResponder(harness.list.tableView)
        XCTAssertEqual(session.phase, .idle, "the afterline goes as the user moves away")
        XCTAssertTrue(layer(harness).afterline.isHidden)
        field.window?.makeFirstResponder(field)
        harness.reader.helpMeWriteWithInstructions(nil)
        XCTAssertTrue(session.isPromptShown)
        field.window?.makeFirstResponder(harness.list.tableView)
        XCTAssertFalse(session.isPromptShown, "and the prompt line closes")
    }

    // MARK: The bar and the conversation going away

    func testAnotherConversationEndsTheWriteAndPutsTheFieldBack() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        script.holdsAfter = 1
        let field = type("notes for thread two", harness)
        commandJ(harness)
        until({ field.string != "notes for thread two" })
        let other = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-4" }?.id)
        harness.list.selectedConversationID = other
        harness.list.onSelectionChange?(other)
        XCTAssertFalse(harness.reader.isWritingReply)
        XCTAssertFalse(WriteSession.isStreaming(in: harness.controller.window))
        let thread2 = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = thread2
        harness.list.onSelectionChange?(thread2)
        harness.spin { harness.reader.quickReplyBar.text == "notes for thread two" }
        XCTAssertEqual(harness.reader.quickReplyBar.text, "notes for thread two", "the notes were parked as typed")
    }

    func testTheWeekMidWriteEndsTheWriteWithTheFieldPutBack() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        let (field, _) = try streaming("my notes", harness, script)
        _ = harness.controller.perform(.toggleWeek)
        XCTAssertFalse(harness.reader.isOnScreen)
        XCTAssertFalse(harness.reader.isWritingReply)
        XCTAssertEqual(field.string, "my notes")
        XCTAssertFalse(WriteSession.isStreaming(in: field.window))
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(field.string, "my notes", "nothing streams into a field no one sees")
        XCTAssertFalse(field.window?.firstResponder === field, "and the keyboard is not in it")
    }

    func testAComposerTakingTheReplyMidWriteEndsTheWrite() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        let (field, _) = try streaming("my notes", harness, script)
        let composer = replyComposer(harness)
        until({ harness.reader.quickReplyBar.isComposerOpen })
        XCTAssertFalse(harness.reader.isWritingReply, "the write stops as the bar gives the reply to the composer")
        XCTAssertEqual(field.string, "my notes")
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(field.string, "my notes", "nothing streams into the hidden field")
        composer.closeWithoutSaving()
    }

    func testAWriteThatEndsAfterTheUserMovedOnLeavesTheKeyboardWhereTheyWent() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        script.delay = .milliseconds(100)
        let field = type("my notes", harness)
        commandJ(harness)
        until({ field.string.hasPrefix("One") })
        let window = try XCTUnwrap(field.window)
        window.makeFirstResponder(harness.list.tableView)
        until({ try! self.session(harness).phase != .writing })
        XCTAssertEqual(field.string, "One two three four five six seven eight")
        XCTAssertTrue(window.firstResponder === harness.list.tableView, "J and K still go to the list")
    }

    func testAFailureAfterTheUserMovedOnLeavesTheKeyboardWhereTheyWent() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        script.delay = .milliseconds(100)
        script.failure = .timedOut
        script.failsAfter = 2
        let field = type("my notes", harness)
        commandJ(harness)
        until({ field.string.hasPrefix("One") })
        let window = try XCTUnwrap(field.window)
        window.makeFirstResponder(harness.list.tableView)
        until({ try! self.session(harness).phase != .writing })
        XCTAssertEqual(field.string, "my notes")
        XCTAssertTrue(window.firstResponder === harness.list.tableView, "the line says why without taking the keyboard")
    }

    func testAWriteStillBuildingItsContextAsTheEnvironmentGoesSendsNothing() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        let field = type("my notes", harness)
        commandJ(harness)
        // What `HelpMeWrite.shutdown` does first, before the context, built off the main thread, reaches the writer.
        harness.environment.helpMeWrite.writer.shutDown()
        until({ try! self.session(harness).phase == .idle })
        ListTestSupport.spin(for: 0.3)
        XCTAssertTrue(script.requests.isEmpty, "nothing was asked once the environment went")
        XCTAssertEqual(field.string, "my notes")
        XCTAssertFalse(WriteSession.isStreaming(in: field.window))
    }

    // MARK: The composer

    func testAReplyComposerWritesAboveItsSignatureAndUndoesInOneStep() throws {
        let (harness, _) = try harness(reply: "Thanks, I'll read it tonight.")
        defer { harness.close() }
        try harness.environment.store.setSignature("<p>Alex</p>", for: ListTestSupport.accountA.id)
        harness.controller.refreshAccounts()
        let composer = replyComposer(harness)
        let editor = composer.bodyEditor
        composer.window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("will read", replacementRange: editor.selectedRange())
        let before = composer.bodyText
        XCTAssertTrue(before.hasSuffix("Alex"), "the signature sits below what was typed")
        XCTAssertEqual(try XCTUnwrap(composer.bodyWriteSession).plan, .fromNotes, "the notes are the user's own words, not the signature")
        XCTAssertTrue(composer.validateMenuItem(writeItem))
        composer.helpMeWrite(nil)
        let session = try XCTUnwrap(composer.writeSession)
        until({ session.phase == .written })
        XCTAssertEqual(composer.bodyText, "Thanks, I'll read it tonight.\n\nAlex", "the reply replaces the notes and keeps the signature")
        MainWindowHarness.assertWritingStyle(composer.contents.body)
        XCTAssertEqual(composer.bodyWriteLayer.afterline.lineWords,
                       "Written by Claude \u{00b7} Try again \u{2318}J \u{00b7} Shorter \u{00b7} Say how \u{21e7}\u{2318}J \u{00b7} Undo \u{2318}Z")
        XCTAssertEqual(editor.undoManager?.undoMenuItemTitle, "Undo Help Me Write")
        editor.undoManager?.undo()
        XCTAssertEqual(composer.bodyText, before)
    }

    /// The composer's prompt line opens under the caret's line in the body: the signature under it moves down by its height
    /// (the body's text is never covered), and back as it closes; a chip runs from the notes.
    func testTheComposersPromptLineMakesRoomInTheBody() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        try harness.environment.store.setSignature("<p>Alex</p>", for: ListTestSupport.accountA.id)
        harness.controller.refreshAccounts()
        let composer = replyComposer(harness)
        let editor = composer.bodyEditor
        composer.window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("will read tonight", replacementRange: editor.selectedRange())
        func signatureTop() -> CGFloat {
            let signature = (editor.string as NSString).range(of: "Alex")
            editor.layoutManager?.ensureLayout(for: editor.textContainer!)
            let glyph = editor.layoutManager!.glyphIndexForCharacter(at: signature.location)
            return editor.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        }
        let before = signatureTop()
        let height = editor.intrinsicContentSize.height
        XCTAssertTrue(composer.validateMenuItem(instructionsItem))
        composer.helpMeWriteWithInstructions(nil)
        let layer = composer.bodyWriteLayer
        XCTAssertTrue(layer.prompt.fieldHoldsFocus)
        XCTAssertTrue(layer.prompt.isDescendant(of: editor), "in the body's text")
        XCTAssertEqual(signatureTop() - before, WritePromptLine.blockHeight, accuracy: 0.5, "the signature moved down by the line's height")
        XCTAssertEqual(editor.intrinsicContentSize.height - height, WritePromptLine.blockHeight, accuracy: 0.5, "and the body grew by it")
        XCTAssertGreaterThanOrEqual(editor.convert(layer.prompt.frame, from: layer.prompt.superview).minY,
                                    editor.textContainerOrigin.y + 21 - 0.5, "under the caret's line")
        layer.prompt.chips[1].performClick(nil)
        let session = try XCTUnwrap(composer.writeSession)
        until({ session.phase == .written })
        XCTAssertTrue(script.requests.first?.task.hasSuffix("Friendlier") == true)
        XCTAssertTrue(script.requests.first?.task.contains("will read tonight") == true)
        XCTAssertFalse(layer.afterline.isHidden, "the afterline under the draft, in its own room")
        XCTAssertTrue(session.escape(), "Esc dismisses the afterline")
        XCTAssertTrue(layer.afterline.isHidden)
        XCTAssertEqual(editor.textContainer?.exclusionPaths.count, 0, "the room is given back once nothing shows")
        XCTAssertEqual(layer.reservedHeight, 0)
        XCTAssertEqual(editor.reservedBottom, 0)
        XCTAssertEqual(composer.bodyText.hasPrefix("Tuesday at ten works."), true, "the draft kept")
    }

    func testEscInAComposerStopsTheWriteBeforeItCanClose() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        script.holdsAfter = 1
        let composer = replyComposer(harness)
        composer.window?.makeFirstResponder(composer.bodyEditor)
        composer.helpMeWrite(nil)
        let session = try XCTUnwrap(composer.writeSession)
        until({ !composer.bodyText.isEmpty })
        composer.escapeComposer(nil)
        XCTAssertEqual(composer.bodyText, "", "the body is back as it was")
        XCTAssertTrue(composer.window?.isVisible ?? false, "and Esc did not close the composer")
        XCTAssertEqual(session.phase, .idle)
    }

    func testClosingAComposerMidWriteKeepsWhatTheUserWrote() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        script.holdsAfter = 2
        let composer = replyComposer(harness)
        let editor = composer.bodyEditor
        composer.window?.makeFirstResponder(editor)
        editor.insertText("will read tonight", replacementRange: NSRange(location: 0, length: 0))
        composer.helpMeWrite(nil)
        until({ composer.bodyText.hasPrefix("Tuesday") })
        let draftID = composer.draftID
        composer.window?.performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        let kept = try XCTUnwrap(ComposeDraftStore.shared.draft(id: draftID, accounts: harness.controller.accounts))
        XCTAssertEqual(kept.body.string, "will read tonight", "the kept draft holds the user's words, not half a reply")
    }

    private func button(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let found = button(title, in: subview) { return found }
        }
        return nil
    }

    func testDiscardDraftAndInsertPictureWaitForAWriteAndUndoBringsBackTheUsersWords() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        script.holdsAfter = 2
        let composer = replyComposer(harness)
        let editor = composer.bodyEditor
        composer.window?.makeFirstResponder(editor)
        editor.insertText("will read tonight", replacementRange: NSRange(location: 0, length: 0))
        composer.helpMeWrite(nil)
        let session = try XCTUnwrap(composer.writeSession)
        until({ composer.bodyText.hasPrefix("One two three four") })

        let discard = NSMenuItem(title: "Discard Draft\u{2026}", action: #selector(ComposeWindowController.discardDraft(_:)), keyEquivalent: "")
        let picture = NSMenuItem(title: "Insert Picture\u{2026}", action: #selector(ComposeWindowController.insertPicture(_:)),
                                 keyEquivalent: "")
        let link = NSMenuItem(title: "Link\u{2026}", action: #selector(ComposeWindowController.insertLink(_:)), keyEquivalent: "")
        for item in [discard, picture, link] {
            XCTAssertFalse(composer.validateMenuItem(item), "\(item.title) waits for the write")
        }
        composer.discardDraft(nil)
        composer.insertPicture(nil)
        XCTAssertNil(composer.window?.attachedSheet, "no alert or panel over a reply streaming in")
        XCTAssertEqual(session.phase, .writing)
        session.stop()
        XCTAssertTrue(composer.bodyText.hasPrefix("will read tonight"), "Stop puts the body back")
        XCTAssertTrue(composer.validateMenuItem(discard))
        XCTAssertTrue(composer.validateMenuItem(picture))

        var undo: ComposeDraftUndo?
        let observer = NotificationCenter.default.addObserver(forName: ComposeWindowController.draftDiscardedNotification, object: nil,
                                                              queue: nil) { note in
            undo = note.userInfo?[ComposeWindowController.draftUndoKey] as? ComposeDraftUndo
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        composer.discardDraft(nil)
        let sheet = try XCTUnwrap(composer.window?.attachedSheet)
        try XCTUnwrap(button("Discard", in: sheet.contentView)).performClick(nil)
        until({ undo != nil })
        try XCTUnwrap(undo).undo()
        let reopened = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first { $0 !== composer })
        XCTAssertTrue(reopened.bodyText.hasPrefix("will read tonight"), "Undo brings back the user's own words")
    }

    func testAComposerRewriteOfATripleClickedParagraphKeepsItsStyle() throws {
        let (harness, _) = try harness(reply: "Thursday suits me")
        defer { harness.close() }
        let composer = replyComposer(harness)
        let editor = composer.bodyEditor
        composer.window?.makeFirstResponder(editor)
        editor.insertText("Tuesday works\nSee you", replacementRange: NSRange(location: 0, length: 0))
        // The first line underlined, then triple-clicked: the paragraph with its line break.
        editor.setSelectedRange(NSRange(location: 0, length: 14))
        editor.textStorage?.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 14))
        editor.setSelectedRange(NSRange(location: 0, length: 14))
        composer.helpMeWrite(nil)
        until({ composer.writeSession?.phase == .written })
        XCTAssertTrue(composer.bodyText.hasPrefix("Thursday suits me\nSee you"), composer.bodyText)
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertEqual(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue,
                       "the rewrite keeps the selection's own style")
        XCTAssertNil(storage.attribute(.underlineStyle, at: 18, effectiveRange: nil), "and the next line stays as it was")
    }

    // MARK: Nothing else takes or edits a reply streaming in

    private func pendingSends(_ harness: MainWindowHarness) -> [PendingSend] {
        (try? harness.environment.store.pendingSends()) ?? []
    }

    /// A write resting mid-reply in the quick reply, over `notes`.
    private func streaming(_ notes: String, _ harness: MainWindowHarness, _ script: DemoAIScript) throws -> (NSTextView, WriteSession) {
        script.holdsAfter = 2
        let field = type(notes, harness)
        commandJ(harness)
        let session = try session(harness)
        until({ field.string == "One two three four " })
        XCTAssertEqual(session.phase, .writing)
        return (field, session)
    }

    func testTheQuickReplyNeitherSendsNorSchedulesAHalfWrittenReply() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        let (field, session) = try streaming("my notes", harness, script)
        let bar = harness.reader.quickReplyBar
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.sendControlsEnabled.send, false)
        XCTAssertEqual(bar.sendControlsEnabled.options, false, "the drop-down and its Send Later times wait too")
        let later = Date().addingTimeInterval(3_600)
        bar.sendLater(at: later)
        harness.reader.sendQuickReplyLater(field.string, mode: .reply, at: later)
        harness.reader.sendQuickReply(field.string, mode: .reply)
        XCTAssertEqual(pendingSends(harness).count, 0, "half a reply is never sent or scheduled")
        ListTestSupport.spin(for: 0.2)
        XCTAssertEqual(field.string, "One two three four ", "and the stream goes on where it was")
        XCTAssertEqual(session.phase, .writing)
        session.stop()
        XCTAssertEqual(field.string, "my notes")
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.sendControlsEnabled.options, true)
    }

    func testAComposerNeitherSendsNorSchedulesAHalfWrittenReply() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        script.holdsAfter = 2
        let accounts = harness.controller.accounts
        let composer = replyComposer(harness)
        composer.window?.makeFirstResponder(composer.bodyEditor)
        let send = NSMenuItem(title: "Send", action: #selector(ComposeWindowController.send(_:)), keyEquivalent: "\r")
        let sendAndArchive = NSMenuItem(title: "Send and Archive", action: #selector(ComposeWindowController.sendAndArchive(_:)),
                                        keyEquivalent: "\r")
        let sendLater = NSMenuItem(title: "Send Later…", action: #selector(ComposeWindowController.sendLater(_:)), keyEquivalent: "l")
        until({ composer.validateMenuItem(send) }, "a reply with its recipient can be sent")
        composer.helpMeWrite(nil)
        let session = try XCTUnwrap(composer.writeSession)
        until({ composer.bodyText.hasPrefix("One two three four") })
        for item in [send, sendAndArchive, sendLater] {
            XCTAssertFalse(composer.validateMenuItem(item), "\(item.title): ⌘↩, ⇧⌘↩ and ⇧⌘L wait for the write")
        }
        XCTAssertFalse(composer.content.bottomBar.sendButton.isEnabled)
        composer.send(nil)
        composer.sendAndArchive(nil)
        composer.sendLater(at: Date().addingTimeInterval(3_600))
        XCTAssertEqual(pendingSends(harness).count, 0, "nothing is queued with half a reply in it")
        XCTAssertTrue(composer.window?.isVisible ?? false)
        if accounts.count > 1 {
            composer.chooseFrom(accounts[1].id)
            XCTAssertEqual(composer.account.id, accounts[0].id, "From waits: the body would refuse the new signature")
        }
        XCTAssertEqual(session.phase, .writing)
        session.stop()
        XCTAssertTrue(composer.validateMenuItem(send))
        XCTAssertTrue(composer.content.bottomBar.sendButton.isEnabled)
    }

    /// A file dragged over a field a reply streams into, from the Finder as from a message (§5.17).
    private func fileDrag() throws -> FakeDraggingInfo {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("brief.txt")
        try Data("brief".utf8).write(to: file)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HelpMeWriteTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        return FakeDraggingInfo(pasteboard: pasteboard, source: nil, mask: .copy)
    }

    /// A drop on the quick reply would move the half-written reply to a composer: while a reply streams the bar takes
    /// none, and it shows no drop treatment; once the write ends the bar takes drops again.
    func testTheQuickReplyRefusesADropWhileAReplyStreams() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        let (field, session) = try streaming("my notes", harness, script)
        let bar = harness.reader.quickReplyBar
        let drag = try fileDrag()
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertFalse(bar.acceptsDrops)
        XCTAssertEqual(bar.draggingEntered(drag), [])
        XCTAssertFalse(bar.showsDropTarget, "no treatment for a drop the bar refuses")
        XCTAssertFalse(bar.performDragOperation(drag))
        XCTAssertTrue(ComposeWindowRegistry.shared.openControllers.isEmpty, "the reply moved nowhere")
        XCTAssertEqual(field.string, "One two three four ", "and the stream goes on where it was")
        XCTAssertEqual(session.phase, .writing)
        session.stop()
        XCTAssertEqual(field.string, "my notes")
        XCTAssertTrue(bar.acceptsDrops)
        XCTAssertEqual(bar.draggingEntered(drag), .copy)
        bar.draggingExited(drag)
    }

    /// A composer's attachment strip is not the body: while a reply streams in, a file dropped on the window or pasted on
    /// the body attaches as Attach Files… would, and the reply streams on, untouched.
    func testAComposerStillAttachesWhileAReplyStreams() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        script.holdsAfter = 2
        let composer = replyComposer(harness)
        composer.window?.makeFirstResponder(composer.bodyEditor)
        composer.helpMeWriteWithInstructions(nil)
        composer.bodyWriteLayer.prompt.chips[0].performClick(nil)
        let session = try XCTUnwrap(composer.writeSession)
        until({ composer.bodyText.hasPrefix("One two three four") })
        let content = try XCTUnwrap(composer.window?.contentView as? ComposeContentView)
        let drag = try fileDrag()
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(content.draggingEntered(drag), .copy)
        XCTAssertTrue(content.showsDropOutline)
        let body = try XCTUnwrap(content.subviews.firstIndex(of: content.scrollView))
        let veil = try XCTUnwrap(content.subviews.firstIndex(of: content.dropOverlay))
        XCTAssertGreaterThan(veil, body, "the outline and its words are drawn over the body, Help me write's marks included")
        XCTAssertTrue(content.performDragOperation(drag))
        XCTAssertFalse(content.showsDropOutline)
        XCTAssertEqual(composer.contents.attachments.map(\.filename), ["brief.txt"], "dropped while the reply streams")
        composer.bodyEditor.pasteboard = drag.draggingPasteboard
        composer.bodyEditor.paste(nil)
        XCTAssertEqual(composer.contents.attachments.map(\.filename), ["brief.txt", "brief.txt"], "and pasted on the body")
        XCTAssertTrue(composer.bodyText.hasPrefix("One two three four"))
        XCTAssertFalse(composer.bodyText.contains("brief"), "nothing went into the reply")
        XCTAssertEqual(session.phase, .writing, "and it streams on")
        session.stop()
        XCTAssertEqual(composer.contents.attachments.map(\.filename), ["brief.txt", "brief.txt"], "putting the body back keeps the strip")
    }

    func testTheSendLaterUndoMidWriteKeepsTheUsersTextAndStopsTheWrite() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        var scheduled: SendLaterScheduled?
        let observer = NotificationCenter.default.addObserver(forName: SendLaterScheduled.didSchedule, object: nil, queue: nil) { note in
            scheduled = note.userInfo?[SendLaterScheduled.userInfoKey] as? SendLaterScheduled
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        let bar = harness.reader.quickReplyBar
        bar.text = "Thanks, see you Monday"
        bar.sendLater(at: Date().addingTimeInterval(86_400))
        let undo = try XCTUnwrap(scheduled)
        let (field, _) = try streaming("my notes", harness, script)

        XCTAssertTrue(undo.undo(), "the toast's Undo, while the reply streams in")
        XCTAssertFalse(harness.reader.isWritingReply, "the write stops first")
        XCTAssertFalse(WriteSession.isStreaming(in: field.window))
        XCTAssertEqual(field.string, "Thanks, see you Monday\n\nmy notes", "the unsent reply, then what the user typed")
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(field.string, "Thanks, see you Monday\n\nmy notes", "and nothing streams into it afterwards")
        XCTAssertTrue(field.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x"))
    }

    func testTextSetFromOutsideMidWriteNeverLandsUnderTheStream() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        let (field, _) = try streaming("my notes", harness, script)
        harness.reader.quickReplyBar.text = ""
        XCTAssertFalse(harness.reader.isWritingReply)
        XCTAssertEqual(field.string, "")
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(field.string, "", "the stream wrote nothing more, at no stale range")
        XCTAssertNotEqual(field.undoManager?.undoMenuItemTitle, "Undo Help Me Write")
    }

    func testAWriterStoppedFromOutsidePutsTheFieldBack() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        let (field, session) = try streaming("my notes", harness, script)
        harness.environment.helpMeWrite.writer.stopAll()
        until({ session.phase == .idle }, "as quitting or leaving the demo stops it")
        XCTAssertEqual(field.string, "my notes")
        XCTAssertFalse(WriteSession.isStreaming(in: field.window), "Undo and Redo work again")
        XCTAssertTrue(field.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x"), "typing works again")
        XCTAssertNotEqual(field.undoManager?.undoMenuItemTitle, "Undo Help Me Write")
        XCTAssertTrue(field.undoManager?.isUndoRegistrationEnabled ?? false)
    }

    // MARK: Rewrites and limits

    func testARewriteKeepsTheSelectionsOwnLineBreak() throws {
        let (harness, script) = try harness(reply: "Thursday suits me.")
        defer { harness.close() }
        let field = type("Tuesday works for me.\nSee you then.", harness)
        // A triple-click selects the paragraph with its line break.
        field.setSelectedRange(NSRange(location: 0, length: 22))
        commandJ(harness)
        until({ try! self.session(harness).phase == .written })
        XCTAssertEqual(field.string, "Thursday suits me.\nSee you then.")
        let request = try XCTUnwrap(script.requests.first)
        XCTAssertTrue(request.task.contains("Tuesday works for me."))
        field.undoManager?.undo()
        XCTAssertEqual(field.string, "Tuesday works for me.\nSee you then.")
    }

    func testASelectionLongerThanWhatIsSentIsRefusedWhole() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        let long = String(repeating: "word ", count: 1_700) + "end"
        let field = type(long, harness)
        field.setSelectedRange(NSRange(location: 0, length: (long as NSString).length))
        commandJ(harness)
        let session = try session(harness)
        XCTAssertEqual(session.phase, .failed(reason: "The selection is too long to rewrite. Select less.",
                                              offersSettings: false))
        ListTestSupport.spin(for: 0.2)
        XCTAssertTrue(script.requests.isEmpty, "nothing is sent, rather than a cut part the reply would replace whole")
        XCTAssertEqual(field.string, long)

        field.setSelectedRange(NSRange(location: (long as NSString).length, length: 0))
        commandJ(harness)
        XCTAssertEqual(session.phase, .failed(reason: "Your draft is too long to send as notes. Shorten it, or select a part to rewrite.",
                                              offersSettings: false))
        XCTAssertTrue(script.requests.isEmpty)
    }

    func testUndoBringsBackTheTextWithItsAttributes() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let field = type("tue 10 ok", harness)
        let before = NSAttributedString(attributedString: field.attributedString())
        commandJ(harness)
        until({ try! self.session(harness).phase == .written })
        XCTAssertEqual(field.selectedRange(), NSRange(location: (field.string as NSString).length, length: 0), "the caret after the reply")
        field.undoManager?.undo()
        XCTAssertEqual(field.attributedString(), before, "the text and every attribute, as they were")
        XCTAssertLessThanOrEqual(NSMaxRange(field.selectedRange()), (field.string as NSString).length)
        field.undoManager?.redo()
        XCTAssertEqual(field.string, "Tuesday at ten works. See you then.", "and Redo brings the reply back")
    }

    // MARK: The demo and the breadcrumbs

    func testTheDemoNeverCreditsMadeUpTextToAModel() throws {
        let demo = HelpMeWrite.demo(isDemo: true)
        for kind in AIProviderKind.selectable {
            XCTAssertEqual(demo.sourceLine(for: AIProviderConfiguration(kind: kind)), "Demo \u{00b7} made up on this Mac", "\(kind)")
            XCTAssertEqual(demo.writerName(for: kind), "the demo", "“Written by the demo”, never by a model")
            XCTAssertEqual(demo.turnOnAlert(for: kind).title, "Try Help Me Write?")
        }
        // With --live-ai-clis the demo's CLIs run for real: those say who writes, and where the conversation goes.
        let live = HelpMeWrite.demo(isDemo: true, liveCLIs: true)
        XCTAssertEqual(live.sourceLine(for: AIProviderConfiguration(kind: .claudeCode)), "Claude Code \u{00b7} Anthropic")
        XCTAssertEqual(live.writerName(for: .claudeCode), "Claude")
        XCTAssertEqual(live.turnOnAlert(for: .claudeCode).title, "Use Claude Code to help write replies?")
        XCTAssertEqual(live.sourceLine(for: AIProviderConfiguration(kind: .claudeAPI)), "Demo \u{00b7} made up on this Mac")
        let real = HelpMeWrite.demo(isDemo: false)
        XCTAssertEqual(real.sourceLine(for: AIProviderConfiguration(kind: .claudeAPI)), "Claude Opus 5.5 \u{00b7} Anthropic")
        XCTAssertEqual(real.writerName(for: .codex), "GPT")

        let suite = "HelpMeWriteTests.demo.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        demo.settings = settings
        demo.presentAlert = { _, _, done in done(1) }
        let model = AISettingsModel(settings: settings, center: demo)
        model.locateExecutable = { _, _ in nil }
        model.setProvider(.claudeAPI)
        XCTAssertEqual(model.caption, "In the demo, Help Me Write makes replies up on this Mac. Nothing is sent.")
        XCTAssertNil(settings.aiProvider, "a provider chosen in the demo is the demo's alone")
        XCTAssertEqual(settings.aiProvider(demo: true), .claudeAPI)
        XCTAssertFalse(settings.hasAIConsent(for: .claudeAPI, demo: false), "and so is its Turn On")
    }

    func testATurnOnInTheMadeUpDemoNeverStandsForALiveCLISend() throws {
        let suite = "HelpMeWriteTests.live.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let plain = HelpMeWrite.demo(isDemo: true)
        plain.settings = settings
        XCTAssertEqual(plain.turnOnAlert(for: .claudeCode).title, "Try Help Me Write?")
        plain.recordConsent(for: .claudeCode)
        plain.recordConsent(for: .claudeAPI)
        XCTAssertTrue(plain.hasConsent(for: .claudeCode))

        let live = HelpMeWrite.demo(isDemo: true, liveCLIs: true)
        live.settings = settings
        XCTAssertFalse(live.hasConsent(for: .claudeCode), "“Nothing is sent” never allowed a send")
        XCTAssertTrue(live.hasConsent(for: .claudeAPI), "the demo writer still makes Claude's replies up: that Turn On stands")
        live.recordConsent(for: .claudeCode)
        XCTAssertTrue(live.hasConsent(for: .claudeCode))
        XCTAssertFalse(settings.hasAIConsent(for: .claudeCode, demo: false), "and neither stands for real mail")
        live.withdrawConsent(for: .claudeCode)
        XCTAssertFalse(live.hasConsent(for: .claudeCode))
        XCTAssertTrue(plain.hasConsent(for: .claudeCode), "withdrawing one leaves the other")
    }

    func testAWriteLeavesNamesFromTheCodeOnly() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let previous = CrashReporting.breadcrumbSink
        var crumbs: [(String?, String?)] = []
        CrashReporting.breadcrumbSink = { crumb in
            MainActor.assumeIsolated { crumbs.append((crumb.category, crumb.message)) }
        }
        defer { CrashReporting.breadcrumbSink = previous }
        type("tue 10 ok", harness)
        commandJ(harness)
        until({ try! self.session(harness).phase == .written })
        let ai = crumbs.filter { $0.0 == "ai" }.compactMap(\.1)
        XCTAssertEqual(ai, ["write started", "claudeAPI", "write finished", "claudeAPI"])
    }
}
