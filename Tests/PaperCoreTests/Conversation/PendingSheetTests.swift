import XCTest
@testable import PaperCore

/// Replies on their way out show in the conversation they answer (spec §5.14, Pending send).
final class PendingSheetTests: XCTestCase {
    private let account = Account(id: AccountID("a"), kind: .gmail, email: "me@example.com", displayName: "Alex Morgan", addedAt: Date())

    private func message(_ id: String, conversation: String = "c1") -> MessageMetadata {
        MessageMetadata(id: MessageID(accountID: account.id, providerID: id),
                        conversationID: ConversationID(accountID: account.id, providerID: conversation), subject: "Plans",
                        snippet: "", from: EmailAddress(name: "Ben", address: "ben@example.com"), date: Date(timeIntervalSince1970: 0),
                        roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false)
    }

    private func send(_ id: String, replyingTo original: MessageID?, forward: Bool = false, status: PendingSendStatus = .scheduled,
                      at seconds: TimeInterval = 10) -> PendingSendSummary {
        PendingSendSummary(PendingSend(id: id, message: OutgoingMessage(accountID: account.id, to: [EmailAddress(address: "ben@example.com")], subject: "Re: Plans",
                                                     html: "<p>Yes</p>", text: "Yes\n\nOn Monday, Ben wrote:\n> Plans?", inReplyTo: original,
                                                     isForward: forward),
                    createdAt: Date(timeIntervalSince1970: seconds), sendAfter: Date(), status: status))
    }

    func testOnlyRepliesOnTheirWayIntoThisConversationShow() {
        let thread = [message("m1"), message("m2")]
        let elsewhere = message("x1", conversation: "c2")
        let sends = [
            send("later", replyingTo: thread[0].id, status: .sending, at: 20),
            send("first", replyingTo: thread[1].id, at: 10),
            send("forward", replyingTo: thread[1].id, forward: true),
            send("failed", replyingTo: thread[1].id, status: .failed),
            send("other", replyingTo: elsewhere.id),
            send("new", replyingTo: nil),
        ]
        let sheets = PendingSheet.sheets(for: sends, answering: thread, accounts: [account.id: account])
        XCTAssertEqual(sheets.map(\.metadata.id.providerID), ["ss-pending-first", "ss-pending-later"], "oldest first")
        XCTAssertTrue(sheets.allSatisfy { PendingSheet.isPending($0.metadata.id) })
        XCTAssertFalse(PendingSheet.isPending(thread[0].id))
        let first = sheets[0]
        XCTAssertEqual(first.metadata.conversationID, thread[0].conversationID)
        XCTAssertEqual(first.metadata.from?.address, "me@example.com")
        XCTAssertEqual(first.body.typesetting, .plain)
        XCTAssertTrue(first.body.renderedHTML.hasPrefix("<div class=\"ss-body ss-plain\">"))
        XCTAssertEqual(first.body.hasQuotedContent, true, "the quoted original folds like any plain body")
        XCTAssertEqual(first.metadata.snippet, "Yes")
    }

    func testThePayloadMarksPendingSheets() {
        let thread = [message("m1")]
        let sheet = PendingSheet.sheets(for: [send("s", replyingTo: thread[0].id)], answering: thread, accounts: [account.id: account])[0]
        let payload = RenderPayloadBuilder().build(messages: thread + [sheet.metadata], bodies: [sheet.metadata.id: sheet.body],
                                                   accounts: [account.id: account], pending: [sheet.metadata.id])
        XCTAssertEqual(payload.messages.map(\.isPending), [false, true])
        XCTAssertEqual(payload.messages.last?.hasBody, true)
    }
}
