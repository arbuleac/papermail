import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// Help me write in the app (spec §5.56): ⌘J applies to the quick reply and reply composers only, the card's states, the
/// consent sheet the first time a provider is used (Cancel sends nothing), the streamed reply as one undo step, Esc and a
/// failure putting the field back. Every write goes to the demo writer: nothing here reaches the network, a CLI or the
/// Keychain.
@MainActor
final class HelpMeWriteTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowHelpMeWrite-\(UUID().uuidString)")
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

    // MARK: Support

    /// A main window on thread-2 (three messages), Claude chosen in Settings › AI, the demo writer quick and scripted.
    private func harness(provider: AIProviderKind? = .claudeAPI, reply: String = "Tuesday at ten works. See you then.") throws
        -> (MainWindowHarness, DemoAIScript) {
        let harness = try MainWindowHarness()
        harness.settings.aiProvider = provider
        let script = try XCTUnwrap(harness.environment.helpMeWrite.demoScript)
        script.delay = .milliseconds(1)
        script.reply = reply
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentMessages.count == 3 }
        return (harness, script)
    }

    /// The quick reply focused with `text` typed, as R and typing leave it.
    private func type(_ text: String, _ harness: MainWindowHarness) -> NSTextView {
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        let field = harness.reader.quickReplyBar.writingTextView
        field.insertText(text, replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        return field
    }

    /// Answers the consent sheet with `choice` (0 Cancel, 1 Allow), recording each sheet shown.
    private func answerConsent(_ harness: MainWindowHarness, with choice: Int) -> () -> [AppAlert] {
        var shown: [AppAlert] = []
        harness.environment.helpMeWrite.presentAlert = { alert, _, done in
            shown.append(alert)
            done(choice)
        }
        return { shown }
    }

    private func helpMeWriteItem() -> NSMenuItem {
        NSMenuItem(title: "Help Me Write\u{2026}", action: #selector(ConversationViewController.helpMeWrite(_:)), keyEquivalent: "j")
    }

    private func openCard(_ harness: MainWindowHarness) throws -> WriteSession {
        harness.reader.helpMeWrite(nil)
        return try XCTUnwrap(harness.reader.writeSession)
    }

    // MARK: ⌘J

    func testCommandJIsEditHelpMeWrite() {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let edit = bar.items.first { $0.title == "Edit" }?.submenu
        let item = edit?.items.first { $0.action == #selector(ConversationViewController.helpMeWrite(_:)) }
        XCTAssertEqual(item?.title, "Help Me Write\u{2026}")
        XCTAssertEqual(item?.keyEquivalent, "j")
        XCTAssertEqual(item?.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]), [.command])
        XCTAssertNil(item?.target, "the focused reader or composer answers it")
        XCTAssertTrue(Quire.cheatSheet.first { $0.title == "Write" }?.rows.contains { $0.keys == "⌘J" && $0.label == "Help me write" } ?? false)
    }

    func testCommandJAppliesInTheFocusedQuickReplyOnly() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        harness.controller.window?.makeFirstResponder(harness.list.tableView)
        XCTAssertFalse(harness.reader.validateMenuItem(helpMeWriteItem()), "the list has no text to write in")
        _ = type("Tuesday?", harness)
        XCTAssertTrue(harness.reader.validateMenuItem(helpMeWriteItem()))
        _ = try openCard(harness)
        XCTAssertFalse(harness.reader.validateMenuItem(helpMeWriteItem()), "one card at a time")
    }

    func testCommandJAppliesToReplyComposersOnly() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let accounts = harness.controller.accounts
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2")
        let reply = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                    mode: .reply(original, all: false))
        reply.window?.makeFirstResponder(reply.bodyEditor)
        let item = helpMeWriteItem()
        XCTAssertTrue(reply.validateMenuItem(item))
        XCTAssertNil(item.toolTip)
        for mode in [ComposeMode.new, .forward(original)] {
            let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                           mode: mode)
            composer.window?.makeFirstResponder(composer.bodyEditor)
            XCTAssertFalse(composer.validateMenuItem(item), "\(mode) answers no one")
            XCTAssertEqual(item.toolTip, "Help Me Write works on replies")
        }
    }

    // MARK: The card

    func testOffOpensTheCardWithOpenSettings() throws {
        let (harness, script) = try harness(provider: nil)
        defer { harness.close() }
        var opened = 0
        harness.environment.helpMeWrite.openSettings = { opened += 1 }
        _ = type("Tuesday?", harness)
        let session = try openCard(harness)
        XCTAssertEqual(session.state, .off)
        XCTAssertEqual(session.card.messageLabel.stringValue, "Help Me Write is off")
        XCTAssertFalse(session.card.settingsButton.isHidden)
        session.card.settingsButton.performClick(nil)
        XCTAssertEqual(opened, 1, "Open Settings… opens Settings › AI")
        XCTAssertNil(harness.reader.writeSession, "and the card closes")
        XCTAssertTrue(script.requests.isEmpty)
    }

    func testTheCardNamesItsSourceAndRewritesASelection() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let field = type("Tuesday works for me", harness)
        let session = try openCard(harness)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.card.statusLabel.stringValue, "Claude Opus 5.5 · Anthropic")
        XCTAssertEqual(session.card.actionButton.title, "Write")
        XCTAssertEqual(session.card.field.textField.placeholderString ?? WriteCardView.placeholder, WriteCardView.placeholder)
        XCTAssertTrue(session.card.holdsFocus, "the instruction field takes the keyboard")
        XCTAssertTrue(harness.reader.quickReplyBar.isHeldOpen, "the bar stays open around its text")
        session.escape()
        XCTAssertNil(harness.reader.writeSession, "Esc closes the card")
        XCTAssertTrue(field.window?.firstResponder === field, "and the keyboard goes back to the reply")

        field.setSelectedRange(NSRange(location: 0, length: 7))
        let rewrite = try openCard(harness)
        XCTAssertEqual(rewrite.card.actionButton.title, "Rewrite")
        XCTAssertTrue(rewrite.card.statusLabel.stringValue.hasPrefix("Rewrite selection · "))
    }

    func testANeedsSetupHealthShowsItsWords() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        script.health = .needsSetup(reason: "Add your API key")
        _ = type("", harness)
        let session = try openCard(harness)
        XCTAssertTrue(ListTestSupport.spin(until: { session.state == .needsSetup(reason: "Add your API key") }, timeout: 3))
        XCTAssertEqual(session.card.messageLabel.stringValue, "Add your API key")
        XCTAssertFalse(session.card.settingsButton.isHidden)
    }

    // MARK: Consent

    func testConsentCancelSendsNothingAndKeepsTheCard() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        let shown = answerConsent(harness, with: 0)
        let field = type("Tuesday works", harness)
        let session = try openCard(harness)
        session.card.instruction = "Keep it short"
        session.write()
        let alert = try XCTUnwrap(shown().first)
        XCTAssertEqual(alert.title, "Send this conversation to Anthropic?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Allow"], "Cancel is the default: ↩ sends nothing")
        XCTAssertEqual(alert.escapeIndex, 0)
        XCTAssertTrue(alert.body.contains("Only when you use Help Me Write"))
        ListTestSupport.spin(for: 0.2)
        XCTAssertTrue(script.requests.isEmpty, "Cancel sends nothing")
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.card.instruction, "Keep it short")
        XCTAssertEqual(field.string, "Tuesday works")
        XCTAssertFalse(harness.settings.hasAIConsent(for: .claudeAPI, demo: false))
    }

    func testTheCLIsConsentSaysWhosePlanAndTheDemoSaysNothingLeaves() {
        XCTAssertTrue(AppAlert.helpMeWriteConsent(.claudeCode).body.hasSuffix("Through Claude Code, under your Claude plan\u{2019}s privacy settings."))
        XCTAssertTrue(AppAlert.helpMeWriteConsent(.codex).body.hasSuffix("Through Codex, under your OpenAI account\u{2019}s privacy settings."),
                      "Codex may be signed in with a key, not a ChatGPT plan")
        XCTAssertEqual(AppAlert.helpMeWriteConsent(.openAIAPI).title, "Send this conversation to OpenAI?")
        XCTAssertTrue(AppAlert.helpMeWriteConsent(.claudeAPI).body.contains("Addresses from the conversation, attachments and other mail never do."),
                      "the user's own notes go as typed: the promise is about the conversation's addresses")
        let demo = AppAlert.helpMeWriteConsent(.claudeAPI, demo: true)
        XCTAssertEqual(demo.title, "Try Help Me Write?")
        XCTAssertEqual(demo.body, "In the demo, replies are made up on this Mac. Nothing is sent.")
        XCTAssertFalse(demo.body.contains("Anthropic"), "no company is named where nothing goes to one")
        XCTAssertEqual(demo.buttons.map(\.title), ["Cancel", "Allow"])
        XCTAssertTrue(AppAlert.specimens.contains { $0.title == "Send this conversation to Anthropic?" })
        XCTAssertTrue(AppAlert.specimens.contains { $0.title == "Try Help Me Write?" })
    }

    func testTheDemoNeverCreditsMadeUpTextToAModel() throws {
        let demo = HelpMeWrite.demo(isDemo: true)
        for kind in AIProviderKind.selectable {
            XCTAssertEqual(demo.sourceLine(for: AIProviderConfiguration(kind: kind)), "Demo \u{00b7} made up on this Mac", "\(kind)")
            XCTAssertEqual(demo.consentAlert(for: kind).title, "Try Help Me Write?")
        }
        // With --live-ai-clis the demo's CLIs run for real: those say who writes, and where the conversation goes.
        let live = HelpMeWrite.demo(isDemo: true, liveCLIs: true)
        XCTAssertEqual(live.sourceLine(for: AIProviderConfiguration(kind: .claudeCode)), "Claude Code \u{00b7} Anthropic")
        XCTAssertEqual(live.consentAlert(for: .claudeCode).title, "Send this conversation to Anthropic?")
        XCTAssertEqual(live.sourceLine(for: AIProviderConfiguration(kind: .claudeAPI)), "Demo \u{00b7} made up on this Mac")
        let real = HelpMeWrite.demo(isDemo: false)
        XCTAssertEqual(real.sourceLine(for: AIProviderConfiguration(kind: .claudeAPI)), "Claude Opus 5.5 \u{00b7} Anthropic")

        let suite = "HelpMeWriteTests.demo.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        demo.settings = settings
        let model = AISettingsModel(settings: settings, center: demo)
        model.locateExecutable = { _, _ in nil }
        model.setProvider(.claudeAPI)
        XCTAssertEqual(model.caption, "In the demo, Help Me Write makes replies up on this Mac. Nothing is sent.")
        XCTAssertNil(settings.aiProvider, "a provider chosen in the demo is the demo's alone")
        XCTAssertEqual(settings.aiProvider(demo: true), .claudeAPI)
    }

    // MARK: Writing

    func testAllowWritesTheReplyAsOneUndoStep() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        let shown = answerConsent(harness, with: 1)
        let field = type("tue 10 ok", harness)
        let session = try openCard(harness)
        session.write()
        XCTAssertEqual(shown().count, 1)
        XCTAssertTrue(harness.settings.hasAIConsent(for: .claudeAPI, demo: false), "Allow is remembered for the provider")
        XCTAssertTrue(ListTestSupport.spin(until: { harness.reader.writeSession == nil }, timeout: 5), "the card closes when done")
        XCTAssertEqual(field.string, "Tuesday at ten works. See you then.")
        XCTAssertTrue(field.window?.firstResponder === field)

        let request = try XCTUnwrap(script.requests.first)
        XCTAssertTrue(request.task.contains("tue 10 ok"), "the typed text goes as the user's notes")
        XCTAssertFalse(request.userTurn.contains("@"), "no address is sent")

        let undo = try XCTUnwrap(field.undoManager)
        XCTAssertEqual(undo.undoMenuItemTitle, "Undo Help Me Write")
        undo.undo()
        XCTAssertEqual(field.string, "tue 10 ok", "one undo brings back exactly what was there")

        // The second time, no sheet.
        let again = try openCard(harness)
        again.write()
        XCTAssertTrue(ListTestSupport.spin(until: { harness.reader.writeSession == nil }, timeout: 5))
        XCTAssertEqual(shown().count, 1, "consent is asked once per provider")
    }

    func testWhileWritingTheFieldRefusesTypingAndEscPutsItBack() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight nine ten eleven twelve")
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        script.holdsAfter = 2
        let field = type("my notes", harness)
        let session = try openCard(harness)
        session.card.instruction = "friendlier"
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: { field.string == "One two three four " }, timeout: 5), "text streams into the field")
        XCTAssertEqual(session.state, .writing)
        XCTAssertEqual(session.card.actionButton.title, "Stop")
        XCTAssertTrue(session.card.statusLabel.stringValue.hasPrefix("Writing… · "))
        XCTAssertFalse(field.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x"), "typing waits")
        XCTAssertFalse(harness.reader.validateMenuItem(helpMeWriteItem()))
        XCTAssertTrue(WriteSession.isStreaming(in: field.window))

        // Esc in the field is claimed first: the write stops and the field comes back as it was.
        field.window?.makeFirstResponder(field)
        field.cancelOperation(nil)
        XCTAssertEqual(field.string, "my notes")
        XCTAssertEqual(session.state, .idle, "the card stays")
        XCTAssertEqual(session.card.instruction, "friendlier", "with the instruction kept")
        XCTAssertFalse(WriteSession.isStreaming(in: field.window))
        XCTAssertTrue(field.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "x"))
        XCTAssertNotEqual(field.undoManager?.undoMenuItemTitle, "Undo Help Me Write", "a stopped write leaves no undo step")
    }

    func testAFailurePutsTheFieldBackAndSaysWhy() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        script.failure = .keyRefused
        script.failsAfter = 2
        let field = type("my notes", harness)
        let session = try openCard(harness)
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: {
            if case .failed = session.state { return true } else { return false }
        }, timeout: 5))
        XCTAssertEqual(field.string, "my notes")
        XCTAssertEqual(session.state, .failed(reason: "The Anthropic API key was refused", offersSettings: true))
        XCTAssertTrue(session.card.statusLabel.stringValue.hasPrefix("Couldn\u{2019}t write"))
        XCTAssertFalse(session.card.tryAgainLink.isHidden)
        XCTAssertFalse(session.card.settingsLink.isHidden, "the fix is in Settings › AI")
        XCTAssertFalse(session.card.accessibilityWords.contains("my notes"), "no words from the field in the failure")

        // Try Again writes again.
        script.failure = nil
        session.card.tryAgainLink.performClick(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { harness.reader.writeSession == nil }, timeout: 5))
        XCTAssertEqual(field.string, "Tuesday at ten works. See you then.")
    }

    func testARewriteReplacesOnlyTheSelection() throws {
        let (harness, _) = try harness(reply: "Thursday")
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        let field = type("See you Tuesday, Ben", harness)
        field.setSelectedRange(NSRange(location: 8, length: 7))
        let session = try openCard(harness)
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: { harness.reader.writeSession == nil }, timeout: 5))
        XCTAssertEqual(field.string, "See you Thursday, Ben")
    }

    func testAnotherConversationClosesTheCardAndPutsTheFieldBack() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        script.holdsAfter = 1
        let field = type("notes for thread two", harness)
        let session = try openCard(harness)
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: { field.string != "notes for thread two" }, timeout: 5))
        let other = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-4" }?.id)
        harness.list.selectedConversationID = other
        harness.list.onSelectionChange?(other)
        XCTAssertNil(harness.reader.writeSession)
        XCTAssertFalse(WriteSession.isStreaming(in: harness.controller.window))
        let thread2 = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = thread2
        harness.list.onSelectionChange?(thread2)
        harness.spin { harness.reader.quickReplyBar.text == "notes for thread two" }
        XCTAssertEqual(harness.reader.quickReplyBar.text, "notes for thread two", "the notes were parked as typed")
    }

    func testAReplyComposerWritesAboveItsSignatureAndUndoesInOneStep() throws {
        let (harness, _) = try harness(reply: "Thanks, I'll read it tonight.")
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        try harness.environment.store.setSignature("<p>Alex</p>", for: ListTestSupport.accountA.id)
        harness.controller.refreshAccounts()
        let accounts = harness.controller.accounts
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2")
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: .reply(original, all: false))
        let editor = composer.bodyEditor
        composer.window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("will read", replacementRange: editor.selectedRange())
        let before = composer.bodyText
        XCTAssertTrue(before.hasSuffix("Alex"), "the signature sits below what was typed")

        composer.helpMeWrite(nil)
        let session = try XCTUnwrap(composer.writeSession)
        XCTAssertTrue(session.card.isDescendant(of: composer.content))
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: { composer.writeSession == nil }, timeout: 5))
        XCTAssertEqual(composer.bodyText, "Thanks, I'll read it tonight.\n\nAlex", "the reply replaces the notes and keeps the signature")
        MainWindowHarness.assertWritingStyle(composer.contents.body)
        XCTAssertEqual(editor.undoManager?.undoMenuItemTitle, "Undo Help Me Write")
        editor.undoManager?.undo()
        XCTAssertEqual(composer.bodyText, before)
    }

    func testEscInAComposerStopsTheWriteBeforeItCanClose() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        script.holdsAfter = 1
        let accounts = harness.controller.accounts
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2")
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: .reply(original, all: false))
        composer.window?.makeFirstResponder(composer.bodyEditor)
        composer.helpMeWrite(nil)
        let session = try XCTUnwrap(composer.writeSession)
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: { !composer.bodyText.isEmpty }, timeout: 5))
        composer.escapeComposer(nil)
        XCTAssertEqual(composer.bodyText, "", "the body is back as it was")
        XCTAssertTrue(composer.window?.isVisible ?? false, "and Esc did not close the composer")
        XCTAssertEqual(session.state, .idle)
    }

    func testClosingAComposerMidWriteKeepsWhatTheUserWrote() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        script.holdsAfter = 2
        let accounts = harness.controller.accounts
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2")
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: .reply(original, all: false))
        let editor = composer.bodyEditor
        composer.window?.makeFirstResponder(editor)
        editor.insertText("will read tonight", replacementRange: NSRange(location: 0, length: 0))
        composer.helpMeWrite(nil)
        try XCTUnwrap(composer.writeSession).write()
        XCTAssertTrue(ListTestSupport.spin(until: { composer.bodyText.hasPrefix("Tuesday") }, timeout: 5))
        let draftID = composer.draftID
        composer.window?.performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        let kept = try XCTUnwrap(ComposeDraftStore.shared.draft(id: draftID, accounts: accounts))
        XCTAssertEqual(kept.body.string, "will read tonight", "the kept draft holds the user's words, not half a reply")
    }

    private func replyComposer(_ harness: MainWindowHarness) -> ComposeWindowController {
        let accounts = harness.controller.accounts
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2")
        return ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                               mode: .reply(original, all: false))
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
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        script.holdsAfter = 2
        let composer = replyComposer(harness)
        let editor = composer.bodyEditor
        composer.window?.makeFirstResponder(editor)
        editor.insertText("will read tonight", replacementRange: NSRange(location: 0, length: 0))
        composer.helpMeWrite(nil)
        let session = try XCTUnwrap(composer.writeSession)
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: { composer.bodyText.hasPrefix("One two three four") }, timeout: 5))

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
        XCTAssertEqual(session.state, .writing)
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
        XCTAssertTrue(ListTestSupport.spin(until: { undo != nil }, timeout: 3))
        try XCTUnwrap(undo).undo()
        let reopened = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first { $0 !== composer })
        XCTAssertTrue(reopened.bodyText.hasPrefix("will read tonight"), "Undo brings back the user's own words")
    }

    func testAComposerRewriteOfATripleClickedParagraphKeepsItsStyle() throws {
        let (harness, _) = try harness(reply: "Thursday suits me")
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        let composer = replyComposer(harness)
        let editor = composer.bodyEditor
        composer.window?.makeFirstResponder(editor)
        editor.insertText("Tuesday works\nSee you", replacementRange: NSRange(location: 0, length: 0))
        // The first line underlined, then triple-clicked: the paragraph with its line break.
        editor.setSelectedRange(NSRange(location: 0, length: 14))
        editor.textStorage?.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 14))
        editor.setSelectedRange(NSRange(location: 0, length: 14))
        composer.helpMeWrite(nil)
        try XCTUnwrap(composer.writeSession).write()
        XCTAssertTrue(ListTestSupport.spin(until: { composer.writeSession == nil }, timeout: 5))
        XCTAssertTrue(composer.bodyText.hasPrefix("Thursday suits me\nSee you"), composer.bodyText)
        let storage = try XCTUnwrap(editor.textStorage)
        XCTAssertEqual(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue,
                       "the rewrite keeps the selection's own style")
        XCTAssertNil(storage.attribute(.underlineStyle, at: 18, effectiveRange: nil), "and the next line stays as it was")
    }

    // MARK: The keyboard and the bar going out of sight

    func testTheWeekMidWriteClosesTheCardWithTheFieldPutBack() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        let (field, _) = try streaming("my notes", harness, script)
        _ = harness.controller.perform(.toggleWeek)
        XCTAssertFalse(harness.reader.isOnScreen)
        XCTAssertNil(harness.reader.writeSession, "the card closes with the bar out of sight")
        XCTAssertEqual(field.string, "my notes")
        XCTAssertFalse(WriteSession.isStreaming(in: field.window))
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(field.string, "my notes", "nothing streams into a field no one sees")
        XCTAssertFalse(field.window?.firstResponder === field, "and the keyboard is not in it")
    }

    func testAComposerTakingTheReplyMidWriteClosesTheCard() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        let (field, _) = try streaming("my notes", harness, script)
        let composer = replyComposer(harness)
        XCTAssertTrue(ListTestSupport.spin(until: { harness.reader.quickReplyBar.isComposerOpen }, timeout: 3))
        XCTAssertNil(harness.reader.writeSession, "the card closes as the bar gives the reply to the composer")
        XCTAssertEqual(field.string, "my notes")
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(field.string, "my notes", "nothing streams into the hidden field")
        XCTAssertFalse(field.window?.firstResponder === field)
        composer.closeWithoutSaving()
    }

    func testAWriteThatEndsAfterTheUserMovedOnLeavesTheKeyboardWhereTheyWent() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        script.delay = .milliseconds(100)
        let field = type("my notes", harness)
        let session = try openCard(harness)
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: { field.string.hasPrefix("One") }, timeout: 5))
        let window = try XCTUnwrap(field.window)
        window.makeFirstResponder(harness.list.tableView)
        XCTAssertTrue(ListTestSupport.spin(until: { harness.reader.writeSession == nil }, timeout: 5))
        XCTAssertEqual(field.string, "One two three four five six seven eight")
        XCTAssertTrue(window.firstResponder === harness.list.tableView, "J and K still go to the list")
    }

    func testAFailureAfterTheUserMovedOnLeavesTheKeyboardWhereTheyWent() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        script.delay = .milliseconds(100)
        script.failure = .timedOut
        script.failsAfter = 2
        let field = type("my notes", harness)
        let session = try openCard(harness)
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: { field.string.hasPrefix("One") }, timeout: 5))
        let window = try XCTUnwrap(field.window)
        window.makeFirstResponder(harness.list.tableView)
        XCTAssertTrue(ListTestSupport.spin(until: { session.state != .writing }, timeout: 5))
        XCTAssertEqual(field.string, "my notes")
        XCTAssertTrue(window.firstResponder === harness.list.tableView, "the card says why without taking the keyboard")
    }

    func testAWriteStillBuildingItsContextAsTheEnvironmentGoesSendsNothing() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        let field = type("my notes", harness)
        let session = try openCard(harness)
        session.write()
        // What `HelpMeWrite.shutdown` does first, before the context, built off the main thread, reaches the writer.
        harness.environment.helpMeWrite.writer.shutDown()
        XCTAssertTrue(ListTestSupport.spin(until: { session.state == .idle }, timeout: 3))
        ListTestSupport.spin(for: 0.3)
        XCTAssertTrue(script.requests.isEmpty, "nothing was asked once the environment went")
        XCTAssertEqual(field.string, "my notes")
        XCTAssertFalse(WriteSession.isStreaming(in: field.window))
    }

    func testAnAllowInTheMadeUpDemoNeverStandsForALiveCLISend() throws {
        let suite = "HelpMeWriteTests.live.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let plain = HelpMeWrite.demo(isDemo: true)
        plain.settings = settings
        XCTAssertEqual(plain.consentAlert(for: .claudeCode).title, "Try Help Me Write?")
        plain.recordConsent(for: .claudeCode)
        plain.recordConsent(for: .claudeAPI)
        XCTAssertTrue(plain.hasConsent(for: .claudeCode))

        let live = HelpMeWrite.demo(isDemo: true, liveCLIs: true)
        live.settings = settings
        XCTAssertFalse(live.hasConsent(for: .claudeCode), "“Nothing is sent” never allowed a send")
        XCTAssertEqual(live.consentAlert(for: .claudeCode).title, "Send this conversation to Anthropic?")
        XCTAssertTrue(live.hasConsent(for: .claudeAPI), "the demo writer still makes Claude's replies up: that Allow stands")
        live.recordConsent(for: .claudeCode)
        XCTAssertTrue(live.hasConsent(for: .claudeCode))
        XCTAssertFalse(settings.hasAIConsent(for: .claudeCode, demo: false), "and neither stands for real mail")
        XCTAssertTrue(AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).hasAIConsent(for: .claudeCode, demo: true, live: true),
                      "kept")
        settings.setAIConsent(false, for: .claudeCode, demo: true, live: true)
        XCTAssertFalse(live.hasConsent(for: .claudeCode))
        XCTAssertTrue(plain.hasConsent(for: .claudeCode), "forgetting one leaves the other")
    }

    // MARK: Nothing else takes or edits a reply streaming in

    private func pendingSends(_ harness: MainWindowHarness) -> [PendingSend] {
        (try? harness.environment.store.pendingSends()) ?? []
    }

    /// A write resting mid-reply in the quick reply, over `notes`.
    private func streaming(_ notes: String, _ harness: MainWindowHarness, _ script: DemoAIScript) throws -> (NSTextView, WriteSession) {
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        script.holdsAfter = 2
        let field = type(notes, harness)
        let session = try openCard(harness)
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: { field.string == "One two three four " }, timeout: 5))
        XCTAssertEqual(session.state, .writing)
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
        XCTAssertEqual(session.state, .writing)
        session.stop()
        XCTAssertEqual(field.string, "my notes")
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.sendControlsEnabled.options, true)
    }

    func testAComposerNeitherSendsNorSchedulesAHalfWrittenReply() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        script.holdsAfter = 2
        let accounts = harness.controller.accounts
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2")
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: .reply(original, all: false))
        composer.window?.makeFirstResponder(composer.bodyEditor)
        let send = NSMenuItem(title: "Send", action: #selector(ComposeWindowController.send(_:)), keyEquivalent: "\r")
        let sendAndArchive = NSMenuItem(title: "Send and Archive", action: #selector(ComposeWindowController.sendAndArchive(_:)),
                                        keyEquivalent: "\r")
        let sendLater = NSMenuItem(title: "Send Later…", action: #selector(ComposeWindowController.sendLater(_:)), keyEquivalent: "l")
        XCTAssertTrue(ListTestSupport.spin(until: { composer.validateMenuItem(send) }, timeout: 3),
                      "a reply with its recipient can be sent")
        composer.helpMeWrite(nil)
        let session = try XCTUnwrap(composer.writeSession)
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: { composer.bodyText.hasPrefix("One two three four") }, timeout: 5))
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
        XCTAssertEqual(session.state, .writing)
        session.stop()
        XCTAssertTrue(composer.validateMenuItem(send))
        XCTAssertTrue(composer.content.bottomBar.sendButton.isEnabled)
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
        XCTAssertNil(harness.reader.writeSession, "the write stops and its card closes first")
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
        XCTAssertNil(harness.reader.writeSession)
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
        XCTAssertTrue(ListTestSupport.spin(until: { session.state == .idle }, timeout: 3), "as quitting or leaving the demo stops it")
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
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        let field = type("Tuesday works for me.\nSee you then.", harness)
        // A triple-click selects the paragraph with its line break.
        field.setSelectedRange(NSRange(location: 0, length: 22))
        let session = try openCard(harness)
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: { harness.reader.writeSession == nil }, timeout: 5))
        XCTAssertEqual(field.string, "Thursday suits me.\nSee you then.")
        let request = try XCTUnwrap(script.requests.first)
        XCTAssertTrue(request.task.contains("Tuesday works for me."))
        field.undoManager?.undo()
        XCTAssertEqual(field.string, "Tuesday works for me.\nSee you then.")
    }

    func testASelectionLongerThanWhatIsSentIsRefusedWhole() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        let long = String(repeating: "word ", count: 1_700) + "end"
        let field = type(long, harness)
        field.setSelectedRange(NSRange(location: 0, length: (long as NSString).length))
        let session = try openCard(harness)
        session.write()
        XCTAssertEqual(session.state, .failed(reason: "The selection is too long to rewrite. Select less, then try again.",
                                              offersSettings: false))
        ListTestSupport.spin(for: 0.2)
        XCTAssertTrue(script.requests.isEmpty, "nothing is sent, rather than a cut part the reply would replace whole")
        XCTAssertEqual(field.string, long)

        field.setSelectedRange(NSRange(location: (long as NSString).length, length: 0))
        let notes = try openCard(harness)
        notes.write()
        XCTAssertEqual(notes.state, .failed(reason: "Your draft is too long to send as notes. Shorten it, or select a part to rewrite.",
                                            offersSettings: false))
        XCTAssertTrue(script.requests.isEmpty)
    }

    func testUndoBringsBackTheTextWithItsAttributes() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        let field = type("tue 10 ok", harness)
        let before = NSAttributedString(attributedString: field.attributedString())
        let session = try openCard(harness)
        session.write()
        XCTAssertTrue(ListTestSupport.spin(until: { harness.reader.writeSession == nil }, timeout: 5))
        XCTAssertEqual(field.selectedRange(), NSRange(location: (field.string as NSString).length, length: 0), "the caret after the reply")
        field.undoManager?.undo()
        XCTAssertEqual(field.attributedString(), before, "the text and every attribute, as they were")
        XCTAssertLessThanOrEqual(NSMaxRange(field.selectedRange()), (field.string as NSString).length)
        field.undoManager?.redo()
        XCTAssertEqual(field.string, "Tuesday at ten works. See you then.", "and Redo brings the reply back")
    }

    // MARK: Needs setup while typing

    func testNeedsSetupFoundWhileTypingKeepsTheKeysOutOfTheReply() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        script.health = .needsSetup(reason: "Add your API key")
        let field = type("my notes", harness)
        let session = try openCard(harness)
        XCTAssertTrue(session.card.holdsFocus, "the instruction field has the keyboard while the check runs")
        XCTAssertTrue(ListTestSupport.spin(until: { session.state == .needsSetup(reason: "Add your API key") }, timeout: 3))
        let window = try XCTUnwrap(field.window)
        XCTAssertTrue(window.firstResponder === session.card, "the keyboard stays on the card, not the reply")
        XCTAssertTrue(KeyboardRouter.isTextInput(window.firstResponder), "so a key is not a command either")
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "e",
                                                 charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
        session.card.keyDown(with: key)
        XCTAssertEqual(field.string, "my notes", "what was being typed never lands in the reply")
        session.escape()
        XCTAssertNil(harness.reader.writeSession)
        XCTAssertTrue(window.firstResponder === field, "Esc gives the keyboard back to the reply")
    }

    // MARK: The failure line

    func testTheFailureLinksAreEvenlySpacedAndAnswerTheirWholeFace() throws {
        let card = WriteCardView(frame: NSRect(x: 0, y: 0, width: Quire.Layout.WriteCard.width, height: 120))
        card.configure(state: .failed(reason: "The Anthropic API key was refused", offersSettings: true), isRewrite: false,
                       sourceLine: "Claude Opus 5.5 · Anthropic")
        card.frame.size = card.preferredSize
        card.layoutSubtreeIfNeeded()
        let pad = SyncLineActionButton.padX
        let tryAgain = card.tryAgainLink.alignmentRect(forFrame: card.tryAgainLink.frame)
        let settings = card.settingsLink.alignmentRect(forFrame: card.settingsLink.frame)
        for (link, face) in [(card.tryAgainLink, tryAgain), (card.settingsLink, settings)] {
            XCTAssertEqual(face.size, link.intrinsicContentSize, "placed by its visual rect")
            XCTAssertGreaterThanOrEqual(link.hitRect.height, Quire.Layout.Button.minHit, "a 24 pt target")
            XCTAssertTrue(link.hitRect.contains(NSPoint(x: link.faceRect.maxX - 1, y: link.faceRect.midY)),
                          "the label's last letters answer a click")
        }
        let statusEnd = card.statusLabel.frame.maxX - 2
        let space = ceil(QuireFont.attributedString(" ", role: .meta, color: .qInk3).size().width)
        XCTAssertEqual(tryAgain.minX + pad - statusEnd, space, accuracy: 0.5, "one space after the first dot")
        let dotStart = settings.minX + pad - space - ceil(QuireFont.attributedString("\u{00b7}", role: .meta, color: .qInk3).size().width)
        XCTAssertEqual(dotStart - (tryAgain.maxX - pad), space, accuracy: 0.5, "one space each side of the second dot")
    }

    // MARK: Breadcrumbs

    func testAWriteLeavesNamesFromTheCodeOnly() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        let previous = CrashReporting.breadcrumbSink
        var crumbs: [(String?, String?)] = []
        CrashReporting.breadcrumbSink = { crumb in
            MainActor.assumeIsolated { crumbs.append((crumb.category, crumb.message)) }
        }
        defer { CrashReporting.breadcrumbSink = previous }
        _ = type("tue 10 ok", harness)
        try openCard(harness).write()
        XCTAssertTrue(ListTestSupport.spin(until: { harness.reader.writeSession == nil }, timeout: 5))
        let ai = crumbs.filter { $0.0 == "ai" }.compactMap(\.1)
        XCTAssertEqual(ai, ["write started", "claudeAPI", "write finished", "claudeAPI"])
    }
}
