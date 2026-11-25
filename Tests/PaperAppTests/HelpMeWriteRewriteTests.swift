import AppKit
import PaperCore
@testable import PaperDesign
import XCTest
@testable import PaperApp

/// A selection's rewrite in place (spec §5.56): it reads the user's own draft around the selection, and the words right
/// beside it may change, a little, so the part joins its sentence, in the part's one undo step. Every write goes to the
/// demo writer, scripted as a model would answer; nothing here reaches the network, a CLI or the Keychain.
@MainActor
final class HelpMeWriteRewriteTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperHelpMeWriteRewrite-\(UUID().uuidString)")
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

    /// “John is coming tomorrow.” with “John” rewritten: the part, then an AFTER line that changes one of the three words
    /// after it.
    private let seamed = "Priya and Ben\n<<<AFTER {fence}>>>are coming tomorrow<<<END AFTER {fence}>>>"

    /// A main window on thread-2, Claude chosen and turned on, the demo writer quick and answering `reply`.
    private func harness(reply: String?) throws -> (MainWindowHarness, DemoAIScript) {
        let harness = try MainWindowHarness()
        harness.settings.aiProvider = .claudeAPI
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        let script = try XCTUnwrap(harness.environment.helpMeWrite.demoScript)
        script.delay = .milliseconds(1)
        script.reply = reply
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentMessages.count == 3 }
        return (harness, script)
    }

    /// The quick reply focused with `text` in it, its marks drawn as in the key window.
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

    private func press(_ action: WriteAfterline.Action, in layer: WriteInlineLayer) {
        layer.afterline.layoutSubtreeIfNeeded()
        layer.afterline.actions[action]?.performClick(nil)
    }

    private func commandJ(_ harness: MainWindowHarness, file: StaticString = #filePath, line: UInt = #line) {
        let item = NSMenuItem(title: "", action: #selector(ConversationViewController.helpMeWrite(_:)), keyEquivalent: "j")
        XCTAssertTrue(harness.reader.validateMenuItem(item), "⌘J applies", file: file, line: line)
        harness.reader.helpMeWrite(nil)
    }

    private func until(_ condition: () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ListTestSupport.spin(until: condition, timeout: 5), message, file: file, line: line)
    }

    private func color(of field: NSTextView, at index: Int) -> NSColor? {
        field.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    private func select(_ words: String, in field: NSTextView) {
        let range = (field.string as NSString).range(of: words)
        XCTAssertNotEqual(range.location, NSNotFound, words)
        field.setSelectedRange(range)
    }

    /// Where the afterline hangs.
    private func afterlineAnchor(_ harness: MainWindowHarness) -> WriteInlineLayer.Anchor? {
        if case .afterline(let anchor, _)? = layer(harness).state.block { return anchor }
        return nil
    }

    /// What a frame sent of the draft, its instruction aside: the same draft around the same selection.
    private func around(_ request: AIWriteRequest?) -> [String?] {
        guard let frame = request?.rewrite else { return [] }
        return [frame.lead, frame.before, frame.gapBefore, frame.selection, frame.gapAfter, frame.after, frame.trail]
    }

    // MARK: The quick reply

    func testAQuickReplysRewriteReadsTheDraftAndJoinsTheWordsBesideIt() throws {
        let (harness, script) = try harness(reply: seamed)
        defer { harness.close() }
        var announced: [String] = []
        QuireAccessibility.observer = { _, text in if let text { announced.append(text) } }
        let field = type("John is coming tomorrow.", harness)
        let session = try session(harness)

        // Mid-stream: the part in pencil in the selection's place, the words beside it in ink and as typed.
        script.holdsAfter = 1
        field.setSelectedRange(NSRange(location: 0, length: 4))
        commandJ(harness)
        until({ field.string.hasPrefix("Priya and ") }, "the part's first words stream in")
        let request = try XCTUnwrap(script.requests.first)
        let code = request.fence
        XCTAssertTrue(request.task.contains("<<<DRAFT \(code)>>>"))
        XCTAssertTrue(request.task.contains("<<<SELECTION \(code)>>>John<<<END SELECTION \(code)>>> <<<AFTER \(code)>>>is coming tomorrow"
                                            + "<<<END AFTER \(code)>>>."))
        XCTAssertEqual(request.promptVersion, "rewrite-reply-1")
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(field.string, "Priya and  is coming tomorrow.", "only the part, and never a marker")
        XCTAssertEqual(color(of: field, at: 0), WriteStreamEdit.pencilInk)
        let neighbour = (field.string as NSString).range(of: "is coming").location
        XCTAssertNotEqual(color(of: field, at: neighbour), WriteStreamEdit.pencilInk, "the words beside it are never pencilled")

        // Esc mid-write, the seam line still to come: everything as it was, the selection too.
        XCTAssertTrue(session.escape())
        XCTAssertEqual(field.string, "John is coming tomorrow.")
        XCTAssertEqual(field.selectedRange(), NSRange(location: 0, length: 4))

        // Landed: the part and the joined words in one step, the caret after the part, the afterline under it.
        script.holdsAfter = nil
        commandJ(harness)
        until({ session.phase == .written })
        XCTAssertEqual(field.string, "Priya and Ben are coming tomorrow.")
        XCTAssertEqual(field.selectedRange(), NSRange(location: 13, length: 0))
        XCTAssertEqual(afterlineAnchor(harness), .end(13))
        XCTAssertEqual(announced.last, "Selection rewritten by Claude, with the words next to it adjusted")
        XCTAssertEqual(field.undoManager?.undoMenuItemTitle, "Undo Help Me Write")

        // One ⌘Z: the text and the selection as they were. ⇧⌘Z: all of it again, the caret after the part.
        field.undoManager?.undo()
        XCTAssertEqual(field.string, "John is coming tomorrow.")
        XCTAssertEqual(field.selectedRange(), NSRange(location: 0, length: 4))
        field.undoManager?.redo()
        XCTAssertEqual(field.string, "Priya and Ben are coming tomorrow.")
        XCTAssertEqual(field.selectedRange(), NSRange(location: 13, length: 0), "nothing selected")
        XCTAssertEqual(session.plan, .tryAgain, "⌘Z then ⇧⌘Z keeps Try again")
    }

    func testABeforeSeamThatChangesLengthMovesWhereThePartEnds() throws {
        let (harness, _) = try harness(reply: "could have the garden\n<<<BEFORE {fence}>>>so we<<<END BEFORE {fence}>>>")
        defer { harness.close() }
        let field = type("Tomorrow and then we can has the garden too.", harness)
        let session = try session(harness)
        select("can has the garden", in: field)
        let selected = field.selectedRange()
        commandJ(harness)
        until({ session.phase == .written })
        XCTAssertEqual(field.string, "Tomorrow so we could have the garden too.")
        let partEnd = ("Tomorrow so we could have the garden" as NSString).length
        XCTAssertEqual(field.selectedRange(), NSRange(location: partEnd, length: 0))
        XCTAssertEqual(afterlineAnchor(harness), .end(partEnd), "the afterline hangs under the part's own end")
        press(.sayHow, in: layer(harness))
        XCTAssertTrue(session.isPromptShown)
        XCTAssertEqual(layer(harness).state.block, .prompt(.end(partEnd), chips: true), "and so does Say how")
        session.closePrompt(focusText: true)
        field.undoManager?.undo()
        XCTAssertEqual(field.string, "Tomorrow and then we can has the garden too.")
        XCTAssertEqual(field.selectedRange(), selected)
    }

    func testASeamThatFailsItsChecksLeavesTheWordsBesideThePart() throws {
        let (harness, script) = try harness(reply: nil)
        defer { harness.close() }
        let field = type("", harness)
        let session = try session(harness)
        let refused = [
            "Priya and Ben\n<<<AFTER {fence}>>>they will all be here<<<END AFTER {fence}>>>",
            "Priya and Ben\n<<<AFTER {fence}>>>are\n<<<END AFTER {fence}>>>",
            "Priya and Ben\n<<<AFTER {fence}>>>are coming",
            "Priya and Ben\n<<<BEFORE {fence}>>>So<<<END BEFORE {fence}>>>",
        ]
        for (index, answer) in refused.enumerated() {
            script.reply = answer
            field.insertText("John is coming tomorrow.", replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
            field.setSelectedRange(NSRange(location: 0, length: 4))
            commandJ(harness)
            until({ script.requests.count == index + 1 && session.phase == .written }, answer)
            XCTAssertTrue(field.string.hasPrefix("Priya and Ben"), answer)
            XCTAssertTrue(field.string.hasSuffix(" is coming tomorrow."), "\(answer): the words beside it stand: \(field.string)")
        }
    }

    func testAPartThatBeginsWithPunctuationTakesNoBlankBeforeIt() throws {
        let (harness, script) = try harness(reply: ", and we can use")
        defer { harness.close() }
        let field = type("It fits 40 people and we can use the garden.", harness)
        let session = try session(harness)
        select("and we can use", in: field)
        commandJ(harness)
        until({ session.phase == .written })
        XCTAssertEqual(field.string, "It fits 40 people, and we can use the garden.")
        field.undoManager?.undo()
        XCTAssertEqual(field.string, "It fits 40 people and we can use the garden.")

        script.reply = "; and we can use\n<<<AFTER {fence}>>>all the garden<<<END AFTER {fence}>>>"
        select("and we can use", in: field)
        commandJ(harness)
        until({ script.requests.count == 2 && session.phase == .written })
        XCTAssertEqual(field.string, "It fits 40 people; and we can use all the garden.")
    }

    /// New words that come right up to the part, where the window's own punctuation and a blank parted it from the
    /// selection, keep the blank: the punctuation may go, but no word glues onto the part.
    func testNewWordsRightBesideThePartKeepTheBlankThatPartedThem() throws {
        let (harness, script) = try harness(reply: nil)
        defer { harness.close() }
        let field = type("", harness)
        let session = try session(harness)
        let notes = "It has room for 40 people and we can has the garden too, so the March dates work."
        let cases = [
            ("we can have the garden too.\n<<<AFTER {fence}>>>So the March<<<END AFTER {fence}>>>",
             "It has room for 40 people and we can have the garden too. So the March dates work."),
            ("we can have the garden too\n<<<AFTER {fence}>>>so the March<<<END AFTER {fence}>>>",
             "It has room for 40 people and we can have the garden too so the March dates work."),
            ("we can have the garden too\n<<<AFTER {fence}>>>,so the March<<<END AFTER {fence}>>>",
             "It has room for 40 people and we can have the garden too, so the March dates work."),
        ]
        for (index, (answer, landed)) in cases.enumerated() {
            script.reply = answer
            field.insertText(notes, replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
            select("we can has the garden too", in: field)
            commandJ(harness)
            until({ script.requests.count == index + 1 && session.phase == .written }, answer)
            XCTAssertEqual(script.requests.last?.rewrite?.after, ", so the March", "no gap: the comma and its blank are the window's")
            XCTAssertEqual(field.string, landed, answer)
        }

        // The mirror before the part: “Please call (” then the part, with no gap.
        script.reply = "Ben\n<<<BEFORE {fence}>>>Please call<<<END BEFORE {fence}>>>\n<<<AFTER {fence}>>>today<<<END AFTER {fence}>>>"
        field.insertText("Please call (John) today.", replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        select("John", in: field)
        commandJ(harness)
        until({ script.requests.count == cases.count + 1 && session.phase == .written })
        XCTAssertEqual(script.requests.last?.rewrite?.before, "Please call (")
        XCTAssertEqual(script.requests.last?.rewrite?.after, ") today")
        XCTAssertEqual(field.string, "Please call Ben today.")
        XCTAssertEqual(field.selectedRange(), NSRange(location: ("Please call Ben" as NSString).length, length: 0), "the caret after the part")
    }

    // MARK: Asking again

    func testTryAgainShorterAChipAndSayHowAskWithTheSameDraftAround() throws {
        let (harness, script) = try harness(reply: seamed)
        defer { harness.close() }
        let field = type("John is coming tomorrow.", harness)
        let session = try session(harness)
        field.setSelectedRange(NSRange(location: 0, length: 4))
        commandJ(harness)
        until({ session.phase == .written })
        let first = around(script.requests.first)
        XCTAssertFalse(first.isEmpty)

        // Try again: its step undone first, so the words beside it are as typed again, the old part in pencil.
        script.holdsAfter = 0
        commandJ(harness)
        until({ script.requests.count == 2 })
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(field.string, "Priya and Ben is coming tomorrow.")
        XCTAssertEqual(color(of: field, at: 0), WriteStreamEdit.pencilInk)
        XCTAssertEqual(around(script.requests[1]), first, "the same draft around the same selection")
        session.stop()
        XCTAssertEqual(field.string, "John is coming tomorrow.")
        script.holdsAfter = nil
        commandJ(harness)
        until({ script.requests.count == 3 && session.phase == .written })
        XCTAssertEqual(field.string, "Priya and Ben are coming tomorrow.", "new seams can be chosen; they never compound")

        press(.shorter, in: layer(harness))
        until({ script.requests.count == 4 && session.phase == .written })
        XCTAssertEqual(around(script.requests[3]), first)
        XCTAssertEqual(script.requests[3].rewrite?.instruction, "Shorter")
        XCTAssertEqual(field.string, "Priya and Ben are coming tomorrow.")

        harness.reader.helpMeWriteWithInstructions(nil)
        layer(harness).prompt.chips[1].performClick(nil)
        until({ script.requests.count == 5 && session.phase == .written })
        XCTAssertEqual(around(script.requests[4]), first, "a chip too")

        harness.reader.helpMeWriteWithInstructions(nil)
        let prompt = layer(harness).prompt
        prompt.instruction = "Name both of them"
        let editor = try XCTUnwrap(prompt.field.currentEditor() as? NSTextView)
        XCTAssertTrue(prompt.control(prompt.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        until({ script.requests.count == 6 && session.phase == .written })
        XCTAssertEqual(around(script.requests[5]), first, "and Say how's ↩")
        XCTAssertEqual(script.requests[5].rewrite?.instruction, "Name both of them")
        XCTAssertEqual(field.string, "Priya and Ben are coming tomorrow.")
    }

    func testAFailuresTryAgainAsksTheSame() throws {
        let (harness, script) = try harness(reply: seamed)
        defer { harness.close() }
        let field = type("John is coming tomorrow.", harness)
        let session = try session(harness)
        script.failure = .overloaded
        script.failsAfter = 1
        field.setSelectedRange(NSRange(location: 0, length: 4))
        commandJ(harness)
        until({ session.phase.isFailed })
        XCTAssertEqual(field.string, "John is coming tomorrow.", "the field as it was: seams are only written as the part lands")
        script.failure = nil
        commandJ(harness)
        until({ script.requests.count == 2 && session.phase == .written })
        XCTAssertEqual(around(script.requests[1]), around(script.requests[0]))
        XCTAssertEqual(field.string, "Priya and Ben are coming tomorrow.")
    }

    // MARK: An answer that repeats the draft

    func testAnEchoIsTakenOffAndAnAnswerThatCopiesTheDraftFails() throws {
        let (harness, script) = try harness(reply: "Priya and Ben is coming tomorrow")
        defer { harness.close() }
        let field = type("John is coming tomorrow.", harness)
        let session = try session(harness)
        field.setSelectedRange(NSRange(location: 0, length: 4))
        commandJ(harness)
        until({ session.phase == .written })
        XCTAssertEqual(field.string, "Priya and Ben is coming tomorrow.", "the restated end goes; the sentence is not doubled")

        let notes = "We met on Monday to go over the plan for the spring offsite and everyone agreed on the venue. John is coming tomorrow."
        script.reply = "Priya and Ben, since we met on Monday to go over the plan for the spring offsite"
        field.insertText(notes, replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        select("John", in: field)
        commandJ(harness)
        until({ script.requests.count == 2 && session.phase.isFailed })
        XCTAssertEqual(session.phase, .failed(reason: "The rewrite repeated the rest of your draft", offersSettings: false))
        XCTAssertEqual(field.string, notes, "nothing landed")
    }

    // MARK: A composer

    private func replyComposer(_ harness: MainWindowHarness) -> ComposeWindowController {
        let accounts = harness.controller.accounts
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2")
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: .reply(original, all: false))
        composer.window?.makeFirstResponder(composer.bodyEditor)
        composer.bodyWriteSession?.assumesKeyWindow = true
        return composer
    }

    func testAComposersWindowKeepsItsStyleAndALinkIsNeverAWindow() throws {
        let (harness, script) = try harness(reply: "Priya and Ben\n<<<BEFORE {fence}>>>Read the doc<<<END BEFORE {fence}>>>\n"
                                            + "<<<AFTER {fence}>>>are here<<<END AFTER {fence}>>>")
        defer { harness.close() }
        let composer = replyComposer(harness)
        let editor = composer.bodyEditor
        editor.insertText("Open the doc John is here.", replacementRange: NSRange(location: 0, length: 0))
        let storage = try XCTUnwrap(editor.textStorage)
        let link = (editor.string as NSString).range(of: "the doc")
        storage.addAttribute(.link, value: try XCTUnwrap(URL(string: "https://example.test/doc")), range: link)
        let here = (editor.string as NSString).range(of: "is here")
        let font = try XCTUnwrap(storage.attribute(.font, at: here.location, effectiveRange: nil) as? NSFont)
        storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: here)
        editor.setSelectedRange((editor.string as NSString).range(of: "John"))
        // Slow enough that the part streams into the text before it lands, where the after window's style was.
        script.delay = .milliseconds(30)
        composer.helpMeWrite(nil)
        let session = try XCTUnwrap(composer.writeSession)
        until({ session.phase == .written })
        let request = try XCTUnwrap(script.requests.last)
        XCTAssertNil(request.rewrite?.before, "the words beside a link are no window")
        XCTAssertEqual(request.rewrite?.after, "is here")
        XCTAssertTrue(composer.bodyText.hasPrefix("Open the doc Priya and Ben are here."), composer.bodyText)
        XCTAssertNotNil(storage.attribute(.link, at: link.location, effectiveRange: nil), "the link is never touched")
        XCTAssertEqual((editor.string as NSString).substring(with: link), "the doc")
        let landed = (editor.string as NSString).range(of: "are here")
        let landedFont = try XCTUnwrap(storage.attribute(.font, at: landed.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: landedFont).contains(.boldFontMask), "the window's new words keep its bold")
        XCTAssertNotEqual(storage.attribute(.foregroundColor, at: landed.location, effectiveRange: nil) as? NSColor, WriteStreamEdit.pencilInk,
                          "and its ink: the style read before the part streamed in, never the pencil's")
        let part = try XCTUnwrap(storage.attribute(.font, at: (editor.string as NSString).range(of: "Priya").location,
                                                   effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: part).contains(.boldFontMask), "and the part keeps the selection's")
        editor.undoManager?.undo()
        XCTAssertTrue(composer.bodyText.hasPrefix("Open the doc John is here."))
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(storage.attribute(.font, at: here.location, effectiveRange: nil)
                                                                        as? NSFont)).contains(.boldFontMask))
    }

    /// New words take one style, so a window whose words differ in style (one underlined) is not offered, and the word
    /// keeps its own.
    func testAComposersWindowOfMixedStyleIsNotOfferedAndItsWordsKeepTheirs() throws {
        let (harness, script) = try harness(reply: "Priya and Ben\n<<<AFTER {fence}>>>are really coming<<<END AFTER {fence}>>>")
        defer { harness.close() }
        let composer = replyComposer(harness)
        let editor = composer.bodyEditor
        editor.insertText("John is really coming tomorrow.", replacementRange: NSRange(location: 0, length: 0))
        let storage = try XCTUnwrap(editor.textStorage)
        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                             range: (editor.string as NSString).range(of: "really"))
        editor.setSelectedRange((editor.string as NSString).range(of: "John"))
        composer.helpMeWrite(nil)
        let session = try XCTUnwrap(composer.writeSession)
        until({ session.phase == .written })
        let request = try XCTUnwrap(script.requests.last)
        XCTAssertNotNil(request.rewrite, "the draft around the selection still goes")
        XCTAssertNil(request.rewrite?.after, "“is really coming” is in two styles: no window")
        XCTAssertTrue(request.task.contains("<<<END SELECTION \(request.fence)>>> is really coming tomorrow."))
        XCTAssertTrue(composer.bodyText.hasPrefix("Priya and Ben is really coming tomorrow."), composer.bodyText)
        let really = (editor.string as NSString).range(of: "really")
        XCTAssertNotNil(storage.attribute(.underlineStyle, at: really.location, effectiveRange: nil), "the word keeps its style")
        XCTAssertNil(storage.attribute(.underlineStyle, at: (editor.string as NSString).range(of: "is ").location, effectiveRange: nil))
    }

    func testTheSignatureNeverGoesAndASelectionIntoItGoesAlone() throws {
        let (harness, script) = try harness(reply: "Priya and Ben")
        defer { harness.close() }
        try harness.environment.store.setSignature("<p>SIGMARK Person</p>", for: ListTestSupport.accountA.id)
        harness.controller.refreshAccounts()
        let composer = replyComposer(harness)
        let editor = composer.bodyEditor
        editor.insertText("Thanks. John is coming tomorrow.", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(composer.bodyText.hasSuffix("SIGMARK Person"))
        editor.setSelectedRange((editor.string as NSString).range(of: "John"))
        composer.helpMeWrite(nil)
        let session = try XCTUnwrap(composer.writeSession)
        until({ session.phase == .written })
        let drafted = try XCTUnwrap(script.requests.last)
        XCTAssertTrue(drafted.task.contains("<<<DRAFT"))
        XCTAssertTrue(drafted.task.contains("Thanks."))
        XCTAssertFalse(drafted.userTurn.contains("SIGMARK"), "never the signature")
        XCTAssertFalse(drafted.task.contains("wrote:"), "never the folded original")

        editor.undoManager?.undo()
        let into = NSRange(location: (editor.string as NSString).range(of: "tomorrow").location,
                           length: NSMaxRange((editor.string as NSString).range(of: "SIGMARK")) - (editor.string as NSString).range(of: "tomorrow").location)
        editor.setSelectedRange(into)
        composer.helpMeWrite(nil)
        until({ script.requests.count == 2 && session.phase == .written })
        let alone = try XCTUnwrap(script.requests.last)
        XCTAssertNil(alone.rewrite, "a selection reaching into the signature goes alone")
        XCTAssertFalse(alone.task.contains("<<<DRAFT"))
        XCTAssertTrue(alone.task.contains("isn't given"))
        XCTAssertFalse(alone.task.contains("Thanks."), "nothing around it")
    }

    // MARK: The demo writer

    func testTheDemoStreamsThePartThenItsSeamLines() throws {
        let rewrite = AIWriteRequest(kind: .reply, instructions: "", transcript: "", task: "t", isRewrite: true, fence: "1a2b3c4d")
        let answer = DemoAIScript.answer(seamed, for: rewrite).message
        XCTAssertEqual(answer, "Priya and Ben\n<<<AFTER 1a2b3c4d>>>are coming tomorrow<<<END AFTER 1a2b3c4d>>>", "“{fence}” is the request's code")
        let (part, tail) = DemoAIScript.seamTail(of: answer)
        XCTAssertEqual(part, "Priya and Ben\n")
        XCTAssertEqual(tail, "<<<AFTER 1a2b3c4d>>>are coming tomorrow<<<END AFTER 1a2b3c4d>>>")
        XCTAssertEqual(DemoAIScript.seamTail(of: "no seam here").tail, "")
        let whole = AIWriteRequest(kind: .reply, instructions: "", transcript: "", task: "t", fence: "1a2b3c4d")
        XCTAssertEqual(DemoAIScript.answer("a {fence} b", for: whole).message, "a {fence} b", "only a rewrite's script is filled in")

        // Fails as far into the part as it is asked to, before any seam line.
        let (harness, script) = try harness(reply: seamed)
        defer { harness.close() }
        let field = type("John is coming tomorrow.", harness)
        let session = try session(harness)
        script.failure = .overloaded
        script.failsAfter = 1
        field.setSelectedRange(NSRange(location: 0, length: 4))
        commandJ(harness)
        until({ session.phase.isFailed })
        XCTAssertEqual(field.string, "John is coming tomorrow.")
    }
}
