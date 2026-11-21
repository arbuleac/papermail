import AppKit
import SSCore
@testable import SSDesign
import XCTest
@testable import SuperSparrowApp

/// Help me write at the caret (spec §5.56, 1.13): every mark is in the reply's text. The ghost after the caret on an empty
/// reply and after a pause at the end of the notes, the pill under a settled selection, ⇧⌘J's prompt line in a space the
/// text makes under the caret's line, the pencil after the last word while a reply streams, the afterline under the draft,
/// the text's menu; nothing in the quick reply's tool row or the composer's bar. Every write goes to the demo writer.
@MainActor
final class HelpMeWriteCaretTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowHelpMeWriteCaret-\(UUID().uuidString)")
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

    /// A main window on thread-2, `provider` chosen and turned on (`turnedOn`), the demo writer quick and scripted.
    private func harness(provider: AIProviderKind? = .claudeAPI, turnedOn: Bool = true,
                         reply: String = "Tuesday at ten works. See you then.") throws -> (MainWindowHarness, DemoAIScript) {
        let harness = try MainWindowHarness()
        harness.settings.aiProvider = provider
        if let provider, turnedOn { harness.settings.setAIConsent(true, for: provider, demo: false) }
        harness.environment.helpMeWrite.presentAlert = { _, _, done in done(0) }
        let script = try XCTUnwrap(harness.environment.helpMeWrite.demoScript)
        script.delay = .milliseconds(1)
        script.reply = reply
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentMessages.count == 3 }
        return (harness, script)
    }

    /// The quick reply focused with `text` typed, its session drawing as in the key window (the test window never is).
    @discardableResult
    private func type(_ text: String, _ harness: MainWindowHarness) throws -> (NSTextView, WriteSession) {
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        let field = harness.reader.quickReplyBar.writingTextView
        let session = try XCTUnwrap(harness.reader.quickReplyWriteSession)
        session.assumesKeyWindow = true
        field.insertText(text, replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        harness.reader.quickReplyBar.layoutSubtreeIfNeeded()
        return (field, session)
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

    /// A reply composer with the keyboard in its body, its session drawing as in the key window.
    private func composerSession(_ harness: MainWindowHarness) throws -> (ComposeWindowController, WriteSession) {
        let composer = replyComposer(harness)
        composer.window?.makeFirstResponder(composer.bodyEditor)
        let session = try XCTUnwrap(composer.bodyWriteSession)
        session.assumesKeyWindow = true
        composer.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))
        return (composer, session)
    }

    /// Whether anything titled Write (1.12's control) shows in `view`'s tree.
    private func showsAWriteButton(in view: NSView) -> Bool {
        if !view.isHiddenOrHasHiddenAncestor, let button = view as? QuireButton, button.title == "Write" { return true }
        if !view.isHiddenOrHasHiddenAncestor, view.accessibilityLabel() == "Write with Help Me Write",
           !(view is WriteCaretHint) { return true }
        return view.subviews.contains { showsAWriteButton(in: $0) }
    }

    // MARK: Nothing in the bars

    func testNeitherTheToolRowNorTheComposersBarHoldsWrite() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        try type("tue 10 works, I'll bring the budget", harness)
        let bar = harness.reader.quickReplyBar
        bar.layoutSubtreeIfNeeded()
        let tools = bar.subviews.filter { !($0 is NSScrollView) }
        XCTAssertFalse(tools.contains { showsAWriteButton(in: $0) }, "the quick reply's tool row holds no Write")
        let (composer, _) = try composerSession(harness)
        composer.content.layoutSubtreeIfNeeded()
        XCTAssertFalse(showsAWriteButton(in: composer.content.bottomBar), "nor does the composer's bar")
    }

    // MARK: The ghost

    /// An empty reply shows the ghost at once: after the quick reply's placeholder words, at the caret in a composer.
    func testTheGhostShowsAtOnceOnAnEmptyFocusedReply() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let (field, session) = try type("", harness)
        let layer = session.layer
        XCTAssertEqual(layer.state.ghost?.words, WriteWords.ghostAfterPlaceholder)
        let offset = try XCTUnwrap(layer.state.ghost?.offset)
        XCTAssertGreaterThan(offset, 100, "after “Reply to …”")
        XCTAssertFalse(layer.ghost.isHidden)
        XCTAssertTrue(layer.ghost.showsWords)
        let face = layer.ghost.alignmentRect(forFrame: layer.ghost.frame)
        XCTAssertEqual(face.minX, offset + Quire.Layout.WriteCaret.ghostGap, accuracy: 1, "after the placeholder's words, on its line")
        XCTAssertTrue(layer.ghost.isDescendant(of: field), "in the text")

        let (composer, composed) = try composerSession(harness)
        XCTAssertEqual(composed.layer.state.ghost?.words, WriteWords.ghostReply)
        XCTAssertEqual(composed.layer.state.ghost?.offset, 0)
        let ghost = composed.layer.ghost.alignmentRect(forFrame: composed.layer.ghost.frame)
        XCTAssertEqual(ghost.minX, Quire.Layout.Composer.valueX + Quire.Layout.WriteCaret.ghostGap, accuracy: 1, "at the caret")
        let caret = try XCTUnwrap(WriteTextGeometry.caret(at: 0, in: composer.bodyEditor, attributes: composed.layer.textAttributes))
        XCTAssertEqual(ghost.minY + composed.layer.ghost.baselineFromTop, caret.baseline, accuracy: 0.5, "on the caret's baseline")
    }

    /// The notes ghost waits for a pause, goes on the next key and the next click, and needs the user's own words.
    func testTheNotesGhostWaitsForAPauseAndGoesOnTheNextKey() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let (field, session) = try type("thursday", harness)
        let layer = session.layer
        ListTestSupport.spin(for: Quire.Motion.writeGhostPause + 0.3)
        XCTAssertNil(layer.state.ghost, "one word is not yet notes")
        field.insertText(" works", replacementRange: field.selectedRange())
        XCTAssertNil(layer.state.ghost, "not while typing")
        until({ layer.state.ghost?.words == WriteWords.ghostNotes }, "after a pause")
        XCTAssertTrue(layer.state.ghost?.fades == true, "it fades in")
        XCTAssertFalse(layer.ghost.isHidden)
        field.insertText("!", replacementRange: field.selectedRange())
        XCTAssertNil(layer.state.ghost, "gone on the next key")
        until({ layer.state.ghost != nil })
        field.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNil(layer.state.ghost, "never mid-line, and gone on a click")
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
        XCTAssertNil(layer.state.ghost, "back at the end, it waits for a pause again")
        until({ layer.state.ghost != nil })
        harness.controller.window?.makeFirstResponder(harness.list.tableView)
        XCTAssertNil(layer.state.ghost, "gone as the keyboard leaves")
        XCTAssertTrue(layer.ghost.isHidden)
    }

    /// At the end of a paragraph inside the notes (a line break after the caret) the ghost shows; in the signature never.
    func testTheGhostEndsAParagraphOfTheUsersOwnText() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        try harness.environment.store.setSignature("<p>Alex</p>", for: ListTestSupport.accountA.id)
        harness.controller.refreshAccounts()
        let (composer, session) = try composerSession(harness)
        let editor = composer.bodyEditor
        editor.insertText("Hi Sam,\nsee you tuesday", replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        session.showNotesGhostNow()
        XCTAssertEqual(session.layer.state.ghost?.words, WriteWords.ghostNotes, "the end of a paragraph of the notes")
        let alex = (editor.string as NSString).range(of: "Alex")
        editor.setSelectedRange(NSRange(location: NSMaxRange(alex), length: 0))
        session.showNotesGhostNow()
        XCTAssertNil(session.layer.state.ghost, "never in the signature")
    }

    func testTheGhostNeedsAReadyProviderAndNoMarkedText() throws {
        for (provider, turnedOn) in [(AIProviderKind?.none, true), (.claudeAPI, false)] {
            let (harness, _) = try harness(provider: provider, turnedOn: turnedOn)
            defer { harness.close() }
            let (_, session) = try type("", harness)
            XCTAssertNil(session.layer.state.ghost, "\(String(describing: provider)) \(turnedOn): no ghost")
            XCTAssertTrue(session.layer.ghost.isHidden)
        }
        let (harness, _) = try harness()
        defer { harness.close() }
        let (field, session) = try type("", harness)
        XCTAssertNotNil(session.layer.state.ghost)
        field.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(field.hasMarkedText())
        session.selectionDidChange()
        XCTAssertNil(session.layer.state.ghost, "not while an input method's text is open")
        field.unmarkText()
    }

    /// The ghost never wraps and never runs past its line: whole where it fits, its keycap alone where only that does,
    /// else not at all.
    func testTheGhostTakesOnlyTheRoomItsLineHas() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let (field, session) = try type("ok then", harness)
        let layer = session.layer
        let column = WriteTextGeometry.column(of: field)
        var forms: [String] = []
        for _ in 0..<400 {
            field.insertText("w", replacementRange: field.selectedRange())
            session.showNotesGhostNow()
            guard let caret = WriteTextGeometry.caret(at: field.selectedRange().location, in: field, attributes: layer.textAttributes),
                  abs(caret.line.minY - field.textContainerOrigin.y) < 0.5 else { break }
            let form = layer.ghost.isHidden ? "none" : layer.ghost.showsWords ? "whole" : "keycap"
            if forms.last != form { forms.append(form) }
            if !layer.ghost.isHidden {
                let face = layer.ghost.alignmentRect(forFrame: layer.ghost.frame)
                XCTAssertLessThanOrEqual(face.minX + layer.ghost.width(showingWords: layer.ghost.showsWords), column.maxX + 0.5,
                                         "never past the column")
                XCTAssertGreaterThanOrEqual(face.minX, caret.x, "never over the text")
            }
        }
        XCTAssertEqual(forms, ["whole", "keycap", "none"])
    }

    func testAClickOnTheGhostWrites() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        let (field, session) = try type("", harness)
        session.layer.ghost.performClick(nil)
        until({ session.phase == .written })
        XCTAssertEqual(field.string, "Tuesday at ten works. See you then.")
        XCTAssertEqual(script.requests.count, 1)
    }

    // MARK: The selection pill

    func testThePillHangsUnderASettledSelectionAndGoesWithIt() throws {
        let (harness, script) = try harness(reply: "I\u{2019}ll bring the venue list")
        defer { harness.close() }
        let (composer, session) = try composerSession(harness)
        let editor = composer.bodyEditor
        editor.insertText("tue 10 works, I'll bring the budget", replacementRange: NSRange(location: 0, length: 0))
        let layer = session.layer
        editor.setSelectedRange(NSRange(location: 14, length: 21))
        XCTAssertEqual(layer.state.pill, NSRange(location: 14, length: 21))
        XCTAssertFalse(layer.pill.isHidden)
        let pill = editor.convert(layer.pill.alignmentRect(forFrame: layer.pill.frame), from: layer.pill.superview)
        let end = try XCTUnwrap(WriteTextGeometry.caret(at: 35, in: editor, attributes: layer.textAttributes))
        XCTAssertEqual(pill.minY, end.line.maxY + Quire.Layout.WriteCaret.pillGap, accuracy: 0.5, "under the selection's last line")
        XCTAssertEqual(pill.minX, end.x, accuracy: 0.5, "its leading edge at the selection's end")
        XCTAssertEqual(layer.pill.accessibilityLabel(), "Rewrite selection with Help Me Write")
        editor.setSelectedRange(NSRange(location: 20, length: 0))
        XCTAssertNil(layer.state.pill, "gone as the selection collapses")
        XCTAssertTrue(layer.pill.isHidden)
        editor.setSelectedRange(NSRange(location: 14, length: 21))
        layer.pill.performClick(nil)
        until({ session.phase == .written })
        XCTAssertTrue(script.requests.first?.task.contains("<<<SELECTION") == true, "a click rewrites the selection")
        XCTAssertTrue(composer.bodyText.hasPrefix("tue 10 works, I\u{2019}ll bring the venue list"), composer.bodyText)
    }

    /// In the quick reply the pill never lands on the tool row, nor outside the field: on the selection's line after its
    /// end where nothing follows it, else at the end of the line's text.
    func testTheQuickReplysPillNeverCoversTheToolRow() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let (field, session) = try type("tue 10 works, I\u{2019}ll bring the budget", harness)
        let bar = harness.reader.quickReplyBar
        let controls = bar.subviews.filter { !$0.isHidden && ($0 is QuireControl || $0 is QuireUnderlineTabs || $0 is QuireSplitButton) }
            .filter { !($0 is WriteSelectionPill) }
        XCTAssertTrue(controls.contains { $0 is QuireSplitButton }, "Send is among them")
        let field1 = bar.restGeometry.field
        for selection in [NSRange(location: 14, length: 21), NSRange(location: 0, length: 6), NSRange(location: 4, length: 2)] {
            field.setSelectedRange(selection)
            bar.layoutSubtreeIfNeeded()
            let layer = session.layer
            XCTAssertFalse(layer.pill.isHidden, "\(selection)")
            let pill = layer.pill.alignmentRect(forFrame: layer.pill.frame)
            for control in controls {
                XCTAssertFalse(pill.intersects(control.frame.insetBy(dx: 4, dy: 4)), "\(selection) over \(Swift.type(of: control))")
            }
            let text = field.enclosingScrollView!.frame
            XCTAssertEqual(pill.midY, text.minY + 21 / 2, accuracy: 1, "\(selection): on the selection's own line")
            XCTAssertTrue(field1.insetBy(dx: 0, dy: -1).contains(pill) || bar.bounds.contains(pill), "\(selection): inside the bar")
        }
    }

    // MARK: Reserved blocks

    /// ⇧⌘J under the first of two lines: the second line moves down by the block's height, and back as it closes; the
    /// quick reply grows by as much, beyond its five lines.
    func testThePromptLineMakesRoomInTheText() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let (field, session) = try type("first line\nsecond line", harness)
        let bar = harness.reader.quickReplyBar
        field.setSelectedRange(NSRange(location: 10, length: 0))
        func secondLineTop() -> CGFloat {
            field.layoutManager!.ensureLayout(for: field.textContainer!)
            let glyph = field.layoutManager!.glyphIndexForCharacter(at: 12)
            return field.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        }
        let top = secondLineTop()
        let height = bar.barHeight
        harness.reader.helpMeWriteWithInstructions(nil)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(secondLineTop() - top, WritePromptLine.blockHeight, accuracy: 0.5, "the line below moved down")
        XCTAssertEqual(bar.barHeight - height, WritePromptLine.blockHeight, accuracy: 0.5, "and the field grew by as much")
        XCTAssertEqual(field.string, "first line\nsecond line", "the text never changes for it")
        let prompt = session.layer.prompt
        XCTAssertEqual(prompt.frame.minY, field.textContainerOrigin.y + 21 + Quire.Layout.WriteCaret.blockGapTop, accuracy: 0.5,
                       "under the caret's line")
        XCTAssertEqual(prompt.frame.minX, WriteTextGeometry.column(of: field).minX, accuracy: 0.5, "on the text column")
        session.closePrompt(focusText: true)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(secondLineTop(), top, accuracy: 0.5, "and back as it closes")
        XCTAssertEqual(bar.barHeight, height, accuracy: 0.5)

        // Five lines and a block: the block does not count against the five.
        field.insertText("\nthree\nfour\nfive", replacementRange: NSRange(location: (field.string as NSString).length, length: 0))
        bar.layoutSubtreeIfNeeded()
        let full = bar.barHeight
        harness.reader.helpMeWriteWithInstructions(nil)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.barHeight - full, WritePromptLine.blockHeight, accuracy: 0.5)
    }

    /// The afterline hangs under the draft's last line; typing, Esc and the keyboard leaving take it away.
    func testTheAfterlineHangsUnderTheDraftUntilTheUserMovesOn() throws {
        let (harness, _) = try harness(reply: "Tuesday at ten works for me. I\u{2019}ll bring the draft budget, and we can go through the open questions on the venue together.")
        defer { harness.close() }
        let (field, session) = try type("tue 10 ok", harness)
        let bar = harness.reader.quickReplyBar
        let height = bar.barHeight
        harness.reader.helpMeWrite(nil)
        until({ session.phase == .written })
        bar.layoutSubtreeIfNeeded()
        let afterline = session.layer.afterline
        XCTAssertFalse(afterline.isHidden)
        let used = field.layoutManager!.usedRect(for: field.textContainer!)
        XCTAssertEqual(afterline.frame.minY, field.textContainerOrigin.y + used.maxY + Quire.Layout.WriteCaret.blockGapTop, accuracy: 0.5,
                       "under the draft's last line")
        XCTAssertGreaterThanOrEqual(field.frame.maxY, afterline.frame.maxY, "inside the text view, where its clicks land")
        XCTAssertEqual(bar.barHeight - height, WriteInlineLayer.Block.afterline(.end(0), .failed(reason: "", offersSettings: false)).height
                       + CGFloat(Int(used.height / 21) - 1) * 21, accuracy: 0.5, "the field grew by its room and the draft's lines")
        field.insertText(" Thanks", replacementRange: NSRange(location: (field.string as NSString).length, length: 0))
        XCTAssertTrue(afterline.isHidden, "typing takes it away")

        harness.reader.helpMeWrite(nil)
        until({ session.phase == .written })
        XCTAssertFalse(afterline.isHidden)
        field.cancelOperation(nil)
        XCTAssertTrue(afterline.isHidden, "Esc dismisses it")
        XCTAssertEqual(session.phase, .idle)
        XCTAssertTrue(field.string.hasPrefix("Tuesday at ten"), "the draft kept")
        XCTAssertTrue(harness.controller.window?.firstResponder === field, "and the keyboard stays")
    }

    /// The afterline gives way where the column is tight, each step measured: the keycaps, then Shorter, then the words
    /// (the glyph stays), then Say how; a failure keeps its reason longest and cuts it where it must. Nothing past the room.
    func testTheAfterlineGivesWayInOrder() throws {
        let afterline = WriteAfterline(frame: NSRect(x: 0, y: 0, width: 800, height: WriteAfterline.height))
        afterline.content = .written(writer: "Claude", rewrite: false, source: "Claude Opus 5.5 \u{00b7} Anthropic")
        var seen: [WriteAfterline.Form] = []
        for width in stride(from: CGFloat(800), through: 120, by: -4) {
            afterline.setFrameSize(NSSize(width: width, height: WriteAfterline.height))
            afterline.layoutSubtreeIfNeeded()
            if seen.last != afterline.form { seen.append(afterline.form) }
            for link in afterline.actions.values where !link.isHidden {
                XCTAssertLessThanOrEqual(link.alignmentRect(forFrame: link.frame).maxX, width + 0.5, "nothing past \(width)")
            }
        }
        XCTAssertEqual(seen, [WriteAfterline.Form(), .init(keycaps: false), .init(keycaps: false, shorter: false),
                              .init(keycaps: false, shorter: false, words: false),
                              .init(keycaps: false, shorter: false, words: false, sayHow: false)])
        XCTAssertEqual(afterline.lineWords,
                       "Written by Claude \u{00b7} Try again \u{2318}J \u{00b7} Shorter \u{00b7} Say how \u{21e7}\u{2318}J \u{00b7} Undo \u{2318}Z",
                       "VoiceOver hears the whole line")
        XCTAssertEqual(afterline.toolTip, "Claude Opus 5.5 \u{00b7} Anthropic")

        let reason = AIError.signedOut.lineMessage(for: .claudeCode)
        afterline.content = .failed(reason: reason, offersSettings: true)
        afterline.setFrameSize(NSSize(width: 800, height: WriteAfterline.height))
        afterline.layoutSubtreeIfNeeded()
        XCTAssertEqual(afterline.shownWords, reason + " \u{00b7} Try again \u{2318}J \u{00b7} Settings\u{2026}")
        afterline.setFrameSize(NSSize(width: 300, height: WriteAfterline.height))
        afterline.layoutSubtreeIfNeeded()
        XCTAssertTrue(afterline.shownWords.contains("\u{2026} \u{00b7} Try again"), "the reason cut, its links kept: \(afterline.shownWords)")
        XCTAssertFalse(afterline.actions[.settings]?.isHidden ?? true)
        XCTAssertFalse(AIError.rateLimited(retryAfter: 30).lineMessage(for: .claudeAPI).contains("Try again"))
    }

    /// In a composer a block often opens inside the body's text (under a line more notes or the signature follow): the
    /// lines under it move down, and the body grows by as much, so they stay in the editor, over nothing of the quoted
    /// original, where a click reaches them; and back as it closes.
    func testABlockInsideTheComposersBodyGrowsIt() throws {
        let (harness, _) = try harness(reply: "Thursday")
        defer { harness.close() }
        let (composer, session) = try composerSession(harness)
        let editor = composer.bodyEditor
        let lines = (1...30).map { "line \($0) of my notes" }.joined(separator: "\n")
        editor.insertText(lines, replacementRange: NSRange(location: 0, length: 0))
        let page = try XCTUnwrap(composer.window?.contentView)
        page.layoutSubtreeIfNeeded()
        func textFits(_ message: String) {
            let used = editor.layoutManager!.usedRect(for: editor.textContainer!)
            XCTAssertGreaterThanOrEqual(editor.frame.height, editor.textContainerOrigin.y + used.maxY - 0.5, message)
        }
        let height = editor.frame.height
        textFits("at rest")

        editor.setSelectedRange(NSRange(location: 3, length: 0))
        composer.helpMeWriteWithInstructions(nil)
        XCTAssertTrue(session.isPromptShown)
        page.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.frame.height - height, WritePromptLine.blockHeight, accuracy: 0.5, "the body grew by the prompt line")
        textFits("its last line still in the editor")
        session.closePrompt(focusText: true)
        page.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.frame.height, height, accuracy: 0.5, "and gave it back")

        // A rewrite in the first line: the afterline under it, thirty lines below it.
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        composer.helpMeWrite(nil)
        until({ session.phase == .written })
        page.layoutSubtreeIfNeeded()
        XCTAssertFalse(session.layer.afterline.isHidden)
        let afterline = WriteInlineLayer.Block.afterline(.end(0), .written(writer: "", rewrite: true, source: nil)).height
        XCTAssertEqual(editor.frame.height - height, afterline, accuracy: 0.5, "the body grew by the afterline")
        textFits("under the afterline too")
        session.escape()
        page.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.frame.height, height, accuracy: 0.5)
    }

    // MARK: The pencil

    func testThePencilFollowsTheLastWordAndAClickStops() throws {
        let (harness, script) = try harness(reply: "One two three four five six seven eight")
        defer { harness.close() }
        script.holdsAfter = 2
        let (field, session) = try type("my notes", harness)
        harness.reader.helpMeWrite(nil)
        XCTAssertFalse(session.layer.pencil.isHidden, "at once, after the text it will replace")
        XCTAssertEqual(field.insertionPointColor, .clear, "the insertion point gives way to it")
        until({ field.string == "One two three four " })
        let pencil = session.layer.pencil
        XCTAssertEqual(session.layer.state.pencil, (field.string as NSString).length)
        let caret = try XCTUnwrap(WriteTextGeometry.caret(at: (field.string as NSString).length, in: field, attributes: session.layer.textAttributes))
        XCTAssertEqual(pencil.alignmentRect(forFrame: pencil.frame).minX, caret.x + Quire.Layout.WriteCaret.pencilGap, accuracy: 0.5,
                       "just after the last word")
        XCTAssertEqual(pencil.toolTip, "Stop  esc")
        pencil.performClick(nil)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(field.string, "my notes", "a click stops, as esc does")
        XCTAssertTrue(pencil.isHidden)
        XCTAssertNotEqual(field.insertionPointColor, .clear, "and the insertion point comes back")
    }

    // MARK: The text's menu and Esc

    func testTheTextsMenuOpensWithHelpMeWrite() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let (field, session) = try type("tue 10 ok", harness)
        let bar = harness.reader.quickReplyBar
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: nil, keyEquivalent: "")
        let shown = try XCTUnwrap(bar.textView(field, menu: menu, for: event, at: 0))
        XCTAssertEqual(shown.items.map(\.title), ["Write Reply from Notes", "Say How\u{2026}", "", "Cut"])
        XCTAssertEqual(shown.items[0].keyEquivalent, "j")
        XCTAssertEqual(shown.items[0].keyEquivalentModifierMask, .command)
        XCTAssertTrue(shown.items[2].isSeparatorItem)
        field.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertEqual(session.contextMenuItems().first?.title, "Rewrite Selection")
        field.setSelectedRange(NSRange(location: 9, length: 0))
        let say = shown.items[1]
        _ = (say.target as? NSObject)?.perform(say.action, with: say)
        XCTAssertTrue(session.isPromptShown, "Say How… opens the prompt line")

        let (composer, composed) = try composerSession(harness)
        let body = NSMenu()
        let composerMenu = composer.textView(composer.bodyEditor, menu: body, for: event, at: 0)
        XCTAssertEqual(composerMenu?.items.first?.title, "Write Reply")
        _ = composed
    }

    /// Esc: a write stops, then the prompt line closes, then the afterline goes, then Esc is the field's own again.
    func testEscGoesInOrder() throws {
        let (harness, script) = try harness()
        defer { harness.close() }
        let (_, session) = try type("tue 10 ok", harness)
        script.holdsAfter = 1
        harness.reader.helpMeWrite(nil)
        XCTAssertTrue(session.escape())
        XCTAssertEqual(session.phase, .idle, "a write stops first")
        script.holdsAfter = nil
        harness.reader.helpMeWrite(nil)
        until({ session.phase == .written })
        harness.reader.helpMeWriteWithInstructions(nil)
        XCTAssertTrue(session.isPromptShown)
        XCTAssertTrue(session.escape())
        XCTAssertFalse(session.isPromptShown, "then the prompt line closes")
        session.layer.afterline.actions[.tryAgain]?.performClick(nil)
        until({ session.phase == .written })
        XCTAssertTrue(session.escape())
        XCTAssertEqual(session.phase, .idle, "then the afterline goes")
        XCTAssertFalse(session.escape(), "then Esc is the field's own")
    }
}
