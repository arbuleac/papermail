import AppKit
import XCTest
@testable import PaperDesign

/// Intrinsic sizes and geometry against the token metrics (spec §5, `layout.*`).
@MainActor
final class ComponentMetricsTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private func labelWidth(_ text: String, _ role: QuireFont.Role) -> CGFloat {
        ceil(QuireFont.attributedString(text, role: role, color: .black).size().width)
    }

    // MARK: Buttons

    func testButtonFontTokensNameRoles() {
        for size in QuireButton.Size.allCases {
            XCTAssertNotEqual(size.role, size.strongRole, "\(size)")
        }
        XCTAssertEqual(QuireButton.Size.small.role, .label)
        XCTAssertEqual(QuireButton.Size.small.strongRole, .labelStrong)
        XCTAssertEqual(QuireButton.Size.regular.role, .bodyMedium)
        XCTAssertEqual(QuireButton.Size.regular.strongRole, .bodyStrong)
        XCTAssertEqual(QuireButton.Size.large.role, .buttonLarge)
        XCTAssertEqual(QuireButton.Size.large.strongRole, .buttonLargeStrong)
    }

    func testButtonHeightsAndPaddingFollowTheSize() {
        let expectations: [(QuireButton.Size, CGFloat, CGFloat)] = [(.small, 22, 9), (.regular, 28, 12), (.large, 36, 16)]
        for (size, height, padX) in expectations {
            let secondary = QuireButton(title: "Reconnect", variant: .secondary, size: size)
            XCTAssertEqual(secondary.intrinsicContentSize.height, height, "\(size)")
            XCTAssertEqual(secondary.intrinsicContentSize.width, 2 * padX + labelWidth("Reconnect", size.role), "\(size)")
            let primary = QuireButton(title: "Send", variant: .primary, size: size)
            XCTAssertEqual(primary.intrinsicContentSize.width, 2 * padX + labelWidth("Send", size.strongRole), "primary uses the strong role")
        }
    }

    func testLinkButtonsUseTheLinkPadding() {
        let link = QuireButton(title: "Load images", variant: .link, size: .small)
        XCTAssertEqual(Quire.Layout.Button.linkPadX, 4)
        XCTAssertEqual(link.intrinsicContentSize.width, 2 * 4 + labelWidth("Load images", .label))
    }

    func testGlyphKeycapAndLoadingWidths() {
        let plain = QuireButton(title: "Send", variant: .primary)
        let glyph = QuireButton(title: "Send", variant: .primary, symbolName: Quire.Icon.send)
        let glyphWidth = QuireDraw.symbolSize(Quire.Icon.send, size: .custom(14)).width
        XCTAssertEqual(glyph.intrinsicContentSize.width, plain.intrinsicContentSize.width + glyphWidth + Quire.Layout.Button.glyphGap)

        // The reader footer's Reply with its R (§5.14): the keycap sits beside the face, never on it.
        let reply = QuireButton(title: "Reply", variant: .secondary)
        let keyed = QuireButton(title: "Reply", variant: .secondary)
        keyed.keycap = "R"
        keyed.sizeToFit()
        let cap = QuireKeycap.size(for: "R", style: .standard).width
        XCTAssertEqual(keyed.intrinsicContentSize.width, reply.intrinsicContentSize.width + Quire.Layout.Button.keycapGap + cap)
        XCTAssertEqual(keyed.faceRect.width, reply.intrinsicContentSize.width, accuracy: 0.01)

        let loading = QuireButton(title: "Send", variant: .primary)
        let before = loading.intrinsicContentSize.width
        loading.loadingTitle = "Sending…"
        let kept = loading.intrinsicContentSize.width
        XCTAssertGreaterThan(kept, before, "the wider loading label sets the width")
        loading.isLoading = true
        XCTAssertEqual(loading.intrinsicContentSize.width, kept, "width kept while loading")
    }

    /// The welcome screen's large buttons (spec §5.39): a trailing note widens the face by the note and its
    /// gap, and the 16 pt loading spinner takes a wider lead than the 12 pt default.
    func testTrailingNoteAndLoadingSpinnerSizeWidths() {
        let plain = QuireButton(title: "Add Gmail account", variant: .secondary, size: .large, symbolName: Quire.Icon.addAccountProvider)
        let noted = QuireButton(title: "Add Gmail account", variant: .secondary, size: .large, symbolName: Quire.Icon.addAccountProvider)
        noted.trailingNote = "Google"
        let note = QuireDraw.width(QuireDraw.line("Google", .snippet, .black))
        XCTAssertEqual(noted.intrinsicContentSize.width, plain.intrinsicContentSize.width + 2 * Quire.Layout.Button.glyphGap + note,
                       accuracy: 1)

        let small = QuireButton(title: "Try", variant: .ghost)
        small.loadingTitle = "Preparing the demo…"
        let medium = QuireButton(title: "Try", variant: .ghost)
        medium.loadingTitle = "Preparing the demo…"
        medium.loadingSpinnerSize = .medium
        let grown = QuireSpinnerView.Size.medium.diameter - QuireSpinnerView.Size.small.diameter
        XCTAssertEqual(medium.intrinsicContentSize.width - small.intrinsicContentSize.width, grown, accuracy: 1)
    }

    func testControlsKeepRoomForTheRingAndReportTheVisualRectForLayout() {
        let button = QuireButton(title: "Send", variant: .primary)
        let m = QuireFocusRing.margin
        XCTAssertEqual(m, 5, "2 pt gap + 3 pt Increase Contrast ring")
        XCTAssertEqual(button.alignmentRectInsets.top, m)
        XCTAssertEqual(button.frame.height, 28 + 2 * m)
        XCTAssertEqual(button.bodyRect.height, 28)
        XCTAssertEqual(button.frame(forVisualRect: NSRect(x: 10, y: 10, width: 60, height: 28)),
                       NSRect(x: 10 - m, y: 10 - m, width: 60 + 2 * m, height: 28 + 2 * m))
    }

    func testHitRectsAreAtLeast24Points() {
        let small = QuireButton(title: "Send", variant: .primary, size: .small)
        XCTAssertGreaterThanOrEqual(small.hitRect.height, 24)
        let tool = QuireIconButton(symbolName: Quire.Icon.attach, size: .small)
        XCTAssertGreaterThanOrEqual(tool.hitRect.width, 24)
        XCTAssertGreaterThanOrEqual(tool.hitRect.height, 24)
        let clear = QuireSearchClearButton(frame: .zero)
        XCTAssertEqual(clear.faceRect.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(clear.hitRect.size, NSSize(width: 24, height: 24))
        // A regular button's hit rect is its face: clicks in the ring margin do not count.
        let regular = QuireButton(title: "Reconnect")
        XCTAssertEqual(regular.hitRect, regular.faceRect)
        XCTAssertNil(regular.hitTest(NSPoint(x: 1, y: 1)))
    }

    func testIconButtonSquares() {
        XCTAssertEqual(QuireIconButton.Size.allCases.map(\.side), [22, 24, 28])
        XCTAssertEqual(QuireIconButton.Size.allCases.map(\.cornerRadius), [5, 5, 6])
        XCTAssertEqual(QuireIconButton(symbolName: Quire.Icon.archive).intrinsicContentSize, NSSize(width: 28, height: 28))
        XCTAssertEqual(QuireIconButton.Size.large.defaultSymbolSize.pointSize, 15)
        XCTAssertEqual(QuireIconButton.Size.medium.defaultSymbolSize.pointSize, 14)
    }

    // MARK: Badges, tags, keycaps

    func testBadgeSizes() {
        // A pill padded 0 5 around its numerals, never narrower than 16 (unread) or 18 (row counts).
        XCTAssertEqual(QuireBadge(.unread(3)).intrinsicContentSize, NSSize(width: max(16, labelWidth("3", .badge) + 10), height: 16))
        XCTAssertEqual(QuireBadge(.messageCount(2)).intrinsicContentSize, NSSize(width: max(18, labelWidth("2", .badge) + 10), height: 16))
        XCTAssertGreaterThanOrEqual(QuireBadge(.unread(1)).intrinsicContentSize.width, 16)
        XCTAssertGreaterThanOrEqual(QuireBadge(.messageCount(1)).intrinsicContentSize.width, 18, "row counts are at least 18 wide")
        XCTAssertEqual(QuireBadge(.dot).intrinsicContentSize, NSSize(width: 8, height: 8))
        XCTAssertEqual(QuireBadge(.attention).intrinsicContentSize, NSSize(width: 16, height: 16))
        let capped = QuireBadge(.unread(128))
        XCTAssertEqual(capped.intrinsicContentSize.width, labelWidth("99+", .badge) + 2 * 5)
        XCTAssertEqual(capped.alignmentRectInsets.left, Quire.Layout.Badge.cutout, "room for the cut-out ring")
    }

    func testTagSize() {
        let tag = QuireTag("Gmail")
        XCTAssertEqual(tag.intrinsicContentSize, NSSize(width: labelWidth("Gmail", .tag) + 10, height: 16))
    }

    func testKeycapSizes() {
        XCTAssertEqual(QuireKeycap.size(for: "E", style: .standard), NSSize(width: 18, height: 18), "never narrower than tall")
        XCTAssertEqual(QuireKeycap.size(for: "/", style: .inField), NSSize(width: 16, height: 16))
        XCTAssertEqual(QuireKeycap.size(for: "K", style: .large).height, 24)
        XCTAssertEqual(QuireKeycap.Style.large.cornerRadius, 5)
        XCTAssertEqual(QuireKeycap.Style.standard.cornerRadius, 3)
        let legend = NSAttributedString(string: "⇧⌘R", attributes: [.font: QuireFont.font(.kbd)])
        XCTAssertEqual(QuireKeycap.size(for: "⇧⌘R", style: .standard).width, ceil(legend.size().width) + 8)
        XCTAssertEqual(QuireKeycap.Style.large.font.pointSize, 12)
    }

    // MARK: Progress

    func testSpinnerSizesAndStrokes() {
        XCTAssertEqual(QuireSpinnerView.Size.allCases.map(\.diameter), [12, 16, 32])
        XCTAssertEqual(QuireSpinnerView.Size.allCases.map(\.strokeWidth), [1.5, 2, 3])
        XCTAssertEqual(QuireSpinnerView(size: .medium).intrinsicContentSize, NSSize(width: 16, height: 16))
    }

    func testBarAndContrailHeights() {
        XCTAssertEqual(QuireProgressBar().intrinsicContentSize.height, 4)
        XCTAssertEqual(QuireContrailView().intrinsicContentSize.height, 4, "the 4 pt head")
    }

    func testSkeletonGeometry() {
        XCTAssertEqual(QuireSkeleton.height(of: .row(index: 0)), 68)
        XCTAssertEqual(QuireSkeleton.height(of: .compactRow(index: 0)), 48)
        XCTAssertEqual(QuireSkeleton.height(of: .body), 58, "three 10 pt bars 14 pt apart (§4.10)")
        let shapes = QuireSkeleton.shapes(.row(index: 0), in: NSRect(x: 0, y: 0, width: 364, height: 68))
        XCTAssertEqual(shapes[0].rect, NSRect(x: 24, y: 19, width: 30, height: 30))
        XCTAssertTrue(shapes[0].isCircle)
        XCTAssertEqual(shapes[1].rect, NSRect(x: 68, y: 14, width: 120, height: 9), "row 0 takes the table's 0 jitter")
        XCTAssertEqual(shapes[2].rect, NSRect(x: 364 - 16 - 28, y: 14, width: 28, height: 9))
        for index in 0..<10 {
            let bar = QuireSkeleton.shapes(.row(index: index), in: NSRect(x: 0, y: 0, width: 600, height: 68))[3].rect
            XCTAssertEqual(bar.width / 190, 1, accuracy: 0.3 + 1e-9, "widths vary within ±0.3")
        }
        let body = QuireSkeleton.shapes(.body, in: NSRect(x: 0, y: 0, width: 500, height: 58))
        XCTAssertEqual(body.map(\.rect.width), [500, 460, 300])
        XCTAssertEqual(body.map(\.rect.minY), [0, 24, 48])
    }

    // MARK: Fields and choices

    func testTextFieldAndSearchSizes() {
        XCTAssertEqual(QuireTextField().intrinsicContentSize.height, 28)
        XCTAssertEqual(QuireTextField(size: .settings).intrinsicContentSize.height, 24)
        let error = QuireTextField()
        error.errorMessage = "That doesn't look like a Google client ID."
        error.frame = error.frame(forVisualRect: NSRect(x: 0, y: 0, width: 600, height: 50))
        XCTAssertEqual(error.intrinsicContentSize.height, 28 + 5 + 14, "help line 5 pt below, one meta line when it fits")
        XCTAssertEqual(error.faceRect.height, 28)
        XCTAssertEqual(QuireSearchField().intrinsicContentSize, NSSize(width: 140, height: 26), "its minimum: the header gives it the free width")
        // The keycap stays only while the whole placeholder fits beside it.
        let narrow = QuireSearchField(placeholder: "Search All Mail")
        XCTAssertFalse(narrow.showsKeycap, "“Search All Mail” and “/” need more than 140 pt")
        narrow.frame = narrow.frame(forVisualRect: NSRect(x: 0, y: 0, width: 200, height: 26))
        XCTAssertTrue(narrow.showsKeycap)
    }

    func testChoiceControlSizes() {
        XCTAssertEqual(QuireCheckbox().intrinsicContentSize, NSSize(width: 14, height: 14))
        let labelled = QuireCheckbox(title: "Show sender")
        XCTAssertEqual(labelled.intrinsicContentSize, NSSize(width: 14 + 8 + labelWidth("Show sender", .body), height: 18))
        XCTAssertEqual(QuireRadioButton().intrinsicContentSize, NSSize(width: 14, height: 14))
        XCTAssertEqual(QuireToggle().intrinsicContentSize, NSSize(width: 30, height: 18))
    }

    func testToggleKnobPositionsAndStretch() {
        let toggle = QuireToggle()
        toggle.layoutSubtreeIfNeeded()
        let track = toggle.trackRect
        let off = toggle.knobFrame(on: false, stretched: false)
        XCTAssertEqual(off, NSRect(x: track.minX + 2, y: track.minY + 2, width: 14, height: 14))
        let on = toggle.knobFrame(on: true, stretched: false)
        XCTAssertEqual(on.maxX, track.maxX - 2)
        // The press stretches toward the centre: the knob keeps its outer edge.
        XCTAssertEqual(toggle.knobFrame(on: false, stretched: true), NSRect(x: off.minX, y: off.minY, width: 18, height: 14))
        let onStretched = toggle.knobFrame(on: true, stretched: true)
        XCTAssertEqual(onStretched.maxX, on.maxX)
        XCTAssertEqual(onStretched.width, 18)
        XCTAssertEqual(toggle.knobRect, off)
        toggle.displayState = .pressed
        XCTAssertEqual(toggle.knobRect.width, 18, "a forced press shows the stretch")
    }

    func testPopupAndTabs() {
        let popup = QuirePopUpButton(titles: ["5 seconds", "10 seconds", "20 seconds"])
        XCTAssertEqual(popup.intrinsicContentSize.height, 24)
        let chevron = QuireDraw.symbolSize(Quire.Icon.popup, size: .custom(12)).width
        let widest = ["5 seconds", "10 seconds", "20 seconds"].map { labelWidth($0, .body) }.max()!
        XCTAssertEqual(popup.intrinsicContentSize.width, ceil(9 + widest + 8 + chevron + 6), "sized to the widest item")
        let marked = QuirePopUpButton(titles: ["Persimmon"])
        marked.inkMark = .swatch(slot: 0)
        XCTAssertEqual(marked.intrinsicContentSize.width, ceil(9 + 14 + 8 + labelWidth("Persimmon", .body) + 8 + chevron + 6))
        XCTAssertEqual(QuirePopUpButton.InkMark.dot(slot: 2).diameter, 7)

        // The borderless popup (the composer's From) hugs the chosen value, so its chevron follows the words; a host
        // laying it out by hand is asked to place it again when the value changes.
        let long = "Alex Morgan <alex.morgan@contoso-engineering.test>", short = "Alex <a@b.test>"
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        let from = QuirePopUpButton(titles: [long, short], isBorderless: true)
        host.addSubview(from)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(from.intrinsicContentSize.width, ceil(9 + labelWidth(long, .body) + 8 + chevron + 6))
        from.selectedIndex = 1
        XCTAssertEqual(from.intrinsicContentSize.width, ceil(9 + labelWidth(short, .body) + 8 + chevron + 6),
                       "sized to the chosen value, not the widest")
        XCTAssertTrue(host.needsLayout, "the host places it again")
        let bordered = QuirePopUpButton(titles: [long, short], selectedIndex: 1)
        XCTAssertEqual(bordered.intrinsicContentSize.width, ceil(9 + labelWidth(long, .body) + 8 + chevron + 6),
                       "a bordered popup keeps its widest item's width")

        // The quick reply's mode tabs (§5.18), the only underline tabs since the filter tabs went (§5.5).
        let titles = ["Reply", "Reply all", "Forward"]
        let tabs = QuireUnderlineTabs(titles: titles)
        XCTAssertEqual(tabs.intrinsicContentSize.height, 28, "the tool row")
        let strong = titles.map { labelWidth($0, .labelStrong) }
        XCTAssertEqual(tabs.intrinsicContentSize.width, strong.reduce(0, +) + 2 * 16)
        XCTAssertEqual(tabs.labelRect(forTab: 0).minY - tabs.bodyRect.minY, 6, "label box y 6–22")
        XCTAssertEqual(tabs.hitRect(forTab: 1).height, 28, "full row height")
        XCTAssertEqual(tabs.hitRect(forTab: 1).width, tabs.slotRect(forTab: 1).width + 12, "label ± 6")
        // Choosing a tab never moves the others.
        let before = tabs.slotRect(forTab: 2)
        tabs.selectedIndex = 1
        XCTAssertEqual(tabs.slotRect(forTab: 2), before)
    }

    // MARK: Surfaces

    func testSlipAndBannerMetrics() {
        let toast = QuireSlipView(kind: .undoable, message: "Archived", symbolName: Quire.Icon.archive)
        XCTAssertEqual(toast.intrinsicContentSize.height, 34)
        let bare = ceil(14 + 14 + 10 + labelWidth("Archived", .bodyMedium) + 14)
        XCTAssertEqual(toast.intrinsicContentSize.width, bare, "padding 0 14 without an action")
        let action = toast.setAction("Undo", keycap: "Z")!
        XCTAssertEqual(action.intrinsicContentSize.height, 26)
        XCTAssertEqual(action.intrinsicContentSize.width, 8 + labelWidth("Undo", .bodyStrong) + 6 + 18 + 8)
        XCTAssertEqual(toast.intrinsicContentSize.width,
                       ceil(14 + 14 + 10 + labelWidth("Archived", .bodyMedium) + 10 + 1 + 10 + action.intrinsicContentSize.width + 6))

        let banner = QuireBannerView(kind: .neutral, message: "3 remote images hidden to protect your privacy.")
        XCTAssertEqual(banner.height(forWidth: 400), 32)
        banner.allowsMultipleLines = true
        let wrapped = banner.height(forWidth: 160)
        XCTAssertGreaterThan(wrapped, 32, "wraps instead of truncating")
        XCTAssertEqual((wrapped - 16).truncatingRemainder(dividingBy: 15), 0, "8 pt padding around whole 15 pt snippet lines")
    }

    func testEmptyStateStaysWithin300Points() {
        let long = QuireEmptyStateView(sentence: "Every conversation in this account appears here, archived ones too.",
                                       hint: "Search looks at subjects, people and message text.")
        XCTAssertLessThanOrEqual(long.intrinsicContentSize.width, 300)
        let short = QuireEmptyStateView(sentence: "Nothing left to read.", hint: "New mail will land here.", glyph: .brandMark)
        XCTAssertEqual(short.intrinsicContentSize.height, 40 + 8 + 24 + 4 + 15, "glyph, gap, aside line, 4 pt, snippet line")
    }

    /// §5.19: the several-selected hint is one line in a normal reader, wider than the sentence's 300 pt,
    /// and when it must wrap it breaks only before a keycap, never between a keycap and its words.
    func testAKeycapHintKeepsItsCommandsWhole() throws {
        let view = QuireEmptyStateView(sentence: "Three conversations, one keystroke.",
                                       hint: [.keys(["E"]), .text("archives them \u{00b7}"), .keys(["#"]),
                                              .text("moves them to Trash \u{00b7}"), .keys(["S"]), .text("stars them")])
        let wide = view.hintSize(available: 790)
        XCTAssertGreaterThan(wide.width, 300, "the hint may be wider than the sentence's cap")
        let oneLine = QuireEmptyStateView(sentence: "", hint: [.keys(["E"]), .text("archives")]).hintSize(available: 790).height
        XCTAssertEqual(wide.height, oneLine, "one line")
        XCTAssertLessThanOrEqual(view.intrinsicContentSize.width, 300, "the view never asks the pane for more")

        let narrow = view.hintSize(available: wide.width - 10)
        XCTAssertEqual(narrow.height, 2 * oneLine, accuracy: 1, "two lines")
        let string = try XCTUnwrap(view.hintString()).string
        let breakable = string.enumerated().filter { $0.element == " " }.map(\.offset)
        let attachments = string.enumerated().filter { $0.element == "\u{FFFC}" }.map(\.offset)
        XCTAssertEqual(breakable.map { $0 + 1 }, Array(attachments.dropFirst()), "breaks only right before the second and third keycaps")
    }

    /// §5.23: Send is as wide as its own label at rest (80 pt in the specimen) and grows to the gerund only
    /// while sending; other buttons keep the wider of the two widths.
    func testALoadingTitleReservesWidthOnlyWhenAsked() {
        let send = QuireButton(title: "Send", variant: .primary, size: .regular, symbolName: Quire.Icon.send)
        let rest = send.intrinsicContentSize.width
        send.loadingTitle = "Sending…"
        XCTAssertGreaterThan(send.intrinsicContentSize.width, rest, "reserved by default")
        send.reservesLoadingWidth = false
        XCTAssertEqual(send.intrinsicContentSize.width, rest, "at rest, its own label")
        XCTAssertEqual(rest, 80, accuracy: 1, "12 + 14 + 6 + “Send” + 12")
        send.isLoading = true
        XCTAssertGreaterThan(send.intrinsicContentSize.width, rest, "the gerund fits while sending")
    }

    func testHairlineWidth() {
        XCTAssertEqual(QuireHairline.width(backingScale: 2, increasedContrast: false), 0.5)
        XCTAssertEqual(QuireHairline.width(backingScale: 1, increasedContrast: false), 1)
        XCTAssertEqual(QuireHairline.width(backingScale: 2, increasedContrast: true), 1, "Increase Contrast draws 1 pt")
    }

    func testFocusRingGeometry() {
        XCTAssertEqual(QuireFocusRing.width(increasedContrast: false), 2)
        XCTAssertEqual(QuireFocusRing.width(increasedContrast: true), 3)
        let path = QuireFocusRing.path(around: CGRect(x: 10, y: 10, width: 60, height: 28), cornerRadius: 6, gap: 2, width: 2)
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 7, y: 7, width: 66, height: 34), "centre line at gap + width / 2")
    }
}
