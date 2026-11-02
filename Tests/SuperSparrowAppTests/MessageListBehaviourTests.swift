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
            case .footer: expected = Quire.Layout.ListFooter.height
            }
            XCTAssertEqual(list.tableView.rect(ofRow: row).height, expected, "row \(row)")
        }
        XCTAssertEqual(list.tableView.numberOfRows, list.layout.rowCount)
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

    func testTheFooterGoesAtTheTrueEnd() throws {
        let store = try Support.store(threads: 12)
        let (list, _) = Support.host(store: store, query: ConversationQuery(limit: 10), settings: Support.settings())
        XCTAssertNotNil(list.layout.footerRow)
        list.loadMore()
        Support.spin(until: { list.conversations.count == 12 }, timeout: 5)
        XCTAssertEqual(list.conversations.count, 12)
        XCTAssertNil(list.layout.footerRow, "no footer once the last page is in")
    }

    func testEmptyStatesFollowTheView() throws {
        let store = try Support.store(threads: 0)
        let inbox = Support.host(store: store, settings: Support.settings()).list
        XCTAssertFalse(inbox.emptyView.isHidden)
        XCTAssertEqual(inbox.emptyView.sentence, "Nothing left to read.")
        XCTAssertEqual(inbox.emptyView.glyph, .sparrow)

        inbox.query = ConversationQuery(view: .inbox, section: .other)
        Support.spin(for: 0.05)
        XCTAssertEqual(inbox.emptyView.sentence, "Nothing in Other")
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
        XCTAssertEqual(rowView?.density, .compact)
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
