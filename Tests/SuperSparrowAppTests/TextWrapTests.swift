import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// Long text typed without a Return wraps where it is written (spec §5.18, §5.20): the quick reply, in the main window
/// and in a reader window, wraps at the field's width, grows a line at a time to five lines and then scrolls with the
/// caret in view, and wraps again when the window is resized; a composer's body wraps and scrolls the same way. A word
/// longer than the line (an address) breaks between letters; nothing is cut off with an ellipsis. Drafts go to a
/// temporary folder, the windows are a throwaway store's, and nothing reaches the network.
@MainActor
final class TextWrapTests: XCTestCase {
    private var folder: URL!

    static let paragraph = "Tuesday at ten works for me, and I will bring the draft budget along with the notes from the "
        + "last review so we can go through the open questions on the venue, the catering and the travel together before "
        + "anyone books anything. If the room is taken we could meet in the small office on the second floor instead, "
        + "which has a screen, or move the whole thing to Wednesday afternoon when the rest of the team is back."

    static let address = "https://example.com/shared/folders/quarterly-planning/2026/budget-review-final-version-with-every-"
        + "comment-from-the-team-and-the-venue-shortlist-attached-for-tuesday.pdf"

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowTextWrap-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder) }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            QuireEnvironment.shared.setTextSize(.default)
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Helpers

    /// The text's lines as laid out now: how many, the widest line's right edge, the container's width, and whether
    /// any line was cut off (an ellipsis in place of the rest).
    private struct Lines {
        var count = 0
        var widest: CGFloat = 0
        var containerWidth: CGFloat = 0
        var truncated = false
    }

    private func lines(_ view: NSTextView) -> Lines {
        guard let layoutManager = view.layoutManager, let container = view.textContainer else { return Lines() }
        layoutManager.ensureLayout(for: container)
        var lines = Lines(containerWidth: container.size.width)
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
            lines.count += 1
            lines.widest = max(lines.widest, used.maxX)
            if layoutManager.truncatedGlyphRange(inLineFragmentForGlyphAt: range.location).location != NSNotFound { lines.truncated = true }
        }
        return lines
    }

    /// Types `text` a character at a time, as keystrokes put it there, calling `each` after every one.
    private func type(_ text: String, into view: NSTextView, each: (() -> Void)? = nil) {
        view.window?.makeFirstResponder(view)
        for character in text {
            view.insertText(String(character), replacementRange: view.selectedRange())
            each?()
        }
    }

    /// Whether the caret's line is inside what the field's scroll view shows. Neither field scrolls sideways, and no line
    /// runs past its width (`lines(_:)`), so its line is what can go out of view.
    private func caretIsVisible(_ view: NSTextView) -> Bool {
        guard let clip = view.enclosingScrollView?.contentView, let layoutManager = view.layoutManager,
              let container = view.textContainer else { return false }
        layoutManager.ensureLayout(for: container)
        let length = (view.string as NSString).length
        let caret = view.selectedRange().location
        var line = layoutManager.extraLineFragmentRect
        if caret < length || line.isEmpty, length > 0 {
            // At the end of the text the caret sits on the last character's line (after a space a line ends with, too).
            let glyph = layoutManager.glyphIndexForCharacter(at: caret < length ? caret : length - 1)
            line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let origin = view.textContainerOrigin
        let shown = clip.convert(line.offsetBy(dx: origin.x, dy: origin.y), from: view)
        return shown.minY >= clip.bounds.minY - 0.5 && shown.maxY <= clip.bounds.maxY + 0.5
    }

    /// The focused bar's height for `lines` of text (spec §5.18): 9 + lines × the line + 4 + 28 + 4 inside the field,
    /// 11 above and below it, five lines at most.
    private func barHeight(lines: Int, at size: QuireFont.TextSize) -> CGFloat {
        let m = Quire.Layout.QuickReply.self
        let line = QuireFont.Role.writing.lineHeight(at: size)
        let step = QuireFont.Role.writing.step(at: size)
        let shown = CGFloat(min(lines, Int(m.maxLines)))
        let field = min(m.fieldMax + m.maxLines * step, m.fieldPadTop + shown * line + m.toolRowGap + m.toolRow + m.toolRowBottom)
        return min(m.max + m.maxLines * step, field + 2 * m.barPadY)
    }

    /// The bar as laid out now matches its text: its height for the lines the text takes, and its text view as tall as
    /// those lines (five at most) and as wide as the text it wraps.
    private func assertBarFits(_ bar: QuickReplyView, at size: QuireFont.TextSize, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        bar.window?.layoutIfNeeded()
        // Focus coming or going animates the bar to its height.
        ListTestSupport.spin(until: { abs(bar.frame.height - bar.barHeight) < 0.5 }, timeout: 2)
        let field = bar.writingTextView
        let laid = lines(field)
        let lineHeight = QuireFont.Role.writing.lineHeight(at: size)
        XCTAssertEqual(bar.barHeight, barHeight(lines: laid.count, at: size), "\(message): the bar for \(laid.count) lines", file: file, line: line)
        XCTAssertEqual(bar.frame.height, bar.barHeight, "\(message): the bar's frame", file: file, line: line)
        let scroll = field.enclosingScrollView
        XCTAssertEqual(scroll?.frame.height ?? 0, CGFloat(min(laid.count, 5)) * lineHeight, "\(message): the lines shown", file: file, line: line)
        XCTAssertEqual(field.frame.width, scroll?.contentSize.width ?? -1, "\(message): the text as wide as its field", file: file, line: line)
        XCTAssertEqual(laid.containerWidth, field.frame.width, accuracy: 0.5, "\(message): the text wraps at the field's width", file: file, line: line)
        XCTAssertLessThanOrEqual(laid.widest, laid.containerWidth + 0.5, "\(message): no line runs past the field", file: file, line: line)
        XCTAssertFalse(laid.truncated, "\(message): no line is cut off", file: file, line: line)
    }

    private func mainWindowBar(_ harness: MainWindowHarness) -> QuickReplyView {
        harness.selectFirst(1)
        harness.spin(until: { !harness.reader.currentMessages.isEmpty })
        let bar = harness.reader.quickReplyBar
        bar.focus()
        return bar
    }

    /// A bare bar, `width` wide, at the bottom of a window of its own.
    private func standaloneBar(width: CGFloat) throws -> (QuickReplyView, NSWindow) {
        let bar = QuickReplyView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.layoutIfNeeded()
        bar.focus()
        return (bar, window)
    }

    // MARK: Quick reply

    /// A paragraph typed with no Return wraps at the field's width, and the bar grows by a line each time the text takes
    /// one more, at Default and at the largest Text size. The field used to keep it on one line, cut at its edge.
    func testTheQuickReplyWrapsALongParagraphAndGrowsLineByLine() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let bar = mainWindowBar(harness)
        for size in [QuireFont.TextSize.default, .larger] {
            harness.settings.textSize = size
            bar.text = ""
            var seen: [Int] = []
            type(Self.paragraph, into: bar.writingTextView) {
                let count = self.lines(bar.writingTextView).count
                if seen.last != count {
                    seen.append(count)
                    self.assertBarFits(bar, at: size, "\(size) at \(count) lines")
                }
            }
            XCTAssertGreaterThanOrEqual(seen.last ?? 0, 4, "\(size): the paragraph takes several lines: \(seen)")
            XCTAssertEqual(Array(seen.prefix(5)), Array(1...min(5, seen.count)), "\(size): one line at a time")
            assertBarFits(bar, at: size, "\(size) typed")
            XCTAssertTrue(caretIsVisible(bar.writingTextView), "\(size): the caret shows")
        }
        harness.settings.textSize = .default
        bar.text = ""
    }

    /// An address longer than the line breaks between its letters, at the field's width, instead of running off it.
    func testTheQuickReplyBreaksALongWordAtTheFieldsWidth() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let bar = mainWindowBar(harness)
        type(Self.address, into: bar.writingTextView)
        let laid = lines(bar.writingTextView)
        XCTAssertGreaterThanOrEqual(laid.count, 2, "the address wraps")
        assertBarFits(bar, at: .default, "an address")
        XCTAssertTrue(caretIsVisible(bar.writingTextView))
        bar.text = ""
    }

    /// Past five lines the bar stops growing and the text scrolls inside the field, the caret in view after every
    /// keystroke; below five, the first line stays at the top.
    func testPastFiveLinesTheQuickReplyScrollsWithTheCaretInView() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let bar = mainWindowBar(harness)
        let field = bar.writingTextView
        var hidden = 0
        var scrolledEarly = 0
        type(Self.paragraph + " " + Self.paragraph, into: field) {
            bar.window?.layoutIfNeeded()
            if !self.caretIsVisible(field) { hidden += 1 }
            if self.lines(field).count <= 5, (field.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0.5 { scrolledEarly += 1 }
        }
        XCTAssertEqual(hidden, 0, "the caret stays in view")
        XCTAssertEqual(scrolledEarly, 0, "the field grows before it scrolls")
        XCTAssertGreaterThan(lines(field).count, 5)
        XCTAssertEqual(bar.barHeight, Quire.Layout.QuickReply.max, "the bar stops at its cap")
        assertBarFits(bar, at: .default, "past five lines")
        XCTAssertGreaterThan(field.enclosingScrollView?.contentView.bounds.minY ?? 0, 0, "the text scrolled")
        bar.text = ""
    }

    /// Resizing wraps the text again at the new width, and the bar takes the lines it now needs, both ways.
    func testResizingWrapsTheQuickReplyAgain() throws {
        let (bar, window) = try standaloneBar(width: 900)
        defer { window.close() }
        type(String(Self.paragraph.prefix(260)), into: bar.writingTextView)
        assertBarFits(bar, at: .default, "wide")
        let wide = lines(bar.writingTextView).count

        window.setContentSize(NSSize(width: 480, height: 400))
        assertBarFits(bar, at: .default, "narrowed")
        let narrow = lines(bar.writingTextView).count
        XCTAssertGreaterThan(narrow, wide, "the narrower field takes more lines")
        XCTAssertTrue(caretIsVisible(bar.writingTextView), "the caret stays in view")

        window.setContentSize(NSSize(width: 900, height: 400))
        assertBarFits(bar, at: .default, "widened again")
        XCTAssertEqual(lines(bar.writingTextView).count, wide)
    }

    /// The main window resized to its narrowest and back: the text keeps wrapping at the field's width.
    func testResizingTheMainWindowKeepsTheQuickReplyWrapped() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let bar = mainWindowBar(harness)
        let window = try XCTUnwrap(harness.controller.window)
        type(String(Self.paragraph.prefix(220)), into: bar.writingTextView)
        for width in [window.minSize.width, 1_600, window.minSize.width] {
            window.setContentSize(NSSize(width: width, height: 800))
            assertBarFits(bar, at: .default, "window \(width) wide")
            XCTAssertGreaterThanOrEqual(lines(bar.writingTextView).count, 2, "window \(width) wide: wrapped")
        }
        bar.text = ""
    }

    /// Focus out and back: the field at rest shows its first line; focused again it is measured at its focused width.
    func testTheQuickReplyRegainsItsLinesWhenFocusedAgain() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let bar = mainWindowBar(harness)
        type(String(Self.paragraph.prefix(200)), into: bar.writingTextView)
        assertBarFits(bar, at: .default, "typed")
        bar.blur()
        harness.controller.window?.layoutIfNeeded()
        XCTAssertEqual(bar.barHeight, Quire.Layout.QuickReply.rest, "at rest, one line")
        ListTestSupport.spin(until: { abs(bar.frame.height - bar.barHeight) < 0.5 }, timeout: 2)
        bar.focus()
        assertBarFits(bar, at: .default, "focused again")
        XCTAssertGreaterThanOrEqual(lines(bar.writingTextView).count, 2)
        bar.text = ""
    }

    /// Blurring a bar of wrapped lines glides it back to rest (spec §4.10): the text wraps again at the rest width as the
    /// bar lays out, and that must not set the bar's height at once and cut the glide short.
    func testBlurringAWrappedQuickReplyGlidesToRest() throws {
        let environment = QuireEnvironment.shared
        let saved = environment.overrides
        defer { environment.setOverrides(saved) }
        environment.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false))
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let bar = mainWindowBar(harness)
        type(String(Self.paragraph.prefix(200)), into: bar.writingTextView)
        assertBarFits(bar, at: .default, "typed")
        let focused = bar.frame.height
        let rest = Quire.Layout.QuickReply.rest
        bar.blur()
        var heights: [CGFloat] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 0.6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            heights.append(bar.frame.height)
        }
        XCTAssertTrue(heights.contains { $0 > rest + 0.5 && $0 < focused - 0.5 }, "the bar passes between its heights: \(heights)")
        XCTAssertEqual(heights.last ?? 0, rest, "and comes to rest")
        bar.text = ""
    }

    /// Text put in the field from outside (a parked reply coming back) wraps as typed text does.
    func testARestoredQuickReplyWraps() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let bar = mainWindowBar(harness)
        bar.restoreDraft(Self.paragraph)
        assertBarFits(bar, at: .default, "restored")
        XCTAssertGreaterThanOrEqual(lines(bar.writingTextView).count, 4)
        bar.text = ""
    }

    /// A reader window's quick reply (§5.49) is the same field: it wraps and grows too.
    func testAReaderWindowsQuickReplyWraps() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.selectFirst(1)
        harness.spin(until: { !harness.reader.currentMessages.isEmpty })
        harness.controller.openSelectionInNewWindow(nil)
        let reader = try XCTUnwrap(harness.controller.readerWindows.first)
        defer { reader.close() }
        harness.spin(until: { !reader.conversation.currentMessages.isEmpty })
        let bar = reader.conversation.quickReplyBar
        reader.window?.layoutIfNeeded()
        bar.focus()
        type(Self.paragraph, into: bar.writingTextView)
        XCTAssertGreaterThanOrEqual(lines(bar.writingTextView).count, 4, "the paragraph wraps")
        assertBarFits(bar, at: .default, "reader window")
        XCTAssertTrue(caretIsVisible(bar.writingTextView))
        bar.text = ""
    }

    // MARK: Composer

    private func newMessage(_ harness: MainWindowHarness) throws -> ComposeWindowController {
        harness.controller.composeNew()
        return try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.last)
    }

    private func reply(_ harness: MainWindowHarness) throws -> ComposeWindowController {
        let message = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-0-0")
        let accounts = harness.controller.accounts
        return ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                               mode: .reply(message, all: false))
    }

    /// The body wraps at its text's width (the value axis to 24 pt before the edge), the editor is as tall as its
    /// lines, and nothing runs past the edge or is cut off.
    private func assertBodyFits(_ composer: ComposeWindowController, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        composer.window?.layoutIfNeeded()
        let editor = composer.bodyEditor
        let laid = lines(editor)
        let padding = editor.textContainer?.lineFragmentPadding ?? 0
        XCTAssertEqual(laid.containerWidth, editor.bounds.width - editor.leadingInset - editor.trailingInset + 2 * padding, accuracy: 0.5,
                       "\(message): the body wraps at its width", file: file, line: line)
        XCTAssertLessThanOrEqual(laid.widest, laid.containerWidth + 0.5, "\(message): no line runs past the edge", file: file, line: line)
        XCTAssertFalse(laid.truncated, "\(message): no line is cut off", file: file, line: line)
        XCTAssertGreaterThanOrEqual(editor.frame.height, CGFloat(laid.count) * editor.lineHeight + editor.topInset - 0.5,
                                    "\(message): the editor as tall as its \(laid.count) lines", file: file, line: line)
    }

    /// A reply's and a new message's body wrap a paragraph typed with no Return, at Default and the largest Text size,
    /// and a long address breaks between its letters.
    func testAComposerBodyWrapsALongParagraphAndALongWord() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        for size in [QuireFont.TextSize.default, .larger] {
            harness.settings.textSize = size
            for kind in ["reply", "new"] {
                let composer = kind == "reply" ? try reply(harness) : try newMessage(harness)
                composer.window?.setContentSize(NSSize(width: Quire.Layout.Composer.minWidth, height: 600))
                type(Self.paragraph + " " + Self.address, into: composer.bodyEditor)
                assertBodyFits(composer, "\(kind) at \(size)")
                XCTAssertGreaterThanOrEqual(lines(composer.bodyEditor).count, 8, "\(kind) at \(size): wrapped")
                XCTAssertTrue(caretIsVisible(composer.bodyEditor), "\(kind) at \(size): the caret shows")
                composer.closeWithoutSaving()
            }
        }
        harness.settings.textSize = .default
    }

    /// Typed past the bottom of the window, the body scrolls with the caret in view after every keystroke.
    func testAComposerBodyScrollsWithTheCaretInView() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        composer.window?.setContentSize(NSSize(width: Quire.Layout.Composer.minWidth, height: Quire.Layout.Composer.minHeight))
        var hidden = 0
        type(Self.paragraph + " " + Self.paragraph + " " + Self.address, into: composer.bodyEditor) {
            if !self.caretIsVisible(composer.bodyEditor) { hidden += 1 }
        }
        XCTAssertEqual(hidden, 0, "the caret stays in view")
        XCTAssertGreaterThan(composer.bodyEditor.enclosingScrollView?.contentView.bounds.minY ?? 0, 0, "the body scrolled")
        assertBodyFits(composer, "past the window's bottom")
    }

    /// Resizing the composer wraps its body again at the new width, both ways, and the editor's height follows.
    func testResizingWrapsTheComposerBodyAgain() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        let window = try XCTUnwrap(composer.window)
        window.setContentSize(NSSize(width: 1_200, height: 600))
        type(Self.paragraph, into: composer.bodyEditor)
        assertBodyFits(composer, "wide")
        let wide = lines(composer.bodyEditor).count
        window.setContentSize(NSSize(width: Quire.Layout.Composer.minWidth, height: 600))
        assertBodyFits(composer, "narrowed")
        XCTAssertGreaterThan(lines(composer.bodyEditor).count, wide, "more lines when narrower")
        window.setContentSize(NSSize(width: 1_200, height: 600))
        assertBodyFits(composer, "widened again")
        XCTAssertEqual(lines(composer.bodyEditor).count, wide)
    }
}
