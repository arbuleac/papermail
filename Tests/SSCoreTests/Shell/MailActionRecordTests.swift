import XCTest
@testable import SSCore

final class MailActionRecordTests: XCTestCase {
    private let account = AccountID("acct")

    private func message(_ n: Int, roles: Set<MailboxRole>, isRead: Bool = true) -> MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: account, providerID: "m\(n)"),
            conversationID: ConversationID(accountID: account, providerID: "t1"),
            subject: "Subject", snippet: "", from: nil, to: [],
            date: Date(timeIntervalSince1970: 1_790_000_000 + Double(n) * 60),
            roles: roles, isRead: isRead, isStarred: false, hasAttachments: false
        )
    }

    private func ids(_ messages: [MessageMetadata]) -> [String] { messages.map(\.id.providerID) }

    /// Replays a record's inverse locally, the way the providers converge to `applying`.
    private func undo(_ record: MailActionRecord, on messages: [MessageMetadata]) -> [MessageMetadata] {
        messages.map { original in
            var m = original
            for step in record.inverse where step.targets.contains(m.id) { m = applying(step.change, to: m) }
            return m
        }
    }

    // MARK: Outlook trash keeps the user's own copies where they are

    func testOutlookTrashLeavesSentItemsAndDraftsInPlace() {
        let thread = [message(1, roles: [.inbox]), message(2, roles: [.sent]), message(3, roles: [.drafts]), message(4, roles: [])]
        let targets = MailActionRecord.targets(for: .trash, in: thread, kind: .microsoft)
        XCTAssertEqual(ids(targets), ["m1", "m4"])
        let record = try! XCTUnwrap(MailActionRecord.make(.trash, on: targets, conversation: thread[0].conversationID))
        // Undo never has to move a sent message back to Sent Items, which Graph cannot express.
        XCTAssertFalse(record.inverse.contains { $0.targets.contains(thread[1].id) })
        XCTAssertEqual(record.inverse, [
            .init(change: .restoreFromTrash, targets: [thread[0].id, thread[3].id]),
            .init(change: .archive, targets: [thread[3].id]),
        ])
    }

    func testOutlookTrashOfOnlyOwnMessagesStillTrashesThem() {
        let thread = [message(1, roles: [.sent]), message(2, roles: [.sent])]
        XCTAssertEqual(ids(MailActionRecord.targets(for: .trash, in: thread, kind: .microsoft)), ["m1", "m2"])
    }

    func testGmailTrashTakesTheWholeThreadAndUndoNetsOut() {
        let thread = [message(1, roles: [.inbox]), message(2, roles: [.sent])]
        let targets = MailActionRecord.targets(for: .trash, in: thread, kind: .gmail)
        XCTAssertEqual(ids(targets), ["m1", "m2"])
        let record = try! XCTUnwrap(MailActionRecord.make(.trash, on: targets, conversation: nil))
        let trashed = thread.map { applying(.trash, to: $0) }
        XCTAssertEqual(undo(record, on: trashed), thread)
    }

    // MARK: Move to Inbox

    func testMoveToInboxFromTrashRestoresOnlyTrashedMessagesAndUndoReturnsThem() {
        let thread = [message(1, roles: [.trash]), message(2, roles: [.trash]), message(3, roles: [])]
        let targets = MailActionRecord.targets(for: .moveToInbox, in: thread, kind: .gmail)
        XCTAssertEqual(ids(targets), ["m1", "m2"])
        let record = try! XCTUnwrap(MailActionRecord.make(.moveToInbox, on: targets, conversation: nil))
        XCTAssertEqual(record.title, "Moved to Inbox")
        XCTAssertEqual(record.inverse, [.init(change: .trash, targets: [thread[0].id, thread[1].id])])
        let moved = thread.map { targets.map(\.id).contains($0.id) ? applying(.moveToInbox, to: $0) : $0 }
        XCTAssertTrue(moved[0].isInInbox && moved[1].isInInbox && !moved[2].isInInbox)
        XCTAssertEqual(undo(record, on: moved), thread)
    }

    func testMoveToInboxFromArchiveUndoesToArchive() {
        let thread = [message(1, roles: []), message(2, roles: [.sent])]
        let targets = MailActionRecord.targets(for: .moveToInbox, in: thread, kind: .microsoft)
        XCTAssertEqual(ids(targets), ["m1"])
        let record = try! XCTUnwrap(MailActionRecord.make(.moveToInbox, on: targets, conversation: nil))
        XCTAssertEqual(record.inverse, [.init(change: .archive, targets: [thread[0].id])])
    }

    func testArchiveInTrashChangesNothing() {
        let thread = [message(1, roles: [.trash])]
        let targets = MailActionRecord.targets(for: .archive, in: thread, kind: .gmail)
        XCTAssertNil(MailActionRecord.make(.archive, on: targets, conversation: nil))
    }

    // MARK: Mark as spam

    /// Other people's mail goes to Spam on both providers; the user's own sent messages and drafts, and what is in the
    /// Trash, stay where they are, so the undo never has to put a message back in Sent Items or the Trash.
    func testMarkSpamTakesOnlyOthersMailOutsideTheTrash() {
        let thread = [message(1, roles: [.inbox]), message(2, roles: [.sent]), message(3, roles: [.drafts]),
                      message(4, roles: [.trash]), message(5, roles: [])]
        for kind in [ProviderKind.gmail, .microsoft] {
            XCTAssertEqual(ids(MailActionRecord.targets(for: .markSpam, in: thread, kind: kind)), ["m1", "m5"], "\(kind)")
        }
    }

    /// The inverse lands everything in the Inbox, as restoreFromTrash does, then archives again what was archived.
    func testMarkSpamUndoPutsInboxMailBackInTheInboxAndArchivedMailInTheArchive() throws {
        let thread = [message(1, roles: [.inbox]), message(2, roles: []), message(3, roles: [.sent])]
        let targets = MailActionRecord.targets(for: .markSpam, in: thread, kind: .gmail)
        let record = try XCTUnwrap(MailActionRecord.make(.markSpam, on: targets, conversation: thread[0].conversationID))
        XCTAssertEqual(record.title, "Marked as spam")
        XCTAssertEqual(record.targets, [thread[0].id, thread[1].id])
        XCTAssertEqual(record.inverse, [
            .init(change: .markNotSpam, targets: [thread[0].id, thread[1].id]),
            .init(change: .archive, targets: [thread[1].id]),
        ])
        let marked = thread.map { record.targets.contains($0.id) ? applying(.markSpam, to: $0) : $0 }
        XCTAssertEqual(marked.map(\.roles), [[.spam], [.spam], [.sent]])
        XCTAssertEqual(undo(record, on: marked), thread)
    }

    /// The user's own message the Inbox holds too (on Gmail, after ⇧I or a return from Later, which put INBOX on every
    /// message of the conversation) leaves the Inbox with the rest, into Spam: left out, it would keep the row in the
    /// Inbox. The undo brings it back to the Inbox, still in Sent.
    func testMarkSpamTakesTheUsersOwnMessageTheInboxHolds() throws {
        let thread = [message(1, roles: [.inbox]), message(2, roles: [.sent, .inbox]), message(3, roles: [.sent])]
        let targets = MailActionRecord.targets(for: .markSpam, in: thread, kind: .gmail)
        XCTAssertEqual(ids(targets), ["m1", "m2"])
        let record = try XCTUnwrap(MailActionRecord.make(.markSpam, on: targets, conversation: thread[0].conversationID))
        XCTAssertEqual(record.inverse, [.init(change: .markNotSpam, targets: [thread[0].id, thread[1].id])])
        let marked = thread.map { record.targets.contains($0.id) ? applying(.markSpam, to: $0) : $0 }
        XCTAssertEqual(marked.map(\.roles), [[.spam], [.sent, .spam], [.sent]])
        XCTAssertEqual(undo(record, on: marked), thread)
    }

    func testMarkSpamOfOnlyTheUsersOwnMailChangesNothing() {
        let thread = [message(1, roles: [.sent]), message(2, roles: [.drafts])]
        let targets = MailActionRecord.targets(for: .markSpam, in: thread, kind: .microsoft)
        XCTAssertTrue(targets.isEmpty)
        XCTAssertNil(MailActionRecord.make(.markSpam, on: targets, conversation: nil))
        XCTAssertNil(MailActionRecord.make(.markSpam, on: [message(3, roles: [.spam])], conversation: nil), "already spam")
    }

    func testMarkNotSpamUndoesToSpam() throws {
        let spam = message(1, roles: [.spam])
        let record = try XCTUnwrap(MailActionRecord.make(.markNotSpam, on: [spam], conversation: nil))
        XCTAssertEqual(applying(.markNotSpam, to: spam).roles, [.inbox])
        XCTAssertEqual(record.inverse, [.init(change: .markSpam, targets: [spam.id])])
    }

    // MARK: Read state

    func testMarkUnreadTouchesOnlyTheLatestMessage() {
        let thread = [message(1, roles: [.inbox]), message(2, roles: [.inbox])]
        XCTAssertEqual(ids(MailActionRecord.targets(for: .setRead(false), in: thread, kind: .gmail)), ["m2"])
        XCTAssertEqual(ids(MailActionRecord.targets(for: .setRead(true), in: thread, kind: .gmail)), ["m1", "m2"])
    }
}
