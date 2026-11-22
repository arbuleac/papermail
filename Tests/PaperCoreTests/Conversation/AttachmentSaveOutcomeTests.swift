import Foundation
import XCTest
@testable import PaperCore

/// What a save to Downloads says afterwards (spec §5.17, §5.30), and how Download all's one progress is shared out
/// among its files.
final class AttachmentSaveOutcomeTests: XCTestCase {
    private func urls(_ count: Int) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/Downloads/file\($0).pdf") }
    }

    func testOneFileSavedSaysSavedToDownloads() {
        let outcome = AttachmentSaveOutcome(requested: 1, saved: urls(1), unfetched: 0)
        XCTAssertEqual(outcome.toast(), .saved("Saved to Downloads"))
        XCTAssertEqual(outcome.unwritten, 0)
    }

    func testEveryFileSavedCountsThem() {
        let outcome = AttachmentSaveOutcome(requested: 3, saved: urls(3), unfetched: 0)
        XCTAssertEqual(outcome.toast(), .saved("Saved 3 attachments to Downloads"))
    }

    /// A file that could not be fetched is told by its chip; the toast says how many of the files were saved.
    func testSomeFilesSavedSaysHowManyOfAll() {
        let outcome = AttachmentSaveOutcome(requested: 3, saved: urls(2), unfetched: 1)
        XCTAssertEqual(outcome.toast(), .saved("Saved 2 of 3 attachments to Downloads"))
        XCTAssertEqual(outcome.unwritten, 0)
    }

    /// In a narrower list the words beside Show in Finder lose “attachments”, then, for a partial save, the place;
    /// never the count.
    func testShorterFormsWhereTheLongOneWouldBeCutOff() {
        let all = AttachmentSaveOutcome(requested: 3, saved: urls(3), unfetched: 0)
        XCTAssertEqual(all.toast(fits: { _ in false }), .saved("Saved 3 to Downloads"))
        let some = AttachmentSaveOutcome(requested: 3, saved: urls(2), unfetched: 1)
        XCTAssertEqual(some.toast(fits: { $0.count <= 25 }), .saved("Saved 2 of 3 to Downloads"))
        XCTAssertEqual(some.toast(fits: { _ in false }), .saved("Saved 2 of 3"))
        var asked: [String] = []
        _ = all.toast(fits: { asked.append($0); return true })
        XCTAssertEqual(asked, ["Saved 3 attachments to Downloads"], "the longest form that fits, measured first")
        XCTAssertEqual(AttachmentSaveOutcome(requested: 1, saved: urls(1), unfetched: 0).toast(fits: { _ in false }),
                       .saved("Saved to Downloads"), "one file has no shorter form")
    }

    /// Nothing fetched: the chips say “Couldn't download · Retry”, so no toast repeats it.
    func testNothingFetchedGivesNoToast() {
        XCTAssertNil(AttachmentSaveOutcome(requested: 1, saved: [], unfetched: 1).toast())
        XCTAssertNil(AttachmentSaveOutcome(requested: 3, saved: [], unfetched: 3).toast())
    }

    /// A file that arrived but could not be written has nowhere else to say so.
    func testNothingWrittenSaysSo() {
        let outcome = AttachmentSaveOutcome(requested: 2, saved: [], unfetched: 1)
        XCTAssertEqual(outcome.unwritten, 1)
        XCTAssertEqual(outcome.toast(), .failed("Couldn\u{2019}t save to Downloads"))
    }

    func testLargeCountsUseTheLocalesGrouping() {
        let outcome = AttachmentSaveOutcome(requested: 1_200, saved: urls(1_200), unfetched: 0)
        let n = 1_200.formatted(.number.grouping(.automatic))
        XCTAssertEqual(outcome.toast(), .saved("Saved \(n) attachments to Downloads"))
    }

    // MARK: Download all's one progress

    func testSharesFollowTheListedSizes() {
        let shares = AttachmentDownloadBoard.batchShares(sizes: [1_000, 3_000])
        XCTAssertEqual(shares[0], 0.25, accuracy: 1e-9)
        XCTAssertEqual(shares[1], 0.75, accuracy: 1e-9)
    }

    func testAFileWithNoSizeCountsAsTheAverage() {
        let shares = AttachmentDownloadBoard.batchShares(sizes: [1_000, 0, 3_000])
        XCTAssertEqual(shares[1], 2_000.0 / 6_000.0, accuracy: 1e-9)
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(AttachmentDownloadBoard.batchShares(sizes: [0, 0]), [0.5, 0.5], "no sizes: each file the same")
        XCTAssertEqual(AttachmentDownloadBoard.batchShares(sizes: []), [])
    }

    func testTheBatchFractionRisesThroughEachFileInTurn() {
        let shares = AttachmentDownloadBoard.batchShares(sizes: [1_000, 3_000])
        XCTAssertEqual(AttachmentDownloadBoard.batchFraction(shares: shares, index: 0, fraction: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(AttachmentDownloadBoard.batchFraction(shares: shares, index: 0, fraction: 0.5), 0.125, accuracy: 1e-9)
        XCTAssertEqual(AttachmentDownloadBoard.batchFraction(shares: shares, index: 0, fraction: 1), 0.25, accuracy: 1e-9)
        XCTAssertEqual(AttachmentDownloadBoard.batchFraction(shares: shares, index: 1, fraction: 0.5), 0.625, accuracy: 1e-9)
        XCTAssertEqual(AttachmentDownloadBoard.batchFraction(shares: shares, index: 1, fraction: 2), 1, "a fraction past 1 holds at the end")
        XCTAssertEqual(AttachmentDownloadBoard.batchFraction(shares: shares, index: 5, fraction: 0), 1)
    }

    /// Download all's progress has a place on the board of its own, which no attachment's chip can share.
    func testTheWholeMessageIsNotAChip() {
        let message = MessageID(accountID: AccountID("a"), providerID: "m")
        let all = AttachmentDownloadBoard.Chip.allAttachments(of: message)
        XCTAssertTrue(all.isAllAttachments)
        XCTAssertFalse(AttachmentDownloadBoard.Chip(message: message, attachmentID: "att").isAllAttachments)
        var board = AttachmentDownloadBoard()
        let ticket = board.begin(all)
        XCTAssertFalse(board.isDownloading(AttachmentDownloadBoard.Chip(message: message, attachmentID: "att")))
        XCTAssertEqual(board.reveal(ticket), .sweeping)
        XCTAssertEqual(board.progress(0.4, for: ticket), .fraction(0.4))
        XCTAssertEqual(board.end(ticket), .done)
    }
}
