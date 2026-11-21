import AppKit
import XCTest
@testable import SSDesign

/// Send's split button (spec §5.23): one face, the action segment (glyph, label, its “⌘↩” on the face) and the menu
/// segment behind the divider; two controls with their own hit areas, states, focus rings and VoiceOver names; the faces it
/// draws (accent, raised while the window is not key, quiet while the action cannot act) and the keycap on the accent.
@MainActor
final class QuireSplitButtonTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    @MainActor final class Recorder: NSObject {
        var fired: [String] = []
        var states: [QuireDisplayState] = []
        @objc func send(_ sender: Any?) { fired.append("send") }
        @objc func options(_ sender: Any?) {
            fired.append("options")
            states.append((sender as? QuireSplitSegment)?.interactionState ?? .rest)
        }
    }

    private func split(_ size: QuireButton.Size = .regular, keycap: String? = "⌘↩") -> QuireSplitButton {
        let b = QuireSplitButton(title: "Send", symbolName: Quire.Icon.send, size: size, keycap: keycap, menuAccessibilityLabel: "Send Options")
        b.actionSegment.loadingTitle = "Sending…"
        b.windowKeyOverride = true
        b.frame = b.frame(forVisualRect: NSRect(origin: NSPoint(x: 20, y: 10), size: b.intrinsicContentSize))
        b.layoutSubtreeIfNeeded()
        return b
    }

    private func face(of segment: QuireSplitSegment, in button: QuireSplitButton) -> NSRect {
        button.convert(segment.faceRect, from: segment)
    }

    private func labelWidth(_ text: String, _ role: QuireFont.Role) -> CGFloat {
        ceil(QuireDraw.width(QuireDraw.line(text, role, .black)))
    }

    // MARK: Geometry

    /// One face as tall as the button's size: the action as wide as its glyph, label and keycap with their gaps, the menu
    /// `splitButton.menuWidth`; the two halves meet at the divider with no gap.
    func testTheFaceIsTheTwoSegmentsEdgeToEdgeAtTheSizesHeight() {
        for (index, size) in QuireButton.Size.allCases.enumerated() {
            let b = split(size)
            let action = face(of: b.actionSegment, in: b), menu = face(of: b.menuSegment, in: b)
            XCTAssertEqual(b.intrinsicContentSize.height, size.height, "\(size)")
            XCTAssertEqual(action.height, size.height)
            XCTAssertEqual(menu.height, size.height)
            XCTAssertEqual(menu.width, Quire.Layout.SplitButton.menuWidth[index], "\(size)")
            XCTAssertEqual(action.maxX, menu.minX, "no gap at the divider")
            XCTAssertEqual(action.minX, b.faceRect.minX)
            XCTAssertEqual(menu.maxX, b.faceRect.maxX)
            XCTAssertEqual(b.intrinsicContentSize.width, action.width + menu.width)
        }
    }

    func testTheKeycapSitsOnTheFaceCentredAndEvenlySpacedFromTheDivider() throws {
        for size in [QuireButton.Size.small, .regular] {
            let b = split(size)
            let segment = b.actionSegment
            let content = segment.contentLayout(in: segment.faceRect)
            let cap = try XCTUnwrap(content.keycap, "\(size)")
            let face = segment.faceRect
            XCTAssertEqual(cap.height, Quire.Layout.Kbd.onFill)
            XCTAssertEqual(cap.midY, face.midY, accuracy: 0.5, "centred on the face")
            XCTAssertTrue(face.contains(cap), "inside the face, not beside it")
            let inset = face.maxX - cap.maxX
            // The chevron is as far from the divider on the other side, and the cap never nearer the divider than the top.
            let chevronSide = ((Quire.Layout.SplitButton.menuWidth[QuireButton.Size.allCases.firstIndex(of: size)!]
                - Quire.Layout.SplitButton.divider - Quire.Layout.Popup.chevron) / 2).rounded()
            XCTAssertEqual(inset, max(chevronSide, cap.minY - face.minY), "\(size)")
            let label = try XCTUnwrap(content.label)
            XCTAssertLessThanOrEqual(label.minX + labelWidth("Send", size.strongRole), cap.minX - Quire.Layout.SplitButton.keycapGap + 0.5)
        }
        let regular = split(.regular)
        regular.actionSegment.loadingTitle = nil
        let expected = regular.size.padX + QuireDraw.symbolSize(Quire.Icon.send, size: .custom(regular.size.glyph)).width
            + Quire.Layout.Button.glyphGap + QuireDraw.width(QuireDraw.line("Send", .bodyStrong, .black))
            + Quire.Layout.SplitButton.keycapGap + QuireKeycap.size(for: "⌘↩", style: .onFill).width + 6
        XCTAssertEqual(regular.actionSegment.intrinsicContentSize.width, ceil(expected), "padding, glyph, label, gap, keycap, inset")
    }

    /// Sending: the gerund takes the keycap's place and the face keeps its width, so nothing in the bar moves.
    func testLoadingHidesTheKeycapAndKeepsTheWidth() {
        let b = split()
        let rest = b.intrinsicContentSize.width
        b.actionSegment.isLoading = true
        XCTAssertEqual(b.intrinsicContentSize.width, rest)
        let content = b.actionSegment.contentLayout(in: b.actionSegment.faceRect)
        XCTAssertNil(content.keycap)
        XCTAssertEqual(content.title, "Sending…")
        XCTAssertEqual(b.actionSegment.accessibilityLabel(), "Sending…")
        XCTAssertEqual(b.actionSegment.pointerCursor, .arrow, "a second click starts nothing")
        // The face is as wide as the wider of the two, so the rest face is never narrower than the gerund's.
        let gerund = 2 * b.size.padX + max(QuireDraw.symbolSize(Quire.Icon.send, size: .custom(b.size.glyph)).width,
                                           QuireSpinnerView.Size.small.diameter)
            + Quire.Layout.Button.glyphGap + QuireDraw.width(QuireDraw.line("Sending…", .bodyStrong, .black))
        XCTAssertEqual(b.actionSegment.intrinsicContentSize.width, ceil(max(gerund, b.actionSegment.intrinsicContentSize.width)))
        XCTAssertGreaterThanOrEqual(b.actionSegment.intrinsicContentSize.width, ceil(gerund))
        // Without a keycap (a narrow reader) and no gerund to wait for, the face is its label's, padded on both sides.
        let bare = split(keycap: nil)
        bare.actionSegment.loadingTitle = nil
        let keyed = split()
        keyed.actionSegment.loadingTitle = nil
        XCTAssertEqual(keyed.actionSegment.intrinsicContentSize.width - bare.actionSegment.intrinsicContentSize.width,
                       Quire.Layout.SplitButton.keycapGap + QuireKeycap.size(for: "⌘↩", style: .onFill).width + 6 - b.size.padX, accuracy: 1)
    }

    // MARK: Hit areas

    /// Each half takes its own clicks, never across the divider; a half narrower than the minimum hit grows outward, and
    /// the ring margin around the face is nobody's.
    func testHitAreasSplitAtTheDividerAndMeetTheMinimum() {
        for size in [QuireButton.Size.small, .regular] {
            let b = split(size)
            let action = b.convert(b.actionSegment.hitRect, from: b.actionSegment)
            let menu = b.convert(b.menuSegment.hitRect, from: b.menuSegment)
            XCTAssertEqual(action.maxX, menu.minX, accuracy: 0.001, "\(size): the divider splits them")
            XCTAssertGreaterThanOrEqual(menu.width, Quire.Layout.Button.minHit)
            XCTAssertGreaterThanOrEqual(menu.height, Quire.Layout.Button.minHit)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
            host.addSubview(b)
            let divider = face(of: b.menuSegment, in: b).minX
            let y = b.faceRect.midY
            XCTAssertTrue(b.hitTest(b.convert(NSPoint(x: divider - 1, y: y), to: host)) === b.actionSegment)
            XCTAssertTrue(b.hitTest(b.convert(NSPoint(x: divider + 1, y: y), to: host)) === b.menuSegment)
            XCTAssertNil(b.hitTest(b.convert(NSPoint(x: b.faceRect.minX - 3, y: b.faceRect.minY - 3), to: host)), "the ring margin")
        }
    }

    // MARK: States

    func testTheFaceFollowsTheActionAndTheWindow() {
        let b = split()
        XCTAssertEqual(b.look, .accent)
        b.windowKeyOverride = false
        XCTAssertEqual(b.look, .raised, "a primary in a window that is not key draws as secondary (§3.4)")
        b.windowKeyOverride = true
        b.actionSegment.isEnabled = false
        XCTAssertEqual(b.look, .quiet, "Send waits for a recipient")
        XCTAssertEqual(b.menuSegment.palette.ink, .qInk2, "its options can still be chosen")
        b.menuSegment.isEnabled = false
        XCTAssertEqual(b.menuSegment.palette.ink, .qInkDisabled, "both wait while a reply streams in")
        b.actionSegment.isEnabled = true
        XCTAssertEqual(b.look, .accent)
        XCTAssertNotEqual(b.menuSegment.palette.ink, .qOnAccent, "a waiting chevron steps back on the accent")
    }

    /// Hover and press belong to the segment under the pointer: the other half keeps its rest fill.
    func testHoverAndPressArePerSegment() {
        let b = split()
        b.menuSegment.displayState = .hover
        XCTAssertEqual(b.menuSegment.palette.fills, [.qAccentFillHover])
        XCTAssertEqual(b.actionSegment.palette.fills, [.qAccentFill])
        b.menuSegment.displayState = nil
        b.actionSegment.displayState = .pressed
        XCTAssertEqual(b.actionSegment.palette.fills, [.qAccentFillPressed])
        XCTAssertEqual(b.menuSegment.palette.fills, [.qAccentFill])
    }

    /// The keyboard's ring goes round the focused half only: round on the button's outer side, across the divider.
    func testTheFocusRingGoesRoundTheFocusedSegment() {
        let b = split()
        XCTAssertNil(b.focusedSegment)
        b.menuSegment.displayState = .focused
        XCTAssertTrue(b.focusedSegment === b.menuSegment)
        let menu = face(of: b.menuSegment, in: b)
        let ring = b.ringPath(around: b.menuSegment, gap: QuireFocusRing.gapOnFill, width: 2).bounds
        XCTAssertEqual(ring.minX, menu.minX - QuireFocusRing.gapOnFill - 1, accuracy: 0.01, "across the divider, over the action's edge")
        XCTAssertEqual(ring.maxX, menu.maxX + QuireFocusRing.gapOnFill + 1, accuracy: 0.01)
        XCTAssertLessThanOrEqual(ring.maxX + 1, b.bounds.maxX, "drawn inside the frame")
        b.menuSegment.displayState = nil
        b.actionSegment.displayState = .focused
        XCTAssertTrue(b.focusedSegment === b.actionSegment)
    }

    // MARK: Behaviour

    func testTheSegmentsAreTwoButtonsForTheKeyboardThePointerAndVoiceOver() throws {
        let recorder = Recorder()
        let b = split()
        b.actionSegment.target = recorder
        b.actionSegment.action = #selector(Recorder.send(_:))
        b.menuSegment.target = recorder
        b.menuSegment.action = #selector(Recorder.options(_:))
        XCTAssertFalse(b.isAccessibilityElement(), "VoiceOver meets the two segments")
        XCTAssertEqual(b.actionSegment.accessibilityRole(), .button)
        XCTAssertEqual(b.actionSegment.accessibilityLabel(), "Send")
        XCTAssertEqual(b.menuSegment.accessibilityRole(), .menuButton)
        XCTAssertEqual(b.menuSegment.accessibilityLabel(), "Send Options")
        XCTAssertTrue(b.actionSegment.accessibilityPerformPress())
        XCTAssertEqual(recorder.fired, ["send"])
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        b.menuSegment.mouseDown(with: down)
        XCTAssertEqual(recorder.fired, ["send", "options"], "the menu opens on mouse-down, as a pull-down's")
        XCTAssertEqual(recorder.states, [.pressed], "drawn pressed while its menu tracks")
        XCTAssertEqual(b.menuSegment.interactionState, .rest)
        b.menuSegment.isEnabled = false
        b.menuSegment.mouseDown(with: down)
        XCTAssertEqual(recorder.fired.count, 2, "disabled: nothing")
        b.actionSegment.isEnabled = false
        XCTAssertFalse(b.actionSegment.accessibilityPerformPress())
        XCTAssertEqual(b.actionSegment.pointerCursor, .arrow)
    }

    // MARK: Drawing

    /// On the accent the face is `accentFill` around the content and the keycap's legend is drawn in `onAccent`, in all
    /// four modes and under Graphite (where the fill is ink and `onAccent` paper); the divider is lighter than the face in
    /// light modes, as the label's ink at `splitButton.dividerAlpha`.
    func testTheAccentFaceAndItsKeycapInEveryMode() {
        for graphite in [false, true] {
            for mode in QuireMode.allCases {
                let b = split()
                let snapshot = ComponentSnapshot.render(b, mode: mode, scale: 2, graphite: graphite)
                let label = "\(mode.rawValue)\(graphite ? " Graphite" : "")"
                let origin = b.frame.origin
                func point(_ p: NSPoint, from segment: QuireSplitSegment) -> NSPoint {
                    let local = b.convert(p, from: segment)
                    return NSPoint(x: local.x + origin.x, y: local.y + origin.y)
                }
                let fill = TokenResolver.rgba(.qAccentFill, mode)
                let actionFace = b.actionSegment.faceRect
                XCTAssertTrue(snapshot.matches(fill, at: point(NSPoint(x: actionFace.minX + 3, y: actionFace.midY), from: b.actionSegment)), label)
                let menuFace = b.menuSegment.faceRect
                XCTAssertTrue(snapshot.matches(fill, at: point(NSPoint(x: menuFace.maxX - 3, y: menuFace.minY + 3), from: b.menuSegment)), label)
                // The legend's brightest (or, under Graphite light, darkest) pixel is the label's ink.
                let cap = b.actionSegment.contentLayout(in: actionFace).keycap!
                let ink = TokenResolver.rgba(.qOnAccent, mode)
                var best = Double.infinity
                var y = cap.minY + 2
                while y < cap.maxY - 2 {
                    var x = cap.minX + 2
                    while x < cap.maxX - 2 {
                        let c = snapshot.rgba(at: point(NSPoint(x: x, y: y), from: b.actionSegment))
                        best = min(best, abs(c.r - ink.r) + abs(c.g - ink.g) + abs(c.b - ink.b))
                        x += 0.5
                    }
                    y += 0.5
                }
                XCTAssertLessThan(best * 255, 12, "the legend is drawn in onAccent, \(label)")
            }
        }
    }
}
