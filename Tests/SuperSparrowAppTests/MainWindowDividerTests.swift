import AppKit
import XCTest
@testable import SuperSparrowApp

/// The pane dividers are hairlines (spec §5.1): one device pixel between the rail, the list and the reader,
/// wherever the split was placed, and still one after the window changes scale.
@MainActor
final class MainWindowDividerTests: XCTestCase {
    private func gaps(_ split: NSSplitView) -> [CGFloat] {
        zip(split.subviews, split.subviews.dropFirst()).map { $1.frame.minX - $0.frame.maxX }
    }

    func testTheListAndTheReaderAreSeparatedByAHairlineAtTheDefaultPlacement() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let split = harness.controller.splitView
        split.layoutSubtreeIfNeeded()
        let thickness = split.dividerThickness
        XCTAssertGreaterThan(thickness, 0)
        XCTAssertEqual(gaps(split), [thickness, thickness], "a divider shows between every pane")
    }

    /// The split's items are added before it is in a window; a thickness guessed for another scale used to
    /// stay in the split controller's constraints, and a half-point divider vanished at 1×.
    func testTheDividerFollowsAChangeOfScale() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let split = try XCTUnwrap(harness.controller.splitView as? HairlineSplitView)
        split.backingScaleOverride = 2
        split.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.dividerThickness, 0.5)
        // The list's divider (the rail's is pinned by the rail's fixed width) is laid out at half a point,
        // which pixel rounding drops at 1×: proof the split controller rebuilt its constraints.
        XCTAssertLessThan(gaps(split)[1], 1, "the split controller took the new thickness: \(gaps(split))")
        split.backingScaleOverride = nil
        split.layoutSubtreeIfNeeded()
        let thickness = split.dividerThickness
        XCTAssertEqual(thickness, 1 / (split.window?.backingScaleFactor ?? 1))
        for gap in gaps(split) { XCTAssertEqual(gap, thickness, accuracy: 0.01) }
        // A resize lays the panes out again from the split controller's constraints.
        harness.controller.window?.setContentSize(NSSize(width: 1300, height: 800))
        split.layoutSubtreeIfNeeded()
        for gap in gaps(split) { XCTAssertEqual(gap, thickness, accuracy: 0.01) }
    }
}
