import XCTest
@testable import SSCore

final class MailActionCopyTests: XCTestCase {
    func testToastPastTenseAndCoalescedForms() {
        XCTAssertEqual(MailActionCopy.toast(for: .archive), "Archived")
        XCTAssertEqual(MailActionCopy.toast(for: .archive, count: 3), "Archived 3 conversations")
        XCTAssertEqual(MailActionCopy.toast(for: .trash), "Moved to Trash")
        XCTAssertEqual(MailActionCopy.toast(for: .setRead(false), count: 3), "Marked 3 as unread")
        XCTAssertEqual(MailActionCopy.toast(for: .setStarred(false)), "Unstarred")
    }

    func testUndoConfirmationNamesTheCommand() {
        XCTAssertEqual(MailActionCopy.undoConfirmation(for: .archive), "Undid Archive")
        XCTAssertEqual(MailActionCopy.undoConfirmation(for: .trash), "Undid Move to Trash")
        XCTAssertEqual(MailActionCopy.undoConfirmation(for: .setRead(false)), "Undid Mark as Unread")
        XCTAssertEqual(MailActionCopy.undoMenuTitle(for: .archive), "Undo Archive")
    }

    func testOnlyActionsThatTakeARowAwayGetAToast() {
        XCTAssertTrue(MailActionCopy.wantsToast(for: .archive, in: .inbox, isSearching: false))
        XCTAssertFalse(MailActionCopy.wantsToast(for: .archive, in: .starred, isSearching: false))
        XCTAssertTrue(MailActionCopy.wantsToast(for: .trash, in: .all, isSearching: false))
        XCTAssertFalse(MailActionCopy.wantsToast(for: .setStarred(true), in: .inbox, isSearching: false))
        XCTAssertTrue(MailActionCopy.wantsToast(for: .setStarred(false), in: .starred, isSearching: false))
        XCTAssertFalse(MailActionCopy.wantsToast(for: .setRead(false), in: .inbox, isSearching: false))
        XCTAssertTrue(MailActionCopy.wantsToast(for: .setRead(false), in: .inbox, isSearching: false, count: 3))
        XCTAssertTrue(MailActionCopy.wantsToast(for: .moveToInbox, in: .trash, isSearching: false))
        XCTAssertFalse(MailActionCopy.wantsToast(for: .archive, in: .inbox, isSearching: true))
    }

    func testFailureLines() {
        XCTAssertEqual(MailActionCopy.failure(for: .archive), "Couldn't archive. Restored.")
        XCTAssertEqual(MailActionCopy.failure(for: .trash), "Couldn't move to Trash. Restored.")
    }
}
