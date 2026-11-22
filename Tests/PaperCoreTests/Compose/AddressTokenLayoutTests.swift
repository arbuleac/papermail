import XCTest
@testable import PaperCore

final class AddressTokenLayoutTests: XCTestCase {
    func testTokensWrapAndInputFollowsTheLastToken() {
        let layout = AddressTokenLayout.flow(widths: [100, 120, 90], availableWidth: 300, gap: 4, minimumInputWidth: 80)
        XCTAssertEqual(layout.placements.map(\.line), [0, 0, 1])
        XCTAssertEqual(layout.placements[1].x, 104)
        XCTAssertEqual(layout.placements[2].x, 0)
        XCTAssertEqual(layout.inputLine, 1)
        XCTAssertEqual(layout.inputX, 94)
        XCTAssertEqual(layout.inputWidth, 206)
        XCTAssertEqual(layout.lineCount, 2)
    }

    func testInputStartsANewLineWhenTooLittleIsLeft() {
        let layout = AddressTokenLayout.flow(widths: [100, 140], availableWidth: 300, gap: 4, minimumInputWidth: 80)
        XCTAssertEqual(layout.placements.map(\.line), [0, 0])
        XCTAssertEqual(layout.inputLine, 1)
        XCTAssertEqual(layout.inputX, 0)
        XCTAssertEqual(layout.lineCount, 2)
    }

    func testAnEmptyFieldIsOneLineOfInput() {
        let layout = AddressTokenLayout.flow(widths: [], availableWidth: 300, gap: 4, minimumInputWidth: 80)
        XCTAssertEqual(layout.inputLine, 0)
        XCTAssertEqual(layout.inputWidth, 300)
        XCTAssertEqual(layout.lineCount, 1)
    }

    func testAWideTokenIsNarrowedToTheLine() {
        let layout = AddressTokenLayout.flow(widths: [500], availableWidth: 300, gap: 4, minimumInputWidth: 80)
        XCTAssertEqual(layout.placements.first?.width, 300)
        XCTAssertEqual(layout.inputLine, 1)
    }

    func testCollapsedRowShowsWhatFitsThenMore() {
        let layout = AddressTokenLayout.collapse(widths: [100, 100, 100, 100], invalid: [], availableWidth: 300, gap: 4,
                                                 moreGap: 6) { _ in 60 }
        XCTAssertEqual(layout.placements.map(\.index), [0, 1])
        XCTAssertEqual(layout.hiddenCount, 2)
        XCTAssertEqual(layout.moreX, 210)
        XCTAssertNil(layout.inputLine)
    }

    func testCollapsedRowShowsEverythingWhenItFits() {
        let layout = AddressTokenLayout.collapse(widths: [80, 80], invalid: [], availableWidth: 300, gap: 4,
                                                 moreGap: 6) { _ in 60 }
        XCTAssertEqual(layout.placements.map(\.index), [0, 1])
        XCTAssertEqual(layout.hiddenCount, 0)
        XCTAssertNil(layout.moreX)
    }

    func testAnInvalidTokenIsNeverHiddenBehindMore() {
        let layout = AddressTokenLayout.collapse(widths: [100, 100, 100, 100], invalid: [3], availableWidth: 300, gap: 4,
                                                 moreGap: 6) { _ in 60 }
        XCTAssertTrue(layout.placements.map(\.index).contains(3))
        XCTAssertEqual(layout.placements.map(\.index), [0, 3])
        XCTAssertEqual(layout.hiddenCount, 2)
    }

    func testRowHeightGrowsPerLineUpToThreeLines() {
        XCTAssertEqual(AddressTokenLayout.rowHeight(lines: 1, base: 36, lineGrow: 26, maxLines: 3), 36)
        XCTAssertEqual(AddressTokenLayout.rowHeight(lines: 2, base: 36, lineGrow: 26, maxLines: 3), 62)
        XCTAssertEqual(AddressTokenLayout.rowHeight(lines: 3, base: 36, lineGrow: 26, maxLines: 3), 88)
        XCTAssertEqual(AddressTokenLayout.rowHeight(lines: 7, base: 36, lineGrow: 26, maxLines: 3), 88)
    }

    func testCompletedEntriesKeepTheEntryBeingTyped() {
        let typed = AddressListParser.completedEntries(in: "ben@contoso.test, tom@cont")
        XCTAssertEqual(typed.complete, ["ben@contoso.test"])
        XCTAssertEqual(typed.remainder, "tom@cont")
        let quoted = AddressListParser.completedEntries(in: "\"Doe, John")
        XCTAssertEqual(quoted.complete, [])
        XCTAssertEqual(quoted.remainder, "\"Doe, John")
        let ended = AddressListParser.completedEntries(in: "a@b.test; c@d.test;")
        XCTAssertEqual(ended.complete, ["a@b.test", "c@d.test"])
        XCTAssertEqual(ended.remainder, "")
        XCTAssertEqual(AddressListParser.split("a@b.test, \"Doe, John\" <j@d.test>"), ["a@b.test", "\"Doe, John\" <j@d.test>"])
    }
}
