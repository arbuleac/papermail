import XCTest
@testable import SSCore

final class UndoKeyPrecedenceTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func panel(_ offset: TimeInterval, counting: Bool = true) -> UndoKeyPrecedence.Panel {
        UndoKeyPrecedence.Panel(shownAt: start.addingTimeInterval(offset), isCounting: counting)
    }

    func testTheNewestCountingPanelTakesTheKey() {
        let panels = [panel(0), panel(1), panel(2, counting: false)]
        XCTAssertEqual(UndoKeyPrecedence.owner(of: panels, toastShownAt: nil, toastLife: 5, now: start.addingTimeInterval(3)), 1)
    }

    func testNothingCountingMeansNoOwner() {
        let panels = [panel(0, counting: false)]
        XCTAssertNil(UndoKeyPrecedence.owner(of: panels, toastShownAt: nil, toastLife: 5, now: start.addingTimeInterval(1)))
    }

    /// A toast newer than every panel holds ⌘Z while it is up.
    func testANewerToastHoldsTheKeyWhileItIsUp() {
        let panels = [panel(0)]
        let toast = start.addingTimeInterval(1)
        XCTAssertNil(UndoKeyPrecedence.owner(of: panels, toastShownAt: toast, toastLife: 5, now: start.addingTimeInterval(2)))
    }

    /// Once the toast has gone, the panel that is still counting is live and the toast is not (§6.1 row 2 before row 3).
    func testThePanelTakesTheKeyBackWhenTheToastHasGone() {
        let panels = [panel(0)]
        let toast = start.addingTimeInterval(1)
        XCTAssertEqual(UndoKeyPrecedence.owner(of: panels, toastShownAt: toast, toastLife: 5, now: start.addingTimeInterval(6)), 0)
    }

    func testAPanelShownAfterTheToastOwnsTheKey() {
        let panels = [panel(0), panel(3)]
        let toast = start.addingTimeInterval(1)
        XCTAssertEqual(UndoKeyPrecedence.owner(of: panels, toastShownAt: toast, toastLife: 5, now: start.addingTimeInterval(4)), 1)
    }
}
