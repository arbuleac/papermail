import XCTest
@testable import SSCore

/// The main window's Z and ⌘Z order (spec §6.1): typing, then the most recent of the live sends and the visible
/// toast, then a toast's action in its 10000 ms grace; Z never cancels a send.
final class UndoPrecedenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func send(_ id: String, _ offset: TimeInterval) -> UndoPrecedence.LiveSend {
        UndoPrecedence.LiveSend(id: id, startedAt: t0.addingTimeInterval(offset))
    }

    private func toast(_ group: Int, _ offset: TimeInterval) -> UndoPrecedence.ToastGroup {
        UndoPrecedence.ToastGroup(groupID: group, actedAt: t0.addingTimeInterval(offset))
    }

    func testTypingComesFirst() {
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: true, sends: [send("a", 0)], toast: toast(1, 1), graceGroup: 2), .typing)
    }

    func testTheNewestSendOrToastWins() {
        // The quick reply's countdown started after the panel: it is cancelled first.
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [send("panel", 0), send("quick", 2)], toast: nil, graceGroup: nil),
                       .send("quick"))
        // A toast newer than every send holds ⌘Z while it is up.
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [send("panel", 0)], toast: toast(7, 1), graceGroup: nil), .group(7))
        // A send newer than the toast takes it back.
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [send("quick", 3)], toast: toast(7, 1), graceGroup: nil),
                       .send("quick"))
    }

    func testALiveSendOutranksAToastThatHasGone() {
        // Row 2 before row 3: the toast's action is only in its grace now.
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [send("panel", 0)], toast: nil, graceGroup: 4), .send("panel"))
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [], toast: nil, graceGroup: 4), .group(4))
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [], toast: nil, graceGroup: nil), .nothing)
    }

    func testZOnlyEverRevertsAToastsAction() {
        XCTAssertEqual(UndoPrecedence.z(toast: toast(3, 0), graceGroup: 1), .group(3))
        XCTAssertEqual(UndoPrecedence.z(toast: nil, graceGroup: 1), .group(1))
        XCTAssertEqual(UndoPrecedence.z(toast: nil, graceGroup: nil), .nothing)
    }

    func testThePanelKeycapFollowsTheCommandZOwner() {
        XCTAssertEqual(UndoPrecedence.sendOwningCommandZ(sends: [send("a", 0), send("b", 1)], toast: nil), "b")
        XCTAssertNil(UndoPrecedence.sendOwningCommandZ(sends: [send("a", 0)], toast: toast(1, 2)), "a newer toast took ⌘Z")
        XCTAssertNil(UndoPrecedence.sendOwningCommandZ(sends: [], toast: nil))
    }
}
