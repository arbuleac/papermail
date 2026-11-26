import XCTest
@testable import PaperCore

/// The checks a proposal for the words beside a rewritten selection must pass before it lands.
final class WriteJoinTests: XCTestCase {
    private let fence = "1a2b3c4d"

    private func accept(_ proposed: String, _ offered: String?) -> String? {
        WriteJoin.accept(proposed, replacing: offered, fence: fence)
    }

    func testUpToTwoWordsMayChange() {
        XCTAssertEqual(accept("40 people, and", "40 people and"), "40 people, and", "punctuation is free")
        XCTAssertEqual(accept("And then we", "and then we"), "And then we", "case is free")
        XCTAssertEqual(accept("are", "is"), "are", "one word")
        XCTAssertEqual(accept("so we", "and then we"), "so we", "two words")
        XCTAssertEqual(accept("I was going", "we were going"), "I was going")
        XCTAssertEqual(accept("are coming tomorrow", "is coming tomorrow"), "are coming tomorrow")
        XCTAssertNil(accept("Honestly,", "I think that"), "three words")
        XCTAssertNil(accept("they will all be there soon", "is coming tomorrow"))
        XCTAssertEqual(accept("  are  ", "is"), "are", "trimmed of spaces")
    }

    func testEqualIsNoChange() {
        XCTAssertNil(accept("is coming tomorrow", "is coming tomorrow"))
        XCTAssertNil(accept(" is coming tomorrow\t", "is coming tomorrow"))
    }

    func testAnEmptyProposalTakesAShortWindowAway() {
        XCTAssertEqual(accept("", "and"), "")
        XCTAssertEqual(accept("", "and so"), "")
        XCTAssertNil(accept("", "and so then"), "three words taken away")
    }

    func testWhatCanNeverLand() {
        for proposal in ["is\ncoming", "is\rcoming", "is\u{2028}coming", "is\u{2029}coming", "is\u{85}coming", "is\u{FFFC}",
                         "is\u{0007}", "is\tcoming", "is\u{200B}coming", "<<<is", "is>>>", "is 1A2B3C4D", "is 1a2b3c4d"] {
            XCTAssertNil(accept(proposal, "is coming"), proposal.debugDescription)
        }
        XCTAssertNil(accept("are", nil), "a side that was not offered")
        XCTAssertNil(accept(String(repeating: "a", count: 49), String(repeating: "a", count: 47)), "over 48 units")
        XCTAssertNil(accept("is coming tomorrowxxxxxxxxxxxxxxxxx", "is coming tomorrow"), "more than 16 units longer")
        XCTAssertEqual(accept("is coming tomorrowxxxxxx", "is coming tomorrow"), "is coming tomorrowxxxxxx")
    }

    func testTheOutcomeNamesEveryCase() {
        XCTAssertEqual(WriteJoinOutcome.allCases.map(\.rawValue), ["none", "before", "after", "both", "refused"])
    }
}
