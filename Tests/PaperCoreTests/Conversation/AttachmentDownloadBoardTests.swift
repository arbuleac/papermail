import Foundation
import XCTest
@testable import PaperCore

/// What an attachment chip shows of its fetch (spec §5.17): hidden for 150 ms, then determinate from the reported
/// fraction or sweeping without one, then the meta again.
final class AttachmentDownloadBoardTests: XCTestCase {
    private let chip = AttachmentDownloadBoard.Chip(message: MessageID(accountID: AccountID("a"), providerID: "m"), attachmentID: "att")

    func testAKnownSizeShowsDeterminateFromTheReveal() {
        var board = AttachmentDownloadBoard()
        let ticket = board.begin(chip)

        XCTAssertNil(board.progress(0, for: ticket), "nothing shows in the first 150 ms")
        XCTAssertNil(board.progress(0.2, for: ticket))
        XCTAssertEqual(board.reveal(ticket), .fraction(0.2), "the reveal shows where the download stands")
        XCTAssertEqual(board.progress(0.5, for: ticket), .fraction(0.5))
        XCTAssertNil(board.progress(0.4, for: ticket), "never backwards")
        XCTAssertEqual(board.progress(1, for: ticket), .fraction(1))
        XCTAssertEqual(board.end(ticket), .done)
        XCTAssertFalse(board.isDownloading(chip))
    }

    func testAnUnknownSizeSweepsUntilAFractionComes() {
        var board = AttachmentDownloadBoard()
        let ticket = board.begin(chip)

        XCTAssertEqual(board.reveal(ticket), .sweeping)
        XCTAssertNil(board.reveal(ticket), "revealed once")
        XCTAssertEqual(board.progress(0.3, for: ticket), .fraction(0.3), "a length learned late turns it determinate")
        XCTAssertEqual(board.end(ticket), .done)
    }

    /// A cached file ends before the reveal: the chip never shows a download, and late events change nothing.
    func testAFetchThatEndsWithinTheDelayNeverShows() {
        var board = AttachmentDownloadBoard()
        let ticket = board.begin(chip)

        XCTAssertEqual(board.end(ticket), .done)
        XCTAssertNil(board.reveal(ticket))
        XCTAssertNil(board.progress(0.5, for: ticket))
    }

    /// Quick Look, then Save As before the file arrives: the second fetch takes the chip over where it stands, and
    /// the first one's end does not give the meta back while the second still runs.
    func testASecondFetchTakesTheChipOver() {
        var board = AttachmentDownloadBoard()
        let first = board.begin(chip)
        XCTAssertEqual(board.reveal(first), .sweeping)
        XCTAssertEqual(board.progress(0.4, for: first), .fraction(0.4), "shown at once")

        let second = board.begin(chip)
        XCTAssertNil(board.progress(0.6, for: first), "the first fetch no longer moves the chip")
        XCTAssertEqual(board.progress(0.6, for: second), .fraction(0.6), "the second carries on, already shown")
        XCTAssertNil(board.reveal(second), "already showing")
        XCTAssertNil(board.end(first))
        XCTAssertTrue(board.isDownloading(chip))
        XCTAssertEqual(board.end(second), .done)
    }

    func testFractionsAreClampedToTheContrail() {
        var board = AttachmentDownloadBoard()
        let ticket = board.begin(chip)
        _ = board.reveal(ticket)
        XCTAssertEqual(board.progress(-0.5, for: ticket), .fraction(0))
        XCTAssertEqual(board.progress(1.5, for: ticket), .fraction(1))
    }
}
