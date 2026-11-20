import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The list's behaviour around the redesign (spec §5.7–5.10): running heads that j/k skip, the paging footer,
/// empty states, live density, and selection that never rebuilds a row.
@MainActor
final class MessageListBehaviourTests: XCTestCase {
    private typealias Support = ListTestSupport

    func testJAndKSkipRunningHeads() throws {
        // Two threads a day over a week: several heads between the rows.
        let store = try Support.store(threads: 20, spacing: 12 * 3_600)
        let (list, _) = Support.host(store: store, settings: Support.settings())
        XCTAssertTrue(list.layout.showsHeads)
        XCTAssertGreaterThan(list.layout.rowCount, list.conversations.count, "heads add rows")
        guard case .head? = list.layout.items.first else { return XCTFail("the list opens with a head") }

        var visited: [ConversationID] = []
        for _ in 0..<list.conversations.count {
            list.selectNext()
            guard let id = list.selectedConversationID else { return XCTFail("j selected nothing") }
            visited.append(id)
            let row = list.tableView.selectedRow
            XCTAssertNotNil(list.layout.conversationIndex(atRow: row), "row \(row) is a head or the footer")
        }
        XCTAssertEqual(visited, list.conversations.map(\.id), "j walks every conversation once, in order")
        for _ in 0..<list.conversations.count { list.selectPrevious() }
        XCTAssertEqual(list.selectedConversationID, list.conversations.first?.id)
    }

    func testRowEditsKeepEveryRowAtItsHeight() throws {
        // Threads half a day apart, then a reply that moves an old thread to the top past several heads.
        let now = Date()
        let store = try Support.store(threads: 20, now: now, spacing: 12 * 3_600)
        let (list, window) = Support.host(store: store, settings: Support.settings())
        let moved = list.conversations[15]
        try store.upsertMessages([MessageMetadata(
            id: MessageID(accountID: moved.id.accountID, providerID: "reply-moves-up"), conversationID: moved.id,
            subject: moved.subject, snippet: "Moving up", from: Support.senders[3], date: now, roles: [.inbox],
            isRead: false, isStarred: false, hasAttachments: false
        )])
        Support.spin(until: { list.conversations.first?.id == moved.id }, timeout: 2)
        XCTAssertEqual(list.conversations.first?.id, moved.id)
        window.displayIfNeeded()
        for row in 0..<list.layout.rowCount {
            let expected: CGFloat
            switch list.layout.items[row] {
            case .conversation: expected = Quire.Layout.Row.height
            case .head: expected = Quire.Layout.RunningHead.height
            case .footer, .serverSearch: expected = Quire.Layout.ListFooter.height
            }
            XCTAssertEqual(list.tableView.rect(ofRow: row).height, expected, "row \(row)")
        }
        XCTAssertEqual(list.tableView.numberOfRows, list.layout.rowCount)
    }

    func testRowEditsDoNotAnimate() throws {
        // Nothing in the list moves on its own (spec §1, §5.7): new mail at the top shifts the rows below at once.
        let now = Date()
        let store = try Support.store(threads: 20, now: now, spacing: 600)
        let (list, window) = Support.host(store: store, settings: Support.settings())
        window.displayIfNeeded()
        try store.upsertMessages([MessageMetadata(
            id: MessageID(accountID: Support.accountA.id, providerID: "new-on-top"),
            conversationID: ConversationID(accountID: Support.accountA.id, providerID: "new-thread"),
            subject: "New", snippet: "Arrives at the top", from: Support.senders[2], date: now.addingTimeInterval(60), roles: [.inbox],
            isRead: false, isStarred: false, hasAttachments: false
        )])
        Support.spin(until: { list.conversations.first?.id.providerID == "new-thread" }, timeout: 2)
        var animated: [String] = []
        list.tableView.enumerateAvailableRowViews { rowView, row in
            if let keys = rowView.layer?.animationKeys(), !keys.isEmpty { animated.append("row \(row): \(keys)") }
        }
        XCTAssertEqual(animated, [], "row views carry no animation after an insert")
    }

    func testHeadsAreHiddenInShortViewsAndInSearch() throws {
        let short = Support.host(store: try Support.store(threads: 7), settings: Support.settings()).list
        XCTAssertFalse(short.layout.showsHeads)
        XCTAssertEqual(short.layout.rowCount, short.conversations.count)

        let store = try Support.store(threads: 30)
        let search = Support.host(store: store, query: ConversationQuery(view: .all, searchText: "Project"), settings: Support.settings()).list
        XCTAssertFalse(search.conversations.isEmpty)
        XCTAssertFalse(search.layout.showsHeads, "never over ranked search results")
    }

    func testHeadsAndTheFooterAreNotSelectable() throws {
        let store = try Support.store(threads: 30)
        let (list, _) = Support.host(store: store, query: ConversationQuery(limit: 10), settings: Support.settings())
        guard let footer = list.layout.footerRow else { return XCTFail("older pages exist, so the footer ends the list") }
        XCTAssertFalse(list.tableView.delegate?.tableView?(list.tableView, shouldSelectRow: footer) ?? true)
        XCTAssertFalse(list.tableView.delegate?.tableView?(list.tableView, shouldSelectRow: 0) ?? true, "the first row is a head")
        XCTAssertEqual(list.tableView.delegate?.tableView?(list.tableView, heightOfRow: footer), Quire.Layout.ListFooter.height)
    }

    func testClickingAHeadOrTheFooterKeepsTheSelection() throws {
        let store = try Support.store(threads: 30)
        let (list, _) = Support.host(store: store, query: ConversationQuery(limit: 10), settings: Support.settings())
        list.selectNext()
        list.selectNext()
        let selected = list.tableView.selectedRowIndexes
        let footer = try XCTUnwrap(list.layout.footerRow)
        let ask = { (rows: IndexSet) in
            list.tableView.delegate?.tableView?(list.tableView, selectionIndexesForProposedSelection: rows)
        }
        XCTAssertEqual(ask(IndexSet(integer: 0)), selected, "a click on the first head leaves the selection alone")
        XCTAssertEqual(ask(IndexSet(integer: footer)), selected, "so does a click on the footer")
        XCTAssertEqual(ask(IndexSet()), IndexSet(), "a click below the rows still deselects")
        let row = try XCTUnwrap(list.layout.row(ofConversation: 4))
        XCTAssertEqual(ask(IndexSet([0, row])), IndexSet(integer: row), "heads drop out of a mixed proposal")
    }

    func testTheFooterGoesAtTheTrueEnd() throws {
        let store = try Support.store(threads: 12)
        let (list, _) = Support.host(store: store, query: ConversationQuery(limit: 10), settings: Support.settings())
        XCTAssertNotNil(list.layout.footerRow)
        list.loadMore()
        Support.spin(until: { list.conversations.count == 12 }, timeout: 5)
        XCTAssertEqual(list.conversations.count, 12)
        XCTAssertNil(list.layout.footerRow, "no footer once the last page is in")
    }

    func testAFailedPageShowsRetryAndTheLinkTakesAClick() throws {
        let store = PageFailingStore(base: try Support.store(threads: 30))
        let (list, window) = Support.host(store: store, query: ConversationQuery(limit: 10), settings: Support.settings())
        // The tail is within two screens, so the list asks for the next page at once, and it fails.
        list.loadMore()
        let footerRow = try XCTUnwrap(list.layout.footerRow)
        func footer() -> ListFooterRowView? {
            list.tableView.rowView(atRow: footerRow, makeIfNecessary: false) as? ListFooterRowView
        }
        list.tableView.scrollRowToVisible(footerRow)
        window.displayIfNeeded()
        XCTAssertTrue(Support.spin(until: { footer()?.phase == .failed }, timeout: 2), "a failed page shows the failed tail")
        XCTAssertEqual(footer()?.accessibilityLabel(), "Couldn't load older mail")
        XCTAssertEqual(footer()?.accessibilityRole(), .group, "VoiceOver reaches Retry inside the failed tail")
        XCTAssertEqual(list.conversations.count, 10)

        // A click on Retry reaches the link inside the table row and loads the page.
        store.failsPages = false
        list.tableView.scrollRowToVisible(footerRow)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let retry = try XCTUnwrap(footer()?.subviews.first { $0.accessibilityRole() == .button })
        XCTAssertFalse(retry.isHidden)
        // ↩ and keypad Enter on the focused link are its own: the router, which sees them first, must not open the
        // selected conversation in a window of its own from behind it (§5.49).
        func key(_ keyCode: UInt16, _ characters: String) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                             keyCode: keyCode)
        }
        let control = try XCTUnwrap(retry as? ShellKeyHandling, "Retry answers the shell's keys itself")
        XCTAssertTrue(control.handlesKey(try XCTUnwrap(key(36, "\r"))), "↩")
        XCTAssertTrue(control.handlesKey(try XCTUnwrap(key(76, "\u{3}"))), "keypad Enter")
        XCTAssertFalse(control.handlesKey(try XCTUnwrap(key(38, "j"))), "j still moves the list")
        let point = retry.convert(NSPoint(x: retry.bounds.midX, y: retry.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let up = try XCTUnwrap(mouse(.leftMouseUp))
        let down = try XCTUnwrap(mouse(.leftMouseDown))
        // The pointer lands on the link, and the table hands the click to it rather than treating it as a row
        // click. A window off screen is never key, so the press itself is delivered to the link directly.
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let hitView = frameView.hitTest(frameView.convert(point, from: nil))
        XCTAssertTrue(hitView === retry, "the pointer is over Retry")
        XCTAssertTrue(list.tableView.validateProposedFirstResponder(retry, for: down), "the table lets the link take the click")
        window.postEvent(up, atStart: false)
        retry.mouseDown(with: down)
        XCTAssertTrue(Support.spin(until: { list.conversations.count > 10 }, timeout: 2), "Retry loaded the next page")
    }

    func testEmptyStatesFollowTheView() throws {
        let store = try Support.store(threads: 0)
        let inbox = Support.host(store: store, settings: Support.settings()).list
        XCTAssertFalse(inbox.emptyView.isHidden)
        XCTAssertEqual(inbox.emptyView.sentence, "Nothing left to read.")
        XCTAssertEqual(inbox.emptyView.glyph, .brandMark)

        inbox.query = ConversationQuery(view: .starred)
        Support.spin(for: 0.05)
        XCTAssertEqual(inbox.emptyView.sentence, "No starred conversations")
        XCTAssertNil(inbox.emptyView.glyph)

        inbox.query = ConversationQuery(view: .all, searchText: "lisbon flat")
        Support.spin(for: 0.05)
        XCTAssertEqual(inbox.emptyView.sentence, "No results for “lisbon flat”")
    }

    func testFirstSyncShowsTheSkeletonNotAnEmptyState() throws {
        let store = try Support.store(threads: 0)
        let list = Support.host(store: store, settings: Support.settings()).list
        list.syncStatuses = [AccountSyncStatus(accountID: Support.accountA.id, phase: .bootstrapping)]
        XCTAssertTrue(list.emptyView.isHidden)
        Support.spin(until: { !list.skeletonView.isHidden }, timeout: 1)
        XCTAssertFalse(list.skeletonView.isHidden, "the skeleton shows after its 300 ms delay")

        list.syncStatuses = [AccountSyncStatus(accountID: Support.accountA.id, phase: .idle, lastSuccessfulSyncAt: Date())]
        XCTAssertTrue(list.skeletonView.isHidden)
        XCTAssertFalse(list.emptyView.isHidden)
    }

    func testSyncFinishedWaitsForTheOlderMailToBeListed() throws {
        let store = try Support.store(threads: 0)
        let list = Support.host(store: store, settings: Support.settings()).list
        list.query = ConversationQuery(view: .starred)
        Support.spin(for: 0.05)
        let id = Support.accountA.id
        list.syncStatuses = [AccountSyncStatus(accountID: id, phase: .bootstrapping)]
        // The head page is in and the backfill lists the rest: nothing is finished yet.
        list.syncStatuses = [AccountSyncStatus(accountID: id, phase: .idle, lastSuccessfulSyncAt: Date(),
                                               backfillProgress: 100, backfillTotal: 24_000)]
        XCTAssertTrue(list.skeletonView.isHidden)
        XCTAssertEqual(list.emptyView.sentence, "No starred conversations")
        XCTAssertEqual(list.emptyView.hint, [.text("Older mail is still downloading.")])

        list.syncStatuses = [AccountSyncStatus(accountID: id, phase: .idle, lastSuccessfulSyncAt: Date())]
        XCTAssertEqual(list.emptyView.sentence, "No mail in \(AccountLabels.name(for: Support.accountA)) yet")
        XCTAssertEqual(list.emptyView.hint, [.text("Sync finished. New mail will land here.")])
    }

    /// Between the head page and the backfill's first turn the status carries no backfill progress: during the
    /// first changes call, and after it went through. The stored state still says the older mail is unlisted.
    func testSyncFinishedWaitsForTheStoredListingBeforeTheBackfillReports() throws {
        let store = try Support.store(threads: 0)
        let list = Support.host(store: store, settings: Support.settings()).list
        list.query = ConversationQuery(view: .starred)
        Support.spin(for: 0.05)
        let id = Support.accountA.id
        list.syncStatuses = [AccountSyncStatus(accountID: id, phase: .bootstrapping)]
        var state = BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 100)
        try store.setBootstrapState(state, for: id)

        list.syncStatuses = [AccountSyncStatus(accountID: id, phase: .syncing)]
        XCTAssertEqual(list.emptyView.sentence, "No starred conversations")
        XCTAssertEqual(list.emptyView.hint, [.text("Older mail is still downloading.")])
        let polled = Date()
        list.syncStatuses = [AccountSyncStatus(accountID: id, phase: .idle, lastSuccessfulSyncAt: polled)]
        XCTAssertEqual(list.emptyView.sentence, "No starred conversations")
        XCTAssertEqual(list.emptyView.hint, [.text("Older mail is still downloading.")])

        state.isComplete = true
        try store.setBootstrapState(state, for: id)
        list.syncStatuses = [AccountSyncStatus(accountID: id, phase: .idle, lastSuccessfulSyncAt: polled.addingTimeInterval(5))]
        XCTAssertEqual(list.emptyView.sentence, "No mail in \(AccountLabels.name(for: Support.accountA)) yet")
        XCTAssertEqual(list.emptyView.hint, [.text("Sync finished. New mail will land here.")])
    }

    /// A head page the provider refused leaves no stored state and no poll that went through: nothing finished.
    func testAThrottledHeadPageIsNoFinishedSync() throws {
        let store = try Support.store(threads: 0)
        let list = Support.host(store: store, settings: Support.settings()).list
        list.query = ConversationQuery(view: .starred)
        Support.spin(for: 0.05)
        let id = Support.accountA.id
        list.syncStatuses = [AccountSyncStatus(accountID: id, phase: .bootstrapping)]
        list.syncStatuses = [AccountSyncStatus(accountID: id, phase: .paused, message: "Rate limited; retrying shortly")]
        XCTAssertEqual(list.emptyView.sentence, "No starred conversations")
        XCTAssertEqual(list.emptyView.hint, [.text("Press S to star one.")])
    }

    func testDensitySwitchesLive() throws {
        let settings = Support.settings()
        let store = try Support.store(threads: 20)
        let (list, window) = Support.host(store: store, settings: settings)
        let firstConversationRow = try XCTUnwrap(list.layout.row(ofConversation: 0))
        XCTAssertEqual(list.tableView.rect(ofRow: firstConversationRow).height, Quire.Layout.Row.height)
        list.selectNext()
        let selected = list.selectedConversationID

        settings.listDensity = .compact
        window.displayIfNeeded()
        XCTAssertEqual(list.tableView.rect(ofRow: firstConversationRow).height, Quire.Layout.RowCompact.height)
        XCTAssertEqual(list.tableView.rect(ofRow: 0).height, Quire.Layout.RunningHead.compactHeight)
        XCTAssertEqual(list.selectedConversationID, selected, "the selection survives the switch")
        let rowView = list.tableView.rowView(atRow: firstConversationRow, makeIfNecessary: false) as? ConversationRowView
        XCTAssertEqual(rowView?.metrics, .compact(.default))
    }

    func testSelectionNeverRebuildsARow() throws {
        let store = try Support.store(threads: 40)
        let (list, window) = Support.host(store: store, settings: Support.settings())
        // Walk once, drawing every step, so every row on the way has been built (the first j only selects the
        // top row, so the warm-up goes one further); then walk again.
        for _ in 0..<13 { list.selectNext(); window.displayIfNeeded() }
        for _ in 0..<13 { list.selectPrevious(); window.displayIfNeeded() }
        list.rowContentCache.resetBuildCount()
        for _ in 0..<12 { list.selectNext(); window.displayIfNeeded() }
        for _ in 0..<12 { list.selectPrevious(); window.displayIfNeeded() }
        XCTAssertEqual(list.rowContentCache.buildCount, 0, "j/k reuses every row's strings")
    }

    func testOpeningAFailedRowAcknowledgesIt() throws {
        let store = try Support.store(threads: 10)
        let (list, _) = Support.host(store: store, settings: Support.settings())
        let target = list.conversations[2]
        let messageID = try XCTUnwrap(store.messages(in: target.id).last?.id)
        var operation = Operation(accountID: target.id.accountID, change: .setStarred(!target.isStarred), targets: [messageID])
        try store.enqueue(operation)
        operation.status = .failed
        try store.updateOperation(operation)
        Support.spin(until: { list.conversations.first { $0.id == target.id }?.failedOperation != nil }, timeout: 2)
        XCTAssertNotNil(list.conversations.first { $0.id == target.id }?.failedOperation)

        list.selectedConversationID = target.id
        list.selectNext()
        list.selectPrevious()
        XCTAssertEqual(list.selectedConversationID, target.id)
        Support.spin(until: { list.conversations.first { $0.id == target.id }?.failedOperation == nil }, timeout: 2)
        XCTAssertNil(list.conversations.first { $0.id == target.id }?.failedOperation, "150 ms of selection clears the mark")
    }

    func testHoverIsSuspendedWhileScrolling() throws {
        let store = try Support.store(threads: 40)
        let (list, _) = Support.host(store: store, settings: Support.settings())
        let table = list.tableView
        let row = try XCTUnwrap(list.layout.row(ofConversation: 1))
        table.setHoveredRow(row)
        XCTAssertEqual(table.hoveredRow, row)
        XCTAssertEqual((table.rowView(atRow: row, makeIfNecessary: false) as? ConversationRowView)?.isHovered, true)

        table.beginScrollHoverSuspension()
        XCTAssertTrue(table.isHoverSuspended)
        XCTAssertEqual(table.hoveredRow, -1, "rows sliding under a still pointer draw no wash")
        XCTAssertEqual((table.rowView(atRow: row, makeIfNecessary: false) as? ConversationRowView)?.isHovered, false)
        table.endScrollHoverSuspension()
        XCTAssertFalse(table.isHoverSuspended)

        table.setHoveredRow(0)
        XCTAssertEqual(table.hoveredRow, -1, "heads take no hover")
    }

    func testUnifiedRowsNameTheirAccountInATooltip() throws {
        let store = try Support.store(threads: 10)
        let (list, window) = Support.host(store: store, settings: Support.settings())
        window.displayIfNeeded()
        let cell = try XCTUnwrap(cell(of: list, conversation: 0))
        let account = list.conversations[0].id.accountID == Support.accountA.id ? Support.accountA : Support.accountB
        let face = NSRect(x: Quire.Layout.Row.avatarBoxX, y: Quire.Layout.Row.avatarBoxY, width: Quire.Layout.Row.avatarBox,
                          height: Quire.Layout.Row.avatarBox)
        let regions = cell.toolTipRegions()
        let marks = regions.filter { $0.text == account.email }
        XCTAssertEqual(marks.map(\.rect), [face], "the ringed face names its account (spec §4.2)")
        // The long subject is cut in a 380 pt list: its tooltip says it whole, over its own words (§5.34).
        let subject = try XCTUnwrap(regions.first { $0.text.hasPrefix("Project update 0") })
        XCTAssertEqual(subject.text, "Project update 0 and the quarterly planning document")
        XCTAssertFalse(subject.rect.intersects(face), "never over the account's face")
        XCTAssertEqual(regions.count, 2, "the sender fits, so it has none")
    }

    func testAUnifiedViewOfOneAccountDropsTheAccountMarks() throws {
        let store = try Support.store(threads: 10)
        let (list, window) = Support.host(store: store, settings: Support.settings(faces: true))
        list.accountsByID = [Support.accountA.id: Support.accountA]
        window.displayIfNeeded()
        let cell = try XCTUnwrap(cell(of: list, conversation: 0))
        XCTAssertTrue(cell.toolTipRegions().filter { $0.text.contains("@") }.isEmpty,
                      "with one account the unified view is a single-account view: no ring, no tile")
    }

    func testTheFailedGlyphSaysWhatFailedWithoutCoveringTheAccount() throws {
        let store = try Support.store(threads: 10)
        let (list, window) = Support.host(store: store, settings: Support.settings(faces: true))
        let target = list.conversations[2]
        let messageID = try XCTUnwrap(store.messages(in: target.id).last?.id)
        var operation = Operation(accountID: target.id.accountID, change: .archive, targets: [messageID])
        try store.enqueue(operation)
        operation.status = .failed
        try store.updateOperation(operation)
        Support.spin(until: { list.conversations.first { $0.id == target.id }?.failedOperation != nil }, timeout: 2)
        window.displayIfNeeded()
        let index = try XCTUnwrap(list.conversations.firstIndex { $0.id == target.id })
        let cell = try XCTUnwrap(cell(of: list, conversation: index))
        let regions = cell.toolTipRegions()
        let failure = try XCTUnwrap(regions.first { $0.text == "Couldn't archive" }, "the triangle's tooltip (spec §5.7)")
        let account = regions.filter { $0.text.contains("@") }
        XCTAssertEqual(account.count, 2, "the face and the account tile both name the account")
        for region in account {
            XCTAssertFalse(region.rect.intersects(failure.rect), "tooltip rects never overlap, so each shows its own words")
        }
    }

    /// §5.7 Dragging: a conversation row drags out as its subject and its id; heads do not drag.
    func testConversationRowsDragAsTheirSubject() throws {
        let store = try Support.store(threads: 10)
        let (list, _) = Support.host(store: store, settings: Support.settings())
        let row = try XCTUnwrap(list.layout.row(ofConversation: 1))
        let item = try XCTUnwrap(list.tableView(list.tableView, pasteboardWriterForRow: row) as? NSPasteboardItem)
        XCTAssertEqual(item.string(forType: .string), list.conversations[1].subject)
        let data = try XCTUnwrap(item.data(forType: MessageListViewController.conversationPasteboardType))
        XCTAssertEqual(try JSONDecoder().decode(ConversationID.self, from: data), list.conversations[1].id)
        if let head = list.layout.items.firstIndex(where: { if case .head = $0 { return true } else { return false } }) {
            XCTAssertNil(list.tableView(list.tableView, pasteboardWriterForRow: head))
        }
    }

    private func cell(of list: MessageListViewController, conversation index: Int) -> ConversationCellView? {
        guard let row = list.layout.row(ofConversation: index) else { return nil }
        return list.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ConversationCellView
    }

    func testDraftsAndSentRowsNameRecipients() throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Support.accountA)
        let me = EmailAddress(name: "Alex Morgan", address: Support.accountA.email)
        let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
        let conversation = ConversationID(accountID: Support.accountA.id, providerID: "sent-1")
        try store.upsertMessages([MessageMetadata(
            id: MessageID(accountID: Support.accountA.id, providerID: "sent-1-m"), conversationID: conversation, subject: "Lisbon",
            snippet: "Count me in", from: me, to: [ben], date: Date(), roles: [.sent], isRead: true, isStarred: false, hasAttachments: false
        )])
        let (list, window) = Support.host(store: store, query: ConversationQuery(view: .sent), settings: Support.settings())
        window.displayIfNeeded()
        let row = try XCTUnwrap(list.layout.row(ofConversation: 0))
        let cell = list.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ConversationCellView
        XCTAssertEqual(cell?.content?.sender.string, "To Ben Carter")
    }
}
