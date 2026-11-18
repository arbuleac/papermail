import XCTest
@testable import SSCore

/// The Z and ⌘Z order (spec §6.1): typing, then the most recent of the live sends and the visible toast, then for ⌘Z
/// the latest step still in the history, however old; Z reaches only a toast's action in its 10000 ms grace and never
/// cancels a send.
final class UndoPrecedenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func send(_ id: String, _ offset: TimeInterval) -> UndoPrecedence.LiveSend {
        UndoPrecedence.LiveSend(id: id, startedAt: t0.addingTimeInterval(offset))
    }

    private func toast(_ group: Int, _ offset: TimeInterval) -> UndoPrecedence.ToastGroup {
        UndoPrecedence.ToastGroup(groupID: group, actedAt: t0.addingTimeInterval(offset))
    }

    func testTypingComesFirst() {
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: true, sends: [send("a", 0)], toast: toast(1, 1), latestGroup: 2), .typing)
    }

    func testTheNewestSendOrToastWins() {
        // The quick reply's countdown started after the panel: it is cancelled first.
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [send("panel", 0), send("quick", 2)], toast: nil, latestGroup: nil),
                       .send("quick"))
        // A toast newer than every send holds ⌘Z while it is up.
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [send("panel", 0)], toast: toast(7, 1), latestGroup: nil), .group(7))
        // A send newer than the toast takes it back.
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [send("quick", 3)], toast: toast(7, 1), latestGroup: nil),
                       .send("quick"))
    }

    func testALiveSendOutranksAToastThatHasGone() {
        // Row 2 before row 3: the toast has gone, so its step is only in the history now.
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [send("panel", 0)], toast: nil, latestGroup: 4), .send("panel"))
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [], toast: nil, latestGroup: 4), .group(4))
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [], toast: nil, latestGroup: nil), .nothing,
                       "row 4: only once the history is empty")
    }

    /// Row 3 reaches the latest step however old, so ⌘Z walks back through the history; the visible toast's step still
    /// comes first, as row 2 promises.
    func testCommandZReachesTheLatestStepPastTheGrace() {
        var history = MailActionUndoHistory()
        for n in 1...3 {
            let message = MessageMetadata(
                id: MessageID(accountID: AccountID("acct"), providerID: "m\(n)"),
                conversationID: ConversationID(accountID: AccountID("acct"), providerID: "t\(n)"),
                subject: "Subject", snippet: "", from: nil, to: [], date: t0,
                roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
            )
            history.add(MailActionRecord.make(.archive, on: [message], conversation: message.conversationID)!,
                        at: t0.addingTimeInterval(Double(n) * 60), toasted: false)
        }
        let later = t0.addingTimeInterval(86_400)
        let latest = history.latest?.id
        XCTAssertEqual(latest, 3)
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [], toast: nil, latestGroup: latest), .group(3))
        XCTAssertEqual(UndoPrecedence.z(toast: nil, graceGroup: history.graceGroup(at: later)?.id), .nothing,
                       "Z does not change: nothing past the grace")
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [], toast: toast(1, 0), latestGroup: latest), .group(1),
                       "a visible toast's step still goes first")
        _ = history.remove(3)
        XCTAssertEqual(UndoPrecedence.commandZ(textCanUndo: false, sends: [], toast: nil, latestGroup: history.latest?.id), .group(2),
                       "each press reaches one step further back")
    }

    func testZOnlyEverRevertsAToastsAction() {
        XCTAssertEqual(UndoPrecedence.z(toast: toast(3, 0), graceGroup: 1), .group(3))
        XCTAssertEqual(UndoPrecedence.z(toast: nil, graceGroup: 1), .group(1))
        XCTAssertEqual(UndoPrecedence.z(toast: nil, graceGroup: nil), .nothing)
    }

    func testThePanelKeycapFollowsTheCommandZOwner() {
        XCTAssertEqual(UndoPrecedence.sendOwningCommandZ(sends: [send("a", 0), send("b", 1)], toast: nil), "b")
        XCTAssertNil(UndoPrecedence.sendOwningCommandZ(sends: [send("a", 0)], toast: toast(1, 2)), "a newer toast took ⌘Z")
        XCTAssertNil(UndoPrecedence.sendOwningCommandZ(sends: [], toast: nil))
    }
}
