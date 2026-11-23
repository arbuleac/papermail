import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// A send that fails leaves the Outbox for Drafts (spec §5.53): kept once as a draft holding its reason, its outbox row
/// cleared only once that draft is on disk. The undo-send panel or the quick reply that sent it keeps it while it watches
/// the send, and the window's settler (`SendLaterOutbox`) keeps every other: one whose panel or bar let go, one the app quit
/// while handing over, and never one a live owner answers for. The engine never runs here (the outbox is moved by hand,
/// as the send runner would move it), and drafts go to a temporary folder.
@MainActor
final class FailedSendAppTests: XCTestCase {
    private var folder: URL!
    private var savedUndoWindows: (composer: TimeInterval, reader: TimeInterval) = (5, 5)
    private let ben = EmailAddress(name: "Ben Carter", address: "ben@example.com")
    private let interrupted = "interrupted while sending; check Sent before sending again"

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperFailedSend-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            ComposeDraftStore.shared.useDirectory(folder)
            savedUndoWindows = (ComposeWindowController.undoWindow, ConversationViewController.undoWindow)
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            ComposeWindowController.undoWindow = savedUndoWindows.composer
            ConversationViewController.undoWindow = savedUndoWindows.reader
            for panel in ComposeWindowRegistry.shared.livePanels { panel.orderOut(nil); ComposeWindowRegistry.shared.unregister(panel) }
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Helpers

    private func sends(_ harness: MainWindowHarness) -> [PendingSendSummary] {
        (try? harness.environment.store.pendingSendSummaries()) ?? []
    }

    /// The drafts kept on this Mac, once every write queued so far has landed.
    private func kept(_ harness: MainWindowHarness) -> [ComposeDraft] {
        ComposeDraftStore.shared.waitForWrites()
        return ComposeDraftStore.shared.keptDrafts(accounts: [ListTestSupport.accountA, ListTestSupport.accountB])
    }

    private func fail(_ sendID: String, _ lastError: String, _ harness: MainWindowHarness) throws {
        var send = try XCTUnwrap(sends(harness).first { $0.id == sendID })
        send.status = .failed
        send.lastError = lastError
        try harness.environment.store.updateSend(send)
    }

    private func message(_ subject: String = "Lisbon") -> OutgoingMessage {
        OutgoingMessage(accountID: ListTestSupport.accountA.id, to: [ben], subject: subject, html: "<p>See you there</p>", text: "See you there")
    }

    private func newDraft(_ subject: String = "Lisbon") -> ComposeDraft {
        ComposeDraft(id: UUID(), mode: .new, account: ListTestSupport.accountA, to: [ben], cc: [], bcc: [], subject: subject,
                     body: ComposeTextView.plainBody("See you there"), attachments: [], quoted: nil, threading: nil)
    }

    /// thread-2: three messages, the middle one from the user.
    private func openThread(_ harness: MainWindowHarness) throws {
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentMessages.count == 3 }
    }

    /// G O once the window has heard of a send: the Outbox shows only while one waits (§5.2).
    private func showOutbox(_ harness: MainWindowHarness) {
        harness.spin { harness.controller.showsOutbox }
        XCTAssertTrue(harness.controller.perform(.goTo(.outbox)))
        harness.spin { harness.list.query.view == .outbox }
    }

    // MARK: Owned by the sender

    /// A composer's send fails after its undo window: its panel keeps the draft with the reason, under the send's id, and
    /// the row leaves the Outbox once that draft is on disk. The window, which sees the failed row too, leaves it to the
    /// panel while the panel answers for it: one draft, and the panel, not a toast, says so.
    func testAComposerSendThatFailsEndsAsOneDraftWithItsReasonAndNoOutboxRow() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        ComposeWindowController.undoWindow = 0.05
        let composer = ComposeWindowController.present(client: harness.environment.engine, accounts: harness.controller.accounts,
                                                       draft: newDraft())
        composer.send(nil)
        harness.spin { !ComposeWindowRegistry.shared.livePanels.isEmpty }
        let panel = try XCTUnwrap(ComposeWindowRegistry.shared.livePanels.first, "the send was queued")
        let sendID = panel.sendID
        XCTAssertTrue(SendOwnership.isOwned(sendID), "the panel answers for it from the moment it is queued")
        showOutbox(harness)
        harness.spin { harness.list.conversations.count == 1 }

        try fail(sendID, "server(status: 400, message: rejected)", harness)
        // The window looks first, before the panel's next look: the send is the panel's, so it stays as it is.
        harness.controller.sendLaterOutbox.refresh()
        XCTAssertEqual(sends(harness).map(\.id), [sendID], "left to the panel")
        XCTAssertTrue(kept(harness).isEmpty)

        harness.spin { self.sends(harness).isEmpty }
        XCTAssertTrue(sends(harness).isEmpty, "the row leaves once the draft is kept")
        let drafts = kept(harness)
        XCTAssertEqual(drafts.count, 1, "one draft")
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.id, UUID(uuidString: sendID), "kept under the send's id")
        XCTAssertEqual(draft.sendFailure, "Couldn't send: Gmail didn't accept the message.")
        XCTAssertEqual(draft.subject, "Lisbon")
        XCTAssertEqual(draft.body.string, "See you there")
        XCTAssertFalse(SendOwnership.isOwned(sendID), "let go once settled")
        XCTAssertNil(harness.toastMessage, "the panel says it; the window adds no toast")
        harness.spin { harness.list.query.view == .inbox }
        XCTAssertFalse(harness.controller.showsOutbox, "gone from the Outbox, which goes with it")
        XCTAssertEqual(harness.list.query.view, .inbox, "and the window is back in the Inbox")
        XCTAssertTrue(harness.controller.localDrafts.summaries.contains {
            $0.id == LocalDraftConversation.conversationID(draftID: draft.id, account: draft.account.id)
        }, "listed in Drafts")
    }

    /// A quick reply that fails after its window: the reader that watched it keeps the draft with the reason and toasts
    /// “Couldn't send your reply”, and the row leaves the Outbox; the window keeps no second draft.
    func testAQuickReplySendThatFailsEndsAsOneDraftWithItsReasonAndNoOutboxRow() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        try openThread(harness)
        ConversationViewController.undoWindow = 0.05
        harness.reader.sendQuickReply("Thanks, sounds good", mode: .reply, action: .send)
        let sendID = try XCTUnwrap(sends(harness).first?.id)
        XCTAssertTrue(SendOwnership.isOwned(sendID), "the bar answers for it while it counts down")
        harness.spin { harness.reader.liveQuickSend == nil }
        XCTAssertTrue(harness.reader.watchedSendIDs.contains(sendID))
        XCTAssertTrue(SendOwnership.isOwned(sendID), "and the reader once it watches it")

        try fail(sendID, "network: The Internet connection appears to be offline.", harness)
        harness.controller.sendLaterOutbox.refresh()
        XCTAssertEqual(sends(harness).map(\.id), [sendID], "left to the reader")

        harness.spin { self.sends(harness).isEmpty }
        XCTAssertTrue(sends(harness).isEmpty, "the row leaves once the draft is kept")
        XCTAssertEqual(harness.toastMessage, "Couldn\u{2019}t send your reply")
        let drafts = kept(harness)
        XCTAssertEqual(drafts.count, 1, "one draft")
        XCTAssertEqual(drafts.first?.id, UUID(uuidString: sendID))
        XCTAssertEqual(drafts.first?.body.string, "Thanks, sounds good")
        XCTAssertEqual(drafts.first?.sendFailure, "Couldn't send: the connection to Gmail was lost.")
        XCTAssertFalse(SendOwnership.isOwned(sendID))
    }

    /// The hand-off is race-free: a failed row a live panel answers for is never settled by the window, whatever it sees
    /// and in whichever order. It looks while the panel holds it, and again with the word of the outbox from before the
    /// panel cleared the row (an observation delivered late): the panel's draft is the only one, and the window says
    /// nothing.
    func testAFailedRowOwnedByALivePanelIsNotSettledTwice() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let sendID = try harness.environment.engine.send(message(), undoWindow: 600)
        UndoSendPanel.show(client: harness.environment.engine, accounts: harness.controller.accounts, sendID: sendID, draft: newDraft(),
                           undoWindow: 0.3)
        try fail(sendID, "HTTP 400", harness)
        let stale = sends(harness)
        harness.controller.sendLaterOutbox.sendsChanged(stale)
        harness.controller.sendLaterOutbox.refresh()
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(sends(harness).map(\.id), [sendID], "the panel's, until it has kept it")
        XCTAssertTrue(kept(harness).isEmpty)

        harness.spin { self.sends(harness).isEmpty }
        XCTAssertEqual(kept(harness).count, 1, "the panel kept it")
        harness.controller.sendLaterOutbox.sendsChanged(stale)
        harness.controller.sendLaterOutbox.refresh()
        XCTAssertEqual(kept(harness).map(\.id), [UUID(uuidString: sendID)].compactMap { $0 }, "still one draft")
        XCTAssertNil(harness.toastMessage, "and the window said nothing")
    }

    /// Opens thread-2 in a reader window of its own, its messages shown.
    private func openThreadInWindow(_ harness: MainWindowHarness) throws -> ReaderWindowController {
        try openThread(harness)
        harness.controller.openSelectionInNewWindow(nil)
        let reader = try XCTUnwrap(harness.controller.readerWindows.first)
        harness.spin { reader.conversation.currentMessages.count == 3 }
        return reader
    }

    /// A reply from a reader window whose window closes after its countdown: the main window's reader watches it with its
    /// claim (§5.49), so the window's settler leaves it alone, and that reader keeps the one draft when it fails.
    func testAReplyWatchedPastItsReaderWindowIsKeptOnceByTheMainWindowsReader() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let reader = try openThreadInWindow(harness)
        ConversationViewController.undoWindow = 0.05
        reader.conversation.sendQuickReply("Thanks, sounds good", mode: .reply, action: .send)
        let sendID = try XCTUnwrap(sends(harness).first?.id)
        harness.spin { reader.conversation.liveQuickSend == nil }
        reader.close()
        XCTAssertTrue(harness.reader.watchedSendIDs.contains(sendID), "the main window's reader watches it now")
        XCTAssertTrue(SendOwnership.isOwned(sendID), "with its claim")

        try fail(sendID, "HTTP 400", harness)
        harness.controller.sendLaterOutbox.refresh()
        XCTAssertEqual(sends(harness).map(\.id), [sendID], "left to the reader")
        harness.spin { self.sends(harness).isEmpty }
        XCTAssertTrue(sends(harness).isEmpty, "the row leaves once the draft is kept")
        XCTAssertEqual(kept(harness).map(\.id), [UUID(uuidString: sendID)].compactMap { $0 }, "one draft")
        XCTAssertEqual(harness.toastMessage, "Couldn\u{2019}t send your reply")
        XCTAssertFalse(SendOwnership.isOwned(sendID))
    }

    /// A reply from a reader window whose window closes mid-countdown: the countdown moves to an undo-send panel, which
    /// claims the send before the bar lets go, so it is never unowned in between, and the panel keeps the one draft.
    func testAReplyMovedFromItsReaderWindowToAPanelIsKeptOnceByThePanel() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let reader = try openThreadInWindow(harness)
        ConversationViewController.undoWindow = 0.3
        reader.conversation.sendQuickReply("Thanks, sounds good", mode: .reply, action: .send)
        let sendID = try XCTUnwrap(sends(harness).first?.id)
        reader.close()
        XCTAssertNotNil(UndoSendPanel.panel(sendID: sendID), "the countdown went to a panel")
        XCTAssertTrue(SendOwnership.isOwned(sendID), "which answers for it")

        try fail(sendID, "HTTP 400", harness)
        harness.controller.sendLaterOutbox.refresh()
        XCTAssertEqual(sends(harness).map(\.id), [sendID], "left to the panel")
        harness.spin { self.sends(harness).isEmpty }
        XCTAssertTrue(sends(harness).isEmpty, "the row leaves once the draft is kept")
        let drafts = kept(harness)
        XCTAssertEqual(drafts.map(\.id), [UUID(uuidString: sendID)].compactMap { $0 }, "one draft")
        XCTAssertEqual(drafts.first?.body.string.hasPrefix("Thanks, sounds good"), true)
        XCTAssertNil(harness.toastMessage, "the panel says it; the window adds no toast")
        XCTAssertFalse(SendOwnership.isOwned(sendID))
    }

    // MARK: Nobody to keep it

    /// A quick reply whose Undo came too late stops being watched by its bar: when it fails afterwards, the window keeps
    /// it, built from the message as it would have been sent, toasts once with Open draft, and clears the row.
    func testAFailureNobodyWatchesAnyMoreIsKeptByTheWindow() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        try openThread(harness)
        ConversationViewController.undoWindow = 600
        harness.reader.sendQuickReply("Thanks, sounds good", mode: .reply, action: .send)
        var send = try XCTUnwrap(sends(harness).first)
        send.status = .sending
        try harness.environment.store.updateSend(send)
        XCTAssertTrue(harness.reader.cancelQuickSend(), "⌘Z reaches it")
        XCTAssertEqual(sends(harness).map(\.status), [.sending], "too late: already on its way")
        XCTAssertFalse(SendOwnership.isOwned(send.id), "the bar let go")

        try fail(send.id, "HTTP 400", harness)
        harness.spin { self.sends(harness).isEmpty }
        XCTAssertTrue(sends(harness).isEmpty, "the row leaves")
        let drafts = kept(harness)
        XCTAssertEqual(drafts.count, 1)
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.id, UUID(uuidString: send.id))
        XCTAssertEqual(draft.sendFailure, "Couldn't send: Gmail didn't accept the message.")
        XCTAssertTrue(draft.body.string.hasPrefix("Thanks, sounds good"), draft.body.string)
        XCTAssertEqual(harness.toastMessage, "Couldn\u{2019}t send \u{201c}\(send.subject)\u{201d}")
    }

    /// A send the app quit while handing over is failed at the next launch, with nobody to keep it: the window keeps one
    /// draft whose reason says it may have gone and to check Sent, never inviting a blind resend, clears the row and says
    /// so once; looking again keeps no second draft and says nothing more.
    func testASendInterruptedAtLaunchBecomesOneDraftThatSaysToCheckSent() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let send = PendingSend(message: message(), createdAt: Date().addingTimeInterval(-60), sendAfter: Date().addingTimeInterval(-55),
                               status: .failed, attempts: 1, lastError: interrupted)
        try harness.environment.store.enqueueSend(send)
        harness.spin { self.sends(harness).isEmpty }
        XCTAssertTrue(sends(harness).isEmpty, "it leaves the Outbox")
        let drafts = kept(harness)
        XCTAssertEqual(drafts.count, 1, "one draft")
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.id, UUID(uuidString: send.id))
        XCTAssertEqual(draft.sendFailure,
                       "Couldn't send: Paper quit while sending it, so it may have gone. Check Sent before sending it again.")
        XCTAssertEqual(draft.subject, "Lisbon")
        XCTAssertEqual(draft.to.map(\.address), ["ben@example.com"])
        XCTAssertTrue(draft.bodyIsAsSent, "made from the message as it would have gone: its body is marked as that text (§5.56)")
        XCTAssertEqual(harness.toastMessage, "\u{201c}Lisbon\u{201d} may have gone. Check Sent.")
        // Kept in Drafts: nothing waits to go, so no Outbox shows (it may have, for the moment before it was kept).
        harness.spin { !harness.controller.showsOutbox }
        XCTAssertFalse(harness.controller.showsOutbox)
        XCTAssertTrue(harness.controller.strip.folderTiles[5].isHidden)

        harness.toasts.dismiss()
        harness.controller.sendLaterOutbox.refresh()
        XCTAssertEqual(kept(harness).count, 1, "no second draft")
        XCTAssertNil(harness.toastMessage, "told once")
    }

    /// At launch the window may not have read its accounts when the outbox is first seen: the failed row waits, listed,
    /// until it has, and is then kept as above.
    func testAFailedRowWaitsForItsAccountToBeRead() throws {
        let harness = try MainWindowHarness(accounts: false)
        defer { harness.close() }
        // In the store, not yet read by the window.
        try harness.environment.store.upsertAccount(ListTestSupport.accountA)
        XCTAssertTrue(harness.controller.accounts.isEmpty)
        let send = PendingSend(message: message(), sendAfter: Date().addingTimeInterval(-55), status: .failed, attempts: 1,
                               lastError: interrupted)
        try harness.environment.store.enqueueSend(send)
        harness.controller.sendLaterOutbox.refresh()
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(sends(harness).map(\.id), [send.id], "no account to keep it under yet")
        XCTAssertTrue(kept(harness).isEmpty)

        harness.controller.refreshAccounts()
        harness.spin { self.sends(harness).isEmpty }
        XCTAssertTrue(sends(harness).isEmpty)
        XCTAssertEqual(kept(harness).map(\.id), [UUID(uuidString: send.id)].compactMap { $0 })
    }

    /// The demo keeps its failed sends among its own drafts, as the user's window does among theirs.
    func testTheDemoKeepsAFailedSendToo() throws {
        let harness = try MainWindowHarness(demo: true)
        defer { harness.close() }
        let send = PendingSend(message: message(), sendAfter: Date().addingTimeInterval(-55), status: .failed, attempts: 1,
                               lastError: "HTTP 400")
        try harness.environment.store.enqueueSend(send)
        harness.spin { self.sends(harness).isEmpty }
        XCTAssertTrue(sends(harness).isEmpty)
        XCTAssertEqual(kept(harness).count, 1)
        XCTAssertEqual(harness.toastMessage, "Couldn\u{2019}t send \u{201c}Lisbon\u{201d}")
    }

    /// A window that is going (its mailbox replaced by the demo, or the demo left) keeps no more failed sends: by then the
    /// draft store may be the other mailbox's, where the draft would be lost, so the row waits for its own mailbox.
    func testAWindowThatIsGoingKeepsNothing() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.controller.sendLaterOutbox.stop()
        let send = PendingSend(message: message(), sendAfter: Date().addingTimeInterval(-55), status: .failed, attempts: 1,
                               lastError: "HTTP 400")
        try harness.environment.store.enqueueSend(send)
        harness.controller.sendLaterOutbox.refresh()
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(sends(harness).map(\.id), [send.id])
        XCTAssertTrue(kept(harness).isEmpty)
    }
}
