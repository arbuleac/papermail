import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// The quick reply's hand-offs and states (spec §5.18, §6.1): Open in Composer carries the text, the bar is
/// disabled while a composer holds the reply, it answers the target message, Esc follows §6.1, and a send that
/// fails after its window says so in an error toast.
@MainActor
final class QuickReplyBehaviourTests: XCTestCase {
    private var folder: URL!
    private var savedUndoWindow: TimeInterval = 5

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperQuickReply-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            ComposeDraftStore.shared.useDirectory(folder)
            savedUndoWindow = ConversationViewController.undoWindow
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            ConversationViewController.undoWindow = savedUndoWindow
            for panel in ComposeWindowRegistry.shared.livePanels { panel.orderOut(nil); ComposeWindowRegistry.shared.unregister(panel) }
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// thread-2: three messages, the middle one from the user, so the target can move between two senders.
    private func openThreeMessageThread(_ harness: MainWindowHarness) throws -> ConversationID {
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentMessages.count == 3 }
        return id
    }

    func testOpenInComposerCarriesTheTextAndDisablesTheBar() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        _ = try openThreeMessageThread(harness)
        let bar = harness.reader.quickReplyBar
        bar.text = "Tuesday works for me"

        // ⇧⌘R (the tool row's button and the text view's key call the same thing).
        bar.onOpenInComposer?(bar.text, .reply)
        let composer = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first)
        XCTAssertEqual(composer.bodyText, "Tuesday works for me", "the typed text moves to the composer")
        MainWindowHarness.assertWritingStyle(composer.contents.body)
        XCTAssertEqual(bar.text, "", "and leaves the bar, so the reply is in one place")
        XCTAssertTrue(bar.isComposerOpen, "the bar shows its disabled state while the composer is open")

        // R brings that composer forward instead of focusing the disabled bar.
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        XCTAssertFalse(bar.isFocused)
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.count, 1, "no second composer")

        composer.closeWithoutSaving()
        XCTAssertFalse(bar.isComposerOpen, "closing the composer gives the bar back")
    }

    /// A reply kept as a draft takes the bar's text below what it held, in the same writing style.
    func testOpenInComposerAddsTheTextToAKeptReplyInTheWritingStyle() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        _ = try openThreeMessageThread(harness)
        let bar = harness.reader.quickReplyBar
        bar.onOpenInComposer?("Tuesday works for me", .reply)
        let first = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first)
        try XCTUnwrap(first.window).performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: first.draftID), "the typed reply is kept")

        bar.onOpenInComposer?("Or Wednesday", .reply)
        let reopened = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first)
        XCTAssertEqual(reopened.bodyText, "Tuesday works for me\n\nOr Wednesday")
        MainWindowHarness.assertWritingStyle(reopened.contents.body)
    }

    func testTheQuickReplyAnswersTheTargetMessage() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        _ = try openThreeMessageThread(harness)
        let messages = harness.reader.currentMessages
        let bar = harness.reader.quickReplyBar
        let latestSender = try XCTUnwrap(messages[2].from?.name)
        XCTAssertTrue(bar.replyName.contains(latestSender.components(separatedBy: " ")[0]), bar.replyName)

        let firstSender = try XCTUnwrap(messages[0].from?.name)
        harness.reader.setTarget(messages[0].id)
        XCTAssertTrue(bar.replyName.contains(firstSender.components(separatedBy: " ")[0]), "the placeholder follows the target")

        harness.reader.sendQuickReply("Sounds good", mode: .reply)
        let send = try XCTUnwrap(try harness.environment.store.pendingSends().first)
        XCTAssertEqual(send.message.to.map(\.address), [messages[0].from?.address].compactMap { $0 }, "the reply goes to the target's sender")
    }

    /// §5.14 Pending send: the reply shows in its conversation while it is on its way, and goes with an undo.
    func testASentReplyShowsAsAPendingSheetUntilItIsUndone() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        _ = try openThreeMessageThread(harness)
        XCTAssertTrue(harness.reader.pendingSheetIDs.isEmpty)
        harness.reader.sendQuickReply("On my way", mode: .reply)
        XCTAssertEqual(harness.reader.pendingSheetIDs.count, 1)
        XCTAssertFalse(harness.reader.currentMessages.contains { PendingSheet.isPending($0.id) }, "never the target, never acted on")
        XCTAssertTrue(harness.reader.cancelQuickSend())
        XCTAssertTrue(harness.reader.pendingSheetIDs.isEmpty, "the undone reply leaves the conversation")
    }

    /// A reply on its way is followed through the store's observation of the outbox, not a timer: a failure past the
    /// undo window reaches the reader with no tick, at once, and once nothing is on its way the reader follows nothing.
    /// Each reader (every reader window's too) ran a once-a-second outbox read on the main thread while a reply waited.
    func testTheOutboxIsFollowedByObservationAndOnlyWhileAReplyIsOnItsWay() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        _ = try openThreeMessageThread(harness)
        XCTAssertFalse(harness.reader.followsOutbox, "an idle reader follows nothing")
        ConversationViewController.undoWindow = 0.05
        harness.reader.sendQuickReply("Thanks, sounds good", mode: .reply)
        XCTAssertTrue(harness.reader.followsOutbox)
        harness.spin { harness.reader.liveQuickSend == nil }
        let store = harness.environment.store
        var send = try XCTUnwrap(try store.pendingSends().first)
        XCTAssertTrue(harness.reader.watchedSendIDs.contains(send.id))

        send.status = .failed
        send.lastError = "network"
        try store.updateSend(send)
        XCTAssertTrue(ListTestSupport.spin(until: { harness.reader.watchedSendIDs.isEmpty }, timeout: 0.5),
                      "the failure arrives as the outbox changes, not at the next second's tick")
        XCTAssertEqual(harness.toastMessage, "Couldn\u{2019}t send your reply")
        XCTAssertFalse(harness.reader.followsOutbox, "nothing on its way: the observation ends")
        ComposeDraftStore.shared.waitForWrites()
    }

    func testEscFromTheQuickReplyDismissesAToastFirstThenReturnsToTheList() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        _ = try openThreeMessageThread(harness)
        harness.controller.window?.makeKeyAndOrderFront(nil)
        let bar = harness.reader.quickReplyBar
        bar.focus()
        bar.text = "Half a thought"
        harness.toasts.show("Archived", kind: .confirmation)
        XCTAssertTrue(harness.toasts.isVisible)

        harness.controller.handle(.escapeQuickReply(repeated: false))
        XCTAssertFalse(harness.toasts.isVisible, "the first Esc dismisses the toast")
        harness.controller.handle(.escapeQuickReply(repeated: false))
        XCTAssertTrue(harness.controller.window?.firstResponder is NSTableView, "the second returns focus to the list")
        XCTAssertEqual(bar.text, "Half a thought", "the bar keeps its text")
    }

    func testASendThatFailsAfterItsWindowShowsAnErrorToastAndKeepsTheDraft() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        _ = try openThreeMessageThread(harness)
        // After the window is built: the shell sets the window from the Undo send preference.
        ConversationViewController.undoWindow = 0.05
        harness.reader.sendQuickReply("Thanks, sounds good", mode: .reply)
        harness.spin { harness.reader.liveQuickSend == nil }
        let store = harness.environment.store
        var send = try XCTUnwrap(try store.pendingSends().first)
        XCTAssertTrue(harness.reader.watchedSendIDs.contains(send.id), "the outcome is watched past the window")

        send.status = .failed
        send.lastError = "network"
        try store.updateSend(send)
        harness.reader.pollWatchedSends()
        XCTAssertEqual(harness.toastMessage, "Couldn\u{2019}t send your reply")
        XCTAssertTrue(harness.reader.watchedSendIDs.isEmpty)
        ComposeDraftStore.shared.waitForWrites()
        let accounts = [ListTestSupport.accountA, ListTestSupport.accountB]
        let kept = try XCTUnwrap(ComposeDraftStore.shared.keptDrafts(accounts: accounts).first, "the reply is kept as a draft")
        XCTAssertEqual(kept.body.string, "Thanks, sounds good")
        XCTAssertNotNil(kept.sendFailure, "it opens with the failure banner")
    }
}
