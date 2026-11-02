import AppKit
import XCTest
@testable import SuperSparrowApp

/// The running head's rule is one device pixel (§4.7, §5.8): it starts on the pixel grid at either scale.
final class RunningHeadRowTests: XCTestCase {
    func testTheRuleStartsOnTheDeviceGrid() {
        XCTAssertEqual(RunningHeadRowView.pixelAligned(17 - 1.0 / 2, scale: 1), 16, "1 pt at 1×: one row, not two halves")
        XCTAssertEqual(RunningHeadRowView.pixelAligned(17 - 0.5 / 2, scale: 2), 16.5, "0.5 pt at 2×: device row 33")
        XCTAssertEqual(RunningHeadRowView.pixelAligned(12 - 1.0 / 2, scale: 2), 11.5, "Increase Contrast's 1 pt at 2×")
        XCTAssertEqual(RunningHeadRowView.pixelAligned(16, scale: 2), 16, "already on the grid")
    }
}
