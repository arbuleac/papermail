import AppKit
import XCTest
@testable import SSDesign

/// Views laid over others (spec §4.17): AppKit gives overlapping cursor rects no order, so a target under a cover (a
/// toast's slip, the cheat sheet) leaves the cover's frame to it, and one beside a split view's divider leaves the
/// divider's area to the system's resize pointer. A cover coming, moving or going has every view under it asked again.
@MainActor
final class PointerCoverTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private final class RecordingWindow: NSWindow {
        var invalidated: [NSView] = []

        override func invalidateCursorRects(for view: NSView) {
            invalidated.append(view)
            super.invalidateCursorRects(for: view)
        }

        func wasInvalidated(_ view: NSView) -> Bool { invalidated.contains { $0 === view } }
    }

    private final class RecordingControl: QuireControl {
        var added: [QuirePointerRegion] = []

        override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) {
            added.append(QuirePointerRegion(rect, cursor: object))
            super.addCursorRect(rect, cursor: object)
        }
    }

    /// A row filling its pane up to the divider's hairline, as the list's table does.
    private final class RecordingRow: NSView, QuirePointerTarget {
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

    /// Records the resize rects AppKit's split view adds for its dividers.
    private final class RecordingSplitView: NSSplitView {
        var added: [NSRect] = []

        override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) {
            if !rect.isEmpty { added.append(rect) }
            super.addCursorRect(rect, cursor: object)
        }
    }

    /// Grows each divider's effective rect as the main window's split controller does.
    private final class GrowingDelegate: NSObject, NSSplitViewDelegate {
        func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                       ofDividerAt dividerIndex: Int) -> NSRect {
            proposedEffectiveRect.insetBy(dx: -(6 - drawnRect.width) / 2, dy: 0)
        }
    }

    private func window(_ size: NSSize = NSSize(width: 400, height: 200)) -> RecordingWindow {
        let window = RecordingWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func reset(_ control: RecordingControl, in window: NSWindow) -> [QuirePointerRegion] {
        control.added = []
        window.resetCursorRects()
        return control.added
    }

    // MARK: Covers

    /// A row under a toast's slip leaves the slip's frame to it, so the slip's arrow and its Undo's hand are alone there.
    /// The slip coming, moving, hiding and going asks the views in the window again; then the row has its area back.
    func testAControlUnderASlipLeavesTheSlipsFrameToIt() throws {
        let window = window()
        let row = RecordingControl(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        window.contentView?.addSubview(row)
        let whole = [QuirePointerRegion(row.hitRect, cursor: .pointingHand)]
        XCTAssertEqual(reset(row, in: window), whole)

        window.invalidated = []
        let slip = QuireSlipView(kind: .undoable, message: "Archived")
        let undo = try XCTUnwrap(slip.setAction("Undo", keycap: "Z"))
        window.contentView?.addSubview(slip)
        XCTAssertTrue(window.wasInvalidated(row), "the slip's coming asks the views under it again")
        window.invalidated = []
        slip.setFrameOrigin(NSPoint(x: 100, y: 40))
        XCTAssertTrue(window.wasInvalidated(row), "and so does its moving")
        slip.layoutSubtreeIfNeeded()

        let hole = row.convert(slip.bounds, from: slip)
        let regions = reset(row, in: window)
        XCTAssertTrue(regions.allSatisfy { $0.cursor === NSCursor.pointingHand })
        assertDisjoint(regions.map(\.rect) + [hole])
        XCTAssertEqual(area(regions.map(\.rect)), area([row.hitRect]) - area([row.hitRect.intersection(hole)]), accuracy: 0.01,
                       "the row keeps everything but the slip")
        XCTAssertEqual(undo.pointerRegions.map(\.cursor), [.pointingHand], "the slip's own action is not cut by the slip")
        XCTAssertTrue(slip.pointerRegions.allSatisfy { $0.cursor === NSCursor.arrow })

        window.invalidated = []
        slip.isHidden = true
        XCTAssertTrue(window.wasInvalidated(row))
        XCTAssertEqual(reset(row, in: window), whole, "a hidden slip covers nothing")
        slip.isHidden = false
        XCTAssertNotEqual(reset(row, in: window), whole)

        window.invalidated = []
        slip.removeFromSuperview()
        XCTAssertTrue(window.wasInvalidated(row), "its going asks the window it left")
        XCTAssertEqual(reset(row, in: window), whole)
    }

    /// Only a cover drawn above a view cuts it: a control added after the slip lies over it and keeps its own area.
    func testOnlyACoverDrawnAboveAViewCutsIt() {
        let window = window()
        let slip = QuireSlipView(kind: .confirmation, message: "Undid Archive")
        window.contentView?.addSubview(slip)
        slip.setFrameOrigin(NSPoint(x: 20, y: 20))
        let above = RecordingControl(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        window.contentView?.addSubview(above)
        XCTAssertEqual(reset(above, in: window), [QuirePointerRegion(above.hitRect, cursor: .pointingHand)])
        XCTAssertEqual(above.pointerCoverAreas(), [])
    }

    /// The cheat sheet covers the window: the controls under it add nothing, and a field's own I-beam, AppKit's, is left
    /// out too, so its scrim's hand and its panel's arrow are all there is. Dismissed, everything comes back.
    func testTheCheatSheetLeavesTheWindowToItsOwnPointer() {
        let window = window(NSSize(width: 1280, height: 800))
        let button = RecordingControl(frame: NSRect(x: 600, y: 300, width: 120, height: 40))
        let search = QuireSearchField()
        search.frame = NSRect(x: 20, y: 740, width: 240, height: 40)
        window.contentView?.addSubview(button)
        window.contentView?.addSubview(search)
        XCTAssertFalse(reset(button, in: window).isEmpty)
        XCTAssertFalse(search.textField.isUnderPointerCover)

        window.invalidated = []
        let overlay = QuireCheatSheetOverlay(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        window.contentView?.addSubview(overlay)
        overlay.present(animated: false)
        XCTAssertTrue(window.wasInvalidated(button) && window.wasInvalidated(search.textField), "every view under it is asked again")
        XCTAssertEqual(reset(button, in: window), [], "nothing under the scrim or the panel shows through")
        XCTAssertTrue(search.textField.isUnderPointerCover, "the field's own I-beam is left out")

        overlay.dismiss(animated: false)
        overlay.removeFromSuperview()
        XCTAssertEqual(reset(button, in: window), [QuirePointerRegion(button.hitRect, cursor: .pointingHand)])
        XCTAssertFalse(search.textField.isUnderPointerCover)
    }

    // MARK: Split dividers

    /// A control filling a pane next to a thin divider leaves the divider's area to the split view, as its delegate grows
    /// it: the system's resize pointer and the control's never overlap, at any scale.
    func testAControlBesideASplitDividerLeavesTheDividerItsArea() {
        let window = window(NSSize(width: 600, height: 300))
        let split = RecordingSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        split.isVertical = true
        split.dividerStyle = .thin
        let delegate = GrowingDelegate()
        let panes = [NSView(), NSView()]
        panes.forEach(split.addArrangedSubview)
        window.contentView?.addSubview(split)
        split.setPosition(240, ofDividerAt: 0)
        let left = RecordingRow(frame: panes[0].bounds)
        left.autoresizingMask = [.width, .height]
        let right = RecordingRow(frame: panes[1].bounds)
        right.autoresizingMask = [.width, .height]
        panes[0].addSubview(left)
        panes[1].addSubview(right)

        for grows in [false, true] {
            split.delegate = grows ? delegate : nil
            split.added = []
            window.resetCursorRects()
            let regions = left.added.map { split.convert($0, from: left) } + right.added.map { split.convert($0, from: right) }
            XCTAssertFalse(split.added.isEmpty, "the split view adds its resize rect")
            XCTAssertFalse(regions.isEmpty)
            XCTAssertGreaterThan(left.added.reduce(0) { $0 + $1.width }, panes[0].bounds.width - 12, "the row keeps the rest of its pane")
            for divider in split.added {
                for region in regions {
                    XCTAssertTrue(region.intersection(divider).isEmpty, "\(region) overlaps the divider's \(divider)")
                }
            }
        }
    }

    // MARK: Helpers

    private func area(_ rects: [NSRect]) -> CGFloat {
        rects.reduce(0) { $0 + $1.width * $1.height }
    }

    private func assertDisjoint(_ rects: [NSRect], file: StaticString = #filePath, line: UInt = #line) {
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertTrue(rects[i].intersection(rects[j]).isEmpty, "\(rects[i]) overlaps \(rects[j])", file: file, line: line)
            }
        }
    }
}
