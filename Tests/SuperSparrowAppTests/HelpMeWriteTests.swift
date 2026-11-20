import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// Help me write in the app (spec §5.55): ⌘J applies to the quick reply and reply composers only, the card's states, the
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
        XCTAssertTrue(AppAlert.helpMeWriteConsent(.codex).body.contains("Through Codex, under your ChatGPT plan"))
        XCTAssertEqual(AppAlert.helpMeWriteConsent(.openAIAPI).title, "Send this conversation to OpenAI?")
        XCTAssertTrue(AppAlert.helpMeWriteConsent(.claudeAPI, demo: true).body.hasSuffix("nothing is sent."))
        XCTAssertTrue(AppAlert.specimens.contains { $0.title == "Send this conversation to Anthropic?" })
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
