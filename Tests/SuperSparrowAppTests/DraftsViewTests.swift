import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// Drafts kept on this Mac in the Drafts view (spec §5.19): listed beside the provider's drafts, shown
/// read-only, reopened as they were by Continue Editing, discarded with Undo, and removed with their account.
/// The shared draft store points at a temporary folder for these tests, never the user's drafts.
@MainActor
final class DraftsViewTests: XCTestCase {
    private var folder: URL!
    private let ben = EmailAddress(name: "Ben Carter", address: "ben@example.com")

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowDrafts-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder) }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    @discardableResult
    private func keep(_ subject: String, body: String = "See you in Lisbon", continues: MessageID? = nil) -> ComposeDraft {
        let draft = ComposeDraft(id: UUID(), mode: .new, account: ListTestSupport.accountA, to: [ben], cc: [], bcc: [], subject: subject,
                                 body: NSAttributedString(string: body), attachments: [], quoted: nil, threading: nil,
                                 continuesDraft: continues)
        ComposeDraftStore.shared.saveNow(draft)
        return draft
    }

    private func rowID(_ draft: ComposeDraft) -> ConversationID {
        LocalDraftConversation.conversationID(draftID: draft.id, account: draft.account.id)
    }

    private func select(_ id: ConversationID, in harness: MainWindowHarness) {
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
    }

    func testTheDraftsViewListsKeptDraftsAndTheReaderShowsThem() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = keep("Lisbon plans")
        let id = rowID(draft)
        XCTAssertTrue(harness.controller.perform(.goTo(.drafts)))
        harness.spin { harness.list.conversations.contains { $0.id == id } }
        let row = try XCTUnwrap(harness.list.conversations.first { $0.id == id })
        XCTAssertEqual(row.snippet, "See you in Lisbon")
        select(id, in: harness)
        XCTAssertEqual(harness.reader.selection, .one(id))
        XCTAssertEqual(harness.reader.currentMessages.map(\.subject), ["Lisbon plans"])
        XCTAssertEqual(harness.reader.currentMessages.first?.to, [ben])
        // Inbox never lists it.
        XCTAssertTrue(harness.controller.perform(.goTo(.inbox)))
        XCTAssertFalse(harness.list.conversations.contains { $0.id == id })
        // A draft saved while Drafts is open appears in it.
        XCTAssertTrue(harness.controller.perform(.goTo(.drafts)))
        let later = keep("Later")
        harness.spin { harness.list.conversations.contains { $0.id == self.rowID(later) } }
        // Records keep their edit time to the second, so two drafts saved together may list either way round;
        // both lead the provider's older drafts and mail.
        XCTAssertEqual(Set(harness.list.conversations.prefix(2).map(\.id)), [id, rowID(later)])
    }

    func testContinueEditingReopensTheKeptDraftOnceAndTheReaderSaysItIsOpen() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = keep("Lisbon plans")
        let id = rowID(draft)
        XCTAssertTrue(harness.controller.perform(.goTo(.drafts)))
        harness.spin { harness.list.conversations.contains { $0.id == id } }
        select(id, in: harness)
        let message = LocalDraftConversation.messageID(draftID: draft.id, account: draft.account.id)
        XCTAssertFalse(harness.reader.isDraftInComposer(message))
        XCTAssertTrue(harness.controller.perform(.open), "↩ is Continue Editing in Drafts")
        let composer = try XCTUnwrap(ComposeWindowRegistry.shared.controller(holdingDraft: message))
        XCTAssertEqual(composer.draftID, draft.id, "the kept draft itself, so sending it leaves nothing behind")
        XCTAssertTrue(harness.reader.isDraftInComposer(message), "the sheet reads “Open in a composer window”")
        XCTAssertTrue(harness.controller.perform(.open))
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.filter { $0.draftID == draft.id }.count, 1, "never a second composer")
    }

    func testDiscardingAKeptDraftOffersUndo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = keep("Lisbon plans")
        harness.controller.discardDrafts([rowID(draft)])
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertFalse(ComposeDraftStore.shared.contains(id: draft.id))
        XCTAssertEqual(harness.toastMessage, "Draft discarded")
        XCTAssertTrue(harness.controller.perform(.undo))
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: draft.id), "Undo brings the draft back")
    }

    func testAProviderDraftIsContinuedByOneKeptDraftWhichStandsInForIt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let account = ListTestSupport.accountA
        let thread = ConversationID(accountID: account.id, providerID: "server-draft-thread")
        let serverDraft = MessageMetadata(id: MessageID(accountID: account.id, providerID: "server-draft"), conversationID: thread,
                                          subject: "From Gmail", snippet: "Started on the web", from: EmailAddress(address: account.email),
                                          to: [ben], date: Date(), roles: [.drafts], isRead: true, isStarred: false, hasAttachments: false)
        try harness.environment.store.upsertMessages([serverDraft])
        XCTAssertTrue(harness.controller.perform(.goTo(.drafts)))
        harness.spin { harness.list.conversations.contains { $0.id == thread } }
        // Continue Editing opens a composer that remembers the provider's draft; again, the same one comes forward.
        XCTAssertTrue(DraftReopener.present(serverDraft.id, client: harness.environment.engine, accounts: harness.controller.accounts))
        let composer = try XCTUnwrap(ComposeWindowRegistry.shared.controller(holdingDraft: serverDraft.id))
        XCTAssertEqual(composer.continuesDraft, serverDraft.id)
        XCTAssertTrue(DraftReopener.present(serverDraft.id, client: harness.environment.engine, accounts: harness.controller.accounts))
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.count, 1)
        composer.closeWithoutSaving()
        // Once kept, the kept draft reopens and stands in for the provider's row in Drafts.
        let kept = keep("From Gmail", body: "Finished here", continues: serverDraft.id)
        harness.spin { harness.list.conversations.contains { $0.id == self.rowID(kept) } }
        XCTAssertFalse(harness.list.conversations.contains { $0.id == thread })
        XCTAssertTrue(DraftReopener.present(serverDraft.id, client: harness.environment.engine, accounts: harness.controller.accounts))
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.first?.draftID, kept.id)
    }

    func testRemovingAnAccountTakesItsDrafts() throws {
        let draft = keep("Lisbon plans")
        let composer = ComposeWindowController.present(client: try MainWindowHarness.scratchClient(in: folder), accounts: [draft.account],
                                                       draft: draft)
        XCTAssertTrue(ComposeWindowRegistry.shared.openControllers.contains { $0 === composer })
        AppDelegate.removeDrafts(of: draft.account.id)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertFalse(ComposeWindowRegistry.shared.openControllers.contains { $0 === composer }, "its composers close")
        XCTAssertFalse(ComposeDraftStore.shared.contains(id: draft.id), "closing kept nothing, and the folder is gone")
    }
}
