import XCTest
@testable import PaperCore

/// A message's own words without its quoted history, shared by the time detector and Help Me Write.
final class QuotedHistoryTests: XCTestCase {
    private func own(_ text: String, limit: Int = 16 * 1024) -> String {
        QuotedHistory.ownWords(of: text, limit: limit)
    }

    func testPlainTextQuoteLinesAreLeftOut() {
        XCTAssertEqual(own("Sounds good.\n> Could we meet Friday?\n  > > Earlier\nSee you then."), "Sounds good.\nSee you then.")
    }

    func testReadingStopsAtAnAttributionLine() {
        let text = "Thursday works.\n\nOn 17 Nov 2026, at 15:12, Priya Shah wrote:\nCould we move lunch?"
        XCTAssertEqual(own(text), "Thursday works.\n")
        XCTAssertEqual(own("Ja.\nAm 17.11.2026 um 09:14 schrieb Jane Doe <jane@example.test>:\nHallo"), "Ja.")
    }

    func testReadingStopsAtOutlooksHeaderAndSeparators() {
        XCTAssertEqual(own("Yes.\nFrom: Priya Shah\nSent: Tuesday\nTo: Alex\n\nOld text"), "Yes.")
        XCTAssertEqual(own("Yes.\n-----Original Message-----\nOld"), "Yes.")
        XCTAssertEqual(own("Yes.\n________________________________\nOld"), "Yes.")
    }

    func testAFromLineInProseIsKept() {
        XCTAssertEqual(own("From: the team, with thanks.\nBest"), "From: the team, with thanks.\nBest")
    }

    func testReadingStopsAtTheSignatureLine() {
        XCTAssertEqual(own("See you at 3.\n-- \nPriya Shah\nOffice hours 9-5"), "See you at 3.")
    }

    func testTheLimitIsInBytesAndNeverSplitsACharacter() {
        let text = String(repeating: "é", count: 100)
        let cut = own(text, limit: 11)
        XCTAssertLessThanOrEqual(cut.utf8.count, 11)
        XCTAssertEqual(cut, String(repeating: "é", count: 5))
    }

    func testTheTimeDetectorReadsTheSameWords() {
        let text = "Tomorrow at 10?\n> Old\nOn 1 Nov 2026, Priya wrote:\nNext week"
        XCTAssertEqual(MailTimeDetector.ownWords(of: text), QuotedHistory.ownWords(of: text, limit: MailTimeDetector.maximumScannedLength))
    }
}
