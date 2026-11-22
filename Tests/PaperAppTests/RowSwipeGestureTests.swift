import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// The swipe's state machine (spec §5.7, Swipe), fed the phases and deltas a trackpad sends: which gestures are swipes,
/// where the row's content is under the fingers, what letting go does, and when an open row closes.
final class RowSwipeGestureTests: XCTestCase {
    private typealias G = RowSwipeGesture

    private let archive = G.Button(kind: .archive, title: "Archive", openWidth: 80)
    private let unread = G.Button(kind: .markUnread, title: "Mark as Unread", openWidth: 112)

    private func row(_ n: Int = 1, width: CGFloat = 360, trailing: Bool = true, leading: Bool = true) -> G.Row {
        G.Row(id: ConversationID(accountID: AccountID("a"), providerID: "t\(n)"), width: width,
              trailing: trailing ? archive : nil, leading: leading ? unread : nil)
    }

    private func began(_ dx: CGFloat, _ dy: CGFloat = 0) -> G.Scroll { G.Scroll(phase: .began, dx: dx, dy: dy) }
    private func changed(_ dx: CGFloat, _ dy: CGFloat = 0) -> G.Scroll { G.Scroll(phase: .changed, dx: dx, dy: dy) }
    private let ended = G.Scroll(phase: .ended)

    /// Drags `row` sideways by `distance` in steps of 10 and returns the last step.
    @discardableResult
    private func drag(_ gesture: inout G, _ row: G.Row, by distance: CGFloat) -> G.Step {
        let step: CGFloat = distance < 0 ? -10 : 10
        var last = gesture.handle(began(step), over: row)
        var moved = step
        while abs(moved) < abs(distance) {
            let next = abs(distance - moved) < 10 ? distance - moved : step
            last = gesture.handle(changed(next), over: row)
            moved += next
        }
        return last
    }

    /// Opens `row`'s trailing button.
    private func opened(_ row: G.Row) -> G {
        var gesture = G()
        drag(&gesture, row, by: -60)
        XCTAssertEqual(gesture.handle(ended, over: row).release, .open(.trailing))
        return gesture
    }

    // MARK: Reveal

    func testASidewaysGestureOverARowMovesItsContentUnderTheFingers() {
        var gesture = G()
        let r = row()
        let first = gesture.handle(began(-10, 2), over: r)
        XCTAssertEqual(first.disposition, .consume, "the swipe takes it; the list does not scroll")
        XCTAssertTrue(first.moved)
        XCTAssertEqual(first.row, r)
        XCTAssertEqual(gesture.offset, -10, "to the left with the fingers")
        XCTAssertEqual(gesture.edge, .trailing)
        XCTAssertEqual(gesture.button, archive)
        XCTAssertEqual(gesture.handle(changed(-25, 6), over: nil).disposition, .consume, "up and down drift is ignored once it is a swipe")
        XCTAssertEqual(gesture.offset, -35)
        XCTAssertEqual(gesture.handle(changed(5), over: nil).disposition, .consume)
        XCTAssertEqual(gesture.offset, -30, "and back")
        XCTAssertTrue(gesture.isSwiping)
        XCTAssertTrue(gesture.isOpen)
    }

    func testCrossingRestUncoversTheOtherEdge() {
        var gesture = G()
        drag(&gesture, row(), by: -20)
        gesture.handle(changed(50), over: nil)
        XCTAssertEqual(gesture.offset, 30)
        XCTAssertEqual(gesture.edge, .leading)
        XCTAssertEqual(gesture.button, unread)
    }

    func testAnEdgeThatOffersNothingDoesNotMove() {
        var gesture = G()
        let r = row(trailing: false)
        let step = gesture.handle(began(-20), over: r)
        XCTAssertEqual(step.disposition, .consume, "a swipe all the same: the other edge offers something")
        XCTAssertFalse(step.moved)
        XCTAssertEqual(gesture.offset, 0)
        gesture.handle(changed(-40), over: nil)
        XCTAssertEqual(gesture.offset, 0, "no Archive: the content stays")
        gesture.handle(changed(30), over: nil)
        XCTAssertEqual(gesture.offset, 30, "the leading edge opens at once on the way back, with no slack to take up")
    }

    // MARK: Letting go

    func testLettingGoPastHalfTheButtonSnapsItOpen() {
        var gesture = G()
        let r = row()
        drag(&gesture, r, by: -45)
        let step = gesture.handle(ended, over: nil)
        XCTAssertEqual(step.release, .open(.trailing))
        XCTAssertEqual(step.row, r)
        XCTAssertEqual(step.disposition, .consume)
        XCTAssertEqual(gesture.offset, -80, "the button's open width")
        XCTAssertTrue(gesture.isOpen)
        XCTAssertFalse(gesture.isSwiping)
    }

    func testLettingGoShortOfHalfSnapsBack() {
        var gesture = G()
        drag(&gesture, row(), by: -35)
        XCTAssertEqual(gesture.handle(ended, over: nil).release, .close)
        XCTAssertEqual(gesture.offset, 0)
        XCTAssertNil(gesture.row)
        XCTAssertFalse(gesture.isOpen)
    }

    /// Moving back toward rest says the fingers changed their mind: short of the whole button, the row closes.
    func testMovingBackTowardRestClosesEvenPastHalf() {
        var gesture = G()
        drag(&gesture, row(), by: -70)
        gesture.handle(changed(15), over: nil)
        XCTAssertEqual(gesture.offset, -55)
        XCTAssertEqual(gesture.handle(ended, over: nil).release, .close)
    }

    /// Past the whole button the row settles open, whichever way the fingers last moved.
    func testPastTheWholeButtonItSettlesOpen() {
        var gesture = G()
        drag(&gesture, row(), by: -150)
        gesture.handle(changed(10), over: nil)
        XCTAssertEqual(gesture.handle(ended, over: nil).release, .open(.trailing))
        XCTAssertEqual(gesture.offset, -80)
    }

    func testAFullSwipeMakesTheChange() {
        var gesture = G()
        let r = row()
        XCTAssertEqual(gesture.fullSwipeDistance(row: r, button: archive), 216, "0.6 of 360")
        drag(&gesture, r, by: -230)
        let step = gesture.handle(ended, over: nil)
        XCTAssertEqual(step.release, .commit(.trailing))
        XCTAssertEqual(step.row, r, "the row it was on, by its conversation")
        XCTAssertNil(gesture.row, "nothing is left open")
        XCTAssertEqual(gesture.offset, 0)

        var leading = G()
        drag(&leading, r, by: 250)
        XCTAssertEqual(leading.handle(ended, over: nil).release, .commit(.leading))
    }

    func testACancelledGestureNeverMakesTheChange() {
        var gesture = G()
        drag(&gesture, row(), by: -260)
        XCTAssertEqual(gesture.handle(G.Scroll(phase: .cancelled), over: nil).release, .open(.trailing))
    }

    /// In a narrow list the full swipe is still half a button past the open width, so the button can open.
    func testTheFullSwipeIsNeverCloserThanHalfAButtonPastOpen() {
        let narrow = row(width: 150)
        XCTAssertEqual(G().fullSwipeDistance(row: narrow, button: unread), 168)
    }

    // MARK: Rubber band

    func testPastTheFullSwipeTheRowSlowsAndNeverReachesItsWidth() {
        let gesture = G()
        let r = row()
        XCTAssertEqual(gesture.banded(-216, row: r), -216, "one to one up to the full swipe")
        XCTAssertEqual(gesture.banded(100, row: r), 100)
        let a = -gesture.banded(-250, row: r), b = -gesture.banded(-300, row: r), c = -gesture.banded(-400, row: r)
        let far = -gesture.banded(-5_000, row: r)
        XCTAssertGreaterThan(a, 216)
        XCTAssertLessThan(a, 250, "slower than the fingers")
        XCTAssertGreaterThan(b, a)
        XCTAssertGreaterThan(c, b)
        XCTAssertLessThan(c - b, b - a + 50, "each step moves it less")
        XCTAssertLessThan((c - b) / 100, (b - a) / 50)
        XCTAssertLessThan(far, 360, "never the whole row")
        XCTAssertGreaterThan(far, 340)
        var dragged = G()
        drag(&dragged, r, by: -600)
        XCTAssertEqual(dragged.offset, gesture.banded(-600, row: r), accuracy: 0.001)
    }

    // MARK: Scrolls

    func testUpAndDownIsAScroll() {
        var gesture = G()
        XCTAssertEqual(gesture.handle(began(3, 12), over: row()).disposition, .pass)
        XCTAssertEqual(gesture.handle(changed(-60, 0), over: row()).disposition, .pass, "decided at the start: sideways later scrolls")
        XCTAssertEqual(gesture.offset, 0)
        XCTAssertNil(gesture.row)
        XCTAssertEqual(gesture.handle(ended, over: nil).disposition, .pass)
        XCTAssertEqual(gesture.handle(G.Scroll(momentum: .began, dy: 30), over: nil).disposition, .pass, "a scroll's momentum scrolls")
        XCTAssertEqual(gesture.handle(G.Scroll(momentum: .changed, dy: 20), over: nil).disposition, .pass)
    }

    func testAMouseWheelScrollsAndClosesTheOpenRow() {
        var gesture = opened(row())
        let step = gesture.handle(G.Scroll(dy: -3), over: nil)
        XCTAssertEqual(step.disposition, .pass)
        XCTAssertEqual(step.closed, row())
        XCTAssertFalse(gesture.isOpen)
        XCTAssertEqual(gesture.handle(G.Scroll(dx: -8), over: row()).disposition, .pass, "a tilt sideways is no swipe either")
        XCTAssertNil(gesture.row)
    }

    /// Heads, the tail and the server row are no row a swipe can move (the list gives none), nor is a row that offers
    /// nothing on either edge: a sideways gesture there is the table's.
    func testWhereNothingSwipesASidewaysGestureScrolls() {
        var gesture = G()
        XCTAssertEqual(gesture.handle(began(-20), over: nil).disposition, .pass)
        XCTAssertEqual(gesture.handle(changed(-40), over: nil).disposition, .pass)
        XCTAssertNil(gesture.row)
        XCTAssertEqual(gesture.handle(ended, over: nil).disposition, .pass)
        XCTAssertEqual(gesture.handle(began(-20), over: row(trailing: false, leading: false)).disposition, .pass)
        XCTAssertNil(gesture.row)
    }

    func testMomentumAfterASwipeIsSwallowed() {
        var gesture = G()
        drag(&gesture, row(), by: -50)
        gesture.handle(ended, over: nil)
        for phase in [G.Scroll.Phase.began, .changed, .changed, .ended] {
            let step = gesture.handle(G.Scroll(momentum: phase, dx: -30, dy: 4), over: nil)
            XCTAssertEqual(step.disposition, .consume, "momentum \(phase)")
            XCTAssertFalse(step.moved)
        }
        XCTAssertEqual(gesture.offset, -80, "the flick's tail moved nothing")
        XCTAssertEqual(gesture.handle(G.Scroll(momentum: .began, dy: 4), over: nil).disposition, .pass, "a later momentum is a scroll's")
    }

    // MARK: Waiting for the first movement

    func testAGestureThatBeginsStillWaitsForItsFirstMovement() {
        var gesture = G()
        XCTAssertEqual(gesture.handle(G.Scroll(phase: .mayBegin), over: row()).disposition, .pass, "fingers down")
        XCTAssertEqual(gesture.handle(began(0, 0), over: row()).disposition, .consume, "held back")
        XCTAssertTrue(gesture.isPending)
        XCTAssertEqual(gesture.handle(changed(0, 0), over: nil).disposition, .consume)
        XCTAssertEqual(gesture.handle(changed(1, 9), over: nil).disposition, .passHeld, "a scroll: the held event, then this one")
        XCTAssertFalse(gesture.isPending)
        XCTAssertEqual(gesture.handle(changed(0, 9), over: nil).disposition, .pass)

        var sideways = G()
        sideways.handle(began(0, 0), over: row())
        let step = sideways.handle(changed(-12, 1), over: nil)
        XCTAssertEqual(step.disposition, .consume, "a swipe of the row under the pointer when it began")
        XCTAssertEqual(sideways.offset, -12)

        var still = G()
        still.handle(began(0, 0), over: row())
        XCTAssertEqual(still.handle(ended, over: nil).disposition, .passHeld, "never moved: the table sees all of it")
        XCTAssertFalse(still.isPending)
    }

    // MARK: One row at a time, and the close rules

    func testAnotherRowsSwipeClosesTheOpenOne() {
        var gesture = opened(row(1))
        let step = gesture.handle(began(-10), over: row(2))
        XCTAssertEqual(step.closed, row(1))
        XCTAssertEqual(step.row, row(2))
        XCTAssertEqual(gesture.row, row(2))
        XCTAssertEqual(gesture.offset, -10, "the new row starts from rest")
    }

    func testSwipingTheOpenRowAgainCarriesOnFromWhereItIs() {
        var gesture = opened(row(1))
        let step = gesture.handle(began(-10), over: row(1))
        XCTAssertNil(step.closed)
        XCTAssertEqual(gesture.offset, -90)
        gesture.handle(changed(90), over: nil)
        XCTAssertEqual(gesture.offset, 0)
        XCTAssertEqual(gesture.handle(ended, over: nil).release, .close)
    }

    func testAScrollClosesTheOpenRow() {
        var gesture = opened(row(1))
        let step = gesture.handle(began(0, 12), over: row(3))
        XCTAssertEqual(step.disposition, .pass)
        XCTAssertEqual(step.closed, row(1))
        XCTAssertNil(gesture.row)

        var sidewaysOverAHead = opened(row(1))
        XCTAssertEqual(sidewaysOverAHead.handle(began(-12), over: nil).closed, row(1))
    }

    func testACloseRuleClosesTheOpenRow() {
        var gesture = opened(row(1))
        XCTAssertEqual(gesture.close(), row(1))
        XCTAssertFalse(gesture.isOpen)
        XCTAssertNil(gesture.close(), "nothing left to close")
    }

    /// Closed while the fingers still move it (a refresh, a selection change), the row stays shut: the rest of that
    /// gesture, and its momentum, move nothing and scroll nothing.
    func testClosedUnderTheFingersTheRestOfTheGestureDoesNothing() {
        var gesture = G()
        drag(&gesture, row(), by: -40)
        XCTAssertEqual(gesture.close(), row())
        let step = gesture.handle(changed(-30), over: nil)
        XCTAssertEqual(step.disposition, .consume)
        XCTAssertFalse(step.moved)
        XCTAssertEqual(gesture.offset, 0)
        let release = gesture.handle(ended, over: nil)
        XCTAssertNil(release.release, "no release: nothing to open or change")
        XCTAssertEqual(release.disposition, .consume)
        XCTAssertEqual(gesture.handle(G.Scroll(momentum: .changed, dy: 9), over: nil).disposition, .consume)
        XCTAssertEqual(gesture.handle(began(-10), over: row()).disposition, .consume, "the next gesture swipes again")
        XCTAssertEqual(gesture.offset, -10)
    }

    func testTheTokensSetTheThresholds() {
        XCTAssertEqual(G.Metrics.tokens, G.Metrics(snapOpen: 0.5, fullSwipe: 0.6, rubberBand: 0.55))
    }
}
