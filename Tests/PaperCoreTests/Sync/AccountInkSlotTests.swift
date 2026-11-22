import XCTest
@testable import PaperCore

final class AccountInkSlotTests: XCTestCase {
    func testHandsOutTheLowestUnusedSlot() {
        XCTAssertEqual(AccountInkSlot.next(taken: []), 0)
        XCTAssertEqual(AccountInkSlot.next(taken: [0]), 1)
        XCTAssertEqual(AccountInkSlot.next(taken: [0, 1, 2]), 3)
        // A removed account's slot is reused before a later one.
        XCTAssertEqual(AccountInkSlot.next(taken: [0, 2, 3]), 1)
        XCTAssertEqual(AccountInkSlot.next(taken: [1, 2]), 0)
        XCTAssertEqual(AccountInkSlot.next(taken: [9, 4]), 0)
    }

    func testSequentialAssignmentFillsAllTenThenWraps() {
        var taken: [Int] = []
        for _ in 0..<23 { taken.append(AccountInkSlot.next(taken: taken)) }
        XCTAssertEqual(taken, Array(0..<10) + Array(0..<10) + [0, 1, 2])
    }

    func testWrappingPrefersTheLowestLeastWornSlot() {
        let full = Array(0..<10)
        XCTAssertEqual(AccountInkSlot.next(taken: full), 0)
        XCTAssertEqual(AccountInkSlot.next(taken: full + [0, 1]), 2)
        // Twelve accounts, then the one on slot 5 goes: slot 5 is the only one worn once fewer than the others.
        var twelve = full + [0, 1]
        twelve.remove(at: 5)
        XCTAssertEqual(AccountInkSlot.next(taken: twelve), 5)
    }

    func testOutOfRangeSlotsAreIgnored() {
        XCTAssertEqual(AccountInkSlot.next(taken: [-1, 10, 42]), 0)
        XCTAssertEqual(AccountInkSlot.next(taken: [0, 10]), 1)
        XCTAssertTrue(AccountInkSlot.isValid(0))
        XCTAssertTrue(AccountInkSlot.isValid(9))
        XCTAssertFalse(AccountInkSlot.isValid(10))
        XCTAssertFalse(AccountInkSlot.isValid(-1))
    }

    func testMonogramNormalization() {
        XCTAssertNil(Account.normalizedMonogram(nil))
        XCTAssertNil(Account.normalizedMonogram(""))
        XCTAssertNil(Account.normalizedMonogram("  \n"))
        XCTAssertEqual(Account.normalizedMonogram(" Ga "), "Ga")
        XCTAssertEqual(Account.normalizedMonogram("abc"), "ab")
        // Characters, not bytes or scalars: a flag or an accented letter is one character.
        XCTAssertEqual(Account.normalizedMonogram("É🇵🇹x"), "É🇵🇹")
    }
}
