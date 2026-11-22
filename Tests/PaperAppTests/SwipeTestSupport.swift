import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// Swipes a row of the list as a trackpad would (spec §5.7, Swipe): the phases and deltas of a two-finger sideways scroll,
/// handed to the list's swipe as the table hands it every scroll event. No test can move fingers.
@MainActor
extension MessageListViewController {
    func tableRow(ofConversation index: Int) throws -> Int {
        try XCTUnwrap(layout.row(ofConversation: index))
    }

    func rowView(ofConversation index: Int) throws -> ConversationRowView {
        try XCTUnwrap(tableView.rowView(atRow: try tableRow(ofConversation: index), makeIfNecessary: false) as? ConversationRowView)
    }

    /// Moves conversation `index`'s row by `distance` points (negative to the left, uncovering the trailing edge) in steps,
    /// and lets go unless `lift` is false; a release's settle is finished at once.
    func drag(_ index: Int, by distance: CGFloat, lift: Bool = true) throws {
        let row = try tableRow(ofConversation: index)
        let steps = 8
        let each = distance / CGFloat(steps)
        swipe.handle(RowSwipeGesture.Scroll(phase: .began, dx: each, dy: 0), atRow: row)
        for _ in 1..<steps { swipe.handle(RowSwipeGesture.Scroll(phase: .changed, dx: each, dy: 0), atRow: row) }
        guard lift else { return }
        swipe.handle(RowSwipeGesture.Scroll(phase: .ended), atRow: row)
        Quire.Motion.finishAll()
    }

    /// Opens `edge`'s button on conversation `index`: the row moved by the button's open width and let go of.
    @discardableResult
    func openButton(_ index: Int, _ edge: RowSwipe.Edge, file: StaticString = #filePath, line: UInt = #line) throws -> QuireSwipeButton {
        let offered = try XCTUnwrap(swipeRow(atTableRow: try tableRow(ofConversation: index))?.button(edge),
                                    "\(edge) offers a button", file: file, line: line)
        try drag(index, by: edge == .trailing ? -offered.openWidth : offered.openWidth)
        let view = try rowView(ofConversation: index)
        XCTAssertEqual(view.swipeOffset, edge == .trailing ? -offered.openWidth : offered.openWidth, "open", file: file, line: line)
        return try XCTUnwrap(view.swipeButton, "the button is out", file: file, line: line)
    }
}
