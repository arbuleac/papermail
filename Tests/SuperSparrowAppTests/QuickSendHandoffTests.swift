import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// A quick reply's countdown is never lost (spec §5.18): when the bar hides mid-countdown it moves to an
/// undo-send panel for its remaining seconds, where ⌘Z still reaches it in the order of §6.1.
@MainActor
final class QuickSendHandoffTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated {
            for panel in ComposeWindowRegistry.shared.livePanels { panel.orderOut(nil); ComposeWindowRegistry.shared.unregister(panel) }
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
        }
        super.tearDown()
    }

    func testTheCountdownMovesToAPanelWhenSeveralAreSelected() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let first = harness.list.conversations[0].id
        harness.list.selectedConversationID = first
        harness.list.onSelectionChange?(first)
        XCTAssertFalse(harness.reader.currentMessages.isEmpty)
        harness.reader.sendQuickReply("Thanks, sounds good", mode: .reply)
        let send = try XCTUnwrap(harness.reader.liveQuickSend, "the strip counts down")
        XCTAssertEqual(harness.controller.commandZTarget(textCanUndo: false), .send(send.id))

        // ⇧J: two selected, the bar hides, the countdown moves to a panel with its own start.
        _ = harness.controller.perform(.extendNext)
        XCTAssertNil(harness.reader.liveQuickSend)
        XCTAssertEqual(UndoSendPanel.liveSends, [send], "same send, same start: ⌘Z ranks it as before")
        XCTAssertEqual(UndoSendPanel.undoKeyOwner?.sendID, send.id, "the panel shows the ⌘Z keycap")
        XCTAssertEqual(harness.controller.commandZTarget(textCanUndo: false), .send(send.id))

        // ⌘Z cancels it there; the reply comes back in a composer.
        harness.controller.performUndo(.send(send.id))
        XCTAssertTrue(UndoSendPanel.liveSends.isEmpty)
        let composer = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first)
        XCTAssertEqual(composer.window?.title.hasPrefix("Re:"), true)
        XCTAssertTrue(try harness.environment.store.pendingSends().isEmpty, "the send was cancelled")
    }
}
