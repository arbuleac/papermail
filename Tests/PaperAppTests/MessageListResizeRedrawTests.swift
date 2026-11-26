import AppKit
import ObjectiveC
import XCTest
@testable import PaperApp

/// The list's rows are drawn once and kept (their layers redraw only when asked), so a change of the list's width has to
/// ask: a row that is not redrawn shows its old drawing scaled to the new width. AppKit itself redraws a row only when
/// the list grows past the widest it has been, so the list made narrower, or wider again within that width, showed
/// squashed or stretched rows until something else redrew them.
@MainActor
final class MessageListResizeRedrawTests: XCTestCase {
    private typealias Draw = @convention(c) (AnyObject, Selector, NSRect) -> Void

    /// `draw(_:)` calls per class since the last reset, counted by standing in for the method while a test runs.
    nonisolated(unsafe) private static var draws: [String: Int] = [:]
    private var restores: [() -> Void] = []

    private func count(_ type: AnyClass, as name: String) throws {
        let selector = #selector(NSView.draw(_:))
        let method = try XCTUnwrap(class_getInstanceMethod(type, selector))
        let originalIMP = method_getImplementation(method)
        let original = unsafeBitCast(originalIMP, to: Draw.self)
        let block: @convention(block) (AnyObject, NSRect) -> Void = { object, rect in
            Self.draws[name, default: 0] += 1
            original(object, selector, rect)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        restores.append { method_setImplementation(method, originalIMP) }
    }

    override func tearDown() async throws {
        await MainActor.run {
            restores.forEach { $0() }
            restores = []
            Self.draws = [:]
            // The split's autosave writes the test process's own defaults: forgotten, so later windows open as before.
            UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames MainSplit")
        }
        try await super.tearDown()
    }

    private func settle(_ harness: MainWindowHarness) {
        harness.controller.splitView.layoutSubtreeIfNeeded()
        harness.controller.window?.displayIfNeeded()
        CATransaction.flush()
    }

    /// Sets the list's width and returns the draws that followed, per class.
    private func resizeList(of harness: MainWindowHarness, to width: CGFloat) -> [String: Int] {
        let split = harness.controller.splitView
        Self.draws = [:]
        split.setPosition(split.subviews[0].frame.maxX + split.dividerThickness + width, ofDividerAt: 1)
        settle(harness)
        XCTAssertEqual(split.subviews[1].frame.width, width, accuracy: 1, "the list took the width")
        return Self.draws
    }

    func testEveryRowIsRedrawnWhenTheListChangesWidth() throws {
        try count(ConversationCellView.self, as: "cell")
        try count(ConversationRowView.self, as: "row")
        try count(RunningHeadRowView.self, as: "head")
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1289, height: 900))
        window.orderFront(nil)
        _ = resizeList(of: harness, to: 420)
        let table = harness.list.tableView
        let visible = table.rows(in: table.visibleRect)
        let rows = (visible.location..<NSMaxRange(visible)).compactMap { table.rowView(atRow: $0, makeIfNecessary: false) }
        let conversations = rows.filter { $0 is ConversationRowView }.count
        let heads = rows.filter { $0 is RunningHeadRowView }.count
        XCTAssertGreaterThan(conversations, 0)
        XCTAssertGreaterThan(heads, 0)
        // Narrower, wider within a width it had, and back: the cases AppKit leaves alone.
        for width in [320, 380, 300, 420] as [CGFloat] {
            let draws = resizeList(of: harness, to: width)
            XCTAssertEqual(draws["cell"], conversations, "every conversation's words are drawn again at \(width)")
            XCTAssertEqual(draws["row"], conversations, "every row's ground is drawn again at \(width)")
            XCTAssertEqual(draws["head"], heads, "every running head is drawn again at \(width)")
        }
    }

    /// The reason the rows keep their drawing: a window that grows gives the reader the room, the list keeps its width,
    /// and no row is drawn again.
    func testAWindowResizeThatLeavesTheListsWidthRedrawsNoRow() throws {
        try count(ConversationCellView.self, as: "cell")
        try count(ConversationRowView.self, as: "row")
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1289, height: 900))
        window.orderFront(nil)
        _ = resizeList(of: harness, to: 364)
        let width = harness.controller.splitView.subviews[1].frame.width
        Self.draws = [:]
        window.setContentSize(NSSize(width: 1500, height: 900))
        settle(harness)
        XCTAssertEqual(harness.controller.splitView.subviews[1].frame.width, width, "the reader took the change")
        XCTAssertNil(Self.draws["cell"])
        XCTAssertNil(Self.draws["row"])
    }
}
