import Foundation
import SSCore
import XCTest
@testable import SSGmail

final class GmailLabelEditTests: XCTestCase {
    func testEveryChangeMapsToTheDocumentedLabelEdit() {
        XCTAssertEqual(GmailLabelEdit(.archive).add, [])
        XCTAssertEqual(GmailLabelEdit(.archive).remove, ["INBOX"])

        XCTAssertEqual(GmailLabelEdit(.moveToInbox).add, ["INBOX"])
        XCTAssertEqual(GmailLabelEdit(.moveToInbox).remove, ["TRASH", "SPAM"])

        XCTAssertEqual(GmailLabelEdit(.setRead(true)).add, [])
        XCTAssertEqual(GmailLabelEdit(.setRead(true)).remove, ["UNREAD"])
        XCTAssertEqual(GmailLabelEdit(.setRead(false)).add, ["UNREAD"])
        XCTAssertEqual(GmailLabelEdit(.setRead(false)).remove, [])

        XCTAssertEqual(GmailLabelEdit(.setStarred(true)).add, ["STARRED"])
        XCTAssertEqual(GmailLabelEdit(.setStarred(true)).remove, [])
        XCTAssertEqual(GmailLabelEdit(.setStarred(false)).add, [])
        XCTAssertEqual(GmailLabelEdit(.setStarred(false)).remove, ["STARRED"])

        XCTAssertEqual(GmailLabelEdit(.trash).add, ["TRASH"])
        XCTAssertEqual(GmailLabelEdit(.trash).remove, ["INBOX"])

        XCTAssertEqual(GmailLabelEdit(.restoreFromTrash).add, ["INBOX"])
        XCTAssertEqual(GmailLabelEdit(.restoreFromTrash).remove, ["TRASH"])
    }

    /// The label edit must land on the same state as the local optimistic update for inbox messages.
    func testEditsAgreeWithLocalApplyingForRolesAndFlags() {
        let base = MessageMetadata(
            id: MessageID(accountID: AccountID("a"), providerID: "m"),
            conversationID: ConversationID(accountID: AccountID("a"), providerID: "t"),
            subject: "", snippet: "", from: nil, date: Date(),
            roles: [.inbox], isRead: false, isStarred: false, hasAttachments: false,
            labelIDs: ["INBOX", "UNREAD"]
        )
        let changes: [MetadataChange] = [.archive, .moveToInbox, .setRead(true), .setRead(false), .setStarred(true), .setStarred(false), .trash, .restoreFromTrash]
        for change in changes {
            let edit = GmailLabelEdit(change)
            var labels = Set(base.labelIDs)
            labels.subtract(edit.remove)
            labels.formUnion(edit.add)
            let simulated = GmailMessageMapper.roles(from: Array(labels))
            let expected = applying(change, to: base)
            XCTAssertEqual(simulated, expected.roles, "\(change)")
            XCTAssertEqual(!labels.contains("UNREAD"), expected.isRead, "\(change)")
            XCTAssertEqual(labels.contains("STARRED"), expected.isStarred, "\(change)")
        }
    }
}
