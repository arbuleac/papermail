import XCTest
@testable import SSCore

/// The tracker is what lets a `show` wait on a render a pre-render or a refresh started: the swap
/// attaches to whatever is in flight instead of assuming the earlier `show` registered one.
final class SlotRenderTrackerTests: XCTestCase {
    func testWaiterRunsWhenTheRenderItDidNotStartLands() {
        var tracker = SlotRenderTracker()
        let generation = tracker.begin()
        XCTAssertTrue(tracker.isInFlight)

        var landed: [Bool] = []
        tracker.wait { landed.append($0) }
        XCTAssertEqual(tracker.waiterCount, 1)
        XCTAssertTrue(landed.isEmpty, "nothing runs before the render lands")

        guard case .landed(let waiters) = tracker.finish(generation) else {
            return XCTFail("the latest render landed")
        }
        XCTAssertFalse(tracker.isInFlight)
        XCTAssertEqual(tracker.waiterCount, 0)
        XCTAssertTrue(landed.isEmpty, "the tracker hands waiters back; the caller runs them")
        waiters.forEach { $0(true) }
        XCTAssertEqual(landed, [true])
    }

    func testSupersededRenderKeepsWaitersForTheNewerOne() {
        var tracker = SlotRenderTracker()
        let first = tracker.begin()
        var results: [Bool] = []
        tracker.wait { results.append($0) }
        let second = tracker.begin()
        XCTAssertNotEqual(first, second)

        guard case .superseded = tracker.finish(first) else {
            return XCTFail("an older generation never lands")
        }
        XCTAssertTrue(tracker.isInFlight, "the newer render is still out")
        XCTAssertEqual(tracker.waiterCount, 1)

        guard case .landed(let waiters) = tracker.finish(second) else {
            return XCTFail("the latest render landed")
        }
        XCTAssertEqual(waiters.count, 1)
        waiters.forEach { $0(true) }
        XCTAssertEqual(results, [true], "a waiter runs exactly once, for the render that ends up in the DOM")
    }

    func testResetReleasesWaitersAndOrphansTheRender() {
        var tracker = SlotRenderTracker()
        let generation = tracker.begin()
        var results: [Bool] = []
        tracker.wait { results.append($0) }

        let released = tracker.reset()
        XCTAssertEqual(released.count, 1)
        XCTAssertFalse(tracker.isInFlight)
        XCTAssertEqual(tracker.waiterCount, 0)
        released.forEach { $0(false) }
        XCTAssertEqual(results, [false])

        guard case .superseded = tracker.finish(generation) else {
            return XCTFail("a render from before the reset must not count as landed")
        }
    }

    func testFinishingAnIdleTrackerIsSuperseded() {
        var tracker = SlotRenderTracker()
        let generation = tracker.begin()
        guard case .landed = tracker.finish(generation) else { return XCTFail("first completion lands") }
        guard case .superseded = tracker.finish(generation) else {
            return XCTFail("a second completion for the same generation is ignored")
        }
    }
}
