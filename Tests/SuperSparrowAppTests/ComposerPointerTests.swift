import AppKit
import SSCore
@testable import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The pointer over the composer (spec §4.17): the pointing hand over what a click acts on (Send and its drop-down,
/// Attach, Format, Cc, Bcc, recipient tokens and “+N more”, suggestions, the link popover's buttons, an attachment's
/// remove, the quote's chip and attribution), the I-beam over what takes typing (a recipient row around its tokens, the
/// page under the body), the arrow over what a click leaves as it is (a disabled or loading Send, tokens a send has
/// locked) and over the popovers' own surfaces, with AppKit asked again whenever any of it changes, scrolling included.
/// Drafts go to a temporary folder, the windows are a throwaway store's, and nothing reaches the network.
@MainActor
final class ComposerPointerTests: XCTestCase {
    private var folder: URL!
    private var savedUndoWindow: TimeInterval = 5

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowPointer-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            ComposeDraftStore.shared.useDirectory(folder)
            savedUndoWindow = ConversationViewController.undoWindow
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            ConversationViewController.undoWindow = savedUndoWindow
            for panel in ComposeWindowRegistry.shared.livePanels { panel.orderOut(nil); ComposeWindowRegistry.shared.unregister(panel) }
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Recipients

    /// Each token takes the hand over its pill; the rest of the row the I-beam, since a click there puts the caret in
    /// the text, and the text field keeps its own. A send locks the row: the arrow everywhere, as the disabled ink says.
    func testTokensTakeTheHandAndTheRestOfTheRowTheIBeam() throws {
        let window = RecordingWindow(size: NSSize(width: 600, height: 200))
        let field = AddressTokenField(frame: NSRect(x: 0, y: 0, width: 520, height: Quire.Layout.Composer.fieldRow))
        window.contentView?.addSubview(field)
        field.addresses = [EmailAddress(name: "Ben Carter", address: "ben@contoso.test"), EmailAddress(address: "ada@fabrikam.test")]
        field.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(descendants(TokenDocumentView.self, of: field).first)

        let tokens = field.tokenRects().map(\.rect)
        XCTAssertEqual(tokens.count, 2)
        let regions = document.pointerRegions
        XCTAssertEqual(regions.filter { $0.cursor === NSCursor.pointingHand }.map(\.rect), tokens, "the hand over each pill, exactly")
        XCTAssertTrue(regions.filter { $0.cursor !== NSCursor.pointingHand }.allSatisfy { $0.cursor === NSCursor.iBeam })
        let input = field.input.frame.intersection(document.bounds)
        assertDisjoint(regions.map(\.rect) + [input])
        XCTAssertEqual(area(regions.map(\.rect)) + area([input]), area([document.bounds]), accuracy: 0.01, "nothing left uncovered")

        window.invalidated = []
        field.addresses += [EmailAddress(address: "cy@contoso.test")]
        XCTAssertTrue(window.wasInvalidated(document), "a new token asks AppKit again")
        XCTAssertEqual(document.pointerRegions.filter { $0.cursor === NSCursor.pointingHand }.count, 3)

        window.invalidated = []
        field.isLocked = true
        XCTAssertTrue(window.wasInvalidated(document), "locking asks AppKit again")
        XCTAssertTrue(document.pointerRegions.allSatisfy { $0.cursor === NSCursor.arrow }, "a click on a locked row changes nothing")
        field.isLocked = false
        XCTAssertEqual(document.pointerRegions.filter { $0.cursor === NSCursor.pointingHand }.count, 3)

        // The Cc and Bcc rows start hidden; showing one asks AppKit again.
        window.invalidated = []
        field.isHidden = true
        XCTAssertTrue(window.wasInvalidated(document))
        window.invalidated = []
        field.isHidden = false
        XCTAssertTrue(window.wasInvalidated(document))
    }

    /// A collapsed row's “+N more” takes the hand as far as its click reaches (4 pt round it), leaving the tokens and the
    /// text field their own.
    func testMoreTakesTheHandAsFarAsItsClickReaches() throws {
        let window = RecordingWindow(size: NSSize(width: 600, height: 200))
        let field = AddressTokenField(frame: NSRect(x: 0, y: 0, width: 300, height: Quire.Layout.Composer.fieldRow))
        window.contentView?.addSubview(field)
        field.addresses = (1...8).map { EmailAddress(name: "Recipient Number \($0)", address: "r\($0)@contoso.test") }
        field.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(descendants(TokenDocumentView.self, of: field).first)
        let more = try XCTUnwrap(field.moreRect(), "eight long names collapse behind “+N more”")

        let reach = more.insetBy(dx: -4, dy: -4).intersection(document.bounds)
        let hands = document.pointerRegions.filter { $0.cursor === NSCursor.pointingHand }.map(\.rect)
        let tokens = field.tokenRects().map(\.rect)
        let moreHands = hands.filter { rect in !tokens.contains(rect) }
        XCTAssertFalse(moreHands.isEmpty)
        XCTAssertTrue(moreHands.allSatisfy { reach.contains($0) })
        XCTAssertTrue(moreHands.contains { $0.contains(NSPoint(x: more.midX, y: more.midY)) }, "the words themselves")
        let taken = tokens + [field.input.frame]
        XCTAssertEqual(area(moreHands), area([reach]) - area(taken.map { $0.intersection(reach) }), accuracy: 0.01)
        assertDisjoint(document.pointerRegions.map(\.rect) + [field.input.frame.intersection(document.bounds)])
    }

    /// An expanded row taller than three lines scrolls inside itself: AppKit asks the row again as it scrolls, and its
    /// regions cover every line, so a token scrolled into view has its hand.
    func testARowThatScrollsIsAskedAgainAndCoversWhatScrollsIn() throws {
        let window = RecordingWindow(size: NSSize(width: 600, height: 300))
        let field = AddressTokenField(frame: NSRect(x: 0, y: 0, width: 300, height: 88))
        window.contentView?.addSubview(field)
        field.addresses = (1...12).map { EmailAddress(name: "Recipient Number \($0)", address: "r\($0)@contoso.test") }
        field.expandFromMore()
        // A layout pass keeps the caret's line in view; let the one the focus asked for run before scrolling.
        ListTestSupport.spin(for: 0.05)
        field.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(descendants(TokenDocumentView.self, of: field).first)
        let clip = try XCTUnwrap(document.superview as? NSClipView)
        XCTAssertGreaterThan(document.frame.height, clip.bounds.height, "more lines than the row shows")
        XCTAssertEqual(field.tokenRects().count, 12, "expanded, every token shows")
        let first = try XCTUnwrap(field.tokenRects().first?.rect)
        XCTAssertFalse(document.visibleRect.intersects(first), "the caret's line is in view, the first line out of it")

        // AppKit asks again on a scroll for the views that hold cursor rects, as they do once the window is key.
        window.resetCursorRects()
        window.invalidated = []
        clip.scroll(to: .zero)
        XCTAssertTrue(window.wasInvalidated(document), "scrolling asks AppKit again for the row")
        XCTAssertTrue(document.visibleRect.contains(first))
        XCTAssertTrue(document.pointerRegions.contains { $0.cursor === NSCursor.pointingHand && $0.rect == first })
    }

    // MARK: Suggestions

    /// Each suggestion takes the hand; the padding around them the arrow, so the body's I-beam under the popover never
    /// shows through it. A new list asks AppKit again.
    func testSuggestionsTakeTheHandAndThePopoversPaddingTheArrow() {
        let window = RecordingWindow(size: NSSize(width: 600, height: 400))
        let popover = AddressAutocompleteView(frame: .zero)
        window.contentView?.addSubview(popover)
        let suggestions = [EmailAddress(name: "Ben Carter", address: "ben@contoso.test"), EmailAddress(address: "bea@fabrikam.test")]
        window.invalidated = []
        popover.show(suggestions, typed: "be")
        popover.setFrameFromPopover(NSRect(origin: NSPoint(x: 40, y: 40), size: popover.fittingSize))
        XCTAssertTrue(window.wasInvalidated(popover))

        let regions = popover.pointerRegions
        let hands = regions.filter { $0.cursor === NSCursor.pointingHand }
        XCTAssertEqual(hands.count, 2, "one per suggestion")
        let a = Quire.Layout.Autocomplete.self
        XCTAssertTrue(hands.allSatisfy { abs($0.rect.height - a.row) < 0.01 && popover.bounds.contains($0.rect) })
        XCTAssertTrue(regions.filter { $0.cursor !== NSCursor.pointingHand }.allSatisfy { $0.cursor === NSCursor.arrow })
        assertDisjoint(regions.map(\.rect))
        XCTAssertEqual(area(regions.map(\.rect)), area([popover.bounds]), accuracy: 0.01, "the whole popover has a pointer")

        window.invalidated = []
        popover.show(Array(suggestions.prefix(1)), typed: "ben")
        XCTAssertTrue(window.wasInvalidated(popover), "a new list asks AppKit again")
        XCTAssertEqual(popover.pointerRegions.filter { $0.cursor === NSCursor.pointingHand }.count, 1)
    }

    // MARK: The link popover

    /// The popover's surface takes the arrow around its fields (the I-beam) and buttons (the hand); a Remove Link that is
    /// hidden leaves its place to the surface.
    func testTheLinkPopoverShowsTheArrowAroundItsFieldsAndButtons() throws {
        let window = RecordingWindow(size: NSSize(width: 600, height: 400))
        for existing in [nil, "https://contoso.test"] as [String?] {
            let popover = ComposeLinkPopover(request: .init(range: NSRange(location: 0, length: 0), existingTarget: existing,
                                                             needsText: existing == nil))
            popover.frame = NSRect(origin: NSPoint(x: 20, y: 20), size: popover.preferredSize)
            window.contentView?.addSubview(popover)
            window.invalidated = []
            popover.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.wasInvalidated(popover), "laid out, AppKit is asked again")

            let controls = descendants(QuireControl.self, of: popover).filter { !$0.isHiddenOrHasHiddenAncestor }
            let fields = controls.filter { $0 is QuireTextField }
            let buttons = controls.filter { $0 is QuireButton }
            XCTAssertEqual(fields.count, existing == nil ? 2 : 1, "Link, and Text only for a caret")
            XCTAssertEqual(buttons.count, existing == nil ? 2 : 3, "Cancel and Add Link, and Remove Link only when editing")
            XCTAssertTrue(fields.allSatisfy { $0.pointerRegions.map(\.cursor) == [.iBeam] })
            XCTAssertTrue(buttons.allSatisfy { $0.pointerRegions.map(\.cursor) == [.pointingHand] })

            let surface = popover.pointerRegions
            XCTAssertTrue(surface.allSatisfy { $0.cursor === NSCursor.arrow })
            let holes = controls.map { popover.convert($0.hitRect, from: $0) }
            assertDisjoint(surface.map(\.rect) + holes)
            XCTAssertEqual(area(surface.map(\.rect)) + area(holes), area([popover.bounds]), accuracy: 0.01)
            popover.removeFromSuperview()
        }
    }

    // MARK: Attachments

    /// An attachment's remove takes the hand over its 24 pt hit square; as the strip scrolls AppKit asks again for the
    /// chips scrolled into view, so theirs have it too, all of it once the overlay scroller that showed while the strip
    /// scrolled, and took the clicks along its edge, has faded.
    func testAnAttachmentsRemoveTakesTheHandAlsoOnceScrolledIntoView() throws {
        let window = RecordingWindow(size: NSSize(width: 400, height: 200))
        let strip = AttachmentStripView(frame: NSRect(x: 0, y: 0, width: 320, height: Quire.Layout.Composer.strip))
        window.contentView?.addSubview(strip)
        strip.attachments = (1...6).map {
            ComposeAttachment(filename: "Quarterly plan, draft \($0).pdf", mimeType: "application/pdf", sizeBytes: 2_400_000,
                              source: .data(Data()))
        }
        strip.layoutSubtreeIfNeeded()
        let chips = descendants(AttachmentChipView.self, of: strip)
        XCTAssertEqual(chips.count, 6)
        let removes = chips.compactMap { chip in chip.subviews.lazy.compactMap { $0 as? QuirePointerTarget }.first }
        XCTAssertEqual(removes.count, 6, "every chip's remove is a pointer target")
        let hit = Quire.Layout.Button.minHit
        for remove in removes {
            XCTAssertEqual(remove.pointerRegions, [QuirePointerRegion(remove.bounds, cursor: .pointingHand)])
            XCTAssertEqual(remove.bounds.size, NSSize(width: hit, height: hit))
        }

        let clip = try XCTUnwrap(chips.first?.superview?.superview as? NSClipView)
        let document = try XCTUnwrap(clip.documentView)
        XCTAssertGreaterThan(document.frame.width, clip.bounds.width, "six chips are wider than the strip")
        let last = try XCTUnwrap(removes.last)
        XCTAssertTrue(last.bounds.intersection(last.visibleRect).isEmpty, "the last chip starts out of view")
        let probe = CursorProbe(frame: last.frame)
        last.superview?.addSubview(probe)
        window.resetCursorRects()
        XCTAssertEqual(probe.added, [], "out of view, no rect")
        clip.scroll(to: NSPoint(x: document.frame.width - clip.bounds.width, y: 0))
        XCTAssertTrue(ListTestSupport.spin(until: { !probe.added.isEmpty }, timeout: 2), "scrolled into view, AppKit asks the chips again")
        if probe.added != [probe.bounds] {
            // An overlay scroller showed as the strip scrolled, over the chips' lower edge, and took that strip; faded,
            // the chips are asked again. A legacy scroller, or one already faded, takes nothing.
            XCTAssertFalse(probe.pointerCoverAreas().isEmpty, "only a showing scroller cuts the chip")
            window.invalidated = []
            XCTAssertTrue(ListTestSupport.spin(until: { window.wasInvalidated(probe) && probe.pointerCoverAreas().isEmpty }, timeout: 5))
            window.resetCursorRects()
        }
        XCTAssertEqual(probe.added, [probe.bounds])
        XCTAssertEqual(last.bounds.intersection(last.visibleRect), last.bounds, "the last chip's remove is in view")
    }

    // MARK: The page

    /// The page under the text takes the I-beam, since a click there puts the caret at the end, leaving the editor its
    /// own; the failed-send banner, which lies on the editor's top inset, is a surface on both: the arrow around its
    /// controls, which keep their hand.
    func testThePageTakesTheIBeamAndTheBannerTheArrow() throws {
        let window = RecordingWindow(size: NSSize(width: 600, height: 500))
        let page = ComposeDocumentView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        let editor = ComposeTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 120))
        page.editor = editor
        page.addSubview(editor)
        window.contentView?.addSubview(page)
        page.layoutSubtreeIfNeeded()
        let editorFrame = editor.frame
        var regions = page.pointerRegions
        XCTAssertTrue(regions.allSatisfy { $0.cursor === NSCursor.iBeam })
        assertDisjoint(regions.map(\.rect) + [editorFrame])
        XCTAssertEqual(area(regions.map(\.rect)) + area([editorFrame]), area([page.bounds]), accuracy: 0.01)

        window.invalidated = []
        page.setFailureBanner("Couldn't send. The server didn't answer.")
        let banner = try XCTUnwrap(page.banner)
        let retry = try XCTUnwrap(banner.setAction("Try again"))
        page.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.wasInvalidated(page), "the banner's arrival asks AppKit again")
        regions = page.pointerRegions
        let retryArea = page.convert(retry.hitRect, from: retry)
        let arrows = regions.filter { $0.cursor === NSCursor.arrow }.map(\.rect)
        XCTAssertFalse(arrows.isEmpty)
        XCTAssertTrue(arrows.allSatisfy { banner.frame.contains($0) })
        XCTAssertEqual(area(arrows), area([banner.frame]) - area([retryArea.intersection(banner.frame)]), accuracy: 0.01)
        XCTAssertEqual(retry.pointerRegions.map(\.cursor), [.pointingHand])
        assertDisjoint(regions.map(\.rect) + [retryArea])
        assertDisjoint(regions.filter { $0.cursor === NSCursor.iBeam }.map(\.rect) + [editor.frame])
    }

    // MARK: The real composer

    /// In a real composer: Send takes the hand once it can send and the arrow before; Send's drop-down, Attach, Format,
    /// Cc and Bcc the hand; the recipients' tokens the hand and their row the I-beam. Once Send is pressed the message
    /// is on its way: Send (loading), its drop-down (disabled) and the locked tokens take the arrow.
    func testTheComposersControlsFollowWhatAClickWouldDo() throws {
        ConversationViewController.undoWindow = 0
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.controller.composeNew()
        let empty = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.last)
        let emptyBar = try XCTUnwrap(descendants(ComposeBottomBar.self, of: empty.window?.contentView).first)
        XCTAssertFalse(emptyBar.sendButton.isEnabled, "no recipient yet")
        XCTAssertEqual(emptyBar.sendButton.pointerRegions.map(\.cursor), [.arrow])
        empty.closeWithoutSaving()

        let link = MailtoLink(to: [EmailAddress(name: "Ben Carter", address: "ben@contoso.test")], subject: "Lunch?", body: "Noon")
        let composer = try XCTUnwrap(harness.controller.openMailLink(link))
        let content = try XCTUnwrap(composer.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let bar = try XCTUnwrap(descendants(ComposeBottomBar.self, of: content).first)
        XCTAssertTrue(bar.sendButton.isEnabled)
        for button in [bar.sendButton, bar.sendOptionsButton, bar.attachButton, bar.formatButton] as [QuireControl] {
            XCTAssertEqual(button.pointerRegions.map(\.cursor), [.pointingHand], "\(button.accessibilityLabel() ?? "")")
        }
        let ccAndBcc = descendants(QuireButton.self, of: content).filter { ["Cc", "Bcc"].contains($0.title) }
        XCTAssertEqual(ccAndBcc.count, 2)
        XCTAssertTrue(ccAndBcc.allSatisfy { $0.pointerRegions.map(\.cursor) == [.pointingHand] })

        let rows = descendants(TokenDocumentView.self, of: content)
        let to = try XCTUnwrap(rows.first { $0.field?.addresses.isEmpty == false })
        XCTAssertEqual(to.pointerRegions.filter { $0.cursor === NSCursor.pointingHand }.count, 1, "Ben's token")
        XCTAssertTrue(to.pointerRegions.contains { $0.cursor === NSCursor.iBeam })
        let page = try XCTUnwrap(descendants(ComposeDocumentView.self, of: content).first)
        XCTAssertTrue(page.pointerRegions.allSatisfy { $0.cursor === NSCursor.iBeam })

        let window = try XCTUnwrap(composer.window)
        let input = try XCTUnwrap(to.field?.input)
        let typing = NSRect(x: input.bounds.midX, y: input.bounds.midY, width: 0, height: 0)
        XCTAssertEqual(CursorRectRecorder(window).cursors(atCentreOf: typing, in: input), [.iBeam], "the recipients' text field")
        let subject = try XCTUnwrap(descendants(NSTextField.self, of: content).first { "\(type(of: $0))" == "ComposeSubjectField" })
        let words = NSRect(x: subject.bounds.midX, y: subject.bounds.midY, width: 0, height: 0)
        XCTAssertEqual(CursorRectRecorder(window).cursors(atCentreOf: words, in: subject), [.iBeam], "the subject")

        composer.send(nil)
        XCTAssertTrue(bar.sendButton.isLoading, "Send is on its way")
        XCTAssertEqual(bar.sendButton.pointerRegions.map(\.cursor), [.arrow], "a second click sends nothing")
        XCTAssertEqual(bar.sendOptionsButton.pointerRegions.map(\.cursor), [.arrow])
        XCTAssertTrue(to.pointerRegions.allSatisfy { $0.cursor === NSCursor.arrow }, "the tokens are locked")
        XCTAssertEqual(CursorRectRecorder(window).cursors(atCentreOf: typing, in: input), [.arrow],
                       "and so is their text field: the arrow alone, its I-beam gone")
        XCTAssertFalse(subject.isEditable || subject.isSelectable, "the send locks the subject too")
        XCTAssertEqual(CursorRectRecorder(window).cursors(atCentreOf: words, in: subject), [],
                       "so it adds no I-beam: a click there leaves it as it is, and the arrow shows")
        XCTAssertTrue(ListTestSupport.spin(until: { (try? harness.environment.store.pendingSends().isEmpty) == false }, timeout: 5))
    }

    /// A reply's folded original: the chip and the attribution beside it unfold it on a click, so both take the hand,
    /// the attribution over its words alone.
    func testTheQuotesChipAndAttributionTakeTheHand() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-0-0")
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: "<p>The quarterly plan is attached.</p>",
                                                                            text: "The quarterly plan is attached."),
                                                          renderedHTML: "<p>The quarterly plan is attached.</p>",
                                                          plainText: "The quarterly plan is attached."), for: original)
        let accounts = harness.controller.accounts
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: .reply(original, all: false))
        XCTAssertTrue(ListTestSupport.spin(until: { composer.contents.quoted != nil }, timeout: 5), "the original folds in")
        let content = try XCTUnwrap(composer.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let quote = try XCTUnwrap(descendants(QuotedOriginalView.self, of: content).first)
        XCTAssertFalse(quote.isHidden)
        XCTAssertEqual(quote.chip.pointerRegions.map(\.cursor), [.pointingHand])
        let attribution = try XCTUnwrap(quote.subviews.first { $0 is QuirePointerTarget && !($0 is QuireControl) } as? QuirePointerTarget)
        XCTAssertEqual(attribution.pointerRegions, [QuirePointerRegion(attribution.bounds, cursor: .pointingHand)])
        XCTAssertGreaterThan(attribution.bounds.width, 0)
        XCTAssertLessThan(attribution.frame.maxX, quote.bounds.maxX, "its words, not the rest of the line")

        // The page leaves both to them.
        let page = try XCTUnwrap(descendants(ComposeDocumentView.self, of: content).first)
        let chipArea = page.convert(quote.chip.hitRect, from: quote.chip)
        let attributionArea = page.convert(attribution.bounds, from: attribution)
        assertDisjoint(page.pointerRegions.map(\.rect) + [chipArea, attributionArea])
        composer.closeWithoutSaving()
    }

    /// Read from the cursor rects the window gets: the editor's I-beam is its own frame, not the page it lies on, so the
    /// quote's chip and attribution, and the failed-send banner laid in the editor's top inset, each have one pointer
    /// alone: the hand over the chip, the attribution and Try again, the arrow over the banner's words.
    func testTheEditorsIBeamLeavesTheQuoteAndTheBannerTheirOwn() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try replyComposer(harness)
        let window = try XCTUnwrap(composer.window)
        let content = try XCTUnwrap(window.contentView)
        let page = try XCTUnwrap(descendants(ComposeDocumentView.self, of: content).first)
        page.setFailureBanner("Couldn't send. The server didn't answer.")
        let banner = try XCTUnwrap(page.banner)
        let retry = try XCTUnwrap(banner.setAction("Try again"))
        content.layoutSubtreeIfNeeded()
        let quote = try XCTUnwrap(descendants(QuotedOriginalView.self, of: content).first)
        let attribution = try XCTUnwrap(quote.subviews.first { $0 is QuirePointerTarget && !($0 is QuireControl) })
        let editor = try XCTUnwrap(descendants(ComposeTextView.self, of: content).first)

        let recorder = CursorRectRecorder(window)
        XCTAssertEqual(recorder.cursors(atCentreOf: quote.chip.hitRect, in: quote.chip), [.pointingHand], "the chip")
        XCTAssertEqual(recorder.cursors(atCentreOf: attribution.bounds, in: attribution), [.pointingHand], "the attribution")
        XCTAssertEqual(recorder.cursors(atCentreOf: retry.hitRect, in: retry), [.pointingHand], "Try again")
        let words = NSRect(x: banner.bounds.minX + 40, y: banner.bounds.midY, width: 0, height: 0)
        XCTAssertEqual(recorder.cursors(atCentreOf: words, in: banner), [.arrow], "the banner's words")
        let text = NSRect(x: editor.bounds.midX, y: editor.bounds.maxY - 4, width: 0, height: 0)
        XCTAssertEqual(recorder.cursors(atCentreOf: text, in: editor), [.iBeam], "the text")
        for rect in recorder.rects(of: editor) {
            let own = editor.convert(editor.bounds, to: nil).insetBy(dx: -0.5, dy: -0.5)
            XCTAssertTrue(own.contains(rect.rect), "the editor adds \(rect.rect) outside its \(own)")
        }
        composer.closeWithoutSaving()
    }

    /// The autocomplete and the link popover lie on the recipient rows, the subject, their buttons and the body, whose
    /// pointers AppKit would show in no order with theirs. As covers they have everything under them leave their frame
    /// to them, the text fields and the editor included: read from the window's cursor rects, every point of each
    /// popover has one pointer, its own. Gone, the views under it have their area back.
    func testThePopoversCoverWhatTheyLieOn() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try replyComposer(harness)
        let window = try XCTUnwrap(composer.window)
        let content = try XCTUnwrap(window.contentView)
        let subject = try XCTUnwrap(descendants(NSTextField.self, of: content).first { "\(type(of: $0))" == "ComposeSubjectField" })
        let editor = try XCTUnwrap(descendants(ComposeTextView.self, of: content).first)
        let rows = descendants(TokenDocumentView.self, of: content).filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertFalse(rows.isEmpty)

        // Where the To row's suggestions fall: from under its line, over the subject, into the body.
        let suggestions = AddressAutocompleteView(frame: .zero)
        content.addSubview(suggestions, positioned: .above, relativeTo: nil)
        suggestions.show((1...4).map { EmailAddress(name: "Ben Carter \($0)", address: "ben\($0)@contoso.test") }, typed: "be")
        let subjectTop = content.convert(subject.bounds, from: subject).minY
        let top = max(0, subjectTop - 30)
        suggestions.setFrameFromPopover(NSRect(origin: NSPoint(x: 60, y: top), size: suggestions.fittingSize))
        let underSuggestions = [subject, editor] + rows
        XCTAssertTrue(underSuggestions.contains { content.convert($0.bounds, from: $0).intersects(suggestions.frame) },
                      "the suggestions lie on a field")
        var recorder = CursorRectRecorder(window)
        assertOnePointer(over: suggestions, in: recorder, hands: suggestions.pointerRegions.filter { $0.cursor === NSCursor.pointingHand }.map(\.rect))
        suggestions.removeFromSuperview()
        recorder = CursorRectRecorder(window)
        let subjectCentre = NSRect(x: subject.bounds.midX, y: subject.bounds.midY, width: 0, height: 0)
        XCTAssertEqual(recorder.cursors(atCentreOf: subjectCentre, in: subject), [.iBeam], "gone, the subject has its I-beam back")

        // The link popover over the body's first lines, where ⌘K puts it.
        let popover = ComposeLinkPopover(request: .init(range: NSRange(location: 0, length: 0), existingTarget: nil, needsText: true))
        let editorTop = content.convert(editor.bounds, from: editor).minY
        popover.present(in: content, frame: NSRect(origin: NSPoint(x: 90, y: editorTop + 8), size: popover.preferredSize))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.convert(editor.bounds, from: editor).intersects(popover.frame), "the popover lies on the editor")
        recorder = CursorRectRecorder(window)
        let buttons = descendants(QuireButton.self, of: popover).filter { !$0.isHiddenOrHasHiddenAncestor }
        let fields = descendants(QuireTextField.self, of: popover).filter { !$0.isHiddenOrHasHiddenAncestor }
        for button in buttons {
            XCTAssertEqual(recorder.cursors(atCentreOf: button.hitRect, in: button), [.pointingHand], button.title)
        }
        for field in fields {
            let face = NSRect(x: field.hitRect.minX + 6, y: field.hitRect.midY, width: 0, height: 0)
            XCTAssertEqual(Set(recorder.cursors(atCentreOf: face, in: field).map(ObjectIdentifier.init)), [ObjectIdentifier(NSCursor.iBeam)])
        }
        let surface = NSRect(x: 4, y: 4, width: 0, height: 0)
        XCTAssertEqual(recorder.cursors(atCentreOf: surface, in: popover), [.arrow], "the popover's own surface")
        assertOnePointer(over: popover, in: recorder, hands: nil)
        popover.removeFromSuperview()
        composer.closeWithoutSaving()
    }

    // MARK: Undo-send panel

    /// The panel never becomes key, so its action set the hand itself, and no exit event follows when the panel goes:
    /// a click on Open draft orders it out under the resting pointer, and the action takes the hand back first.
    func testTheUndoPanelTakesBackTheHandWhenAClickOrdersItOut() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = ComposeDraft(id: UUID(), mode: .new, account: ListTestSupport.accountA, to: [EmailAddress(address: "ben@contoso.test")],
                                 cc: [], bcc: [], subject: "Lisbon", body: NSAttributedString(string: "See you there"), attachments: [],
                                 quoted: nil, threading: nil)
        let panel = UndoSendPanel(client: harness.environment.engine, accounts: harness.controller.accounts, sendID: "pointer-\(UUID())",
                                  draft: draft, undoWindow: 5)
        defer { panel.orderOut(nil) }
        let slip = try XCTUnwrap(descendants(QuireUndoPanelView.self, of: panel.contentView).first)
        slip.state = .failed
        let action = try XCTUnwrap(slip.actionButton, "Open draft")
        XCTAssertFalse(panel.isKeyWindow)

        action.pointerEntered()
        XCTAssertTrue(NSCursor.current === NSCursor.pointingHand, "the pointer rests on Open draft")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(action.action), to: action.target, from: action))
        XCTAssertFalse(panel.isVisible, "the click ordered the panel out")
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "and the hand went with it")
        XCTAssertFalse(action.hasSetPointer)
        NSCursor.arrow.set()
    }

    // MARK: Helpers

    /// Every point of `popover` on a 6 pt grid has exactly one pointer, unless it lies in two of its own controls' rects
    /// with the same pointer (a field and the text field inside it); with `hands`, the hand inside them and the arrow
    /// elsewhere.
    private func assertOnePointer(over popover: NSView, in recorder: CursorRectRecorder, hands: [NSRect]?,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var checked = 0
        for x in stride(from: popover.bounds.minX + 1, to: popover.bounds.maxX, by: 6) {
            for y in stride(from: popover.bounds.minY + 1, to: popover.bounds.maxY, by: 6) {
                let point = popover.convert(NSPoint(x: x, y: y), to: nil)
                let foreign = recorder.rects.filter { $0.rect.contains(point) && !$0.view.isDescendant(of: popover) }
                XCTAssertEqual(foreign.map { "\(type(of: $0.view))" }, [], "at \(x), \(y) under the popover", file: file, line: line)
                let cursors = Set(recorder.cursors(at: point).map(ObjectIdentifier.init))
                XCTAssertEqual(cursors.count, 1, "at \(x), \(y): \(recorder.rects.filter { $0.rect.contains(point) }.map { "\(type(of: $0.view))" })",
                               file: file, line: line)
                if let hands {
                    let expected = hands.contains { $0.contains(NSPoint(x: x, y: y)) } ? NSCursor.pointingHand : NSCursor.arrow
                    XCTAssertEqual(cursors, [ObjectIdentifier(expected)], "at \(x), \(y)", file: file, line: line)
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 100, file: file, line: line)
    }

    /// A reply composer whose original has folded in under the editor.
    private func replyComposer(_ harness: MainWindowHarness) throws -> ComposeWindowController {
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-0-0")
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: "<p>The quarterly plan is attached.</p>",
                                                                            text: "The quarterly plan is attached."),
                                                          renderedHTML: "<p>The quarterly plan is attached.</p>",
                                                          plainText: "The quarterly plan is attached."), for: original)
        let accounts = harness.controller.accounts
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: .reply(original, all: false))
        XCTAssertTrue(ListTestSupport.spin(until: { composer.contents.quoted != nil }, timeout: 5), "the original folds in")
        composer.window?.contentView?.layoutSubtreeIfNeeded()
        return composer
    }

    private func descendants<T: NSView>(_ type: T.Type, of view: NSView?) -> [T] {
        guard let view else { return [] }
        let own: [T] = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { descendants(type, of: $0) }
    }

    private func area(_ rects: [NSRect]) -> CGFloat {
        rects.reduce(0) { $0 + $1.width * $1.height }
    }

    private func assertDisjoint(_ rects: [NSRect], file: StaticString = #filePath, line: UInt = #line) {
        let rects = rects.filter { !$0.isEmpty }
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertTrue(rects[i].intersection(rects[j]).isEmpty, "\(rects[i]) overlaps \(rects[j])", file: file, line: line)
            }
        }
    }
}

/// A target that records the cursor rects it adds: laid beside a view in a scrolling strip or row, it shows what AppKit
/// asks for there as it scrolls.
@MainActor
private final class CursorProbe: NSView, QuirePointerTarget {
    var added: [NSRect] = []

    var pointerRegions: [QuirePointerRegion] { [.control(bounds, acts: true)] }

    override func resetCursorRects() {
        added = []
        addPointerRects()
    }

    override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) {
        added.append(rect)
        super.addCursorRect(rect, cursor: object)
    }
}

/// Records which views AppKit is asked to reset the cursor rects of.
@MainActor
private final class RecordingWindow: NSWindow {
    var invalidated: [NSView] = []

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        contentView = FlippedTestView(frame: NSRect(origin: .zero, size: size))
    }

    override func invalidateCursorRects(for view: NSView) {
        invalidated.append(view)
        super.invalidateCursorRects(for: view)
    }

    func wasInvalidated(_ view: NSView) -> Bool { invalidated.contains { $0 === view } }
}

/// A flipped content view, as the composer's is.
@MainActor
private final class FlippedTestView: NSView {
    override var isFlipped: Bool { true }
}
