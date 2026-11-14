import XCTest
@testable import SSCore

/// A quick reply is addressed to the latest message of the conversation shown, so text typed under one
/// thread must never still be in the box when another is shown.
final class QuickReplyDraftsTests: XCTestCase {
    private typealias F = ConversationFixtures
    private let a = ConversationID(accountID: F.accountID, providerID: "thread-a")
    private let b = ConversationID(accountID: F.accountID, providerID: "thread-b")

    func testDraftLeavesTheBoxWithItsConversation() {
        var drafts = QuickReplyDrafts()
        let underB = drafts.move(boxText: "Sure, 3pm works, door code 4421", from: a, to: b)
        XCTAssertEqual(underB, "", "nothing written under A is sendable under B")
        XCTAssertEqual(drafts.draft(under: a), "Sure, 3pm works, door code 4421")

        let backUnderA = drafts.move(boxText: "", from: b, to: a)
        XCTAssertEqual(backUnderA, "Sure, 3pm works, door code 4421")
        XCTAssertTrue(drafts.isEmpty, "while A is shown the box is the only copy")
    }

    func testEachConversationKeepsItsOwnDraft() {
        var drafts = QuickReplyDrafts()
        _ = drafts.move(boxText: "for ada", from: a, to: b)
        XCTAssertEqual(drafts.move(boxText: "for bob", from: b, to: a), "for ada")
        XCTAssertEqual(drafts.move(boxText: "for ada", from: a, to: b), "for bob")
    }

    func testBlankTextForgetsTheDraft() {
        var drafts = QuickReplyDrafts()
        drafts.park("hello", under: a)
        drafts.park("  \n", under: a)
        XCTAssertEqual(drafts.draft(under: a), "")
        XCTAssertTrue(drafts.isEmpty)
    }

    func testMovingFromNoSelectionParksNothing() {
        var drafts = QuickReplyDrafts()
        XCTAssertEqual(drafts.move(boxText: "stale", from: nil, to: a), "")
        XCTAssertTrue(drafts.isEmpty)
        XCTAssertEqual(drafts.move(boxText: "typed under a", from: a, to: nil), "")
        XCTAssertEqual(drafts.draft(under: a), "typed under a")
    }

    func testUnsentTextReturnsToTheBoxOnlyUnderItsOwnThread() {
        var drafts = QuickReplyDrafts()
        XCTAssertTrue(drafts.restoreUnsent("oops", under: a, shown: a))
        XCTAssertTrue(drafts.isEmpty, "shown thread: the box takes it, nothing is parked")

        // Undo pressed after `j` moved the selection on: the text waits under A, not under B.
        XCTAssertFalse(drafts.restoreUnsent("oops", under: a, shown: b))
        XCTAssertEqual(drafts.draft(under: a), "oops")
        XCTAssertEqual(drafts.draft(under: b), "")
        XCTAssertFalse(drafts.restoreUnsent("oops", under: a, shown: nil))
    }

    /// Two boxes show A at once (the main window's reader and a reader window's, spec §5.19a): the window closes and
    /// parks its text, then the main window's box, empty, moves on. The window's text waits for the next box on A.
    func testABoxLeavingABlankThreadKeepsWhatAnotherBoxParked() {
        var drafts = QuickReplyDrafts()
        _ = drafts.move(boxText: "", from: nil, to: a)
        drafts.leave("Typed in the window", under: a)
        XCTAssertEqual(drafts.move(boxText: "", from: a, to: b), "")
        XCTAssertEqual(drafts.draft(under: a), "Typed in the window", "an empty box never drops another box's text")
        XCTAssertEqual(drafts.move(boxText: "", from: b, to: a), "Typed in the window")
    }

    func testTwoBoxesTextUnderOneThreadIsKeptBoth() {
        var drafts = QuickReplyDrafts()
        drafts.leave("From the window", under: a)
        drafts.leave("From the main window", under: a)
        XCTAssertEqual(drafts.draft(under: a), "From the window\n\nFrom the main window")
        drafts.leave("From the main window", under: b)
        drafts.leave("From the main window", under: b)
        XCTAssertEqual(drafts.draft(under: b), "From the main window", "the same text is kept once")
    }

    func testUnsentTextIsKeptAboveWhatWasParkedSince() {
        var drafts = QuickReplyDrafts()
        drafts.leave("Typed after sending", under: a)
        XCTAssertFalse(drafts.restoreUnsent("The reply", under: a, shown: b))
        XCTAssertEqual(drafts.draft(under: a), "The reply\n\nTyped after sending")
    }
}
