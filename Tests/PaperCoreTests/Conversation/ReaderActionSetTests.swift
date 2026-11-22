import XCTest
@testable import PaperCore

/// Spec §5.12, the action set per view and selection, row by row.
final class ReaderActionSetTests: XCTestCase {
    private typealias Set_ = ReaderActionSet

    func testOneConversationInTheMailboxes() {
        for view in [MailboxView.inbox, .starred, .sent, .all] {
            let set = Set_.make(.one(view: view, inTrash: false, emptied: false, starred: false, replyAllAvailable: true))
            XCTAssertEqual(set.primary, [.star, .archive, .trash], "\(view)")
            XCTAssertEqual(set.replies, [.reply, .replyAll, .forward], "\(view)")
            XCTAssertTrue(set.disabled.isEmpty)
            XCTAssertFalse(set.starOn)
        }
        let starred = Set_.make(.one(view: .inbox, inTrash: false, emptied: false, starred: true, replyAllAvailable: true))
        XCTAssertTrue(starred.starOn)
    }

    func testReplyAllIsDisabledWithOneParticipant() {
        let set = Set_.make(.one(view: .inbox, inTrash: false, emptied: false, starred: false, replyAllAvailable: false))
        XCTAssertFalse(set.isEnabled(.replyAll))
        XCTAssertTrue(set.isEnabled(.reply))
    }

    func testTrashSwapsArchiveForMoveToInboxAndDropsTrash() {
        for set in [Set_.make(.one(view: .trash, inTrash: true, emptied: false, starred: false, replyAllAvailable: true)),
                    Set_.make(.one(view: .all, inTrash: true, emptied: false, starred: false, replyAllAvailable: true))] {
            XCTAssertEqual(set.primary, [.star, .moveToInbox])
            XCTAssertEqual(set.replies, [.reply, .replyAll, .forward])
            XCTAssertFalse(set.all.contains(.trash), "v1 has no Delete Forever")
        }
    }

    func testSeveralSelectedHideTheReplyGroup() {
        let mixed = Set_.make(.several(count: 3, view: .inbox, allStarred: false))
        XCTAssertEqual(mixed.primary, [.star, .archive, .trash])
        XCTAssertTrue(mixed.replies.isEmpty)
        XCTAssertFalse(mixed.starOn, "none or mixed: Star All")
        XCTAssertTrue(Set_.make(.several(count: 3, view: .inbox, allStarred: true)).starOn, "every one starred: Unstar All")
        XCTAssertEqual(Set_.make(.several(count: 2, view: .trash, allStarred: false)).primary, [.star, .moveToInbox])
        XCTAssertEqual(Set_.make(.several(count: 2, view: .drafts, allStarred: false)).all, [.discardDraft])
    }

    func testDraftsOfferContinueEditingAndDiscard() {
        let set = Set_.make(.one(view: .drafts, inTrash: false, emptied: false, starred: false, replyAllAvailable: true))
        XCTAssertEqual(set.all, [.continueEditing, .discardDraft])
        XCTAssertTrue(set.disabled.isEmpty)
    }

    func testNothingSelectedShowsTheFullSetDisabled() {
        let set = Set_.make(.nothing)
        XCTAssertEqual(set.all, [.star, .archive, .trash, .reply, .replyAll, .forward])
        XCTAssertTrue(set.all.allSatisfy { !set.isEnabled($0) })
    }

    func testAnEmptiedConversationKeepsOnlyTrash() {
        let set = Set_.make(.one(view: .inbox, inTrash: false, emptied: true, starred: false, replyAllAvailable: true))
        XCTAssertEqual(set.all.filter(set.isEnabled), [.trash])
        let inTrash = Set_.make(.one(view: .trash, inTrash: true, emptied: true, starred: false, replyAllAvailable: true))
        XCTAssertTrue(inTrash.all.allSatisfy { !inTrash.isEnabled($0) }, "in Trash every action is disabled")
    }

    // MARK: Reader mode (spec §5.59)

    /// Offered, reader mode's toggle is a group of its own before the first, on as reader mode is, and never disabled with
    /// the rest: it is global, so it answers with nothing selected too. Not offered, the set is exactly as before.
    func testReaderModesToggleLeadsWhileOffered() {
        let one = Set_.make(.one(view: .inbox, inTrash: false, emptied: false, starred: false, replyAllAvailable: true))
        XCTAssertEqual(one.offeringReaderMode(nil), one, "not offered: nothing changes")
        let offered = one.offeringReaderMode(true)
        XCTAssertEqual(offered.view, [.readerMode])
        XCTAssertEqual(offered.all, [.readerMode, .star, .archive, .trash, .reply, .replyAll, .forward])
        XCTAssertTrue(offered.readerModeOn)
        XCTAssertFalse(one.offeringReaderMode(false).readerModeOn)
        let nothing = Set_.make(.nothing).offeringReaderMode(false)
        XCTAssertTrue(nothing.isEnabled(.readerMode), "global: it works with nothing selected")
        XCTAssertFalse(nothing.isEnabled(.star))
        let emptied = Set_.make(.one(view: .inbox, inTrash: false, emptied: true, starred: false, replyAllAvailable: true)).offeringReaderMode(true)
        XCTAssertTrue(emptied.isEnabled(.readerMode))
        XCTAssertEqual(Set_.make(.outbox(continues: false)).offeringReaderMode(true).all, [.readerMode])
    }
}
