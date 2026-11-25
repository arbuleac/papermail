import AppKit
import PaperCore
@testable import PaperDesign
import XCTest
@testable import PaperApp

/// Help me write in every composer (spec §5.56): a new message and the message above a forward, beside the replies
/// `HelpMeWriteTests` covers. ⌘J writes at once where there is something to write from and opens the prompt line where
/// there is nothing; the words, the chips and what is sent follow what is written; a new message's draft can bring its
/// subject, set as it lands in the draft's one undo step; and the bodies a composer did not write are never taken for
/// the user's notes. Every write goes to the demo writer: nothing here reaches the network, a CLI or the Keychain.
@MainActor
final class HelpMeWriteComposeTests: XCTestCase {
    private var folder: URL!
    /// Sheets something tried to show while writing: there must be none (§5.56).
    private var sheets: [AppAlert] = []
    private let a = ListTestSupport.accountA
    private let b = ListTestSupport.accountB
    private let priya = EmailAddress(name: "Priya Raman", address: "priya.raman@example.test")
    private let lunch = "Subject: Lunch on Thursday?\n\nHi Priya,\n\nAre you free for lunch on Thursday?"
    private let lunchBody = "Hi Priya,\n\nAre you free for lunch on Thursday?"

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperHelpMeWriteCompose-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder) }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers {
                if let sheet = composer.window?.attachedSheet { composer.window?.endSheet(sheet) }
                composer.closeWithoutSaving()
            }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
            QuireAccessibility.observer = nil
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Support

    /// A main window with `provider` chosen in Settings › AI and turned on for everything (`turnedOn`), the demo writer
    /// quick and answering `reply` (nil: its own canned draft). Any sheet the write path tried to show is recorded.
    private func harness(provider: AIProviderKind? = .claudeAPI, turnedOn: Bool = true, reply: String? = "Thursday at noon works.",
                         settings: AppSettings? = nil) throws -> (MainWindowHarness, DemoAIScript) {
        let harness = try MainWindowHarness(settings: settings)
        if settings == nil {
            harness.settings.aiProvider = provider
            if let provider, turnedOn { harness.settings.setAIConsent(true, for: provider, demo: false) }
        }
        harness.environment.helpMeWrite.presentAlert = { [weak self] alert, _, done in
            self?.sheets.append(alert)
            done(0)
        }
        let script = try XCTUnwrap(harness.environment.helpMeWrite.demoScript)
        script.delay = .milliseconds(1)
        script.reply = reply
        return (harness, script)
    }

    /// Settings as a version before 1.21 left them: Claude chosen and turned on past the sheet that asked about replies.
    private func settingsTurnedOnForRepliesOnly() throws -> AppSettings {
        let suite = "HelpMeWriteComposeTests.earlier.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("claudeAPI", forKey: "aiProvider")
        defaults.set(["claudeAPI"], forKey: "aiConsent")
        return AppSettings(defaults: defaults)
    }

    private func present(_ mode: ComposeMode, _ harness: MainWindowHarness, from account: Int = 0) -> ComposeWindowController {
        let accounts = harness.controller.accounts
        return ComposeWindowController.present(client: harness.environment.engine, account: accounts[account], accounts: accounts, mode: mode)
    }

    /// A new message from account A (Gmail), or B (Microsoft) with `from: 1`, opened by a link so it can name
    /// several recipients.
    private func newMessage(_ harness: MainWindowHarness, link: MailtoLink = MailtoLink(), from account: Int = 0) -> ComposeWindowController {
        let accounts = harness.controller.accounts
        if link == MailtoLink() { return present(.new, harness, from: account) }
        return ComposeWindowController.present(client: harness.environment.engine, account: accounts[account], accounts: accounts, link: link)
    }

    private func saveBody(_ text: String, for message: String, _ harness: MainWindowHarness) throws {
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: "<p>\(text)</p>", text: text),
                                                          renderedHTML: "<p>\(text)</p>", plainText: text),
                                               for: MessageID(accountID: a.id, providerID: message))
    }

    /// A forward of thread-2's latest message (account A), every message of the thread stored with words of its own, so
    /// the quote folds in without the network and what is sent can be told apart.
    private func forward(_ harness: MainWindowHarness, text: String = "The venue is booked for the ninth. LATEST") throws -> ComposeWindowController {
        try saveBody("We looked at three venues last month. EARLIEST", for: "msg-2-0", harness)
        try saveBody("I would rather not say which I prefer. MINE", for: "msg-2-1", harness)
        try saveBody(text, for: "msg-2-2", harness)
        let composer = present(.forward(MessageID(accountID: a.id, providerID: "msg-2-2")), harness)
        XCTAssertTrue(ListTestSupport.spin(until: { composer.hasForwardedMessage }, timeout: 5), "the forwarded message folds in")
        return composer
    }

    /// A forward whose original is not in the store: nothing is quoted, and nothing will be.
    private func forwardWithoutItsOriginal(_ harness: MainWindowHarness) -> ComposeWindowController {
        let composer = present(.forward(MessageID(accountID: a.id, providerID: "gone")), harness)
        XCTAssertTrue(ListTestSupport.spin(until: { !composer.isLoadingForwardedMessage }, timeout: 5), "prefill ends")
        return composer
    }

    private func addressFields(in view: NSView?) -> [AddressTokenField] {
        guard let view else { return [] }
        if let field = view as? AddressTokenField { return [field] }
        return view.subviews.flatMap { addressFields(in: $0) }
    }

    /// Pastes a small picture at the caret in the body, as ⌘V would, from a pasteboard of its own (never the user's
    /// clipboard): its attachment character, U+FFFC, goes into the text.
    private func pastePicture(in composer: ComposeWindowController) {
        let board = NSPasteboard(name: NSPasteboard.Name("HelpMeWriteCompose-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        board.setData(picture?.representation(using: .png, properties: [:]), forType: .png)
        composer.bodyEditor.pasteboard = board
        composer.bodyEditor.paste(nil)
    }

    /// The body's session with the keyboard in the body, its marks drawn as in the key window (the test window never is).
    private func session(_ composer: ComposeWindowController) throws -> WriteSession {
        composer.window?.makeFirstResponder(composer.bodyEditor)
        let session = try XCTUnwrap(composer.bodyWriteSession)
        session.assumesKeyWindow = true
        return session
    }

    /// Types `text` at the top of the body, above any signature.
    private func type(_ text: String, in composer: ComposeWindowController) {
        composer.window?.makeFirstResponder(composer.bodyEditor)
        composer.bodyEditor.insertText(text, replacementRange: NSRange(location: 0, length: 0))
    }

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "j")
    }

    private var writeItem: NSMenuItem { item(#selector(ComposeWindowController.helpMeWrite(_:))) }
    private var instructionsItem: NSMenuItem { item(#selector(ComposeWindowController.helpMeWriteWithInstructions(_:))) }

    /// What Edit's two items read now in `composer`, nil where one does not apply.
    private func titles(_ composer: ComposeWindowController) -> [String?] {
        [writeItem, instructionsItem].map { composer.validateMenuItem($0) ? $0.title : nil }
    }

    /// ⌘J, as the menu sends it once it validates.
    private func commandJ(_ composer: ComposeWindowController, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(composer.validateMenuItem(writeItem), "⌘J applies", file: file, line: line)
        composer.helpMeWrite(nil)
    }

    /// ↩ in the prompt line, as its field sends it.
    @discardableResult
    private func pressReturn(in composer: ComposeWindowController) -> Bool {
        let prompt = composer.bodyWriteLayer.prompt
        let editor = prompt.field.currentEditor() as? NSTextView ?? NSTextView()
        return prompt.control(prompt.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    /// Says `words` in the open prompt line and presses ↩.
    private func say(_ words: String, in composer: ComposeWindowController) {
        composer.bodyWriteLayer.prompt.instruction = words
        pressReturn(in: composer)
    }

    /// ⌘J on the empty body, which opens the prompt line, then `words` and ↩: a new message from a brief.
    private func write(_ words: String, in composer: ComposeWindowController, file: StaticString = #filePath, line: UInt = #line) throws {
        let session = try session(composer)
        commandJ(composer, file: file, line: line)
        XCTAssertTrue(session.isPromptShown, "⌘J asks what to write", file: file, line: line)
        say(words, in: composer)
    }

    private func press(_ action: WriteAfterline.Action, in composer: ComposeWindowController) {
        let afterline = composer.bodyWriteLayer.afterline
        afterline.layoutSubtreeIfNeeded()
        afterline.actions[action]?.performClick(nil)
    }

    /// A request's task without its fence code, which is new for every request.
    private func task(_ request: AIWriteRequest) -> String {
        request.task.replacingOccurrences(of: " " + request.fence, with: "")
    }

    private func until(_ condition: () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ListTestSupport.spin(until: condition, timeout: 5), message, file: file, line: line)
    }

    /// The Subject field itself, to put the keyboard in it.
    private func subjectField(_ composer: ComposeWindowController) throws -> NSTextField {
        func views(in view: NSView?) -> [NSView] {
            guard let view else { return [] }
            return [view] + view.subviews.flatMap { views(in: $0) }
        }
        let row = try XCTUnwrap(views(in: composer.window?.contentView).compactMap { $0 as? ComposeFieldRow }.first { $0.title == "Subject" })
        return try XCTUnwrap(row.control as? NSTextField)
    }

    // MARK: Where ⌘J applies

    /// ⌘J and ⇧⌘J apply in every composer's body, whatever it writes, with nothing to say why not: the tooltip that
    /// sent the user to replies is gone. They apply nowhere else in the window: not in Subject, not in To.
    func testCommandJAppliesInEveryComposersBodyAndNowhereElse() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let original = MessageID(accountID: a.id, providerID: "msg-2-2")
        for mode in [ComposeMode.new, .reply(original, all: false), .forward(original)] {
            let composer = present(mode, harness)
            composer.window?.makeFirstResponder(composer.bodyEditor)
            for item in [writeItem, instructionsItem] {
                XCTAssertTrue(composer.validateMenuItem(item), "\(mode): it applies in the body")
                XCTAssertNil(item.toolTip, "\(mode): no tooltip")
                XCTAssertNotEqual(item.toolTip, "Help Me Write works on replies")
            }
            composer.window?.makeFirstResponder(try subjectField(composer))
            let inSubject = writeItem
            XCTAssertFalse(composer.validateMenuItem(inSubject), "\(mode): not from Subject")
            XCTAssertEqual(inSubject.title, "Help Me Write", "under its own name")
            XCTAssertNil(inSubject.toolTip)
            composer.helpMeWrite(nil)
            composer.helpMeWriteWithInstructions(nil)
            XCTAssertNotEqual(composer.writeSession?.isWriting, true, "\(mode): and nothing is written from there")
            XCTAssertNotEqual(composer.writeSession?.isPromptShown, true)
            composer.closeWithoutSaving()
        }
    }

    // MARK: The one rule for ⌘J

    /// An empty new message has nothing to write from, so ⌘J asks what to write: the prompt line opens, the capsule
    /// alone with no chips, and nothing is sent. ↩ and ⌘J on the empty line send nothing either and leave it open with
    /// the keyboard in it, whether or not a subject is typed: a subject is no brief. Words in the line are one.
    func testCommandJOnAnEmptyNewMessageAsksWhatToWriteAndSendsNothing() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let composer = newMessage(harness, link: MailtoLink(to: [priya]))
        let session = try session(composer)
        let layer = composer.bodyWriteLayer
        let editor = composer.bodyEditor
        XCTAssertEqual(session.plan, .askWhat)
        XCTAssertEqual(layer.state.ghost?.words, "to say what to write", "the ghost says what ⌘J does here")
        XCTAssertEqual(layer.ghost.accessibilityHelp(), "Command J to say what to write")
        XCTAssertEqual(titles(composer), ["Write Message\u{2026}", "Write Message with Instructions\u{2026}"])
        XCTAssertEqual(session.contextMenuItems().prefix(2).map(\.title), ["Write Message\u{2026}", "Say How\u{2026}"])

        let height = editor.intrinsicContentSize.height
        commandJ(composer)
        XCTAssertTrue(session.isPromptShown, "⌘J opens the prompt line")
        XCTAssertEqual(session.phase, .idle, "and writes nothing")
        let prompt = layer.prompt
        XCTAssertTrue(prompt.fieldHoldsFocus, "the keyboard is in the line")
        XCTAssertEqual(prompt.placeholder, "Tell Claude what to write\u{2026}")
        XCTAssertTrue(prompt.chips.isEmpty, "no chips: there is nothing yet for one to work on")
        XCTAssertEqual(layer.state.block, .prompt(.caret(0), chips: false))
        XCTAssertEqual(editor.intrinsicContentSize.height - height, WritePromptLine.blockHeight(chips: false), accuracy: 0.5,
                       "the body grows by the capsule alone")
        XCTAssertEqual(WritePromptLine.blockHeight - WritePromptLine.blockHeight(chips: false),
                       Quire.Layout.WriteCaret.chipsGap + Quire.Layout.WriteCaret.chipHeight, accuracy: 0.01, "less the chips' row")

        // Tab and ↓ have nowhere to go in a line without chips: they do nothing, rather than leave it and close it.
        let field = try XCTUnwrap(prompt.field.currentEditor() as? NSTextView)
        for key in [#selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveDown(_:))] {
            XCTAssertTrue(prompt.control(prompt.field, textView: field, doCommandBy: key), "the key is taken")
            XCTAssertTrue(prompt.fieldHoldsFocus)
            XCTAssertTrue(session.isPromptShown)
        }

        for subject in ["", "Q3 budget"] {
            composer.setSubjectText(subject)
            for words in ["", "   "] {
                prompt.instruction = words
                XCTAssertTrue(pressReturn(in: composer))
                XCTAssertTrue(session.isPromptShown, "↩ with nothing said leaves the line open (subject “\(subject)”)")
                commandJ(composer)
                XCTAssertTrue(session.isPromptShown, "and so does ⌘J")
                XCTAssertTrue(prompt.fieldHoldsFocus, "the keyboard still in it")
                XCTAssertEqual(session.phase, .idle, "no failure line")
                XCTAssertTrue(layer.afterline.isHidden)
            }
        }
        ListTestSupport.spin(for: 0.2)
        XCTAssertTrue(script.requests.isEmpty, "nothing was sent")
        XCTAssertEqual(composer.bodyText, "")
        XCTAssertEqual(composer.subjectText, "Q3 budget", "a typed subject is left alone")

        composer.setSubjectText("")
        say("ask Priya to lunch on Thursday", in: composer)
        XCTAssertFalse(session.isPromptShown, "words run: the line closes")
        until({ session.phase == .written }, "the message lands")
        XCTAssertEqual(composer.bodyText, lunchBody)
        XCTAssertEqual(script.requests.count, 1)
        let request = try XCTUnwrap(script.requests.first)
        XCTAssertEqual(request.kind, .newMessage)
        XCTAssertEqual(request.promptVersion, "write-new-1")
        XCTAssertEqual(request.task, "Write my message from this brief:\nask Priya to lunch on Thursday")
        XCTAssertTrue(sheets.isEmpty)
    }

    /// A picture holds no words. A new message whose body is pictures alone has nothing to write from: its ghost says
    /// what ⌘J does there, ⌘J opens the prompt line and sends nothing, and a selection of the picture alone is none. The
    /// draft written from what is said there goes above the picture, an empty line between, and the picture stays; ⌘Z
    /// takes the draft back and leaves the picture. Words beside a picture are notes, whose place the draft takes, the
    /// picture kept after it; an invisible mark beside one is no word. A forward of pictures alone is written from its
    /// forwarded message, above them too.
    func testABodyOfPicturesAloneIsNothingToWriteFromAndKeepsItsPicture() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let composer = newMessage(harness, link: MailtoLink(to: [priya]))
        let session = try session(composer)
        pastePicture(in: composer)
        XCTAssertEqual(composer.bodyText, "\u{FFFC}")
        session.refresh()
        XCTAssertEqual(session.plan, .askWhat, "a picture is no brief")
        XCTAssertEqual(composer.bodyWriteLayer.state.ghost?.words, "to say what to write")
        XCTAssertEqual(titles(composer).first, "Write Message\u{2026}")
        composer.bodyEditor.setSelectedRange(NSRange(location: 0, length: 1))
        session.selectionDidChange()
        XCTAssertNil(composer.bodyWriteLayer.state.pill, "a selection of the picture alone is none")
        XCTAssertEqual(session.plan, .askWhat)
        composer.bodyEditor.setSelectedRange(NSRange(location: 1, length: 0))

        commandJ(composer)
        XCTAssertTrue(session.isPromptShown, "⌘J asks what to write")
        pressReturn(in: composer)
        ListTestSupport.spin(for: 0.1)
        XCTAssertTrue(session.isPromptShown)
        XCTAssertEqual(script.requests.count, 0, "nothing is sent for a picture and a name")

        say("ask Priya for the Q3 numbers in the chart", in: composer)
        until({ session.phase == .written })
        let request = try XCTUnwrap(script.requests.last)
        XCTAssertEqual(task(request), "Write my message from this brief:\nask Priya for the Q3 numbers in the chart")
        XCTAssertFalse(request.userTurn.contains("\u{FFFC}"))
        XCTAssertTrue(request.wantsSubject)
        XCTAssertEqual(composer.bodyText, lunchBody + "\n\n\u{FFFC}", "the draft above the picture, which stays")
        XCTAssertEqual(ComposeInlineImages.pictures(in: composer.contents.body).count, 1)
        XCTAssertEqual(composer.subjectText, "Lunch on Thursday?")
        guard case .afterline(.end(let end), .written)? = composer.bodyWriteLayer.state.block else {
            return XCTFail("the afterline under the draft")
        }
        XCTAssertEqual(end, (lunchBody as NSString).length, "after its last word, not after the empty line")
        // Try again writes above the picture again.
        commandJ(composer)
        until({ session.phase == .written && script.requests.count == 2 })
        XCTAssertEqual(composer.bodyText, lunchBody + "\n\n\u{FFFC}")
        XCTAssertEqual(ComposeInlineImages.pictures(in: composer.contents.body).count, 1)
        composer.window?.undoManager?.undo()
        XCTAssertEqual(composer.bodyText, "\u{FFFC}", "⌘Z takes the draft back, the picture stays")
        XCTAssertEqual(composer.subjectText, "")

        // While a draft streams above the picture, the pencil waits after its last word; Stop leaves the picture alone.
        script.holdsAfter = 2
        commandJ(composer)
        XCTAssertEqual(composer.bodyWriteLayer.prompt.instruction, "ask Priya for the Q3 numbers in the chart", "the brief, kept")
        pressReturn(in: composer)
        until({ session.phase == .writing && composer.bodyText.hasPrefix("Hi Priya,\n\nAre ") })
        XCTAssertTrue(composer.bodyText.hasSuffix(" \n\n\u{FFFC}"), composer.bodyText.debugDescription)
        XCTAssertEqual(composer.bodyWriteLayer.state.pencil, (composer.bodyText as NSString).length - 3)
        session.stop()
        script.holdsAfter = nil
        XCTAssertEqual(composer.bodyText, "\u{FFFC}")

        // Words beside the picture are notes: sent without it, and the draft takes the words' place with the picture
        // after it, an empty line between (`testADraftOverNotesBesidePicturesKeepsEveryPicture`), one ⌘Z away.
        composer.bodyEditor.insertText("numbers below ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(session.plan, .fromNotes)
        let sent = script.requests.count
        commandJ(composer)
        until({ session.phase == .written && script.requests.count == sent + 1 })
        let notes = try XCTUnwrap(script.requests.last)
        XCTAssertTrue(notes.task.contains("numbers below"))
        XCTAssertFalse(notes.userTurn.contains("\u{FFFC}"))
        XCTAssertEqual(composer.bodyText, lunchBody + "\n\n\u{FFFC}", "the draft keeps the picture")
        XCTAssertEqual(ComposeInlineImages.pictures(in: composer.contents.body).count, 1)
        composer.window?.undoManager?.undo()
        XCTAssertEqual(composer.bodyText, "numbers below \u{FFFC}")
        XCTAssertEqual(ComposeInlineImages.pictures(in: composer.contents.body).count, 1)
        composer.closeWithoutSaving()

        // An invisible mark beside a picture (a byte-order mark a paste left, a right-to-left mark) is no word either,
        // as the request reads it: the ghost and the plan agree that there is nothing to write from, the draft goes
        // above the picture in the mark's place, and the instruction it was written from stays its brief.
        let brief = "ask Priya for the Q3 numbers in the chart"
        for mark in ["\u{FEFF}", "\u{200F}", "\u{2060}"] {
            let marked = newMessage(harness, link: MailtoLink(to: [priya]))
            let writing = try self.session(marked)
            marked.bodyEditor.insertText(mark, replacementRange: NSRange(location: 0, length: 0))
            pastePicture(in: marked)
            XCTAssertEqual(marked.bodyText, mark + "\u{FFFC}")
            writing.refresh()
            XCTAssertEqual(writing.plan, .askWhat, mark.debugDescription)
            XCTAssertEqual(marked.bodyWriteLayer.state.ghost?.words, "to say what to write", "the ghost says what ⌘J does")
            let before = script.requests.count
            commandJ(marked)
            XCTAssertTrue(writing.isPromptShown, "⌘J asks what to write")
            pressReturn(in: marked)
            ListTestSupport.spin(for: 0.1)
            XCTAssertEqual(script.requests.count, before, "nothing is sent for a mark, a picture and a name")
            say(brief, in: marked)
            until({ writing.phase == .written && script.requests.count == before + 1 })
            XCTAssertEqual(task(script.requests[before]), "Write my message from this brief:\n\(brief)")
            XCTAssertEqual(marked.bodyText, lunchBody + "\n\n\u{FFFC}", "above the picture, in the mark's place")
            XCTAssertEqual(ComposeInlineImages.pictures(in: marked.contents.body).count, 1)
            press(.shorter, in: marked)
            until({ writing.phase == .written && script.requests.count == before + 2 })
            XCTAssertTrue(script.requests[before + 1].task.contains(brief), "Shorter is asked on top of the brief")
            XCTAssertTrue(script.requests[before + 1].task.hasSuffix("Write my message from these notes. Shorter"))
            XCTAssertEqual(marked.bodyText, lunchBody + "\n\n\u{FFFC}")
            marked.window?.undoManager?.undo()
            XCTAssertEqual(marked.bodyText, mark + "\u{FFFC}")
            commandJ(marked)
            XCTAssertTrue(writing.isPromptShown)
            XCTAssertEqual(marked.bodyWriteLayer.prompt.instruction, brief, "after ⌘Z, ⌘J offers the brief again")
            marked.closeWithoutSaving()
        }

        // A forward of pictures alone writes from its forwarded message, above them.
        script.reply = "Hi Priya,\n\nForwarding the venue's note."
        let forwarding = try forward(harness)
        let writing = try self.session(forwarding)
        forwarding.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))
        pastePicture(in: forwarding)
        writing.refresh()
        let own = forwarding.bodyText
        XCTAssertTrue(own.hasPrefix("\u{FFFC}"))
        XCTAssertEqual(writing.plan, .fromContext)
        XCTAssertEqual(forwarding.bodyWriteLayer.state.ghost?.words, "to write a message")
        XCTAssertEqual(titles(forwarding).first, "Write Message")
        let before = script.requests.count
        commandJ(forwarding)
        until({ writing.phase == .written && script.requests.count == before + 1 })
        let forwarded = try XCTUnwrap(script.requests.last)
        XCTAssertEqual(forwarded.kind, .forward)
        XCTAssertFalse(forwarded.task.contains("NOTES"), "from the forwarded message alone")
        XCTAssertEqual(forwarding.bodyText, "Hi Priya,\n\nForwarding the venue's note.\n\n" + own)

        // A reply reads a picture as it always did: as notes, which its draft replaces whole.
        let reply = present(.reply(MessageID(accountID: a.id, providerID: "msg-2-2"), all: false), harness)
        let replying = try self.session(reply)
        reply.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))
        pastePicture(in: reply)
        XCTAssertEqual(replying.plan, .fromNotes)
        let replied = script.requests.count
        commandJ(reply)
        until({ replying.phase == .written && script.requests.count == replied + 1 })
        XCTAssertEqual(script.requests.last?.kind, .reply)
        XCTAssertTrue(ComposeInlineImages.pictures(in: reply.contents.body).isEmpty, "a reply's field is written over whole")
    }

    /// A draft of the whole message written over notes beside pictures never takes a picture away: the model never sees
    /// one, so the draft takes the words' place and the pictures follow it, an empty line between, in their order and
    /// as they were. ⌘Z puts the notes back with every picture where it was, ⇧⌘Z the draft with them; Try again and Stop
    /// keep them, and so does a draft written above a picture, edited, then written again.
    func testADraftOverNotesBesidePicturesKeepsEveryPicture() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let composer = newMessage(harness, link: MailtoLink(to: [priya]))
        let session = try session(composer)
        let editor = composer.bodyEditor
        let notes = "crash on login, see below"
        editor.insertText(notes + "\n\n", replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: (notes as NSString).length + 2, length: 0))
        pastePicture(in: composer)
        let body = notes + "\n\n\u{FFFC}"
        XCTAssertEqual(composer.bodyText, body)
        /// The pictures in a body, by content id, in order.
        func pictures(_ composer: ComposeWindowController) -> [String] {
            ComposeInlineImages.pictures(in: composer.contents.body).map(\.inlineImage.contentID)
        }
        let picture = pictures(composer)
        XCTAssertEqual(picture.count, 1)

        // ⇧⌘J and an instruction: the notes go without the picture, and the draft keeps it.
        composer.helpMeWriteWithInstructions(nil)
        XCTAssertTrue(session.isPromptShown)
        say("write this up for Ben", in: composer)
        until({ session.phase == .written && script.requests.count == 1 })
        let request = try XCTUnwrap(script.requests.first)
        XCTAssertTrue(request.task.contains(notes))
        XCTAssertTrue(request.task.hasSuffix("write this up for Ben"))
        XCTAssertFalse(request.userTurn.contains("\u{FFFC}"), "a picture is never sent")
        let drafted = lunchBody + "\n\n\u{FFFC}"
        XCTAssertEqual(composer.bodyText, drafted, "the draft in the notes' place, the picture after it")
        XCTAssertEqual(pictures(composer), picture, "the same picture, not a copy")
        XCTAssertEqual(composer.subjectText, "Lunch on Thursday?")
        guard case .afterline(.end(let end), .written)? = composer.bodyWriteLayer.state.block else {
            return XCTFail("the afterline under the draft")
        }
        XCTAssertEqual(end, (lunchBody as NSString).length, "after the draft's last word")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: (lunchBody as NSString).length, length: 0))

        // One step: ⌘Z brings the notes back with the picture where it was, ⇧⌘Z the draft with it.
        XCTAssertEqual(editor.undoManager?.undoMenuItemTitle, "Undo Help Me Write")
        editor.undoManager?.undo()
        XCTAssertEqual(composer.bodyText, body)
        XCTAssertEqual(pictures(composer), picture)
        XCTAssertEqual(composer.subjectText, "")
        editor.undoManager?.redo()
        XCTAssertEqual(composer.bodyText, drafted)
        XCTAssertEqual(pictures(composer), picture)

        // Try again writes from the same notes, and keeps the picture.
        commandJ(composer)
        until({ session.phase == .written && script.requests.count == 2 })
        XCTAssertEqual(task(script.requests[1]), task(request))
        XCTAssertEqual(composer.bodyText, drafted)
        XCTAssertEqual(pictures(composer), picture)

        // Stop mid-write: the field as it was before the write, picture and all. (Try again shows the draft it replaces
        // until the first words come.)
        script.holdsAfter = 2
        commandJ(composer)
        until({ session.phase == .writing && composer.bodyText != drafted && composer.bodyText.hasPrefix("Hi Priya,\n\nAre ") })
        XCTAssertTrue(composer.bodyText.hasSuffix(" \n\n\u{FFFC}"), composer.bodyText.debugDescription)
        XCTAssertEqual(pictures(composer), picture)
        session.stop()
        script.holdsAfter = nil
        XCTAssertEqual(composer.bodyText, body)
        XCTAssertEqual(pictures(composer), picture)
        composer.closeWithoutSaving()

        // Several pictures keep their order: two that stood apart with blanks between keep the blanks, two with words
        // between go on lines of their own, and two side by side stay so.
        let several = newMessage(harness, link: MailtoLink(to: [priya]))
        let writing = try self.session(several)
        for part in ["see ", "\u{FFFC}", " and ", "\u{FFFC}", "\u{FFFC}", "\n", "\u{FFFC}"] {
            if part == "\u{FFFC}" {
                pastePicture(in: several)
            } else {
                several.bodyEditor.insertText(part, replacementRange: several.bodyEditor.selectedRange())
            }
        }
        XCTAssertEqual(several.bodyText, "see \u{FFFC} and \u{FFFC}\u{FFFC}\n\u{FFFC}")
        let four = pictures(several)
        XCTAssertEqual(four.count, 4)
        XCTAssertEqual(writing.plan, .fromNotes)
        var sent = script.requests.count
        commandJ(several)
        until({ writing.phase == .written && script.requests.count == sent + 1 })
        XCTAssertEqual(several.bodyText, lunchBody + "\n\n\u{FFFC}\n\u{FFFC}\u{FFFC}\n\u{FFFC}")
        XCTAssertEqual(pictures(several), four)
        several.window?.undoManager?.undo()
        XCTAssertEqual(several.bodyText, "see \u{FFFC} and \u{FFFC}\u{FFFC}\n\u{FFFC}")
        XCTAssertEqual(pictures(several), four)
        several.closeWithoutSaving()

        // A draft written above a picture, then edited and written again from what it says now: the picture stays.
        let above = newMessage(harness, link: MailtoLink(to: [priya]))
        let again = try self.session(above)
        pastePicture(in: above)
        sent = script.requests.count
        try write("ask Priya for the Q3 numbers in the chart", in: above)
        until({ again.phase == .written && script.requests.count == sent + 1 })
        XCTAssertEqual(above.bodyText, lunchBody + "\n\n\u{FFFC}")
        let kept = pictures(above)
        let thursday = (above.bodyText as NSString).range(of: "Thursday")
        above.bodyEditor.insertText("Friday", replacementRange: thursday)
        XCTAssertEqual(again.plan, .fromNotes, "the edited draft is the user's notes now")
        sent = script.requests.count
        commandJ(above)
        until({ again.phase == .written && script.requests.count == sent + 1 })
        let edited = try XCTUnwrap(script.requests.last)
        XCTAssertTrue(edited.task.contains("lunch on Friday?"))
        XCTAssertFalse(edited.userTurn.contains("\u{FFFC}"))
        XCTAssertEqual(above.bodyText, lunchBody + "\n\n\u{FFFC}", "the picture the first draft kept, kept again")
        XCTAssertEqual(pictures(above), kept)
        above.closeWithoutSaving()

        // A forward's notes beside a picture: the same.
        script.reply = "Hi Priya,\n\nForwarding the venue's note."
        let forwarding = try forward(harness)
        let forwardWriting = try self.session(forwarding)
        forwarding.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))
        forwarding.bodyEditor.insertText("fyi ", replacementRange: NSRange(location: 0, length: 0))
        pastePicture(in: forwarding)
        XCTAssertTrue(forwarding.bodyText.hasPrefix("fyi \u{FFFC}"))
        XCTAssertEqual(forwardWriting.plan, .fromNotes)
        sent = script.requests.count
        commandJ(forwarding)
        until({ forwardWriting.phase == .written && script.requests.count == sent + 1 })
        XCTAssertEqual(script.requests.last?.kind, .forward)
        XCTAssertFalse(script.requests.last?.userTurn.contains("\u{FFFC}") ?? true)
        XCTAssertTrue(forwarding.bodyText.hasPrefix("Hi Priya,\n\nForwarding the venue's note.\n\n\u{FFFC}"),
                      forwarding.bodyText.debugDescription)
        XCTAssertEqual(ComposeInlineImages.pictures(in: forwarding.contents.body).count, 1)
    }

    /// The session reads a new message's or a forward's body as the request would: it holds words exactly where notes
    /// of that text are something to write from (`WriteKind.hasNothingToWriteFrom`), so blanks, pictures and invisible
    /// marks alone are none, and the set it searches the text with finds a word exactly then. A reply's field reads a
    /// picture and a mark as it always did.
    func testTheSessionReadsABodyAsItsRequestWould() {
        let samples = ["", " \n\t", "\u{FFFC}", "\u{FFFC} \u{FFFC}", "\u{FEFF}\u{FFFC}", "\u{200F}\u{FFFC}\u{200F}", "\u{00AD}",
                       "\u{2060}", "\u{200B}", "\u{FFFC}\u{FE0F}", "\u{E0041}\u{FFFC}", "a", "\u{FFFC}b", "lunch\u{FEFF}",
                       "\u{0301}", "\u{1F642}", "\u{05E9}\u{200F}"]
        for text in samples {
            let holds = WriteSession.holdsWords(text, writing: .newMessage)
            XCTAssertEqual(holds, !WriteKind.newMessage.hasNothingToWriteFrom(WriteAsk(draft: .notes(text))), text.debugDescription)
            let found = (text as NSString).rangeOfCharacter(from: WriteSession.words(writing: .newMessage)).location != NSNotFound
            XCTAssertEqual(found, holds, text.debugDescription)
            XCTAssertEqual(WriteSession.holdsWords(text, writing: .forward), holds, text.debugDescription)
        }
        for text in ["\u{FFFC}", "\u{FEFF}", "\u{200F}", "\u{FFFC}\u{FE0F}"] {
            XCTAssertTrue(WriteSession.holdsWords(text, writing: .reply), text.debugDescription)
        }
        XCTAssertFalse(WriteSession.holdsWords(" \n", writing: .reply))
    }

    /// Esc with the prompt line open on an empty new message closes the line and gives the keyboard back to the body,
    /// the words said in it kept for the next time; a second Esc closes a window that holds nothing worth keeping. The
    /// words were never part of the message: nothing is sent, and no draft is kept for them.
    func testEscClosesTheLineThenTheEmptyWindow() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        let composer = newMessage(harness)
        let session = try session(composer)
        let draftID = composer.draftID
        commandJ(composer)
        let prompt = composer.bodyWriteLayer.prompt
        prompt.instruction = "ask Priya to lunch"
        composer.escapeComposer(nil)
        XCTAssertFalse(session.isPromptShown, "Esc closes the line")
        XCTAssertTrue(composer.window?.firstResponder === composer.bodyEditor, "the keyboard is back in the body")
        XCTAssertTrue(composer.window?.isVisible ?? false, "and the window stays")
        commandJ(composer)
        XCTAssertEqual(prompt.instruction, "ask Priya to lunch", "⌘J again finds the words still in the line")
        composer.escapeComposer(nil)
        composer.escapeComposer(nil)
        XCTAssertFalse(composer.window?.isVisible ?? true, "a second Esc closes a window with nothing worth keeping")
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertNil(ComposeDraftStore.shared.draft(id: draftID, accounts: harness.controller.accounts), "no draft is kept")
        XCTAssertTrue(script.requests.isEmpty, "nothing was sent")
    }

    /// Where Help me write cannot write (off, never turned on, turned on for replies only, needing setup), ⌘J on an
    /// empty new message says why under the caret's line, as on a reply, and opens no prompt line.
    func testWhereItCannotWriteCommandJSaysWhyAndOpensNoLine() throws {
        let earlier = try settingsTurnedOnForRepliesOnly()
        let cases: [(String, AIProviderKind?, Bool, AppSettings?, String?)] = [
            ("Help Me Write is off", nil, false, nil, nil),
            ("Turn it on in Settings \u{203a} AI", .claudeAPI, false, nil, nil),
            ("Help Me Write is on for replies only", .claudeAPI, true, earlier, nil),
            ("Add your API key", .claudeAPI, true, nil, "Add your API key"),
        ]
        for (reason, provider, turnedOn, settings, setup) in cases {
            let (harness, script) = try harness(provider: provider, turnedOn: turnedOn, settings: settings)
            defer { harness.close() }
            if let setup { script.health = .needsSetup(reason: setup) }
            let composer = newMessage(harness)
            let session = try session(composer)
            XCTAssertNil(composer.bodyWriteLayer.state.ghost, "\(reason): no ghost")
            commandJ(composer)
            XCTAssertEqual(session.phase, .failed(reason: reason, offersSettings: true), "the reason, under the caret's line")
            XCTAssertFalse(session.isPromptShown, "\(reason): and no prompt line")
            // With notes it says the same, and still sends nothing.
            XCTAssertTrue(session.escape())
            type("lunch thursday at noon", in: composer)
            commandJ(composer)
            XCTAssertEqual(session.phase, .failed(reason: reason, offersSettings: true))
            ListTestSupport.spin(for: 0.1)
            XCTAssertTrue(script.requests.isEmpty, "\(reason): nothing is sent")
            XCTAssertEqual(composer.bodyText, "lunch thursday at noon")
            composer.closeWithoutSaving()
        }
        XCTAssertTrue(sheets.isEmpty, "no sheet asks in the text")
    }

    /// Something to write from: notes (one word is enough), a selection, a draft just written. With notes ⌘J writes
    /// at once, ⇧⌘J's line has its chips, and an empty ↩ there writes from the notes. Right after a draft ⌘J tries
    /// again, never the prompt line, though the body it was written from was empty.
    func testWithSomethingToWriteFromCommandJWritesAtOnce() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        try harness.environment.store.setSignature("<p>Alex</p>", for: a.id)
        harness.controller.refreshAccounts()
        let composer = newMessage(harness)
        let session = try session(composer)
        let layer = composer.bodyWriteLayer
        XCTAssertEqual(composer.bodyText, "\n\nAlex")
        XCTAssertEqual(session.plan, .askWhat, "a body holding only its signature is empty")
        // Text only below the signature is not notes either.
        composer.bodyEditor.insertText("ps", replacementRange: NSRange(location: (composer.bodyText as NSString).length, length: 0))
        XCTAssertEqual(session.plan, .askWhat)
        composer.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))

        type("lunch", in: composer)
        XCTAssertEqual(session.plan, .fromNotes, "one word is notes")
        XCTAssertEqual(titles(composer), ["Write Message from Notes", "Write Message with Instructions\u{2026}"])
        composer.helpMeWriteWithInstructions(nil)
        XCTAssertEqual(layer.prompt.chips.map(\.title), ["Shorter", "Friendlier", "More formal"], "with notes a chip can run")
        XCTAssertEqual(layer.state.block, .prompt(.caret(5), chips: true))
        XCTAssertTrue(pressReturn(in: composer))
        XCTAssertFalse(session.isPromptShown, "an empty ↩ writes from the notes")
        until({ session.phase == .written })
        XCTAssertEqual(composer.bodyText, "Thursday at noon works.\n\nAlexps")
        XCTAssertTrue(script.requests[0].task.hasSuffix("Write my message from these notes."))
        XCTAssertTrue(script.requests[0].task.contains("lunch"))
        XCTAssertFalse(script.requests[0].task.contains("Alex"), "the signature is not notes")

        XCTAssertEqual(session.plan, .tryAgain)
        XCTAssertEqual(titles(composer).first, "Try Again")
        commandJ(composer)
        XCTAssertFalse(session.isPromptShown)
        until({ script.requests.count == 2 && session.phase == .written }, "⌘J tries again")
        XCTAssertEqual(task(script.requests[1]), task(script.requests[0]))

        composer.bodyEditor.setSelectedRange(NSRange(location: 0, length: 8))
        XCTAssertEqual(titles(composer), ["Rewrite Selection", "Rewrite Selection with Instructions\u{2026}"])
        commandJ(composer)
        until({ script.requests.count == 3 && session.phase == .written }, "a selection is rewritten")
        XCTAssertTrue(script.requests[2].isRewrite)
    }

    // MARK: Words

    /// Ghosts, menu titles and chips say what is written: a reply as it always did, a message in a new message and a
    /// forward. A ghost that begins “to write” writes at once; one that begins “to say” opens the line.
    func testTheWordsFollowWhatIsWritten() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let original = MessageID(accountID: a.id, providerID: "msg-2-2")

        let reply = present(.reply(original, all: false), harness)
        let replying = try session(reply)
        reply.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(reply.bodyWriteLayer.state.ghost?.words, "to write a reply")
        XCTAssertEqual(titles(reply), ["Write Reply", "Write Reply with Instructions\u{2026}"])
        reply.helpMeWriteWithInstructions(nil)
        XCTAssertEqual(reply.bodyWriteLayer.prompt.chips.map(\.title), ["Shorter", "Friendlier", "Say no politely"])
        XCTAssertTrue(replying.escape())
        type("tue 10 ok", in: reply)
        XCTAssertEqual(titles(reply).first, "Write Reply from Notes")
        reply.closeWithoutSaving()

        let forward = try forward(harness)
        let forwarding = try session(forward)
        forward.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(forwarding.field.writeKind, .forward)
        XCTAssertEqual(forwarding.plan, .fromContext)
        XCTAssertEqual(forward.bodyWriteLayer.state.ghost?.words, "to write a message")
        XCTAssertEqual(forward.bodyWriteLayer.ghost.accessibilityHelp(), "Command J to write a message")
        XCTAssertEqual(titles(forward), ["Write Message", "Write Message with Instructions\u{2026}"])
        XCTAssertEqual(forwarding.contextMenuItems().prefix(2).map(\.title), ["Write Message", "Say How\u{2026}"])
        forward.helpMeWriteWithInstructions(nil)
        XCTAssertEqual(forward.bodyWriteLayer.prompt.chips.map(\.title), ["Shorter", "Friendlier", "More formal"],
                       "the forwarded message is there for a chip to work on")
        XCTAssertTrue(forwarding.escape())
        type("fyi before thursday", in: forward)
        XCTAssertEqual(titles(forward), ["Write Message from Notes", "Write Message with Instructions\u{2026}"])
        forwarding.showNotesGhostNow()
        XCTAssertEqual(forward.bodyWriteLayer.state.ghost?.words, "to write from your notes")
        forward.bodyEditor.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertEqual(titles(forward), ["Rewrite Selection", "Rewrite Selection with Instructions\u{2026}"])
        forward.closeWithoutSaving()

        // A forward whose original is gone has only what the user gives: it is worded as a new message is.
        let bare = forwardWithoutItsOriginal(harness)
        let baring = try session(bare)
        XCTAssertEqual(baring.field.writeKind, .newMessage)
        XCTAssertEqual(baring.field.analyticsKind, .forward, "Analytics still names the composer a forward")
        XCTAssertEqual(bare.bodyWriteLayer.state.ghost?.words, "to say what to write")
        XCTAssertEqual(titles(bare), ["Write Message\u{2026}", "Write Message with Instructions\u{2026}"])
        commandJ(bare)
        XCTAssertTrue(baring.isPromptShown)
        XCTAssertTrue(bare.bodyWriteLayer.prompt.chips.isEmpty)
        XCTAssertTrue(baring.escape())
        type("two words", in: bare)
        baring.showNotesGhostNow()
        XCTAssertEqual(bare.bodyWriteLayer.state.ghost?.words, "to write from your notes")
        XCTAssertEqual(titles(bare).first, "Write Message from Notes")
    }

    /// VoiceOver hears what landed: a message, and that its subject was set with it when it was, since that is the one
    /// effect of a write that is not at the caret.
    func testVoiceOverSaysWhatLanded() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        var announced: [String] = []
        QuireAccessibility.observer = { _, text in if let text { announced.append(text) } }

        let composer = newMessage(harness)
        try write("ask Priya to lunch", in: composer)
        let session = try session(composer)
        until({ session.phase == .written })
        XCTAssertTrue(announced.contains("Writing with Claude"), "\(announced)")
        XCTAssertEqual(announced.last, "Message and subject written by Claude")

        // With a subject already there none is set, and none is said.
        composer.setSubjectText("Mine")
        press(.tryAgain, in: composer)
        until({ script.requests.count == 2 && session.phase == .written })
        XCTAssertEqual(announced.last, "Message written by Claude")
        composer.bodyEditor.setSelectedRange(NSRange(location: 0, length: 8))
        script.reply = "Hello Priya"
        commandJ(composer)
        until({ script.requests.count == 3 && session.phase == .written })
        XCTAssertEqual(announced.last, "Selection rewritten by Claude")
        composer.closeWithoutSaving()

        script.reply = "Sharing this with you."
        let forward = try forward(harness)
        let forwarding = try self.session(forward)
        commandJ(forward)
        until({ forwarding.phase == .written })
        XCTAssertEqual(announced.last, "Message written by Claude")
        XCTAssertFalse(announced.contains { $0.contains("Reply") }, "\(announced)")
    }

    // MARK: A forward

    /// An empty forward with its forwarded message in hand writes at once, from that one message as the composer
    /// itself holds it: never the rest of its conversation, never the header block that carries addresses. Its Subject
    /// is never touched.
    func testAForwardIsWrittenFromItsForwardedMessageAlone() throws {
        let (harness, script) = try harness(reply: "Sharing this so you have the date.")
        defer { harness.close() }
        let composer = try forward(harness)
        let session = try session(composer)
        let subject = composer.subjectText
        XCTAssertTrue(subject.hasPrefix("Fwd:"), subject)
        commandJ(composer)
        XCTAssertFalse(session.isPromptShown, "it writes at once")
        until({ session.phase == .written })
        XCTAssertEqual(composer.bodyText, "Sharing this so you have the date.")
        XCTAssertEqual(composer.subjectText, subject, "a forward's Subject is never touched")

        let request = try XCTUnwrap(script.requests.first)
        XCTAssertEqual(request.kind, .forward)
        XCTAssertEqual(request.promptVersion, "write-forward-1")
        XCTAssertFalse(request.wantsSubject)
        XCTAssertEqual(request.task, "Write my message.")
        XCTAssertTrue(request.transcript.contains("The message I'm forwarding:"))
        XCTAssertTrue(request.transcript.contains("The venue is booked for the ninth. LATEST"), "the forwarded message")
        XCTAssertFalse(request.userTurn.contains("EARLIEST"), "nothing of the conversation's other messages")
        XCTAssertFalse(request.userTurn.contains("MINE"))
        XCTAssertFalse(request.userTurn.contains("@"), "no address")
        let quoted = try XCTUnwrap(composer.contents.quoted)
        XCTAssertTrue(quoted.header.contains("@"), "the header block the recipients get does carry addresses")
        XCTAssertFalse(request.userTurn.contains("Forwarded message"), "and none of it is sent")
        for line in quoted.header.split(separator: "\n") where line.contains("@") {
            XCTAssertFalse(request.userTurn.contains(String(line)), "not the header's \(line.prefix(8))")
        }
        XCTAssertFalse(request.instructions.contains("LATEST"), "the fixed instructions hold no mail")
        XCTAssertTrue(sheets.isEmpty)

        // With notes: from the notes, the forwarded message as context. A selection: it and the instruction alone.
        composer.bodyEditor.insertText("fyi before thursday", replacementRange: NSRange(location: 0, length: (composer.bodyText as NSString).length))
        commandJ(composer)
        until({ script.requests.count == 2 && session.phase == .written })
        XCTAssertTrue(script.requests[1].task.contains("fyi before thursday"))
        XCTAssertTrue(script.requests[1].task.hasSuffix("Write my message from these notes."))
        XCTAssertTrue(script.requests[1].transcript.contains("LATEST"))
        composer.bodyEditor.setSelectedRange(NSRange(location: 0, length: 7))
        commandJ(composer)
        until({ script.requests.count == 3 && session.phase == .written })
        XCTAssertTrue(script.requests[2].isRewrite)
        XCTAssertEqual(script.requests[2].transcript, "", "a rewrite sends the selection and the instruction only")
        XCTAssertFalse(script.requests[2].userTurn.contains("LATEST"))
    }

    /// While the forwarded message is still loading there is nothing to write from yet: no ghost, and ⌘J without a
    /// selection says so, quietly, and sends nothing. Nothing failed: the line is a notice, the info glyph in `ink3`
    /// and the words in `ink2` with no action, which VoiceOver reads alone. ⌘J under it asks again. When the message
    /// lands the session reads the field again: the notice goes and the ghost appears.
    func testAForwardStillLoadingWaitsForItsForwardedMessage() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        var announced: [String] = []
        QuireAccessibility.observer = { _, text in if let text { announced.append(text) } }
        try saveBody("The venue is booked for the ninth. LATEST", for: "msg-2-2", harness)
        let composer = present(.forward(MessageID(accountID: a.id, providerID: "msg-2-2")), harness)
        // Prefill has not run yet: nothing is quoted.
        XCTAssertTrue(composer.isLoadingForwardedMessage)
        let session = try session(composer)
        composer.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(session.field.selectionOnlyReason, "The forwarded message is still loading")
        XCTAssertNil(composer.bodyWriteLayer.state.ghost, "no ghost while it loads")
        XCTAssertEqual(titles(composer), ["Help Me Write", "Help Me Write with Instructions\u{2026}"])
        let loading = "The forwarded message is still loading"
        for shifted in [false, true, false] {
            if shifted { composer.helpMeWriteWithInstructions(nil) } else { composer.helpMeWrite(nil) }
            XCTAssertEqual(session.phase, .notice(loading), "said under the caret's line, as a notice")
            XCTAssertFalse(session.isPromptShown)
            XCTAssertFalse(session.isWriting)
        }
        let afterline = composer.bodyWriteLayer.afterline
        XCTAssertEqual(composer.bodyWriteLayer.state.block, .afterline(.caret(0), .notice(loading)))
        XCTAssertEqual(afterline.lineWords, loading, "no Try again, no Settings…")
        afterline.layoutSubtreeIfNeeded()
        XCTAssertEqual(afterline.shownWords, loading)
        XCTAssertTrue(afterline.actions.values.allSatisfy(\.isHidden))
        XCTAssertEqual(afterline.glyphName, Quire.Icon.info)
        XCTAssertEqual(afterline.glyphColor, .qInk3)
        XCTAssertEqual(afterline.wordsColor, .qInk2)
        XCTAssertEqual(afterline.accessibilityLabel(), loading, "VoiceOver reads the words alone")
        XCTAssertEqual(announced.last, loading)
        XCTAssertFalse(announced.contains { $0.hasPrefix("Couldn") }, "nothing failed")
        XCTAssertTrue(script.requests.isEmpty)

        // It goes as a failure's line goes: on Esc, and on typing.
        XCTAssertTrue(session.escape())
        XCTAssertEqual(session.phase, .idle)
        composer.helpMeWrite(nil)
        composer.bodyEditor.insertText("fyi ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(session.phase, .idle, "typing takes it away")
        composer.bodyEditor.undoManager?.undo()
        composer.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))
        composer.helpMeWrite(nil)
        XCTAssertEqual(session.phase, .notice(loading))

        until({ composer.hasForwardedMessage }, "the forwarded message lands")
        XCTAssertNil(session.field.selectionOnlyReason)
        XCTAssertEqual(session.phase, .idle, "the line that said it was loading goes")
        XCTAssertEqual(composer.bodyWriteLayer.state.ghost?.words, "to write a message", "and the ghost appears")
        ListTestSupport.spin(for: 0.1)
        XCTAssertTrue(script.requests.isEmpty, "none of this sent anything")
    }

    /// A forward with no forwarded message to read is written as a new message is: ⌘J asks what to write, a write
    /// from notes sends the notes and no mail, and its Subject, empty for good, never gets one.
    func testAForwardWithoutItsOriginalIsWrittenAsANewMessageAndGetsNoSubject() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let composer = forwardWithoutItsOriginal(harness)
        let session = try session(composer)
        XCTAssertEqual(composer.subjectText, "", "prefill found no original to take a subject from")
        try write("tell them the venue is booked", in: composer)
        until({ session.phase == .written })
        let request = try XCTUnwrap(script.requests.first)
        XCTAssertEqual(request.kind, .newMessage)
        XCTAssertEqual(request.promptVersion, "write-new-1")
        XCTAssertFalse(request.wantsSubject, "never on a forward")
        XCTAssertEqual(request.transcript, "", "there is no mail to send")
        XCTAssertEqual(composer.subjectText, "", "the Subject is never touched")
        XCTAssertEqual(composer.bodyText, lunchBody, "a subject line the model sent anyway is dropped, not shown")
        XCTAssertEqual(harness.environment.helpMeWrite.writeDetails.count, 0)
    }

    // MARK: The subject of a new message

    /// A new message with an empty Subject is asked for one with its draft. It is held while the body streams and set
    /// only as the draft lands, in the draft's one undo step: the window's undo manager is the body's, and one Undo
    /// takes body and subject back together; Redo brings both. Stop leaves the Subject as it was.
    func testANewMessagesSubjectLandsWithItsDraftInOneUndoStep() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let composer = newMessage(harness, link: MailtoLink(to: [priya]))
        let editor = composer.bodyEditor
        XCTAssertTrue(composer.window?.undoManager === editor.undoManager, "one undo manager for the window and its body")
        XCTAssertEqual(composer.window?.title, "New Message")

        script.holdsAfter = 2
        try write("ask Priya to lunch on Thursday", in: composer)
        let session = try session(composer)
        until({ composer.bodyText.hasPrefix("Hi Priya") }, "the message streams")
        XCTAssertFalse(composer.bodyText.contains("Subject"), "the subject line is never shown in the body")
        XCTAssertEqual(composer.subjectText, "", "nor in the Subject while the body streams")
        let details = try XCTUnwrap(harness.environment.helpMeWrite.writeDetails[AIFieldID(editor)])
        XCTAssertEqual(details.kind, .new, "Analytics hears a new message")
        XCTAssertTrue(details.subject, "and that a subject was asked for")
        XCTAssertEqual(details.draft, .empty)
        XCTAssertTrue(details.instruction)
        XCTAssertFalse(details.retry)
        session.stop()
        XCTAssertEqual(composer.subjectText, "", "Stop leaves the Subject as it was")
        XCTAssertEqual(composer.bodyText, "")
        XCTAssertEqual(composer.window?.title, "New Message")

        script.holdsAfter = nil
        try write("ask Priya to lunch on Thursday", in: composer)
        until({ session.phase == .written }, "the message lands")
        XCTAssertTrue(script.requests.allSatisfy(\.wantsSubject))
        XCTAssertEqual(composer.bodyText, lunchBody)
        XCTAssertEqual(composer.subjectText, "Lunch on Thursday?", "its subject lands with it")
        XCTAssertEqual(composer.contents.subject, "Lunch on Thursday?")
        XCTAssertEqual(composer.window?.title, "Lunch on Thursday?", "and the window takes its title")
        XCTAssertEqual(composer.bodyWriteLayer.afterline.lineWords,
                       "Written by Claude \u{00b7} Try again \u{2318}J \u{00b7} Shorter \u{00b7} Say how \u{21e7}\u{2318}J \u{00b7} Undo \u{2318}Z")

        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertEqual(undo.undoMenuItemTitle, "Undo Help Me Write", "one step, under the draft's name")
        undo.undo()
        XCTAssertEqual(composer.bodyText, "", "⌘Z takes the body back")
        XCTAssertEqual(composer.subjectText, "", "and the subject with it")
        XCTAssertEqual(composer.window?.title, "New Message")
        XCTAssertFalse(undo.canUndo, "in that one step")
        XCTAssertEqual(undo.redoMenuItemTitle, "Redo Help Me Write")
        undo.redo()
        XCTAssertEqual(composer.bodyText, lunchBody, "⇧⌘Z brings both back")
        XCTAssertEqual(composer.subjectText, "Lunch on Thursday?")
        XCTAssertEqual(composer.window?.title, "Lunch on Thursday?")
        // The afterline's Undo is the same step.
        undo.undo()
        undo.redo()
        XCTAssertEqual(session.plan, .tryAgain)
        XCTAssertEqual(composer.subjectText, "Lunch on Thursday?")
    }

    /// ⌘Z and ⇧⌘Z with the caret in Subject, while the step on top is a draft's: the keyboard goes to the body first,
    /// then the whole step is undone or redone, the Subject at rest as it changes.
    func testUndoFromTheSubjectTakesTheWholeStepWithTheKeyboardInTheBody() throws {
        let (harness, _) = try harness(reply: lunch)
        defer { harness.close() }
        let composer = newMessage(harness)
        try write("ask Priya to lunch", in: composer)
        let session = try session(composer)
        until({ session.phase == .written })
        let window = try XCTUnwrap(composer.window as? ComposeWindow)
        let subject = try subjectField(composer)

        XCTAssertTrue(window.makeFirstResponder(subject))
        XCTAssertNotNil(subject.currentEditor(), "the caret is in Subject")
        // Subject's editor keeps its typing on a manager of its own; ⌘Z in a composer undoes the window's, which is
        // the body's and holds the draft's step, wherever the keyboard is.
        XCTAssertTrue(window.undoManager === composer.bodyEditor.undoManager)
        let undoItem = NSMenuItem(title: "Undo", action: #selector(ComposeWindow.undo(_:)), keyEquivalent: "z")
        XCTAssertTrue(window.validateMenuItem(undoItem))
        XCTAssertEqual(undoItem.title, "Undo Help Me Write")
        window.undo(nil)
        XCTAssertTrue(window.firstResponder === composer.bodyEditor, "the keyboard went to the body")
        XCTAssertEqual(composer.bodyText, "", "the body went back")
        XCTAssertEqual(composer.subjectText, "", "and the subject with it")
        XCTAssertEqual(subject.stringValue, "")
        XCTAssertEqual(window.title, "New Message")

        XCTAssertTrue(window.makeFirstResponder(subject))
        window.redo(nil)
        XCTAssertTrue(window.firstResponder === composer.bodyEditor)
        XCTAssertEqual(composer.bodyText, lunchBody)
        XCTAssertEqual(composer.subjectText, "Lunch on Thursday?")
        XCTAssertEqual(window.title, "Lunch on Thursday?")

        // A step that is not a draft's is undone where the keyboard is, as it always was.
        composer.bodyEditor.insertText(" More.", replacementRange: NSRange(location: (composer.bodyText as NSString).length, length: 0))
        ListTestSupport.spin(for: 0.02)
        XCTAssertTrue(window.makeFirstResponder(subject))
        window.undo(nil)
        XCTAssertFalse(window.firstResponder === composer.bodyEditor, "typing's step leaves the keyboard in Subject")
        XCTAssertEqual(composer.bodyText, lunchBody)
    }

    /// A subject the user changed since the draft landed is theirs: Undo and Redo move the body and leave it, and a
    /// subject they removed never comes back. Undo of a subject of spaces puts the spaces back exactly.
    func testTheUsersOwnSubjectWinsOverTheDraftsStep() throws {
        let (harness, _) = try harness(reply: lunch)
        defer { harness.close() }
        let composer = newMessage(harness)
        try write("ask Priya to lunch", in: composer)
        let session = try session(composer)
        until({ session.phase == .written })
        let undo = try XCTUnwrap(composer.bodyEditor.undoManager)

        composer.setSubjectText("Thursday")
        undo.undo()
        XCTAssertEqual(composer.bodyText, "", "the body goes back")
        XCTAssertEqual(composer.subjectText, "Thursday", "their subject stays")
        undo.redo()
        XCTAssertEqual(composer.bodyText, lunchBody)
        XCTAssertEqual(composer.subjectText, "Thursday", "and Redo does not put the written one over it")
        XCTAssertEqual(composer.window?.title, "Thursday")
        composer.closeWithoutSaving()

        // Removed, then ⌘Z and ⇧⌘Z: it does not come back.
        let second = newMessage(harness)
        try write("ask Priya to lunch", in: second)
        let secondSession = try self.session(second)
        until({ secondSession.phase == .written })
        XCTAssertEqual(second.subjectText, "Lunch on Thursday?")
        second.setSubjectText("")
        let secondUndo = try XCTUnwrap(second.bodyEditor.undoManager)
        secondUndo.undo()
        secondUndo.redo()
        XCTAssertEqual(second.bodyText, lunchBody)
        XCTAssertEqual(second.subjectText, "", "a subject the user removed stays removed")
        second.closeWithoutSaving()

        // Spaces only are empty by Send's own test: a subject is proposed, and Undo puts back exactly the spaces.
        let third = newMessage(harness)
        third.setSubjectText("  ")
        try write("ask Priya to lunch", in: third)
        let thirdSession = try self.session(third)
        until({ thirdSession.phase == .written })
        XCTAssertEqual(third.subjectText, "Lunch on Thursday?")
        third.bodyEditor.undoManager?.undo()
        XCTAssertEqual(third.subjectText, "  ")
    }

    /// Try again, Shorter and a chip take the draft back first, and its subject with it, so a new one is asked for;
    /// while the new draft streams the Subject is empty. A subject the user changed is theirs: it stays, and none is
    /// asked for.
    func testTryAgainAsksForTheSubjectAgainUnlessTheUserChangedIt() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let composer = newMessage(harness)
        try write("ask Priya to lunch", in: composer)
        let session = try session(composer)
        until({ session.phase == .written })
        XCTAssertEqual(composer.subjectText, "Lunch on Thursday?")

        script.reply = "Subject: Thursday lunch\n\nHi Priya,\n\nLunch on Thursday?"
        script.holdsAfter = 1
        commandJ(composer)
        until({ script.requests.count == 2 && session.isWriting })
        XCTAssertEqual(composer.subjectText, "", "the undo took the subject back with the draft")
        XCTAssertEqual(composer.window?.title, "New Message")
        XCTAssertTrue(script.requests[1].wantsSubject, "and a new one is asked for")
        XCTAssertEqual(harness.environment.helpMeWrite.writeDetails[AIFieldID(composer.bodyEditor)]?.retry, true)
        session.stop()
        XCTAssertEqual(composer.subjectText, "", "stopped, nothing was set")
        XCTAssertEqual(composer.bodyText, "")

        script.holdsAfter = nil
        try write("ask Priya to lunch", in: composer)
        until({ script.requests.count == 3 && session.phase == .written })
        XCTAssertEqual(composer.subjectText, "Thursday lunch")
        XCTAssertEqual(composer.bodyEditor.undoManager?.undoMenuItemTitle, "Undo Help Me Write")

        // The user's own subject: Shorter rewrites the body, asks for no subject, and leaves theirs.
        composer.setSubjectText("See you Thursday")
        press(.shorter, in: composer)
        until({ script.requests.count == 4 && session.phase == .written })
        XCTAssertFalse(script.requests[3].wantsSubject, "none is asked for beside the user's own")
        XCTAssertEqual(composer.subjectText, "See you Thursday")
        XCTAssertTrue(script.requests[3].transcript.contains("Subject: See you Thursday"), "it goes as the message's subject, fenced")
        XCTAssertEqual(composer.bodyText, "Hi Priya,\n\nLunch on Thursday?", "the line the model sent anyway is dropped")
    }

    /// The Subject follows through to what is kept: the title, “Draft saved” and the draft on disk hold the subject a
    /// write set, and no longer hold it once the step is undone. Closing mid-write keeps what the user had, without a
    /// subject that was only proposed.
    func testTheTitleTheStatusAndTheKeptDraftFollowTheSubject() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let accounts = harness.controller.accounts
        let composer = newMessage(harness)
        let draftID = composer.draftID
        try write("ask Priya to lunch", in: composer)
        let session = try session(composer)
        until({ session.phase == .written })
        XCTAssertTrue(ListTestSupport.spin(until: { composer.status == .saved }, timeout: 5), "the autosave keeps it")
        XCTAssertEqual(ComposeDraftStore.shared.draft(id: draftID, accounts: accounts)?.subject, "Lunch on Thursday?")
        XCTAssertEqual(ComposeDraftStore.shared.draft(id: draftID, accounts: accounts)?.body.string, lunchBody)

        composer.bodyEditor.undoManager?.undo()
        XCTAssertNotEqual(composer.status, .saved, "“Draft saved” is stale once the step is undone")
        XCTAssertTrue(ListTestSupport.spin(until: {
            ComposeDraftStore.shared.waitForWrites()
            return ComposeDraftStore.shared.draft(id: draftID, accounts: accounts) == nil
        }, timeout: 5), "an empty body and an empty Subject again: nothing is worth keeping")
        composer.closeWithoutSaving()

        // Closed mid-write: the notes are kept, and no subject.
        let second = newMessage(harness)
        script.holdsAfter = 2
        type("lunch thursday at noon", in: second)
        commandJ(second)
        until({ second.bodyText.hasPrefix("Hi Priya") })
        XCTAssertEqual(script.requests.last?.wantsSubject, true)
        let secondID = second.draftID
        second.window?.performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        let kept = try XCTUnwrap(ComposeDraftStore.shared.draft(id: secondID, accounts: accounts))
        XCTAssertEqual(kept.body.string, "lunch thursday at noon", "the kept draft holds the user's words")
        XCTAssertEqual(kept.subject, "", "and no subject that was only proposed")
    }

    /// Where no subject is wanted none is asked for and none is set: a subject typed, a reply (whose answer is never
    /// read for one), an answer that is a subject and nothing else.
    func testNoSubjectIsSetWhereNoneIsWanted() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let typed = newMessage(harness, link: MailtoLink(to: [priya], subject: "Q3 budget"))
        try write("ask Priya to lunch", in: typed)
        let typedSession = try session(typed)
        until({ typedSession.phase == .written })
        XCTAssertEqual(script.requests[0].wantsSubject, false, "a subject is there: none is asked for")
        XCTAssertTrue(script.requests[0].transcript.contains("Subject: Q3 budget"), "it travels with the brief, fenced")
        XCTAssertEqual(typed.subjectText, "Q3 budget")
        XCTAssertEqual(typed.bodyText, lunchBody)
        typed.closeWithoutSaving()

        // A reply's answer is never read for a subject line: it stays in sight as text, and the Subject is the reply's.
        let reply = present(.reply(MessageID(accountID: a.id, providerID: "msg-2-2"), all: false), harness)
        let replySession = try session(reply)
        until({ reply.subjectText.hasPrefix("Re:") })
        let subject = reply.subjectText
        commandJ(reply)
        until({ replySession.phase == .written })
        XCTAssertEqual(reply.bodyText, lunch)
        XCTAssertEqual(reply.subjectText, subject)
        XCTAssertEqual(script.requests[1].kind, .reply)
        reply.closeWithoutSaving()

        // A subject and nothing under it: nothing came back, and nothing is set.
        script.reply = "Subject: Lunch on Thursday?\n\n"
        let empty = newMessage(harness)
        try write("ask Priya to lunch", in: empty)
        let emptySession = try session(empty)
        until({ emptySession.phase.isFailed })
        XCTAssertEqual(emptySession.phase, .failed(reason: "Nothing came back", offersSettings: false))
        XCTAssertEqual(empty.subjectText, "")
        XCTAssertEqual(empty.bodyText, "")
        XCTAssertFalse(empty.bodyEditor.undoManager?.canUndo ?? true, "and no step is left behind")

        // An answer with no subject line is all message: the Subject stays empty, and nothing is wrong.
        script.reply = "Betreff: Mittagessen\n\nHallo Priya"
        press(.tryAgain, in: empty)
        until({ emptySession.phase == .written })
        XCTAssertEqual(empty.bodyText, "Betreff: Mittagessen\n\nHallo Priya", "a translated marker is the message's own text")
        XCTAssertEqual(empty.subjectText, "")
    }

    // MARK: Follow-ups and Try again

    /// A new message written from an instruction alone keeps that instruction as its brief: Shorter, a chip and new
    /// words after Say how are asked on top of it, never in its place. After ⌘Z back to the empty body ⌘J offers the
    /// brief again, selected.
    func testTheBriefIsKeptThroughShorterAChipAndSayHow() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let composer = newMessage(harness)
        let brief = "ask Priya to lunch on Thursday"
        try write(brief, in: composer)
        let session = try session(composer)
        let prompt = composer.bodyWriteLayer.prompt
        until({ session.phase == .written })
        XCTAssertEqual(script.requests[0].task, "Write my message from this brief:\n\(brief)")

        press(.shorter, in: composer)
        until({ script.requests.count == 2 && session.phase == .written })
        XCTAssertTrue(script.requests[1].task.contains(brief), "the brief is still what it is written from")
        XCTAssertTrue(script.requests[1].task.hasPrefix("My notes so far"), "as the notes of what is asked now")
        XCTAssertTrue(script.requests[1].task.hasSuffix("Write my message from these notes. Shorter"))

        composer.helpMeWriteWithInstructions(nil)
        XCTAssertEqual(prompt.chips.map(\.title), ["Shorter", "Friendlier", "More formal"], "a draft stands: a chip can run")
        prompt.chips[2].performClick(nil)
        until({ script.requests.count == 3 && session.phase == .written })
        XCTAssertTrue(script.requests[2].task.contains(brief))
        XCTAssertTrue(script.requests[2].task.hasSuffix("Write my message from these notes. More formal"),
                      "a later follow-up replaces only the instruction")
        XCTAssertFalse(script.requests[2].task.contains("Shorter"))

        composer.helpMeWriteWithInstructions(nil)
        say("mention the new place", in: composer)
        until({ script.requests.count == 4 && session.phase == .written })
        XCTAssertTrue(script.requests[3].task.contains(brief))
        XCTAssertTrue(script.requests[3].task.hasSuffix("Write my message from these notes. mention the new place"))

        // Try again writes from the same brief and the same words.
        commandJ(composer)
        until({ script.requests.count == 5 && session.phase == .written })
        XCTAssertEqual(task(script.requests[4]), task(script.requests[3]))
        XCTAssertEqual(composer.bodyEditor.undoManager?.undoMenuItemTitle, "Undo Help Me Write")

        // ⌘Z back to the empty body: ⌘J asks again, the brief waiting in the line, selected.
        composer.bodyEditor.undoManager?.undo()
        XCTAssertEqual(composer.bodyText, "")
        XCTAssertEqual(titles(composer).first, "Write Message\u{2026}")
        commandJ(composer)
        XCTAssertTrue(session.isPromptShown)
        XCTAssertEqual(prompt.instruction, brief)
        let editor = try XCTUnwrap(prompt.field.currentEditor())
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: (brief as NSString).length), "selected: typing replaces it")
        XCTAssertEqual(script.requests.count, 5, "opening the line sent nothing")
        pressReturn(in: composer)
        until({ script.requests.count == 6 && session.phase == .written })
        XCTAssertEqual(script.requests[5].task, script.requests[0].task, "↩ writes from the brief again")
    }

    /// Try again after a failure asks the same again: the same notes and the same instruction, with no prompt line in
    /// between. On a new message whose brief was said in the line, and on a reply, where the instruction used to be lost.
    func testTryAgainAfterAFailureAsksTheSameAgain() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        script.failure = .keyRefused
        script.failsAfter = 1
        let composer = newMessage(harness)
        try write("ask Priya to lunch on Thursday", in: composer)
        let session = try session(composer)
        until({ session.phase.isFailed })
        XCTAssertEqual(session.phase, .failed(reason: "The Anthropic API key was refused", offersSettings: true))
        XCTAssertEqual(composer.bodyText, "")
        XCTAssertEqual(composer.subjectText, "", "a failure sets no subject")
        XCTAssertEqual(titles(composer).first, "Write Message\u{2026}")

        script.failure = nil
        press(.tryAgain, in: composer)
        XCTAssertFalse(session.isPromptShown, "the same ask runs: the line does not open again")
        until({ session.phase == .written })
        XCTAssertEqual(script.requests.count, 2)
        XCTAssertEqual(script.requests[1].task, script.requests[0].task, "the same brief")
        XCTAssertEqual(composer.bodyText, lunchBody)
        XCTAssertEqual(harness.environment.helpMeWrite.writeDetails.count, 0)
        composer.closeWithoutSaving()

        // A reply: notes and an instruction, failed, then ⌘J under the failure's line.
        script.reply = "No, sorry."
        script.failure = .keyRefused
        let reply = present(.reply(MessageID(accountID: a.id, providerID: "msg-2-2"), all: false), harness)
        let replying = try self.session(reply)
        type("cannot make it", in: reply)
        reply.helpMeWriteWithInstructions(nil)
        say("Say no politely", in: reply)
        until({ replying.phase.isFailed })
        XCTAssertTrue(script.requests[2].task.hasSuffix("Write my reply from these notes. Say no politely"))
        script.failure = nil
        commandJ(reply)
        until({ replying.phase == .written })
        XCTAssertEqual(task(script.requests[3]), task(script.requests[2]), "the instruction is asked again with the notes")

        // Once the user edits, what failed is forgotten: ⌘J writes from the field as it is.
        script.failure = .keyRefused
        reply.bodyEditor.insertText("maybe friday", replacementRange: NSRange(location: 0, length: (reply.bodyText as NSString).length))
        reply.helpMeWriteWithInstructions(nil)
        say("Warmer", in: reply)
        until({ replying.phase.isFailed })
        script.failure = nil
        reply.bodyEditor.insertText(" then", replacementRange: NSRange(location: (reply.bodyText as NSString).length, length: 0))
        commandJ(reply)
        until({ replying.phase == .written })
        XCTAssertTrue(script.requests[5].task.hasSuffix("Write my reply from these notes."), "no instruction comes with new notes")
        XCTAssertTrue(script.requests[5].task.contains("maybe friday then"))

        // A selection's rewrite that failed is asked again while that selection stands, its instruction with it.
        script.failure = .keyRefused
        reply.bodyEditor.setSelectedRange(NSRange(location: 0, length: 2))
        reply.helpMeWriteWithInstructions(nil)
        say("More formal", in: reply)
        until({ replying.phase.isFailed })
        XCTAssertEqual(reply.bodyEditor.selectedRange(), NSRange(location: 0, length: 2), "the selection is back as it was")
        script.failure = nil
        commandJ(reply)
        until({ replying.phase == .written })
        XCTAssertTrue(script.requests[7].isRewrite)
        XCTAssertEqual(task(script.requests[7]), task(script.requests[6]), "the same selection and the same instruction")
        XCTAssertTrue(script.requests[7].task.contains("More formal"))

        // Let go of the selection after a failure, and ⌘J works on what the field holds now: never the selection that
        // is no longer there.
        script.failure = .keyRefused
        reply.bodyEditor.setSelectedRange(NSRange(location: 0, length: 2))
        commandJ(reply)
        until({ replying.phase.isFailed })
        script.failure = nil
        reply.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))
        commandJ(reply)
        until({ replying.phase == .written })
        XCTAssertFalse(script.requests[9].isRewrite, "what failed was a rewrite; this is a draft from the notes")
    }

    /// For a new message and a forward an instruction longer than is sent is refused whole, in words, since it can be
    /// the whole brief. A reply's is still cut, as it always was.
    func testAnInstructionTooLongIsRefusedWholeWhereItCanBeTheBrief() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        let long = String(repeating: "word ", count: 1_700) + "end"
        let composer = newMessage(harness)
        try write(long, in: composer)
        let session = try session(composer)
        XCTAssertEqual(session.phase, .failed(reason: "Your instruction is too long. Shorten it.", offersSettings: false))
        XCTAssertEqual(composer.bodyWriteLayer.afterline.lineWords, "Your instruction is too long. Shorten it. \u{00b7} Try again \u{2318}J")
        composer.closeWithoutSaving()

        let forward = try forward(harness)
        let forwarding = try self.session(forward)
        forward.helpMeWriteWithInstructions(nil)
        say(long, in: forward)
        XCTAssertEqual(forwarding.phase, .failed(reason: "Your instruction is too long. Shorten it.", offersSettings: false))
        ListTestSupport.spin(for: 0.2)
        XCTAssertTrue(script.requests.isEmpty, "nothing is sent, rather than a cut brief")
        forward.closeWithoutSaving()

        let reply = present(.reply(MessageID(accountID: a.id, providerID: "msg-2-2"), all: false), harness)
        let replying = try self.session(reply)
        reply.helpMeWriteWithInstructions(nil)
        say(long, in: reply)
        until({ replying.phase == .written }, "a reply's instruction is cut and sent")
        XCTAssertEqual(script.requests.count, 1)
        XCTAssertEqual(script.requests[0].kind, .reply)
    }

    /// A follow-up too long to send on a standing draft (Say how's words on a new message written from a brief) is
    /// refused before Try again's undo: the draft and its subject stay, the reason shows under them, and nothing is
    /// sent. ⌘J under that line tries the draft again as it was asked.
    func testAFollowUpTooLongIsRefusedWithTheDraftAndItsSubjectStanding() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let composer = newMessage(harness, link: MailtoLink(to: [priya]))
        try write("ask Priya to lunch on Thursday", in: composer)
        let session = try session(composer)
        until({ session.phase == .written })
        XCTAssertEqual(composer.bodyText, lunchBody)
        XCTAssertEqual(composer.subjectText, "Lunch on Thursday?")
        let undoTitle = composer.window?.undoManager?.undoActionName

        let long = String(repeating: "word ", count: 1_700) + "end"
        composer.helpMeWriteWithInstructions(nil)
        XCTAssertTrue(session.isPromptShown)
        say(long, in: composer)
        let reason = "Your instruction is too long. Shorten it."
        XCTAssertEqual(session.phase, .failed(reason: reason, offersSettings: false))
        XCTAssertEqual(composer.bodyText, lunchBody, "the draft stands")
        XCTAssertEqual(composer.subjectText, "Lunch on Thursday?", "with its subject")
        XCTAssertEqual(composer.window?.undoManager?.undoActionName, undoTitle, "nothing was undone")
        XCTAssertEqual(composer.bodyWriteLayer.afterline.lineWords, reason + " \u{00b7} Try again \u{2318}J")
        ListTestSupport.spin(for: 0.2)
        XCTAssertEqual(script.requests.count, 1, "nothing is sent")

        commandJ(composer)
        until({ session.phase == .written && script.requests.count == 2 }, "⌘J tries the draft again as it was asked")
        XCTAssertEqual(script.requests.last.map(task), script.requests.first.map(task))
        XCTAssertEqual(composer.subjectText, "Lunch on Thursday?")
    }

    // MARK: Bodies the composer did not write

    private func draft(_ harness: MainWindowHarness, mode: ComposeMode = .new, body: String, subject: String = "",
                       continues: MessageID? = nil, asSent: Bool = false) -> ComposeDraft {
        ComposeDraft(id: UUID(), mode: mode, account: harness.controller.accounts[0], to: [priya], cc: [], bcc: [], subject: subject,
                     body: asSent ? ComposeTextView.plainBody(body) : NSAttributedString(string: body), attachments: [], quoted: nil,
                     threading: nil, continuesDraft: continues, bodyIsAsSent: asSent)
    }

    /// A provider's draft continued here, and a Send Later message rebuilt from the outbox, hold whatever the message
    /// held (quoted mail, a signature) as unmarked text. Help me write rewrites a selection there and nothing else:
    /// no ghost, the pill as usual, and ⌘J or ⇧⌘J without a selection says to select and sends nothing. No subject is
    /// proposed.
    func testInABodyOfUnknownOriginOnlyASelectionIsRewritten() throws {
        let (harness, script) = try harness(reply: "Subject: New\n\nSee you on Thursday.")
        defer { harness.close() }
        let body = "see you thursday\n\nOn Monday Ada wrote:\n> the offsite, ada@example.test"
        let continued = draft(harness, body: body, continues: MessageID(accountID: a.id, providerID: "msg-0-0"))
        let rebuiltReply = draft(harness, mode: .reply(MessageID(accountID: a.id, providerID: "msg-2-2"), all: false), body: body,
                                 subject: "Re: plans", asSent: true)
        let rebuiltForward = draft(harness, mode: .forward(MessageID(accountID: a.id, providerID: "msg-2-2")), body: body,
                                   subject: "Fwd: plans", asSent: true)
        for (name, kept) in [("continued", continued), ("rebuilt reply", rebuiltReply), ("rebuilt forward", rebuiltForward)] {
            let sentBefore = script.requests.count
            let composer = ComposeWindowController.present(client: harness.environment.engine, accounts: harness.controller.accounts, draft: kept)
            XCTAssertTrue(composer.bodyIsOfUnknownOrigin, name)
            let session = try session(composer)
            let editor = composer.bodyEditor
            editor.setSelectedRange(NSRange(location: 16, length: 0))
            session.showNotesGhostNow()
            XCTAssertNil(composer.bodyWriteLayer.state.ghost, "\(name): no ghost")
            XCTAssertEqual(session.plan, .selectionOnly, name)
            XCTAssertEqual(titles(composer), ["Help Me Write", "Help Me Write with Instructions\u{2026}"], name)
            for shifted in [false, true] {
                if shifted { composer.helpMeWriteWithInstructions(nil) } else { composer.helpMeWrite(nil) }
                XCTAssertEqual(session.phase, .notice("Select the text to rewrite"), name)
                XCTAssertEqual(composer.bodyWriteLayer.afterline.lineWords, "Select the text to rewrite", "\(name): a notice, no action")
                XCTAssertFalse(session.isPromptShown, name)
            }
            composer.window?.makeFirstResponder(try subjectField(composer))
            XCTAssertEqual(session.phase, .idle, "\(name): the keyboard leaving takes the notice away")
            composer.window?.makeFirstResponder(editor)
            ListTestSupport.spin(for: 0.1)
            XCTAssertEqual(script.requests.count, sentBefore, "\(name): nothing is sent")
            XCTAssertEqual(composer.bodyText, body, "\(name): and nothing replaced")

            editor.setSelectedRange(NSRange(location: 0, length: 16))
            session.selectionDidChange()
            XCTAssertEqual(composer.bodyWriteLayer.state.pill, NSRange(location: 0, length: 16), "\(name): the pill as usual")
            XCTAssertEqual(titles(composer).first, "Rewrite Selection", name)
            commandJ(composer)
            until({ session.phase == .written }, name)
            XCTAssertEqual(script.requests.count, sentBefore + 1)
            let request = try XCTUnwrap(script.requests.last)
            XCTAssertTrue(request.isRewrite, name)
            XCTAssertFalse(request.wantsSubject, "\(name): no subject is proposed")
            XCTAssertTrue(request.task.contains("see you thursday"))
            XCTAssertFalse(request.task.contains("the offsite"), "\(name): only the selection goes")
            XCTAssertEqual(composer.subjectText, kept.subject, "\(name): the Subject is as it was")
            XCTAssertTrue(composer.bodyText.hasSuffix("\n\nOn Monday Ada wrote:\n> the offsite, ada@example.test"), "\(name): the rest stands")

            // Try again rewrites the same selection; nothing else can be asked for.
            commandJ(composer)
            until({ script.requests.count == sentBefore + 2 && session.phase == .written }, name)
            XCTAssertTrue(script.requests.last?.isRewrite == true)
            composer.closeWithoutSaving()
        }
        XCTAssertEqual(script.requests.map(\.kind), [.newMessage, .newMessage, .reply, .reply, .newMessage, .newMessage],
                       "a reply's rewrite goes as a reply's; a forward without its original as a new message's")
        XCTAssertEqual(script.requests.filter { $0.kind == .newMessage }.map(\.transcript), ["", "", "", ""],
                       "and a rewrite there sends the selection and the instruction alone")
    }

    /// The outbox's rebuilt draft says what it is, and a kept draft remembers it: the flag is in the record, absent
    /// from every draft written in a composer.
    func testADraftRebuiltFromTheOutboxKeepsItsMark() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let accounts = harness.controller.accounts
        let rebuilt = draft(harness, body: "as it would have gone", asSent: true)
        XCTAssertTrue(ComposeDraftStore.shared.saveNow(rebuilt))
        XCTAssertEqual(ComposeDraftStore.shared.draft(id: rebuilt.id, accounts: accounts)?.bodyIsAsSent, true)
        let written = draft(harness, body: "typed here")
        XCTAssertTrue(ComposeDraftStore.shared.saveNow(written))
        XCTAssertEqual(ComposeDraftStore.shared.draft(id: written.id, accounts: accounts)?.bodyIsAsSent, false)

        // Reopened, edited and kept again, it is still marked: an edit does not tell the user's words apart.
        let composer = ComposeWindowController.present(client: harness.environment.engine, accounts: accounts, draft: rebuilt)
        type("more ", in: composer)
        XCTAssertTrue(composer.contents.bodyIsAsSent)
        XCTAssertTrue(composer.bodyIsOfUnknownOrigin)

        // A fresh composer's body is its own.
        let fresh = newMessage(harness)
        XCTAssertFalse(fresh.bodyIsOfUnknownOrigin)
        XCTAssertFalse(fresh.contents.bodyIsAsSent)
    }

    /// A body a mail link or a Service filled in counts as notes, but someone else may have written it: while it is
    /// exactly what was filled in, what is sent of it goes through the redactor, and no subject is proposed for it.
    /// Once the user changes the body it is theirs and goes as typed. A link's subject counts as typed.
    func testABodyFilledInByALinkOrAServiceIsRedactedUntilTheUserChangesIt() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let filled = "Call me back at ada@example.test about the invoice."
        let link = MailtoLink(to: [priya], body: filled)
        let composer = newMessage(harness, link: link)
        XCTAssertTrue(composer.bodyIsUntouchedPrefill)
        let session = try session(composer)
        XCTAssertEqual(session.plan, .fromNotes, "the link's body counts as notes")
        // A recipient added does not make the link's text the user's.
        commandJ(composer)
        until({ session.phase == .written })
        XCTAssertFalse(script.requests[0].userTurn.contains("ada@example.test"), "an address someone else wrote is not sent")
        XCTAssertTrue(script.requests[0].task.contains("about the invoice"), "the rest of it is")
        XCTAssertFalse(script.requests[0].wantsSubject, "no subject is proposed from text the user did not write")
        XCTAssertEqual(composer.subjectText, "")
        composer.closeWithoutSaving()

        // Edited: theirs, sent as typed, and a subject may come with the draft.
        let edited = newMessage(harness, link: link)
        let editing = try self.session(edited)
        edited.bodyEditor.insertText(" Thanks", replacementRange: NSRange(location: (filled as NSString).length, length: 0))
        XCTAssertFalse(edited.bodyIsUntouchedPrefill)
        commandJ(edited)
        until({ editing.phase == .written })
        XCTAssertTrue(script.requests[1].task.contains("ada@example.test"), "the user's own text goes as typed")
        XCTAssertTrue(script.requests[1].wantsSubject)
        XCTAssertEqual(edited.subjectText, "Lunch on Thursday?")
        edited.closeWithoutSaving()

        // A Service's selection, the same; and a link's own subject is redacted on its way.
        let service = try XCTUnwrap(harness.controller.openServiceRequest(.selection(filled)))
        XCTAssertTrue(service.bodyIsUntouchedPrefill)
        let serving = try self.session(service)
        commandJ(service)
        until({ serving.phase == .written })
        XCTAssertFalse(script.requests[2].userTurn.contains("ada@example.test"))
        XCTAssertFalse(script.requests[2].wantsSubject)
        service.closeWithoutSaving()

        let subjected = newMessage(harness, link: MailtoLink(to: [priya], subject: "Invoice for ada@example.test"))
        XCTAssertFalse(subjected.bodyIsUntouchedPrefill, "a link that filled in no body leaves the body the composer's own")
        try write("ask about the invoice", in: subjected)
        let subjecting = try self.session(subjected)
        until({ subjecting.phase == .written })
        XCTAssertFalse(script.requests[3].wantsSubject, "a link's subject counts as typed")
        XCTAssertTrue(script.requests[3].transcript.contains("Subject: Invoice for"))
        XCTAssertFalse(script.requests[3].userTurn.contains("ada@example.test"), "and travels redacted")
        XCTAssertEqual(subjected.subjectText, "Invoice for ada@example.test")
    }

    /// The filled-in fact goes with the draft: a link's body kept as a draft and reopened (Continue Editing, as Undo
    /// Send and a failed send reopen one) is still redacted while it is exactly what the link filled in, and still asks
    /// for no subject; one character changed makes it the user's. The draft keeps a digest of the text, not the text.
    func testABodyFilledInByALinkStaysRedactedWhenItsDraftIsReopened() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let accounts = harness.controller.accounts
        let filled = "Call me back at ada@example.test about the invoice."
        let composer = newMessage(harness, link: MailtoLink(to: [priya], body: filled))
        let digest = try XCTUnwrap(composer.contents.filledInDigest)
        XCTAssertEqual(digest.count, 64, "SHA-256 in hex")
        XCTAssertFalse(digest.contains("invoice"))
        // A recipient added (the body untouched) makes the window worth keeping; closing keeps it.
        let to = try XCTUnwrap(addressFields(in: composer.window?.contentView).first { $0.addresses == [priya] })
        to.addresses = [priya, EmailAddress(name: "Ben Carter", address: "ben@example.test")]
        let id = composer.draftID
        try XCTUnwrap(composer.window).performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        let kept = try XCTUnwrap(ComposeDraftStore.shared.draft(id: id, accounts: accounts), "kept")
        XCTAssertEqual(kept.filledInDigest, digest)

        XCTAssertTrue(ComposeWindowController.reopenKeptDraft(id: id, client: harness.environment.engine, accounts: accounts))
        let reopened = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first { $0.draftID == id })
        XCTAssertEqual(reopened.bodyText.hasPrefix(filled), true)
        XCTAssertTrue(reopened.bodyIsUntouchedPrefill, "still exactly what the link filled in")
        let session = try session(reopened)
        commandJ(reopened)
        until({ session.phase == .written })
        let first = try XCTUnwrap(script.requests.last)
        XCTAssertFalse(first.userTurn.contains("ada@example.test"), "an address someone else wrote is still not sent")
        XCTAssertTrue(first.task.contains("about the invoice"))
        XCTAssertFalse(first.wantsSubject, "and no subject is asked for")
        XCTAssertEqual(reopened.subjectText, "")

        // Undo brings the link's text back, still redacted; one character changed makes it the user's.
        reopened.window?.undoManager?.undo()
        XCTAssertTrue(reopened.bodyText.hasPrefix(filled))
        XCTAssertTrue(reopened.bodyIsUntouchedPrefill)
        reopened.bodyEditor.insertText("!", replacementRange: NSRange(location: (filled as NSString).length - 1, length: 1))
        XCTAssertFalse(reopened.bodyIsUntouchedPrefill)
        let sentBefore = script.requests.count
        commandJ(reopened)
        until({ script.requests.count == sentBefore + 1 && session.phase == .written })
        let edited = try XCTUnwrap(script.requests.last)
        XCTAssertTrue(edited.task.contains("ada@example.test"), "the user's own text goes as typed")
        XCTAssertTrue(edited.wantsSubject)
    }

    // MARK: What is sent

    /// A new message sends what the window holds and no more: the subject, the first names of the To recipients only
    /// (at most four, none for a bare address or an address written as a name), the user's first name only where Paper
    /// knows it, the notes and the instruction. No address, no Cc or Bcc name, no mail; the fixed instructions hold
    /// nothing typed or read.
    func testANewMessageSendsFirstNamesOfToOnlyAndNoMail() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        let to = [priya, EmailAddress(name: nil, address: "bare@example.test"),
                  EmailAddress(name: "DRESSED@example.test", address: "dressed@example.test"),
                  EmailAddress(name: "Ben Carter", address: "ben@example.test"), EmailAddress(name: "Ada", address: "ada@example.test"),
                  EmailAddress(name: "Grace Hopper", address: "grace@example.test"), EmailAddress(name: "Linus", address: "linus@example.test")]
        let link = MailtoLink(to: to, cc: [EmailAddress(name: "Carol Danvers", address: "carol@example.test")],
                              bcc: [EmailAddress(name: "Dave Bowman", address: "dave@example.test")], subject: "Q3 budget")
        for (account, name) in [(0, nil as String?), (1, "Alex")] {
            let composer = newMessage(harness, link: link, from: account)
            let session = try session(composer)
            type("numbers are in, need a yes by friday", in: composer)
            composer.helpMeWriteWithInstructions(nil)
            say("Friendly but brief", in: composer)
            until({ session.phase == .written })
            let request = try XCTUnwrap(script.requests.last)
            XCTAssertEqual(request.kind, .newMessage)
            XCTAssertFalse(request.userTurn.contains("@"), "no address")
            XCTAssertTrue(request.transcript.contains("Subject: Q3 budget"))
            XCTAssertTrue(request.transcript.contains("To: Priya, Ben, Ada, Grace\n"), "four first names, in To's order: \(request.transcript)")
            for absent in ["Linus", "Carol", "Danvers", "Dave", "Bowman", "Raman", "Carter", "bare", "DRESSED", "example.test"] {
                XCTAssertFalse(request.userTurn.contains(absent), "\(absent) is not sent")
            }
            XCTAssertTrue(request.task.contains("numbers are in, need a yes by friday"))
            XCTAssertTrue(request.task.hasSuffix("Write my message from these notes. Friendly but brief"))
            XCTAssertEqual(request.task.contains("My first name: Alex"), name != nil,
                           "the user's first name only for a Microsoft account, whose display name Paper knows")
            XCTAssertFalse(request.userTurn.contains("Morgan"))
            XCTAssertFalse(request.userTurn.contains("Project update"), "no mail from the store")
            for typed in ["numbers are in", "Friendly but brief", "Q3 budget", "Priya"] {
                XCTAssertFalse(request.instructions.contains(typed), "the fixed instructions hold nothing typed: \(typed)")
            }
            composer.closeWithoutSaving()
        }
        XCTAssertEqual(script.requests[0].instructions, script.requests[1].instructions)

        // A rewrite sends the selection and the instruction only: no subject, no names, no first name.
        let composer = newMessage(harness, link: link, from: 1)
        let session = try session(composer)
        type("numbers are in", in: composer)
        composer.bodyEditor.setSelectedRange(NSRange(location: 0, length: 7))
        commandJ(composer)
        until({ session.phase == .written })
        let rewrite = try XCTUnwrap(script.requests.last)
        XCTAssertEqual(rewrite.transcript, "")
        for absent in ["Q3 budget", "Priya", "Alex", "@"] { XCTAssertFalse(rewrite.userTurn.contains(absent), absent) }
    }

    /// The forwarded message's files go as a count of what is on the strip as the user asks, never as names.
    func testAForwardCountsTheFilesOnItsStripAndNeverNamesThem() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        let composer = try forward(harness)
        let session = try session(composer)
        let file = folder.appendingPathComponent("Quarterly-Plan.pdf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("plan".utf8).write(to: file)
        composer.attachDropped([.file(file)])
        XCTAssertEqual(composer.fileChipCount, 1)
        commandJ(composer)
        until({ session.phase == .written })
        let request = try XCTUnwrap(script.requests.first)
        XCTAssertTrue(request.transcript.contains("1 attachment"), request.transcript)
        XCTAssertFalse(request.userTurn.contains("Quarterly"), "never a file's name")
    }

    // MARK: Sheets and sends

    /// No write starts while the composer has a sheet attached (“Send without a subject?”, whose Send Anyway would
    /// take the body as it fills): the items do not apply, and a standing draft's Try again leaves the draft and its
    /// subject where they are, having read that nothing can be written before it undid anything.
    func testNoWriteStartsUnderASheetAndTryAgainLeavesTheDraftStanding() throws {
        let (harness, script) = try harness(reply: lunch)
        defer { harness.close() }
        let composer = newMessage(harness, link: MailtoLink(to: [priya]))
        try write("ask Priya to lunch", in: composer)
        let session = try session(composer)
        until({ session.phase == .written })
        let window = try XCTUnwrap(composer.window)

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        XCTAssertTrue(window.attachedSheet === sheet)
        XCTAssertEqual(titles(composer), [nil, nil], "neither item applies under a sheet")
        composer.helpMeWrite(nil)
        composer.helpMeWriteWithInstructions(nil)
        XCTAssertFalse(session.isWriting)
        XCTAssertFalse(session.isPromptShown)
        // The afterline's Try again and Shorter reach the session directly: they read first, and nothing is undone.
        press(.tryAgain, in: composer)
        press(.shorter, in: composer)
        session.write()
        ListTestSupport.spin(for: 0.1)
        XCTAssertFalse(session.isWriting)
        XCTAssertEqual(script.requests.count, 1, "nothing more was asked")
        XCTAssertEqual(composer.bodyText, lunchBody, "the draft stands")
        XCTAssertEqual(composer.subjectText, "Lunch on Thursday?", "and its subject")
        XCTAssertEqual(composer.bodyEditor.undoManager?.undoMenuItemTitle, "Undo Help Me Write", "its step is still there to undo")
        window.endSheet(sheet)

        XCTAssertEqual(titles(composer).first, "Try Again", "the sheet gone, it applies again")
        commandJ(composer)
        until({ script.requests.count == 2 && session.phase == .written })
    }

    private func button(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews { if let found = button(title, in: subview) { return found } }
        return nil
    }

    /// Send asks about an empty Subject on a sheet. No write starts under it; and were one streaming as the sheet is
    /// answered (the body refusing edits is how the window knows), Send Anyway sends nothing and a time chosen for
    /// Send Later schedules nothing: a half-written draft is not the user's to send.
    func testSendAnywayRefusesWhileADraftStreams() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        let composer = newMessage(harness, link: MailtoLink(to: [priya]))
        let session = try session(composer)
        type("lunch thursday", in: composer)
        func queued() -> Int { (try? harness.environment.store.pendingSendSummaries().count) ?? -1 }

        composer.send(nil)
        var sheet = try XCTUnwrap(composer.window?.attachedSheet, "Send asks about the empty Subject")
        composer.helpMeWrite(nil)
        session.write()
        XCTAssertFalse(session.isWriting, "no write starts under the sheet")
        composer.refusesBodyEdits = true
        try XCTUnwrap(button("Send Anyway", in: sheet.contentView)).performClick(nil)
        until({ composer.window?.attachedSheet == nil }, "the sheet is answered")
        ListTestSupport.spin(for: 0.2)
        XCTAssertEqual(queued(), 0, "nothing is sent while a draft streams")
        XCTAssertTrue(composer.window?.isVisible ?? false, "and the window stays")

        composer.refusesBodyEdits = false
        composer.sendLater(at: Date().addingTimeInterval(3_600))
        sheet = try XCTUnwrap(composer.window?.attachedSheet, "Send Later asks too")
        composer.refusesBodyEdits = true
        try XCTUnwrap(button("Send Anyway", in: sheet.contentView)).performClick(nil)
        until({ composer.window?.attachedSheet == nil })
        ListTestSupport.spin(for: 0.2)
        XCTAssertEqual(queued(), 0, "nor scheduled")
        XCTAssertTrue(composer.window?.isVisible ?? false)
        composer.refusesBodyEdits = false

        // Send itself waits for a write under way, so no sheet shows over one.
        script.holdsAfter = 2
        composer.window?.makeFirstResponder(composer.bodyEditor)
        commandJ(composer)
        until({ composer.bodyText.hasPrefix("One two three four") })
        composer.send(nil)
        composer.sendLater(at: Date().addingTimeInterval(3_600))
        XCTAssertNil(composer.window?.attachedSheet, "Send waits for the write: no sheet")
        XCTAssertEqual(queued(), 0)
        XCTAssertEqual(session.phase, .writing)
        session.stop()
        XCTAssertEqual(composer.bodyText, "lunch thursday")
    }

    // MARK: The demo writer

    #if DEBUG
    /// The writing render rests `writingHold` chunks into the message, whichever draft the ask picks: each of the
    /// demo's canned new messages and forward messages is longer, and so is every draft the render scripts, so the
    /// render never shows a landed draft instead.
    func testTheWritingRenderRestsPartWayIntoEveryDraftItCanWrite() {
        let hold = WriteSnapshotStates.writingHold
        let wanting = AIWriteRequest(kind: .newMessage, instructions: "", transcript: "", task: "t", wantsSubject: true)
        let scripted = [WriteSnapshotStates.reply, WriteSnapshotStates.longReply,
                        DemoAIScript.answer(WriteSnapshotStates.newMessageDraft, for: wanting).message]
        for message in DemoAIReplies.newMessages.map(\.body) + DemoAIReplies.forwardMessages + scripted {
            XCTAssertGreaterThan(DemoAIScript.chunks(of: message).count, hold, "rests part-way into “\(message.prefix(32))…”")
        }
    }
    #endif

    /// The demo writer answers a request that asks for a subject as a model does: the subject line first, then the
    /// message, so the demo's subject comes through the writer's own split. Its hold and fail counts are counted on
    /// the message, with or without a subject line before it.
    func testTheDemoWriterSendsTheSubjectLineAndCountsOnTheMessage() throws {
        let wanting = AIWriteRequest(kind: .newMessage, instructions: "", transcript: "", task: "Write my message from this brief:\nlunch",
                                     wantsSubject: true)
        let plain = AIWriteRequest(kind: .newMessage, instructions: "", transcript: "", task: "Write my message from this brief:\nlunch")
        let canned = DemoAIReplies.draft(for: wanting)
        let subject = try XCTUnwrap(canned.subject)
        XCTAssertEqual(DemoAIScript.answer(nil, for: wanting).subjectLine, "Subject: \(subject)\n\n")
        XCTAssertEqual(DemoAIScript.answer(nil, for: wanting).message, canned.body)
        XCTAssertEqual(DemoAIScript.answer(nil, for: plain).subjectLine, "", "no line unless one was asked for")
        XCTAssertEqual(DemoAIScript.answer(nil, for: plain).message, canned.body)
        XCTAssertEqual(DemoAIScript.answer(lunch, for: wanting).subjectLine, "Subject: Lunch on Thursday?\n\n")
        XCTAssertEqual(DemoAIScript.answer(lunch, for: wanting).message, lunchBody)
        let reply = AIWriteRequest(kind: .reply, instructions: "", transcript: "", task: "Write my reply.")
        XCTAssertEqual(DemoAIScript.answer(lunch, for: reply).subjectLine, "", "a reply's answer is all message")
        XCTAssertEqual(DemoAIScript.answer(lunch, for: reply).message, lunch)

        // In the app: held before the message's first words, the subject line has passed and nothing shows.
        let (harness, script) = try harness(reply: nil)
        defer { harness.close() }
        script.holdsAfter = 0
        let composer = newMessage(harness)
        try write("lunch", in: composer)
        let session = try session(composer)
        until({ script.requests.count == 1 })
        ListTestSupport.spin(for: 0.2)
        XCTAssertEqual(session.phase, .writing)
        XCTAssertEqual(composer.bodyText, "", "held before the message: none of the subject line is shown")
        session.stop()

        script.holdsAfter = nil
        script.failure = .keyRefused
        script.failsAfter = 2
        try write("lunch", in: composer)
        until({ session.phase.isFailed }, "it fails two chunks into the message, not into the subject line")
        XCTAssertEqual(composer.subjectText, "")
        script.failure = nil
        press(.tryAgain, in: composer)
        until({ session.phase == .written })
        let request = try XCTUnwrap(script.requests.last)
        let draft = DemoAIReplies.draft(for: request)
        XCTAssertEqual(composer.bodyText, draft.body, "the demo's own new message")
        XCTAssertEqual(composer.subjectText, try XCTUnwrap(draft.subject), "with its subject, through the real split")
    }
}
