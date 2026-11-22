import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// Rows dragged onto the rail's folders (spec §5.2): Inbox moves them to the inbox, Trash trashes, Starred stars
/// and All Mail archives, through the keys' path (store first, queued, the same toast and undo); Sent, Drafts and
/// the account tiles take nothing, nor does a drop that would change nothing or a drag from outside the app.
/// The rail is the one drag destination in it, and the drags here go to it at a point in the window, as
/// AppKit's do, so which folder a point lands on is tested too.
@MainActor
final class RailFolderDropTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for pasteboard in pasteboards { pasteboard.releaseGlobally() }
            pasteboards = []
        }
        super.tearDown()
    }

    // MARK: Helpers

    /// A drag of `ids` as the list writes it: one pasteboard item per row from the list's own writer, on a
    /// private pasteboard, with the table as its source.
    private func dragOfRows(_ ids: [ConversationID], in harness: MainWindowHarness,
                            mask: NSDragOperation = [.copy, .move]) throws -> FakeDraggingInfo {
        let list = harness.list
        var items: [NSPasteboardWriting] = []
        for id in ids {
            let index = try XCTUnwrap(list.conversations.firstIndex { $0.id == id }, "the dragged row is in the list")
            let row = try XCTUnwrap(list.layout.row(ofConversation: index))
            items.append(try XCTUnwrap(list.tableView(list.tableView, pasteboardWriterForRow: row)))
        }
        let pasteboard = privatePasteboard()
        pasteboard.writeObjects(items)
        return FakeDraggingInfo(pasteboard: pasteboard, source: list.tableView, mask: mask)
    }

    private func privatePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private func tile(_ view: MailboxView, in harness: MainWindowHarness) throws -> AccountStripButton {
        let index = try XCTUnwrap(TitleMenu.entries.firstIndex { $0.view == view })
        return harness.controller.strip.folderTiles[index]
    }

    /// The rail, laid out: the view AppKit hands a drag over it to.
    private func rail(in harness: MainWindowHarness) -> NSView {
        let rail = harness.controller.strip.view
        rail.layoutSubtreeIfNeeded()
        return rail
    }

    /// Points `info` at `point` in `tile`'s coordinates (the tile's centre by default), in the window's
    /// coordinates as AppKit gives a drag's location.
    private func aim(_ info: FakeDraggingInfo, at tile: AccountStripButton, _ point: NSPoint? = nil) {
        info.draggingLocation = tile.convert(point ?? NSPoint(x: tile.tileRect.midX, y: tile.tileRect.midY), to: nil)
    }

    /// Enters the rail with `info` over `tile` (at `point` in its coordinates, its centre by default) and drops
    /// it there if the rail took it, as AppKit does; returns the operation answered and whether the drop went
    /// through.
    @discardableResult
    private func drop(_ info: FakeDraggingInfo, on tile: AccountStripButton, at point: NSPoint? = nil,
                      in harness: MainWindowHarness) -> (operation: NSDragOperation, dropped: Bool) {
        let rail = rail(in: harness)
        aim(info, at: tile, point)
        let operation = rail.draggingEntered(info)
        guard !operation.isEmpty, !rail.draggingUpdated(info).isEmpty else {
            rail.draggingExited(info)
            return (operation, false)
        }
        let dropped = rail.performDragOperation(info)
        rail.draggingEnded(info)
        return (operation, dropped)
    }

    /// What the rail answers a drag entering it over `tile`; the drag then leaves.
    private func operation(entering info: FakeDraggingInfo, over tile: AccountStripButton, in harness: MainWindowHarness) -> NSDragOperation {
        let rail = rail(in: harness)
        aim(info, at: tile)
        defer { rail.draggingExited(info) }
        return rail.draggingEntered(info)
    }

    /// Every view in the rail registered for the rows' type.
    private func dropDestinations(in view: NSView) -> [NSView] {
        let mine = view.registeredDraggedTypes.contains(MessageListViewController.conversationPasteboardType) ? [view] : []
        return mine + view.subviews.flatMap(dropDestinations(in:))
    }

    private func operations(in harness: MainWindowHarness) throws -> [PaperCore.Operation] {
        let store = harness.environment.store
        return try [ListTestSupport.accountA.id, ListTestSupport.accountB.id].flatMap { try store.pendingOperations(accountID: $0, limit: 100) }
    }

    private func messages(of id: ConversationID, in harness: MainWindowHarness) throws -> [MessageMetadata] {
        try harness.environment.store.messages(in: id)
    }

    /// Every message of `ids` is covered by a queued operation making `change`.
    private func assertQueued(_ change: MetadataChange, for ids: [ConversationID], in harness: MainWindowHarness,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let queued = Set(try operations(in: harness).filter { $0.change == change }.flatMap(\.targets))
        let wanted = Set(try ids.flatMap { try messages(of: $0, in: harness) }.map(\.id))
        XCTAssertFalse(wanted.isEmpty, file: file, line: line)
        XCTAssertTrue(wanted.isSubset(of: queued), "every dragged message is queued for \(change)", file: file, line: line)
    }

    private func goTo(_ view: MailboxView, in harness: MainWindowHarness, until rows: @escaping () -> Bool) {
        XCTAssertTrue(harness.controller.perform(.goTo(view)))
        harness.spin { harness.list.query.view == view && rows() }
    }

    // MARK: The four folders

    func testAllMailArchivesTheDroppedRows() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        let allMail = try tile(.all, in: harness)
        let (operation, dropped) = drop(try dragOfRows([id], in: harness), on: allMail, in: harness)
        XCTAssertEqual(operation, .move)
        XCTAssertTrue(dropped)
        XCTAssertFalse(try messages(of: id, in: harness).contains { $0.roles.contains(.inbox) }, "archived in the store at once")
        try assertQueued(.archive, for: [id], in: harness)
        XCTAssertEqual(harness.toastMessage, "Archived", "E's toast")
        harness.spin { !harness.list.conversations.contains { $0.id == id } }
        XCTAssertFalse(harness.list.conversations.contains { $0.id == id }, "the row leaves the Inbox")
        XCTAssertFalse(allMail.isDropTarget, "the highlight goes with the drag")
    }

    func testTrashTrashesTheDroppedRows() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[2].id
        XCTAssertTrue(drop(try dragOfRows([id], in: harness), on: try tile(.trash, in: harness), in: harness).dropped)
        XCTAssertTrue(try messages(of: id, in: harness).allSatisfy { $0.roles.contains(.trash) })
        try assertQueued(.trash, for: [id], in: harness)
        XCTAssertEqual(harness.toastMessage, "Moved to Trash", "#'s toast")
    }

    func testStarredStarsTheDroppedRows() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        // Thread 1 is not starred (every fifth is).
        let row = harness.list.conversations[1]
        XCTAssertFalse(row.isStarred)
        XCTAssertTrue(drop(try dragOfRows([row.id], in: harness), on: try tile(.starred, in: harness), in: harness).dropped)
        XCTAssertTrue(try messages(of: row.id, in: harness).allSatisfy(\.isStarred))
        try assertQueued(.setStarred(true), for: [row.id], in: harness)
        XCTAssertNil(harness.toastMessage, "as with S, one starred row shows the change itself")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Star", "Z still reaches it")
        harness.spin { harness.list.conversations.first { $0.id == row.id }?.isStarred == true }
        XCTAssertEqual(harness.list.conversations.first { $0.id == row.id }?.isStarred, true, "the row stays in the Inbox, starred")
    }

    func testInboxMovesTrashedRowsBackToTheInbox() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[3].id
        XCTAssertTrue(harness.controller.drop([id], onto: .trash))
        goTo(.trash, in: harness) { harness.list.conversations.contains { $0.id == id } }
        let inbox = try tile(.inbox, in: harness)
        XCTAssertTrue(drop(try dragOfRows([id], in: harness), on: inbox, in: harness).dropped)
        let restored = try messages(of: id, in: harness)
        XCTAssertTrue(restored.allSatisfy { $0.roles.contains(.inbox) && !$0.roles.contains(.trash) })
        try assertQueued(.moveToInbox, for: [id], in: harness)
        XCTAssertEqual(harness.toastMessage, "Moved to Inbox", "⇧I's toast in the Trash")
    }

    func testSeveralDraggedRowsAreOneActionWithOneToast() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let ids = Array(harness.list.conversations[1...3].map(\.id))
        XCTAssertTrue(drop(try dragOfRows(ids, in: harness), on: try tile(.all, in: harness), in: harness).dropped)
        for id in ids {
            XCTAssertFalse(try messages(of: id, in: harness).contains { $0.roles.contains(.inbox) })
        }
        try assertQueued(.archive, for: ids, in: harness)
        XCTAssertEqual(harness.toastMessage, "Archived 3 conversations")
        harness.spin { !harness.list.conversations.contains { ids.contains($0.id) } }
        XCTAssertFalse(harness.list.conversations.contains { ids.contains($0.id) })
    }

    func testUndoBringsDroppedRowsBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let ids = Array(harness.list.conversations[0...1].map(\.id))
        XCTAssertTrue(drop(try dragOfRows(ids, in: harness), on: try tile(.trash, in: harness), in: harness).dropped)
        harness.spin { !harness.list.conversations.contains { ids.contains($0.id) } }
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Move to Trash")
        XCTAssertTrue(harness.controller.perform(.undo))
        harness.spin { ids.allSatisfy { id in harness.list.conversations.contains { $0.id == id } } }
        for id in ids {
            XCTAssertTrue(try messages(of: id, in: harness).allSatisfy { $0.roles.contains(.inbox) && !$0.roles.contains(.trash) })
        }
        XCTAssertEqual(harness.toastMessage, "Undid Move to Trash")
        XCTAssertEqual(harness.list.selectedConversationIDs, ids, "the rows come back selected, as after #")
    }

    // MARK: What is refused

    func testSentDraftsAndTheAccountTilesTakeNothing() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let strip = harness.controller.strip
        let id = harness.list.conversations[1].id
        var refusing = [try tile(.sent, in: harness), try tile(.drafts, in: harness)]
        refusing += try [AccountScope.unified, .account(ListTestSupport.accountA.id), .account(ListTestSupport.accountB.id)]
            .map { try XCTUnwrap(strip.tile(for: $0)) }
        for tile in refusing {
            let (operation, dropped) = drop(try dragOfRows([id], in: harness), on: tile, in: harness)
            XCTAssertEqual(operation, [])
            XCTAssertFalse(dropped)
            XCTAssertFalse(tile.isDropTarget)
        }
        XCTAssertTrue(try messages(of: id, in: harness).allSatisfy { $0.roles == [.inbox] }, "nothing changed")
        XCTAssertTrue(try operations(in: harness).isEmpty, "nothing queued")
    }

    /// A tile refuses a drop that would change nothing the list shows: no highlight, no operation, no change.
    func testADropThatWouldChangeNothingIsRefused() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let inboxRow = harness.list.conversations[1].id
        let starredRow = harness.list.conversations[0]
        XCTAssertTrue(starredRow.isStarred)

        func assertRefused(_ ids: [ConversationID], onto view: MailboxView, _ message: String) throws {
            let target = try tile(view, in: harness)
            let (operation, dropped) = drop(try dragOfRows(ids, in: harness), on: target, in: harness)
            XCTAssertEqual(operation, [], message)
            XCTAssertFalse(dropped, message)
            XCTAssertFalse(target.isDropTarget, message)
            XCTAssertFalse(harness.controller.drop(ids, onto: view), "the window refuses it too: " + message)
        }
        try assertRefused([inboxRow], onto: .inbox, "Inbox rows onto Inbox while viewing Inbox")
        try assertRefused([starredRow.id], onto: .starred, "a starred row onto Starred")
        XCTAssertTrue(try operations(in: harness).isEmpty)
        XCTAssertNil(harness.toastMessage)

        XCTAssertTrue(harness.controller.drop([inboxRow], onto: .trash))
        goTo(.trash, in: harness) { harness.list.conversations.contains { $0.id == inboxRow } }
        let queued = try operations(in: harness).count
        try assertRefused([inboxRow], onto: .trash, "Trash rows onto Trash while viewing Trash")
        try assertRefused([inboxRow], onto: .all, "archiving a trashed row leaves it as it is")
        XCTAssertEqual(try operations(in: harness).count, queued, "nothing more queued")
        XCTAssertTrue(try messages(of: inboxRow, in: harness).allSatisfy { $0.roles.contains(.trash) })
    }

    /// Files, text and anything else from outside the app are refused, and so are rows from another app.
    func testADragFromOutsideTheListIsRefused() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        let trash = try tile(.trash, in: harness)

        let text = privatePasteboard()
        text.setString("Project update", forType: .string)
        let file = privatePasteboard()
        file.writeObjects([FileManager.default.temporaryDirectory as NSURL])
        let rows = try dragOfRows([id], in: harness)
        let drags = [
            FakeDraggingInfo(pasteboard: text, source: nil, mask: [.copy, .move]),
            FakeDraggingInfo(pasteboard: file, source: nil, mask: [.copy, .move]),
            FakeDraggingInfo(pasteboard: text, source: harness.list.tableView, mask: [.copy, .move]),
            // The rows' type, but from another app (another copy of Paper), so not this store's mail.
            FakeDraggingInfo(pasteboard: rows.draggingPasteboard, source: nil, mask: [.copy, .move]),
        ]
        for info in drags {
            let (operation, dropped) = drop(info, on: trash, in: harness)
            XCTAssertEqual(operation, [])
            XCTAssertFalse(dropped)
            XCTAssertFalse(trash.isDropTarget)
        }
        XCTAssertTrue(try messages(of: id, in: harness).allSatisfy { !$0.roles.contains(.trash) })
        XCTAssertTrue(try operations(in: harness).isEmpty)
    }

    func testKeptDraftsGoOnlyToTrash() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperDrafts-\(UUID().uuidString)")
        ComposeDraftStore.shared.useDirectory(folder)
        defer {
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
            try? FileManager.default.removeItem(at: folder)
        }
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let draft = ComposeDraft(id: UUID(), mode: .new, account: ListTestSupport.accountA, to: [], cc: [], bcc: [], subject: "Lisbon",
                                 body: NSAttributedString(string: "See you there"), attachments: [], quoted: nil, threading: nil,
                                 continuesDraft: nil)
        ComposeDraftStore.shared.saveNow(draft)
        let id = LocalDraftConversation.conversationID(draftID: draft.id, account: draft.account.id)
        goTo(.drafts, in: harness) { harness.list.conversations.contains { $0.id == id } }
        for view in [MailboxView.inbox, .starred, .all] {
            XCTAssertEqual(operation(entering: try dragOfRows([id], in: harness), over: try tile(view, in: harness), in: harness), [],
                           "a draft kept on this Mac is not mail in the store")
        }
        // Trash takes it as Discard Draft…, which asks first (# in Drafts); the alert itself is §5.33's.
        XCTAssertTrue(harness.controller.acceptsDrop(of: [id], onto: .trash))
    }

    // MARK: The highlight

    /// The tile under a drag it takes draws its pressed wash, without taking focus; leaving clears it.
    func testATileUnderADragItTakesShowsThePressedWash() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        let rail = rail(in: harness)
        let allMail = try tile(.all, in: harness)
        let responder = window.firstResponder

        /// A point inside the 44 pt hit square but outside the 38 pt tile, where only a wash draws.
        func washPixel() -> NSColor? {
            allMail.appearance = NSAppearance(named: .aqua)
            guard let rep = allMail.bitmapImageRepForCachingDisplay(in: allMail.bounds) else { return nil }
            allMail.cacheDisplay(in: allMail.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / allMail.bounds.width
            return rep.colorAt(x: Int((allMail.tileRect.minX - 1.5) * scale), y: Int(allMail.tileRect.midY * scale))
        }
        let rest = try XCTUnwrap(washPixel())
        XCTAssertLessThan(rest.alphaComponent, 0.01, "nothing beside the tile at rest")

        let info = try dragOfRows([harness.list.conversations[1].id], in: harness)
        aim(info, at: allMail)
        XCTAssertEqual(rail.draggingEntered(info), .move)
        XCTAssertTrue(allMail.isDropTarget)
        let lit = try XCTUnwrap(washPixel())
        XCTAssertGreaterThan(lit.alphaComponent, 0.01, "the pressed wash under the drag")
        XCTAssertTrue(window.firstResponder === responder, "the tile never takes focus for a drag")
        XCTAssertEqual(harness.list.query.view, .inbox, "hovering does not switch the view")

        rail.draggingExited(info)
        XCTAssertFalse(allMail.isDropTarget, "leaving clears it")
        XCTAssertEqual(try XCTUnwrap(washPixel()).alphaComponent, 0, accuracy: 0.01)
        allMail.displayState = .pressed
        let pressed = try XCTUnwrap(washPixel())
        allMail.displayState = nil
        XCTAssertEqual(lit, pressed, "the same wash a click draws")

        // ⌥ narrows the list's mask to a copy; the drop does the same.
        XCTAssertEqual(operation(entering: try dragOfRows([harness.list.conversations[1].id], in: harness, mask: .copy), over: allMail,
                                 in: harness), .copy)
    }

    /// Pressing or releasing a modifier over a still pointer changes the list's mask, and AppKit asks again:
    /// the answer follows the mask then, not the one the drag entered with.
    func testTheOperationFollowsModifiersPressedOverTheFolder() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let rail = rail(in: harness)
        let allMail = try tile(.all, in: harness)
        let info = try dragOfRows([harness.list.conversations[1].id], in: harness)
        aim(info, at: allMail)
        XCTAssertEqual(rail.draggingEntered(info), .move)
        info.draggingSourceOperationMask = .copy
        XCTAssertEqual(rail.draggingUpdated(info), .copy, "⌥ held: the cursor shows a copy")
        XCTAssertTrue(allMail.isDropTarget)
        info.draggingSourceOperationMask = []
        XCTAssertEqual(rail.draggingUpdated(info), [], "⌘ held: the list allows nothing")
        XCTAssertFalse(allMail.isDropTarget, "and the folder goes dark")
        info.draggingSourceOperationMask = [.copy, .move]
        XCTAssertEqual(rail.draggingUpdated(info), .move, "released: a move again")
        XCTAssertTrue(allMail.isDropTarget)
        rail.draggingExited(info)
    }

    // MARK: Where a drag lands

    /// AppKit hands a drag to a view by its frame, never through `hitTest`, and a folder's full-width frame
    /// overlaps its neighbours' by 10 pt: only the rail is registered, and it routes by the hit square.
    func testOnlyTheRailIsADragDestination() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let rail = rail(in: harness)
        XCTAssertEqual(dropDestinations(in: rail), [rail], "no tile is registered for the rows on its own")
    }

    /// A drag goes to the folder whose 44 pt hit square holds it, as a click does, even where the next folder's
    /// frame lies over that square's rim.
    func testADragLandsOnTheFolderWhoseHitSquareHoldsIt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let rail = rail(in: harness)
        let unstarred = harness.list.conversations[1].id
        let starred = try tile(.starred, in: harness)
        let trash = try tile(.trash, in: harness)

        /// `point` in `tile`'s coordinates lies in `neighbour`'s frame too, which would take the drag there.
        func assertOverlaps(_ tile: AccountStripButton, _ point: NSPoint, _ neighbour: AccountStripButton, _ message: String) {
            XCTAssertTrue(neighbour.frame.contains(rail.convert(tile.convert(point, to: nil), from: nil)), message)
        }

        // The rim of Sent's square under Starred's frame: Sent takes nothing, and Starred is not asked.
        let sent = try tile(.sent, in: harness)
        let sentTop = NSPoint(x: sent.tileRect.midX, y: sent.hitRect.minY + 1)
        assertOverlaps(sent, sentTop, starred, "Starred's frame reaches over Sent's square")
        XCTAssertEqual(drop(try dragOfRows([unstarred], in: harness), on: sent, at: sentTop, in: harness).operation, [])
        XCTAssertFalse(starred.isDropTarget)

        // The rim of Drafts' square under Trash's frame: nothing is trashed.
        let drafts = try tile(.drafts, in: harness)
        let draftsFoot = NSPoint(x: drafts.tileRect.midX, y: drafts.hitRect.maxY - 1)
        assertOverlaps(drafts, draftsFoot, trash, "Trash's frame reaches over Drafts' square")
        XCTAssertEqual(drop(try dragOfRows([unstarred], in: harness), on: drafts, at: draftsFoot, in: harness).operation, [])
        XCTAssertFalse(trash.isDropTarget)

        // Beside All Mail's square, still in its frame: nothing is archived.
        let allMail = try tile(.all, in: harness)
        let beside = NSPoint(x: allMail.hitRect.minX - 1, y: allMail.tileRect.midY)
        XCTAssertTrue(allMail.bounds.contains(beside))
        XCTAssertEqual(drop(try dragOfRows([unstarred], in: harness), on: allMail, at: beside, in: harness).operation, [])
        XCTAssertTrue(try operations(in: harness).isEmpty, "nothing starred, trashed or archived")

        // The rim of Inbox's square under Starred's frame, where both would take a trashed, unstarred row: Inbox.
        XCTAssertTrue(harness.controller.drop([unstarred], onto: .trash))
        goTo(.trash, in: harness) { harness.list.conversations.contains { $0.id == unstarred } }
        let inbox = try tile(.inbox, in: harness)
        let inboxFoot = NSPoint(x: inbox.tileRect.midX, y: inbox.hitRect.maxY - 1)
        assertOverlaps(inbox, inboxFoot, starred, "Starred's frame reaches over Inbox's square")
        XCTAssertTrue(drop(try dragOfRows([unstarred], in: harness), on: inbox, at: inboxFoot, in: harness).dropped)
        let moved = try messages(of: unstarred, in: harness)
        XCTAssertTrue(moved.allSatisfy { $0.roles.contains(.inbox) }, "moved to the Inbox")
        XCTAssertFalse(moved.contains(where: \.isStarred), "not starred")
    }

    /// One drag moving down the rail lights each folder that takes it in turn, and nothing between them.
    func testTheHighlightFollowsTheDragFromFolderToFolder() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let rail = rail(in: harness)
        let starred = try tile(.starred, in: harness)
        let trash = try tile(.trash, in: harness)
        let allMail = try tile(.all, in: harness)
        let info = try dragOfRows([harness.list.conversations[1].id], in: harness)

        aim(info, at: starred)
        XCTAssertEqual(rail.draggingEntered(info), .move)
        XCTAssertTrue(starred.isDropTarget)
        aim(info, at: trash)
        XCTAssertEqual(rail.draggingUpdated(info), .move)
        XCTAssertFalse(starred.isDropTarget)
        XCTAssertTrue(trash.isDropTarget)
        // The gap under Trash's square, above All Mail's (the folders' hairline).
        aim(info, at: trash, NSPoint(x: trash.tileRect.midX, y: trash.hitRect.maxY + 1))
        XCTAssertFalse(allMail.hitRect.contains(allMail.convert(info.draggingLocation, from: nil)))
        XCTAssertEqual(rail.draggingUpdated(info), [])
        XCTAssertFalse(trash.isDropTarget)
        XCTAssertFalse(allMail.isDropTarget)
        aim(info, at: allMail)
        XCTAssertEqual(rail.draggingUpdated(info), .move)
        XCTAssertTrue(allMail.isDropTarget)
        rail.draggingExited(info)
        XCTAssertFalse(allMail.isDropTarget)
    }

    // MARK: During a search

    /// A search lists mail from every view under the selected folder, so that folder takes results it would
    /// change, as S acts on them.
    func testDuringASearchTheSelectedFolderTakesResultsItWouldChange() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        goTo(.starred, in: harness) { !harness.list.conversations.isEmpty }
        harness.controller.listPane.header.search.query = "Project"
        harness.controller.listPane.header.search.onQueryChange?("Project")
        harness.spin { harness.list.query.searchText == "Project" && harness.list.conversations.contains { !$0.isStarred } }
        let result = try XCTUnwrap(harness.list.conversations.first { !$0.isStarred })
        let starredRow = try XCTUnwrap(harness.list.conversations.first(where: \.isStarred))

        XCTAssertEqual(drop(try dragOfRows([starredRow.id], in: harness), on: try tile(.starred, in: harness), in: harness).operation, [],
                       "a starred result is left as it is")
        XCTAssertTrue(drop(try dragOfRows([result.id], in: harness), on: try tile(.starred, in: harness), in: harness).dropped)
        XCTAssertTrue(try messages(of: result.id, in: harness).allSatisfy(\.isStarred), "S would star it too")
        try assertQueued(.setStarred(true), for: [result.id], in: harness)
    }

    private func search(_ text: String, in harness: MainWindowHarness) {
        harness.controller.listPane.header.search.query = text
        harness.controller.listPane.header.search.onQueryChange?(text)
        harness.spin { harness.list.query.searchText == text }
    }

    /// Drops treat results as rows of the view searched, as # does (§5.12): with the rail on the Inbox, `in:trash`
    /// results are rows of the Trash, so the Trash refuses them (# leaves them be) and the Inbox restores them (⇧I).
    func testTheTrashRefusesInTrashResultsWhateverTheRailShows() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        XCTAssertTrue(harness.controller.drop([id], onto: .trash))
        search("in:trash", in: harness)
        harness.spin { harness.list.query.view == .trash && harness.list.conversations.contains { $0.id == id } }
        XCTAssertEqual(harness.controller.strip.mailboxView, .inbox, "the rail stays on the Inbox")
        let queued = try operations(in: harness).count

        let trash = try tile(.trash, in: harness)
        let (operation, dropped) = drop(try dragOfRows([id], in: harness), on: trash, in: harness)
        XCTAssertEqual(operation, [], "no highlight for rows already in the Trash")
        XCTAssertFalse(dropped)
        XCTAssertFalse(trash.isDropTarget)
        XCTAssertFalse(harness.controller.drop([id], onto: .trash))
        XCTAssertEqual(try operations(in: harness).count, queued, "nothing queued")

        XCTAssertTrue(drop(try dragOfRows([id], in: harness), on: try tile(.inbox, in: harness), in: harness).dropped)
        XCTAssertTrue(try messages(of: id, in: harness).allSatisfy { $0.roles.contains(.inbox) && !$0.roles.contains(.trash) })
        XCTAssertEqual(harness.toastMessage, "Moved to Inbox", "⇧I's toast in the Trash")
    }

    /// From the Trash a search lists All Mail, whose results # trashes; the Trash takes them too.
    func testTheTrashTakesASearchsResultsFromTheTrash() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        goTo(.trash, in: harness) { true }
        search("Project", in: harness)
        harness.spin { harness.list.query.view == .all && !harness.list.conversations.isEmpty }
        let id = try XCTUnwrap(harness.list.conversations.first?.id)

        XCTAssertTrue(drop(try dragOfRows([id], in: harness), on: try tile(.trash, in: harness), in: harness).dropped)
        XCTAssertTrue(try messages(of: id, in: harness).allSatisfy { $0.roles.contains(.trash) })
        try assertQueued(.trash, for: [id], in: harness)
        XCTAssertEqual(harness.toastMessage, "Moved to Trash", "#'s toast")
    }
}

/// A drag as AppKit hands it to a destination, carrying what a test puts on its pasteboard. Not main-actor
/// isolated, because `NSDraggingInfo` is not.
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    /// Changes under a still pointer as modifiers are pressed.
    var draggingSourceOperationMask: NSDragOperation
    /// In the window's coordinates.
    var draggingLocation: NSPoint = .zero
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(pasteboard: NSPasteboard, source: Any?, mask: NSDragOperation) {
        draggingPasteboard = pasteboard
        draggingSource = source
        draggingSourceOperationMask = mask
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
