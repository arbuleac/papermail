import AppKit
import XCTest
@testable import SSDesign

/// The pointer over AppKit controls (spec §4.17): the pointing hand over a control's hit rect while a click acts on it,
/// the arrow while it is disabled or a click would change nothing, the I-beam over a field's face, one region alone
/// under any point, and AppKit asked for the regions again whenever they change.
@MainActor
final class PointerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    /// Records which views AppKit is asked to reset the cursor rects of.
    private final class RecordingWindow: NSWindow {
        var invalidated: [NSView] = []

        override func invalidateCursorRects(for view: NSView) {
            invalidated.append(view)
            super.invalidateCursorRects(for: view)
        }

        func wasInvalidated(_ view: NSView) -> Bool { invalidated.contains { $0 === view } }
    }

    /// Records the cursor rects the control adds when AppKit asks for them.
    private final class RecordingControl: QuireControl {
        var added: [QuirePointerRegion] = []

        override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) {
            added.append(QuirePointerRegion(rect, cursor: object))
            super.addCursorRect(rect, cursor: object)
        }
    }

    private func window(_ size: NSSize = NSSize(width: 400, height: 200)) -> RecordingWindow {
        let window = RecordingWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// What AppKit gets from `view` when it resets the window's cursor rects.
    private func reset(_ control: RecordingControl, in window: NSWindow) -> [QuirePointerRegion] {
        control.added = []
        window.resetCursorRects()
        return control.added
    }

    // MARK: The base

    /// A control adds the hand over its hit rect, never the ring margin around it; disabled, the arrow there instead, so
    /// a clickable view behind cannot show its hand through it; hidden, nothing. AppKit is asked again at each change.
    func testAControlAddsTheHandOverItsHitRectAndTheArrowWhileDisabled() {
        let window = window()
        let control = RecordingControl(frame: NSRect(x: 20, y: 20, width: 120, height: 40))
        window.contentView?.addSubview(control)
        XCTAssertTrue(control.bounds.contains(control.hitRect) && control.hitRect != control.bounds, "the ring margin is outside")

        XCTAssertEqual(reset(control, in: window), [QuirePointerRegion(control.hitRect, cursor: .pointingHand)])

        window.invalidated = []
        control.isEnabled = false
        XCTAssertTrue(window.wasInvalidated(control), "disabling asks AppKit again")
        XCTAssertEqual(reset(control, in: window), [QuirePointerRegion(control.hitRect, cursor: .arrow)])

        control.isEnabled = true
        window.invalidated = []
        control.isHidden = true
        XCTAssertTrue(window.wasInvalidated(control), "hiding asks AppKit again")
        XCTAssertEqual(reset(control, in: window), [], "a hidden control adds nothing")

        window.invalidated = []
        control.isHidden = false
        XCTAssertTrue(window.wasInvalidated(control))
        XCTAssertEqual(reset(control, in: window), [QuirePointerRegion(control.hitRect, cursor: .pointingHand)])
    }

    /// A control inside another keeps its own region, and its container leaves that area out, so one region alone lies
    /// under any point; when the inner control hides, the container takes the area back.
    func testAControlInsideAnotherKeepsItsOwnArea() {
        let window = window()
        let outer = RecordingControl(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let inner = QuireButton(title: "Retry", variant: .link, size: .small)
        inner.setFrameOrigin(NSPoint(x: 200, y: 10))
        outer.addSubview(inner)
        window.contentView?.addSubview(outer)

        let hole = outer.convert(inner.hitRect, from: inner)
        let regions = reset(outer, in: window)
        XCTAssertGreaterThan(regions.count, 1)
        assertDisjoint(regions.map(\.rect) + [hole])
        XCTAssertEqual(area(regions.map(\.rect)), area([outer.hitRect]) - area([hole]), accuracy: 0.01, "everything else is covered")

        window.invalidated = []
        inner.isHidden = true
        XCTAssertTrue(window.wasInvalidated(outer), "the container is asked again when its child hides")
        XCTAssertEqual(reset(outer, in: window), [QuirePointerRegion(outer.hitRect, cursor: .pointingHand)])
    }

    func testRegionsCutHolesIntoRectsThatNeverOverlap() {
        let rect = NSRect(x: 0, y: 0, width: 100, height: 40)
        let holes = [NSRect(x: 80, y: 10, width: 10, height: 10), NSRect(x: -5, y: 30, width: 20, height: 20), NSRect(x: 200, y: 0, width: 5, height: 5)]
        let regions = QuirePointerRegion.regions(rect, cursor: .iBeam, cutting: holes)
        XCTAssertTrue(regions.allSatisfy { $0.cursor === NSCursor.iBeam && rect.contains($0.rect) })
        assertDisjoint(regions.map(\.rect) + holes)
        XCTAssertEqual(area(regions.map(\.rect)), 4000 - 100 - 15 * 10, accuracy: 0.01)
        XCTAssertEqual(QuirePointerRegion.regions(rect, cursor: .arrow, cutting: []), [QuirePointerRegion(rect, cursor: .arrow)])
        XCTAssertEqual(QuirePointerRegion.regions(rect, cursor: .arrow, cutting: [rect]), [])
    }

    // MARK: Controls a click would leave as they are

    /// A loading button's click starts nothing more: the arrow until its work ends.
    func testLoadingButtonsShowTheArrow() {
        let window = window()
        let button = QuireButton(title: "Add Gmail account")
        let icon = QuireIconButton(symbolName: Quire.Icon.send, size: .medium)
        window.contentView?.addSubview(button)
        window.contentView?.addSubview(icon)
        for control in [button, icon] as [QuireControl] {
            XCTAssertEqual(control.pointerRegions.map(\.cursor), [.pointingHand])
        }
        window.invalidated = []
        button.isLoading = true
        icon.isLoading = true
        XCTAssertTrue(window.wasInvalidated(button) && window.wasInvalidated(icon))
        XCTAssertEqual(button.pointerRegions, [QuirePointerRegion(button.hitRect, cursor: .arrow)])
        XCTAssertEqual(icon.pointerRegions, [QuirePointerRegion(icon.hitRect, cursor: .arrow)])
        button.isLoading = false
        XCTAssertEqual(button.pointerRegions.map(\.cursor), [.pointingHand])
    }

    /// A group's chosen radio stays chosen whatever the click; the others take the hand. A radio on its own sends its
    /// action on every click, so it keeps the hand.
    func testAGroupsChosenRadioShowsTheArrow() {
        let window = window()
        let group = QuireRadioGroupView(titles: ["Standard", "Compact"], selectedIndex: 0)
        window.contentView?.addSubview(group)
        XCTAssertEqual(group.buttons.map { $0.pointerRegions.map(\.cursor) }, [[.arrow], [.pointingHand]])
        window.invalidated = []
        group.buttons[1].performClick(nil)
        XCTAssertTrue(window.wasInvalidated(group.buttons[0]) && window.wasInvalidated(group.buttons[1]))
        XCTAssertEqual(group.buttons.map { $0.pointerRegions.map(\.cursor) }, [[.pointingHand], [.arrow]])
        XCTAssertEqual(QuireRadioButton(title: "Alone", isSelected: true).pointerRegions.map(\.cursor), [.pointingHand])
    }

    /// Each tab has its own area within the control's hit rect: the hand on a tab a click would choose, the arrow on the
    /// chosen tab and on a disabled one (the quick reply's Reply all with one other person), and the arrow between them,
    /// so the whole hit rect, which a container cuts out of its own region, has one pointer at every point.
    func testTabsShowTheHandOnlyWhereAClickChooses() {
        let window = window()
        let tabs = QuireUnderlineTabs(items: [.init("Reply"), .init("Reply all"), .init("Forward", isEnabled: false)], selectedIndex: 0)
        window.contentView?.addSubview(tabs)
        let cursors = { (0..<3).map { index -> NSCursor? in
            let slot = tabs.slotRect(forTab: index)
            return tabs.pointerRegions.first { $0.rect.contains(NSPoint(x: slot.midX, y: slot.midY)) }?.cursor
        } }
        XCTAssertEqual(cursors(), [.arrow, .pointingHand, .arrow])
        assertDisjoint(tabs.pointerRegions.map(\.rect))
        XCTAssertTrue(tabs.pointerRegions.allSatisfy { tabs.hitRect.contains($0.rect) })
        XCTAssertEqual(area(tabs.pointerRegions.map(\.rect)), area([tabs.hitRect]), accuracy: 0.01, "the gaps take the arrow")
        let gap = NSPoint(x: (tabs.slotRect(forTab: 0).maxX + tabs.slotRect(forTab: 1).minX) / 2, y: tabs.hitRect.midY)
        XCTAssertEqual(tabs.pointerRegions.filter { $0.rect.contains(gap) }.map(\.cursor), [.arrow])
        window.invalidated = []
        tabs.selectedIndex = 1
        XCTAssertTrue(window.wasInvalidated(tabs))
        XCTAssertEqual(cursors(), [.pointingHand, .arrow, .arrow])
        tabs.isEnabled = false
        XCTAssertEqual(cursors(), [.arrow, .arrow, .arrow])
    }

    // MARK: Fields

    /// A field's whole face takes the I-beam, since a click anywhere on it puts the caret in the field; its clear or
    /// reveal button keeps its own hand, cut out of the face. Disabled, the arrow.
    func testFieldsShowTheIBeamOverTheirFaceAndLeaveTheirButtonsTheirHand() {
        let window = window(NSSize(width: 600, height: 200))
        let search = QuireSearchField()
        search.setFrameSize(search.frame(forAlignmentRect: NSRect(x: 0, y: 0, width: 280, height: Quire.Layout.ListHeader.searchHeight)).size)
        window.contentView?.addSubview(search)
        XCTAssertEqual(search.pointerRegions, [QuirePointerRegion(search.hitRect, cursor: .iBeam)], "no clear button yet")

        window.invalidated = []
        search.query = "plan"
        search.resultCount = 3
        search.layoutSubtreeIfNeeded()
        let clear = search.subviews.compactMap { $0 as? QuireControl }.first { !$0.isHidden }
        XCTAssertNotNil(clear, "the clear button shows with results")
        XCTAssertTrue(window.wasInvalidated(search), "the field is asked again when its button shows")
        if let clear {
            XCTAssertEqual(clear.pointerRegions.map(\.cursor), [.pointingHand])
            let hole = search.convert(clear.hitRect, from: clear)
            XCTAssertTrue(search.pointerRegions.allSatisfy { $0.cursor === NSCursor.iBeam })
            assertDisjoint(search.pointerRegions.map(\.rect) + [hole])
        }
        search.isEnabled = false
        XCTAssertEqual(search.pointerRegions, [QuirePointerRegion(search.hitRect, cursor: .arrow)])

        let secret = QuireTextField(isSecure: true)
        secret.setFrameSize(secret.frame(forAlignmentRect: NSRect(x: 0, y: 0, width: 240, height: 28)).size)
        secret.setFrameOrigin(NSPoint(x: 300, y: 0))
        window.contentView?.addSubview(secret)
        XCTAssertEqual(secret.pointerRegions, [QuirePointerRegion(secret.hitRect, cursor: .iBeam)], "the reveal button hides at rest")
        secret.isRevealed = true
        secret.layoutSubtreeIfNeeded()
        XCTAssertEqual(secret.revealButton?.isHidden, false)
        if let reveal = secret.revealButton {
            assertDisjoint(secret.pointerRegions.map(\.rect) + [secret.convert(reveal.hitRect, from: reveal)])
            XCTAssertEqual(reveal.pointerRegions.map(\.cursor), [.pointingHand])
        }
    }

    // MARK: Surfaces and links

    /// Surfaces that lie on something clickable show the arrow around their controls, so the page's or the list's
    /// pointer never shows through: the find bar on the reader (its field the I-beam, its buttons the hand, Previous and
    /// Next the arrow while nothing matches), a toast on the list, the cheat sheet's panel on its scrim, whose own
    /// area, which a click closes, takes the hand.
    func testSurfacesOnClickableViewsShowTheArrowAroundTheirControls() {
        let window = window(NSSize(width: 1280, height: 800))
        let bar = QuireFindBar()
        window.contentView?.addSubview(bar)
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(bar.pointerRegions.isEmpty)
        XCTAssertTrue(bar.pointerRegions.allSatisfy { $0.cursor === NSCursor.arrow })
        let controls = bar.subviews.compactMap { $0 as? QuireControl }
        XCTAssertEqual(controls.count, 4, "the field and three buttons")
        assertDisjoint(bar.pointerRegions.map(\.rect) + controls.map { bar.convert($0.hitRect, from: $0) })
        XCTAssertEqual(controls.map { $0.pointerRegions.first?.cursor }, [.iBeam, .arrow, .arrow, .pointingHand])
        bar.hasMatches = true
        XCTAssertEqual(controls.map { $0.pointerRegions.first?.cursor }, [.iBeam, .pointingHand, .pointingHand, .pointingHand])

        let slip = QuireSlipView(kind: .undoable, message: "Archived")
        let undo = slip.setAction("Undo", keycap: "Z")
        slip.setFrameSize(slip.intrinsicContentSize)
        window.contentView?.addSubview(slip)
        slip.layoutSubtreeIfNeeded()
        XCTAssertNotNil(undo)
        XCTAssertTrue(slip.pointerRegions.allSatisfy { $0.cursor === NSCursor.arrow })
        if let undo { assertDisjoint(slip.pointerRegions.map(\.rect) + [slip.convert(undo.hitRect, from: undo)]) }

        let overlay = QuireCheatSheetOverlay(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        window.contentView?.addSubview(overlay)
        overlay.present(animated: false)
        overlay.layoutSubtreeIfNeeded()
        let panel = overlay.panel
        XCTAssertTrue(overlay.pointerRegions.allSatisfy { $0.cursor === NSCursor.pointingHand }, "a click on the scrim closes")
        assertDisjoint(overlay.pointerRegions.map(\.rect) + [panel.frame])
        XCTAssertEqual(area(overlay.pointerRegions.map(\.rect)), area([overlay.bounds]) - area([panel.frame]), accuracy: 0.01)
        XCTAssertTrue(panel.pointerRegions.allSatisfy { $0.cursor === NSCursor.arrow })
        assertDisjoint(panel.pointerRegions.map(\.rect) + [panel.convert(panel.closeButton.hitRect, from: panel.closeButton)])
        window.invalidated = []
        overlay.dismiss(animated: false)
        XCTAssertTrue(window.wasInvalidated(overlay), "dismissed, its rects go")
    }

    /// The empty state's hint link takes the hand over its words; the sentence and the rest of the hint add nothing.
    func testTheEmptyStatesLinkShowsTheHand() {
        let window = window(NSSize(width: 600, height: 300))
        let view = QuireEmptyStateView(sentence: "No results.", hint: [.text("Nothing on this Mac."), .link("Search Gmail")])
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        window.contentView?.addSubview(view)
        let link = view.linkRect
        XCTAssertNotNil(link)
        XCTAssertEqual(view.pointerRegions, link.map { [QuirePointerRegion($0, cursor: .pointingHand)] } ?? [])
        window.invalidated = []
        view.hint = [.text("Nothing on this Mac.")]
        XCTAssertTrue(window.wasInvalidated(view))
        XCTAssertEqual(view.pointerRegions, [])
    }

    // MARK: Controls Quire does not draw, and windows that are never key

    /// An alert's button gets the hand from an overlay that takes no clicks and follows the button's `isEnabled`.
    func testTheOverlayGivesAnAppKitControlTheHand() {
        let window = window()
        let button = NSButton(title: "Snooze", target: nil, action: nil)
        button.frame = NSRect(x: 10, y: 10, width: 90, height: 24)
        window.contentView?.addSubview(button)
        let overlay = QuirePointerOverlay.install(on: button)
        XCTAssertTrue(QuirePointerOverlay.install(on: button) === overlay, "one overlay per control")
        XCTAssertEqual(overlay.frame, button.bounds)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 20, y: 10)), "clicks reach the button")
        XCTAssertEqual(overlay.pointerRegions, [QuirePointerRegion(button.bounds, cursor: .pointingHand)])
        window.invalidated = []
        button.isEnabled = false
        XCTAssertTrue(window.wasInvalidated(overlay), "it follows the button's isEnabled")
        XCTAssertEqual(overlay.pointerRegions, [QuirePointerRegion(button.bounds, cursor: .arrow)])
        button.setFrameSize(NSSize(width: 120, height: 24))
        XCTAssertEqual(overlay.frame, button.bounds, "sized with the button")
    }

    /// The undo-send panel never becomes key, where cursor rects apply, so its action sets the pointer itself from a
    /// tracking area that works whether or not the app is active.
    func testTheUndoPanelsActionSetsThePointerOutsideTheKeyWindow() throws {
        let panel = QuireUndoPanelView(state: .counting(secondsLeft: 5), summary: "To Ada")
        let action = try XCTUnwrap(panel.actionButton)
        XCTAssertTrue(action.tracksPointerOutsideKeyWindow)

        let window = window()
        let button = QuireButton(title: "Undo")
        window.contentView?.addSubview(button)
        XCTAssertFalse(button.trackingAreas.contains { $0.options.contains(.activeAlways) })
        button.tracksPointerOutsideKeyWindow = true
        XCTAssertTrue(button.trackingAreas.contains { $0.options.contains(.activeAlways) && $0.rect == button.hitRect })
        XCTAssertFalse(window.isKeyWindow)
        button.pointerEntered()
        XCTAssertTrue(NSCursor.current === NSCursor.pointingHand)
        button.pointerExited()
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        button.isEnabled = false
        button.pointerEntered()
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "a disabled control shows the arrow")
        button.tracksPointerOutsideKeyWindow = false
        XCTAssertFalse(button.trackingAreas.contains { $0.options.contains(.activeAlways) })
    }

    /// No exit event follows when the pointer is over the panel's action and the action goes (the countdown ends and the
    /// next state removes it, the panel is ordered out) or hides, so the action takes back the hand it set; and it sets
    /// the pointer again when what it shows changes under the resting pointer.
    func testTheUndoPanelsActionTakesBackThePointerItSet() {
        let window = window()
        let button = QuireButton(title: "Undo")
        button.tracksPointerOutsideKeyWindow = true
        window.contentView?.addSubview(button)
        XCTAssertFalse(window.isKeyWindow)

        button.pointerEntered()
        XCTAssertTrue(NSCursor.current === NSCursor.pointingHand)
        button.isEnabled = false
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "disabled under the pointer: the arrow at once")
        button.isEnabled = true
        XCTAssertTrue(NSCursor.current === NSCursor.pointingHand, "and the hand again")
        button.isLoading = true
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "loading: a click does nothing")
        button.isLoading = false

        button.removeFromSuperview()
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "removed under the pointer, it takes the hand back")
        XCTAssertFalse(button.hasSetPointer)

        window.contentView?.addSubview(button)
        button.pointerEntered()
        button.isHidden = true
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "hidden under the pointer, too")
        button.isHidden = false
        button.pointerExited()

        // A control that never set it leaves the pointer alone.
        NSCursor.iBeam.set()
        button.removeFromSuperview()
        XCTAssertTrue(NSCursor.current === NSCursor.iBeam)
        NSCursor.arrow.set()
    }

    /// The G-sequence HUD only tells which keys go where: clicks go through it to the rows under it, whose hand is then
    /// right over it too.
    func testTheSequenceHUDLetsClicksThrough() {
        let hud = QuireSequenceHUDView()
        hud.frame = NSRect(origin: .zero, size: hud.intrinsicContentSize)
        hud.layoutSubtreeIfNeeded()
        XCTAssertNil(hud.hitTest(NSPoint(x: hud.bounds.midX, y: hud.bounds.midY)))
    }

    // MARK: Helpers

    private func area(_ rects: [NSRect]) -> CGFloat {
        rects.reduce(0) { $0 + $1.width * $1.height }
    }

    private func assertDisjoint(_ rects: [NSRect], file: StaticString = #filePath, line: UInt = #line) {
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                XCTAssertTrue(overlap.isEmpty, "\(rects[i]) overlaps \(rects[j])", file: file, line: line)
            }
        }
    }
}
