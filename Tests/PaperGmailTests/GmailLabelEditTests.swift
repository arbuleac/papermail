import Foundation
import PaperCore
import XCTest
@testable import PaperGmail

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

        XCTAssertEqual(GmailLabelEdit(.markSpam).add, ["SPAM"])
        XCTAssertEqual(GmailLabelEdit(.markSpam).remove, ["INBOX", "TRASH"])
        XCTAssertEqual(GmailLabelEdit(.markNotSpam).add, ["INBOX"])
        XCTAssertEqual(GmailLabelEdit(.markNotSpam).remove, ["SPAM"])
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
        let changes: [MetadataChange] = [.archive, .moveToInbox, .setRead(true), .setRead(false), .setStarred(true), .setStarred(false), .trash,
                                         .restoreFromTrash, .markSpam, .markNotSpam]
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

    /// Mark as spam's undo starts from Spam, and an archived message marked as spam ends there too.
    func testSpamEditsAgreeWithLocalApplyingFromSpamAndTheArchive() {
        let cases: [(MetadataChange, [String], Set<MailboxRole>)] = [
            (.markNotSpam, ["SPAM"], [.spam]),
            (.markSpam, ["CATEGORY_UPDATES"], []),
        ]
        for (change, labelIDs, roles) in cases {
            let edit = GmailLabelEdit(change)
            var labels = Set(labelIDs)
            labels.subtract(edit.remove)
            labels.formUnion(edit.add)
            let base = MessageMetadata(
                id: MessageID(accountID: AccountID("a"), providerID: "m"),
                conversationID: ConversationID(accountID: AccountID("a"), providerID: "t"),
                subject: "", snippet: "", from: nil, date: Date(),
                roles: roles, isRead: true, isStarred: false, hasAttachments: false, labelIDs: labelIDs
            )
            XCTAssertEqual(GmailMessageMapper.roles(from: Array(labels)), applying(change, to: base).roles, "\(change)")
        }
    }
}
