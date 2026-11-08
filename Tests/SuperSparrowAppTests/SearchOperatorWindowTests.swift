import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// Search operators in the main window (spec §5.6): typed into the field like any search, an `in:` term picking the
/// view searched, a read result of an `is:unread` search kept while it is open, and a toast for an action that takes
/// a result out of the list. The harness seeds eight threads; 0, 3 and 6 end unread.
@MainActor
final class SearchOperatorWindowTests: XCTestCase {
    private func type(_ text: String, in harness: MainWindowHarness) {
        harness.controller.listPane.header.search.query = text
        harness.controller.listPane.header.search.onQueryChange?(text)
        harness.spin { harness.list.query.searchText == text }
    }

    private func open(_ id: ConversationID, in harness: MainWindowHarness) {
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
    }

    private func unreadCount(_ id: ConversationID, in harness: MainWindowHarness) throws -> Int? {
        try harness.environment.store.conversations(ConversationQuery(view: .all)).first { $0.id == id }?.unreadCount
    }

    func testOperatorsTypedInTheFieldNarrowTheList() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        type("is:unread", in: harness)
        harness.spin { harness.list.conversations.count == 3 }
        XCTAssertEqual(harness.list.conversations.map(\.id.providerID), ["thread-0", "thread-3", "thread-6"])
        XCTAssertEqual(harness.list.query.view, .all)

        type("in:inbox has:attachment", in: harness)
        harness.spin { harness.list.conversations.map(\.id.providerID) == ["thread-1", "thread-5"] }
        XCTAssertEqual(harness.list.query.view, .inbox, "an in: term picks the view searched")
        XCTAssertEqual(harness.list.conversations.map(\.id.providerID), ["thread-1", "thread-5"])
    }

    /// Opening a result of an `is:unread` search reads it after 500 ms. It stays listed and selected while it is open,
    /// so the selection does not jump to the next result, which would be read and leave in turn; it leaves once
    /// another result has been open for a moment.
    func testAReadResultStaysListedWhileItIsOpen() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        type("is:unread", in: harness)
        harness.spin { harness.list.conversations.count == 3 }
        let unread = harness.list.conversations.map(\.id)

        open(unread[0], in: harness)
        harness.spin { (try? self.unreadCount(unread[0], in: harness)) == 0 }
        XCTAssertEqual(try unreadCount(unread[0], in: harness), 0, "the reader read it")
        ListTestSupport.spin(for: 0.8)
        XCTAssertEqual(harness.list.selectedConversationID, unread[0], "the selection stays on what the user opened")
        XCTAssertEqual(harness.list.conversations.map(\.id), unread, "and its row stays, read")
        XCTAssertEqual(harness.list.conversations.first?.unreadCount, 0)
        XCTAssertEqual(try unreadCount(unread[1], in: harness), 1, "nothing else was read")

        // j: the next result opens and rests; the one read before leaves, and the new one stays once it is read.
        _ = harness.controller.perform(.next)
        harness.spin { harness.list.conversations.map(\.id) == Array(unread.dropFirst()) }
        XCTAssertEqual(harness.list.conversations.map(\.id), Array(unread.dropFirst()))
        harness.spin { (try? self.unreadCount(unread[1], in: harness)) == 0 }
        ListTestSupport.spin(for: 0.5)
        XCTAssertEqual(harness.list.selectedConversationID, unread[1])
        XCTAssertEqual(harness.list.conversations.map(\.id), Array(unread.dropFirst()))
        XCTAssertEqual(try unreadCount(unread[2], in: harness), 1)
    }

    /// The search shows Inbox mail only, so archiving a result takes it out: the toast says so and Z brings it back.
    func testArchivingAResultOfAnInboxSearchToasts() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        type("in:inbox project", in: harness)
        harness.spin { harness.list.query.view == .inbox && !harness.list.conversations.isEmpty }
        let first = try XCTUnwrap(harness.list.conversations.first?.id)
        open(first, in: harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertEqual(harness.toastMessage, "Archived")
        harness.spin { !harness.list.conversations.contains { $0.id == first } }
        XCTAssertFalse(harness.list.conversations.contains { $0.id == first })
        XCTAssertTrue(harness.controller.perform(.undo))
        harness.spin { harness.list.conversations.contains { $0.id == first } }
        XCTAssertTrue(harness.list.conversations.contains { $0.id == first })
    }
}
