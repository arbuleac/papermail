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

    /// The request first, then the archive the toast's Undo takes back (spec §5.30, §4.13).
    func testUnsubscribeToastsNameTheRequestThenTheArchive() {
        let page = UnsubscribeMethod.browser(URL(string: "https://news.example.com/u")!)
        let post = UnsubscribeMethod.oneClick(URL(string: "https://news.example.com/u")!)
        let mail = UnsubscribeMethod.mailto(URL(string: "mailto:leave@news.example.com")!)
        XCTAssertEqual(MailActionCopy.unsubscribeToast(for: post, archived: true), "Unsubscribe sent \u{00B7} Archived")
        XCTAssertEqual(MailActionCopy.unsubscribeToast(for: mail, archived: true), "Unsubscribe sent \u{00B7} Archived")
        XCTAssertEqual(MailActionCopy.unsubscribeToast(for: page, archived: true), "Opened in browser \u{00B7} Archived")
        XCTAssertEqual(MailActionCopy.unsubscribeToast(for: post, archived: false), "Unsubscribe sent")
        XCTAssertEqual(MailActionCopy.unsubscribeToast(for: page, archived: false), "Opened in browser")
        XCTAssertEqual(MailActionCopy.commandName(for: .unsubscribe(post)), "Unsubscribe")
    }

    /// The undo of an unsubscribe's archive says what it did not take back (roadmap Q2.4: the request cannot be
    /// unsent, and the toast says so).
    func testAnUnsubscribesUndoSaysTheRequestStaysSent() {
        let post = UnsubscribeMethod.oneClick(URL(string: "https://news.example.com/u")!)
        let mail = UnsubscribeMethod.mailto(URL(string: "mailto:leave@news.example.com")!)
        let page = UnsubscribeMethod.browser(URL(string: "https://news.example.com/u")!)
        XCTAssertEqual(MailActionCopy.unsubscribeUndoConfirmation(for: post), "Undid Archive \u{00B7} Unsubscribe stays sent")
        XCTAssertEqual(MailActionCopy.unsubscribeUndoConfirmation(for: mail), "Undid Archive \u{00B7} Unsubscribe stays sent")
        XCTAssertEqual(MailActionCopy.unsubscribeUndoConfirmation(for: page), "Undid Archive", "a page sent nothing")
    }

    func testUndoConfirmationNamesTheCommand() {
        XCTAssertEqual(MailActionCopy.undoConfirmation(for: .archive), "Undid Archive")
        XCTAssertEqual(MailActionCopy.undoConfirmation(for: .trash), "Undid Move to Trash")
        XCTAssertEqual(MailActionCopy.undoConfirmation(for: .setRead(false)), "Undid Mark as Unread")
        XCTAssertEqual(MailActionCopy.undoMenuTitle(for: .archive), "Undo Archive")
    }

    /// Out of Later, Move to Inbox and Move to Trash take the row away (the snooze ends), so both say so. A search typed
    /// in Later lists All Mail, or its `in:` view, where Move to Inbox takes a result away only as it would there.
    func testLeavingLaterGetsAToast() {
        XCTAssertTrue(MailActionCopy.wantsToast(for: .moveToInbox, in: .later))
        XCTAssertTrue(MailActionCopy.wantsToast(for: .trash, in: .later))
        XCTAssertFalse(MailActionCopy.wantsToast(for: .setStarred(true), in: .later))
        XCTAssertEqual(MailActionCopy.snoozeCommand, "Snooze")
        func toast(_ change: MetadataChange, _ text: String) -> Bool {
            let query = ShellQuery.make(scope: nil, view: .later, searchText: text)
            return MailActionCopy.wantsToast(for: change, in: query.view, search: query.search)
        }
        XCTAssertFalse(toast(.moveToInbox, "lisbon"))
        XCTAssertTrue(toast(.trash, "lisbon"))
        XCTAssertTrue(toast(.moveToInbox, "in:trash lisbon"))
    }

    /// The snooze toast names its time whole: where the sentence would be cut off it goes without “Snoozed”.
    func testTheSnoozeToastKeepsItsTime() {
        XCTAssertEqual(MailActionCopy.snoozed(until: "Tue 09:00") { _ in true }, "Snoozed until Tue 09:00")
        var asked: [String] = []
        let short = MailActionCopy.snoozed(until: "20 May 2027 09:00") { asked.append($0); return false }
        XCTAssertEqual(short, "Until 20 May 2027 09:00")
        XCTAssertEqual(asked, ["Snoozed until 20 May 2027 09:00"], "the sentence is measured first")
    }

    func testOnlyActionsThatTakeARowAwayGetAToast() {
        XCTAssertTrue(MailActionCopy.wantsToast(for: .archive, in: .inbox))
        XCTAssertFalse(MailActionCopy.wantsToast(for: .archive, in: .starred))
        XCTAssertTrue(MailActionCopy.wantsToast(for: .trash, in: .all))
        XCTAssertFalse(MailActionCopy.wantsToast(for: .setStarred(true), in: .inbox))
        XCTAssertTrue(MailActionCopy.wantsToast(for: .setStarred(false), in: .starred))
        XCTAssertFalse(MailActionCopy.wantsToast(for: .setRead(false), in: .inbox))
        XCTAssertTrue(MailActionCopy.wantsToast(for: .setRead(false), in: .inbox, count: 3))
        XCTAssertTrue(MailActionCopy.wantsToast(for: .moveToInbox, in: .trash))
        // A search looks through All Mail, where only moving to the trash takes a result away.
        XCTAssertFalse(MailActionCopy.wantsToast(for: .archive, in: .all, search: SearchQuery(parsing: "budget")))
        XCTAssertTrue(MailActionCopy.wantsToast(for: .trash, in: .all, search: SearchQuery(parsing: "budget")))
    }

    /// A search with operators lists what they describe, so an action that takes a result out of it says so, as it
    /// would in that view.
    func testASearchToastsWhatTakesAResultOutOfIt() {
        func toast(_ change: MetadataChange, _ text: String) -> Bool {
            let query = ShellQuery.make(scope: nil, view: .starred, searchText: text)
            return MailActionCopy.wantsToast(for: change, in: query.view, search: query.search)
        }
        XCTAssertFalse(toast(.archive, "lisbon"), "All Mail keeps archived mail")
        XCTAssertTrue(toast(.archive, "in:inbox lisbon"))
        XCTAssertTrue(toast(.restoreFromTrash, "in:trash"))
        XCTAssertFalse(toast(.trash, "in:trash"))
        XCTAssertTrue(toast(.archive, "in:sent in:inbox"), "every in: term, not only the one that picked the view")
        XCTAssertTrue(toast(.moveToInbox, "-in:inbox"))
        XCTAssertTrue(toast(.setStarred(false), "is:starred"))
        XCTAssertTrue(toast(.setStarred(true), "-is:starred"))
        XCTAssertFalse(toast(.setStarred(false), "budget"))
        XCTAssertFalse(toast(.setRead(true), "is:unread"), "the open conversation stays listed")
        XCTAssertFalse(toast(.setRead(false), "is:read"))
        XCTAssertFalse(toast(.archive, "has:attachment after:2026-01-01"))
    }

    /// Mark as spam (spec “Mark as spam”): no view lists spam, so it always takes the row away and always says so.
    func testMarkAsSpamWords() {
        XCTAssertEqual(MailActionCopy.toast(for: .markSpam), "Marked as spam")
        XCTAssertEqual(MailActionCopy.toast(for: .markSpam, count: 3), "Marked 3 as spam")
        XCTAssertEqual(MailActionCopy.commandName(for: .markSpam), "Mark as Spam")
        XCTAssertEqual(MailActionCopy.undoConfirmation(for: .markSpam), "Undid Mark as Spam")
        XCTAssertEqual(MailActionCopy.undoMenuTitle(for: .markSpam), "Undo Mark as Spam")
        XCTAssertEqual(MailActionCopy.failure(for: .markSpam), "Couldn't mark as spam. Restored.")
        XCTAssertEqual(MailActionCopy.failure(for: .markNotSpam), "Couldn't mark as not spam. Restored.")
        XCTAssertEqual(ConversationRowText.failureText(for: .markSpam), "Couldn't mark as spam")
        for view in MailboxView.allCases {
            XCTAssertTrue(MailActionCopy.wantsToast(for: .markSpam, in: view), "\(view)")
        }
        XCTAssertTrue(MailActionCopy.wantsToast(for: .markSpam, in: .all, search: SearchQuery(parsing: "budget")))
        XCTAssertEqual(MetadataChange.markSpam.kind, .markSpam)
        XCTAssertEqual(MetadataChange.markNotSpam.kind, .markNotSpam)
        XCTAssertEqual(OperationKind(rawValue: "markSpam"), .markSpam, "the stored raw value")
    }

    func testFailureLines() {
        XCTAssertEqual(MailActionCopy.failure(for: .archive), "Couldn't archive. Restored.")
        XCTAssertEqual(MailActionCopy.failure(for: .trash), "Couldn't move to Trash. Restored.")
    }
}
