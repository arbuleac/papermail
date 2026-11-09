import XCTest
@testable import SSCore

/// The Send button's two actions (spec §5.23): their names, tooltips and Edit › Undo titles, and the rule that a new
/// message, which answers no conversation, only sends.
final class SendActionTests: XCTestCase {
    func testSendAndArchiveIsTheDefaultAndListedFirst() {
        XCTAssertEqual(SendAction.default, .sendAndArchive)
        XCTAssertEqual(SendAction.allCases, [.sendAndArchive, .send], "the drop-down lists the default first")
        XCTAssertTrue(SendAction.sendAndArchive.archives)
        XCTAssertFalse(SendAction.send.archives)
    }

    func testWordsAreTheMenusTitleCaseNames() {
        XCTAssertEqual(SendAction.sendAndArchive.title, "Send and Archive")
        XCTAssertEqual(SendAction.send.title, "Send")
        XCTAssertEqual(SendAction.sendAndArchive.tooltip, "Send and Archive  ⌘↩", "the name, two spaces, the shortcut (§5.34)")
        XCTAssertEqual(SendAction.send.tooltip, "Send  ⌘↩")
        XCTAssertEqual(SendAction.send.tooltip, ComposeSendReadiness.sendTooltip, "Send's tooltip is unchanged")
        XCTAssertEqual(SendAction.undoMenuTitle(archived: true), "Undo Send and Archive")
        XCTAssertEqual(SendAction.undoMenuTitle(archived: false), "Undo Send")
    }

    func testAMessageThatAnswersNothingOnlySends() {
        XCTAssertEqual(SendAction.sendAndArchive.effective(answers: true), .sendAndArchive)
        XCTAssertEqual(SendAction.sendAndArchive.effective(answers: false), .send, "a new message has no conversation to archive")
        XCTAssertEqual(SendAction.send.effective(answers: true), .send)
        XCTAssertEqual(SendAction.send.effective(answers: false), .send)
    }

    func testRawValuesAreStableForTheSavedPreference() {
        XCTAssertEqual(SendAction(rawValue: "sendAndArchive"), .sendAndArchive)
        XCTAssertEqual(SendAction(rawValue: "send"), .send)
        XCTAssertNil(SendAction(rawValue: "archive"))
    }
}
