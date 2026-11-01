import XCTest
@testable import SSCore

final class ListDiffTests: XCTestCase {
    func testIdenticalListsProduceNoEdits() {
        let diff = ListDiff.compute(old: ["a", "b", "c"], new: ["a", "b", "c"])
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.applied(to: ["a", "b", "c"]), ["a", "b", "c"])
    }

    func testNewMailInsertsAtTopWithoutTouchingOtherRows() {
        let old = ["a", "b", "c"]
        let new = ["n", "a", "b", "c"]
        let diff = ListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.removals, [])
        XCTAssertEqual(diff.moves, [])
        XCTAssertEqual(diff.insertions, [0])
        XCTAssertEqual(diff.insertedIDs, ["n"])
        XCTAssertEqual(diff.applied(to: old), new)
    }

    func testRemovingSelectedRowHandsSelectionToNextRow() {
        let old = ["a", "b", "c", "d"]
        let new = ["a", "c", "d"]
        let diff = ListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.removals, [1])
        XCTAssertEqual(diff.removedIDs, ["b"])
        XCTAssertTrue(diff.moves.isEmpty)
        XCTAssertTrue(diff.insertions.isEmpty)
        XCTAssertEqual(diff.applied(to: old), new)
        XCTAssertEqual(ListDiff.successor(ofRemoved: "b", in: old, new: new), "c")
    }

    func testRemovingLastSelectedRowFallsBackToPreviousRow() {
        let old = ["a", "b", "c", "d"]
        let new = ["a", "b", "c"]
        XCTAssertEqual(ListDiff.successor(ofRemoved: "d", in: old, new: new), "c")
    }

    func testSuccessorSkipsRowsThatWereRemovedTogether() {
        let old = ["a", "b", "c", "d", "e"]
        let new = ["a", "e"]
        XCTAssertEqual(ListDiff.successor(ofRemoved: "b", in: old, new: new), "e")
        XCTAssertEqual(ListDiff.successor(ofRemoved: "d", in: old, new: new), "e")
    }

    func testSuccessorWhenEverythingIsGoneIsNil() {
        XCTAssertNil(ListDiff.successor(ofRemoved: "a", in: ["a", "b"], new: []))
    }

    func testSuccessorForUnknownRowIsTopOfNewList() {
        XCTAssertEqual(ListDiff.successor(ofRemoved: "zz", in: ["a", "b"], new: ["x", "y"]), "x")
    }

    func testConversationJumpingToTopIsOneMove() {
        let old = ["a", "b", "c", "d", "e"]
        let new = ["d", "a", "b", "c", "e"]
        let diff = ListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.moves, [ListDiff<String>.Move(from: 3, to: 0)])
        XCTAssertTrue(diff.removals.isEmpty)
        XCTAssertTrue(diff.insertions.isEmpty)
        XCTAssertEqual(diff.applied(to: old), new)
    }

    func testConversationSinkingToBottomIsOneMove() {
        let old = ["a", "b", "c", "d"]
        let new = ["b", "c", "d", "a"]
        let diff = ListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.moves, [ListDiff<String>.Move(from: 0, to: 3)])
        XCTAssertEqual(diff.applied(to: old), new)
    }

    func testTwoRowsMovingAcrossEachOtherReplayCorrectly() {
        // The case where naive ascending placement goes wrong: both movers sit above everything they must follow.
        let old = ["e", "d", "a", "b", "c"]
        let new = ["a", "b", "c", "d", "e"]
        let diff = ListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.moves.count, 2)
        XCTAssertEqual(diff.applied(to: old), new)
    }

    func testReorderOfSelectedRowKeepsItFindable() {
        let old = ["a", "b", "c", "d"]
        let new = ["c", "a", "b", "d"]
        let diff = ListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.applied(to: old), new)
        XCTAssertEqual(new.firstIndex(of: "b"), 2)
    }

    func testMixedEditsReplayToNewList() {
        let old = ["a", "b", "c", "d", "e"]
        let new = ["x", "c", "a", "e", "y"]
        let diff = ListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.removals, [3, 1])
        XCTAssertEqual(diff.removedIDs, ["d", "b"])
        XCTAssertEqual(diff.insertions, [0, 4])
        XCTAssertEqual(diff.insertedIDs, ["x", "y"])
        XCTAssertEqual(diff.moves.count, 1)
        XCTAssertEqual(diff.changeCount, 5)
        XCTAssertEqual(diff.applied(to: old), new)
    }

    func testCompleteReplacement() {
        let old = ["a", "b"]
        let new = ["c", "d", "e"]
        let diff = ListDiff.compute(old: old, new: new)
        XCTAssertEqual(diff.removals, [1, 0])
        XCTAssertEqual(diff.insertions, [0, 1, 2])
        XCTAssertTrue(diff.moves.isEmpty)
        XCTAssertEqual(diff.applied(to: old), new)
    }

    func testEmptyToSomeAndSomeToEmpty() {
        let grow = ListDiff.compute(old: [String](), new: ["a", "b"])
        XCTAssertEqual(grow.insertions, [0, 1])
        XCTAssertEqual(grow.applied(to: []), ["a", "b"])

        let shrink = ListDiff.compute(old: ["a", "b"], new: [])
        XCTAssertEqual(shrink.removals, [1, 0])
        XCTAssertEqual(shrink.applied(to: ["a", "b"]), [])
    }

    func testChangeCountIsZeroOnlyWhenNothingChanged() {
        XCTAssertEqual(ListDiff.compute(old: [1, 2], new: [1, 2]).changeCount, 0)
        XCTAssertEqual(ListDiff.compute(old: [1, 2], new: [2, 1]).changeCount, 1)
    }

    func testRandomSequencesReplayExactly() {
        var generator = SeededGenerator(seed: 0x5EED_1234)
        for iteration in 0..<300 {
            let oldCount = Int.random(in: 0...40, using: &generator)
            let old = Array(0..<oldCount)
            // Keep a random subset, shuffle a random slice of it, and sprinkle in new ids.
            var kept = old.filter { _ in Bool.random(using: &generator) }
            if kept.count > 2 {
                let lower = Int.random(in: 0..<kept.count - 1, using: &generator)
                let upper = Int.random(in: lower..<kept.count, using: &generator)
                kept[lower...upper].shuffle(using: &generator)
            }
            var new = kept
            let insertCount = Int.random(in: 0...6, using: &generator)
            for offset in 0..<insertCount {
                let position = Int.random(in: 0...new.count, using: &generator)
                new.insert(1_000 + iteration * 10 + offset, at: position)
            }
            let diff = ListDiff.compute(old: old, new: new)
            XCTAssertEqual(diff.applied(to: old), new, "iteration \(iteration): old=\(old) new=\(new) diff=\(diff)")
            XCTAssertLessThanOrEqual(diff.changeCount, old.count + new.count)
        }
    }

    func testLargeListsDiffQuickly() {
        let old = Array(0..<5_000)
        var new = old
        new.removeSubrange(100..<150)
        new.insert(contentsOf: 10_000..<10_030, at: 0)
        let moved = new.remove(at: 2_500)
        new.insert(moved, at: 10)
        let start = DispatchTime.now()
        let diff = ListDiff.compute(old: old, new: new)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        XCTAssertEqual(diff.applied(to: old), new)
        XCTAssertEqual(diff.removals.count, 50)
        XCTAssertEqual(diff.insertions.count, 30)
        XCTAssertEqual(diff.moves.count, 1)
        XCTAssertLessThan(elapsed, 0.05)
    }
}

/// xorshift64*, so the randomized test is repeatable when it fails.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}
