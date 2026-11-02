import XCTest
@testable import SSCore

final class ComposePlacementTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 640, height: 600)

    func testLinkPopoverSitsBelowTheSelectionUnderItsStart() {
        let line = CGRect(x: 84, y: 200, width: 200, height: 21)
        let frame = ComposePopoverPlacement.linkPopover(firstLine: line, lastLine: line, selectionStartX: 150,
                                                        size: CGSize(width: 320, height: 92), bounds: bounds,
                                                        pad: 12, offsetY: 6, edgeMin: 8)
        XCTAssertEqual(frame.minY, 227)
        XCTAssertEqual(frame.minX, 138)
    }

    func testLinkPopoverFlipsAboveWithoutRoomBelow() {
        let first = CGRect(x: 84, y: 520, width: 200, height: 21)
        let last = CGRect(x: 84, y: 541, width: 200, height: 21)
        let frame = ComposePopoverPlacement.linkPopover(firstLine: first, lastLine: last, selectionStartX: 84,
                                                        size: CGSize(width: 320, height: 92), bounds: bounds,
                                                        pad: 12, offsetY: 6, edgeMin: 8)
        XCTAssertEqual(frame.maxY, 514)
    }

    func testLinkPopoverStaysInsideTheWindow() {
        let line = CGRect(x: 500, y: 100, width: 100, height: 21)
        let frame = ComposePopoverPlacement.linkPopover(firstLine: line, lastLine: line, selectionStartX: 560,
                                                        size: CGSize(width: 320, height: 92), bounds: bounds,
                                                        pad: 12, offsetY: 6, edgeMin: 8)
        XCTAssertEqual(frame.maxX, 632)
    }

    func testAutocompleteLinesNamesUpWithTheTypedLetters() {
        let line = CGRect(x: 84, y: 70, width: 500, height: 22)
        let frame = ComposePopoverPlacement.autocomplete(tokenStartX: 200, caretLine: line,
                                                         size: CGSize(width: 320, height: 128), bounds: bounds,
                                                         offsetX: -46, offsetY: 4, edgeMin: 8)
        XCTAssertEqual(frame.minX, 154)
        XCTAssertEqual(frame.minY, 96)
    }

    func testUndoPanelsStackUpFromTheCorner() {
        let window = CGRect(x: 100, y: 100, width: 1280, height: 800)
        let size = CGSize(width: 280, height: 52)
        let first = UndoSendPanelGeometry.visualFrame(anchor: window, bottomClearance: 0, slot: 0, size: size, inset: 20, stackGap: 8)
        XCTAssertEqual(first, CGRect(x: 1080, y: 120, width: 280, height: 52))
        let second = UndoSendPanelGeometry.visualFrame(anchor: window, bottomClearance: 0, slot: 1, size: size, inset: 20, stackGap: 8)
        XCTAssertEqual(second.minY, 180)
        let lifted = UndoSendPanelGeometry.visualFrame(anchor: window, bottomClearance: 60, slot: 0, size: size, inset: 20, stackGap: 8)
        XCTAssertEqual(lifted.minY, 180)
        let outer = UndoSendPanelGeometry.windowFrame(visual: first, margins: .init(top: 32, side: 48, bottom: 68))
        XCTAssertEqual(outer, CGRect(x: 1032, y: 52, width: 376, height: 152))
    }
}
