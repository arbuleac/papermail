import AppKit
import SQLite3
import PaperCore
import XCTest
@testable import PaperApp

/// The "list.search" interval (CLAUDE.md: signposts around search): a search query opens one, its first page
/// closes it, a query replaced first closes it as superseded, a query whose read fails closes it as failed, and a
/// blank query opens none. The list runs over
/// the SQLite store, which reads a search's first page off the main thread, so the page arrives after the query
/// is set, as in the app.
@MainActor
final class ListSearchSignpostTests: XCTestCase {
    private typealias Support = ListTestSupport

    private func host() throws -> (list: MessageListViewController, window: NSWindow, store: SQLiteMailStore) {
        let store = try SQLiteMailStore.inMemory()
        try store.upsertAccount(Support.accountA)
        try store.upsertAccount(Support.accountB)
        try store.upsertMessages(Support.messages(threads: 30))
        let (list, window) = Support.host(store: store, settings: Support.settings())
        return (list, window, store)
    }

    private func record(_ list: MessageListViewController) -> () -> [ListSearchSignpost.Event] {
        var events: [ListSearchSignpost.Event] = []
        list.searchSignpost.onEvent = { events.append($0) }
        return { events }
    }

    func testASearchBeginsOneIntervalAndItsFirstPageEndsIt() throws {
        let (list, window, store) = try host()
        defer { window.close() }
        let events = record(list)

        list.query = ConversationQuery(view: .all, searchText: "planning")
        XCTAssertEqual(events(), [.began], "open while the first page is being read")
        Support.spin(until: { events().count == 2 }, timeout: 5)
        XCTAssertEqual(events(), [.began, .finished])
        XCTAssertFalse(list.conversations.isEmpty, "ended by the rows, not before them")

        // A later refresh of the same results is not a search anyone waits for.
        let count = list.conversations.count
        try store.upsertMessages(Support.messages(threads: 31).filter { $0.conversationID.providerID == "thread-30" })
        Support.spin(until: { list.conversations.count > count }, timeout: 5)
        XCTAssertGreaterThan(list.conversations.count, count)
        XCTAssertEqual(events(), [.began, .finished])
    }

    func testAQueryReplacedBeforeItsRowsEndsItsInterval() throws {
        let (list, window, _) = try host()
        defer { window.close() }
        let events = record(list)

        // More typing before the first page lands.
        list.query = ConversationQuery(view: .all, searchText: "plan")
        list.query = ConversationQuery(view: .all, searchText: "planning")
        XCTAssertEqual(events(), [.began, .superseded, .began])
        Support.spin(until: { events().count == 4 }, timeout: 5)
        XCTAssertEqual(events(), [.began, .superseded, .began, .finished], "only the latest query's rows end an interval")

        // A cleared field (or another view) before the rows land: ended, and nothing opens for the mailbox.
        list.query = ConversationQuery(view: .all, searchText: "quarterly")
        list.query = ConversationQuery(view: .inbox)
        XCTAssertEqual(Array(events().suffix(2)), [.began, .superseded])
        Support.spin(for: 0.2)
        XCTAssertEqual(events().count, 6, "the cancelled search's late page ends nothing")
    }

    func testABlankQueryBeginsNoInterval() throws {
        let (list, window, _) = try host()
        defer { window.close() }
        let events = record(list)

        list.query = ConversationQuery(view: .all, searchText: "   ")
        list.query = ConversationQuery(view: .starred, searchText: "")
        list.query = ConversationQuery(view: .sent)
        Support.spin(for: 0.1)
        XCTAssertEqual(events(), [])
    }

    /// The store's read fails (the full-text table dropped behind its back, standing in for a damaged index or an
    /// I/O error): no rows will come, so the interval ends then as failed, not later as a long "superseded" one.
    func testASearchWhoseReadFailsEndsItsIntervalAsFailed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ListSearchSignpostTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("mail.sqlite").path
        let store = try SQLiteMailStore(path: path)
        defer { try? store.close() }
        try store.upsertAccount(Support.accountA)
        try store.upsertMessages(Support.messages(threads: 5, accounts: [Support.accountA]))
        let (list, window) = Support.host(store: store, settings: Support.settings())
        defer { window.close() }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DROP TABLE message_fts", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let events = record(list)

        list.query = ConversationQuery(view: .all, searchText: "planning")
        Support.spin(until: { events().count == 2 }, timeout: 5)
        XCTAssertEqual(events(), [.began, .failed])

        list.query = ConversationQuery(view: .inbox)
        XCTAssertEqual(events(), [.began, .failed], "nothing was left open to supersede")
    }

    func testAnIntervalOpenWhenTheListGoesAwayIsEnded() {
        var events: [ListSearchSignpost.Event] = []
        var signpost: ListSearchSignpost? = ListSearchSignpost()
        signpost?.onEvent = { events.append($0) }
        signpost?.begin()
        signpost = nil
        XCTAssertEqual(events, [.began, .superseded])
    }
}
