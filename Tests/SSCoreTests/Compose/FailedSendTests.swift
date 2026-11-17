import XCTest
@testable import SSCore

/// A failed send leaves the Outbox for Drafts (spec §5.53): which failed sends the app keeps itself, the id each is kept
/// under, and the words its toast says, from `PendingSendSummary` values alone.
final class FailedSendTests: XCTestCase {
    private let gmail = AccountID("gmail")
    private let outlook = AccountID("outlook")

    private func send(_ id: String, status: PendingSendStatus, account: AccountID? = nil, lastError: String? = nil,
                      draft: UUID? = nil) -> PendingSendSummary {
        PendingSendSummary(id: id, accountID: account ?? gmail, createdAt: Date(timeIntervalSince1970: 0),
                           sendAfter: Date(timeIntervalSince1970: 5), status: status, lastError: lastError, draftID: draft,
                           subject: "Lisbon", text: "See you there")
    }

    /// Kept under one id whoever keeps it, so keeping it twice rewrites one draft: a Send Later message's own draft, else
    /// the send's id, which is a UUID for every send the app queues, else one derived from it, the same each time.
    func testAFailedSendIsKeptUnderOneIdWhoeverKeepsIt() throws {
        let written = UUID()
        XCTAssertEqual(FailedSend.draftID(for: send("s", status: .failed, draft: written)), written, "the draft it was written in")
        let queued = UUID()
        XCTAssertEqual(FailedSend.draftID(sendID: queued.uuidString, writtenIn: nil), queued, "an undo-send's is its send's id")
        XCTAssertEqual(FailedSend.draftID(for: send(queued.uuidString, status: .failed)), queued)
        let other = FailedSend.draftID(sendID: "send-1", writtenIn: nil)
        XCTAssertEqual(FailedSend.draftID(sendID: "send-1", writtenIn: nil), other, "the same every time")
        XCTAssertNotEqual(FailedSend.draftID(sendID: "send-2", writtenIn: nil), other, "and its own")
        XCTAssertEqual(UUID(uuidString: other.uuidString), other, "a well-formed UUID")
    }

    /// The app keeps every failed send no panel or quick reply answers for, of an account the window knows; one it does
    /// not know yet (accounts still being read at launch) waits, and nothing that has not failed is touched.
    func testTheAppKeepsTheFailedSendsNobodyElseAnswersFor() {
        let sends = [
            send("counting", status: .scheduled),
            send("owned", status: .failed, lastError: "HTTP 400"),
            send("orphan", status: .failed, lastError: "HTTP 400"),
            send("interrupted", status: .failed, lastError: "interrupted while sending; check Sent before sending again"),
            send("later", status: .failed, lastError: "HTTP 400", draft: UUID()),
            send("elsewhere", status: .failed, account: outlook, lastError: "HTTP 400"),
            send("going", status: .sending),
            send("gone", status: .sent, draft: UUID()),
            send("missed", status: .missed, draft: UUID()),
        ]
        let owned: Set<String> = ["owned", "counting"]
        XCTAssertEqual(FailedSend.settledByTheApp(sends, owned: owned.contains, accounts: [gmail]).map(\.id),
                       ["orphan", "interrupted", "later"])
        XCTAssertEqual(FailedSend.settledByTheApp(sends, owned: owned.contains, accounts: [gmail, outlook]).map(\.id),
                       ["orphan", "interrupted", "later", "elsewhere"], "its account known, it is kept too")
        XCTAssertTrue(FailedSend.settledByTheApp(sends, owned: owned.contains, accounts: []).isEmpty, "no account known yet")
    }

    /// The toast says it failed, or, for a send the app quit while handing over, that it may have gone and where to look,
    /// never that it was not sent, which would invite a second copy.
    func testTheToastSaysAnInterruptedSendMayHaveGone() {
        let interrupted = "interrupted while sending; check Sent before sending again"
        XCTAssertEqual(SendFailureWording.notice(subject: "Lisbon", lastError: "HTTP 400"), "Couldn\u{2019}t send \u{201c}Lisbon\u{201d}")
        XCTAssertEqual(SendFailureWording.notice(subject: "  ", lastError: nil), "Couldn\u{2019}t send your message")
        XCTAssertEqual(SendFailureWording.notice(subject: "Lisbon", lastError: interrupted),
                       "\u{201c}Lisbon\u{201d} may have gone. Check Sent.")
        XCTAssertEqual(SendFailureWording.notice(subject: "", lastError: interrupted), "Your message may have gone. Check Sent.")
        XCTAssertTrue(SendFailureWording.isInterrupted(lastError: interrupted))
        XCTAssertFalse(SendFailureWording.isInterrupted(lastError: "HTTP 400"))
        XCTAssertFalse(SendFailureWording.isInterrupted(lastError: nil))
        for words in [SendFailureWording.notice(subject: "Lisbon", lastError: interrupted),
                      SendFailureWording.banner(lastError: interrupted, provider: .microsoft)] {
            XCTAssertFalse(words.contains("\u{2014}") || words.contains("\u{2013}"), "no long dash: \(words)")
            XCTAssertTrue(words.contains("may have gone"), words)
            XCTAssertTrue(words.contains("Check Sent"), words)
        }
    }
}
