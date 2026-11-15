import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The list's pointer (spec §4.17): the table lists one region per row in view, the hand over conversation rows and the
/// arrow over heads and the tail, with the links rows hold left to their own hand, and AppKit is asked again whenever
/// rows scroll, reload, come or go, so recycled row views never carry another row's pointer.
@MainActor
final class ListPointerTests: XCTestCase {
    private typealias Support = ListTestSupport

    /// Records which views AppKit is asked to reset the cursor rects of.
    private final class RecordingWindow: NSWindow {
        var invalidated: [NSView] = []

        override func invalidateCursorRects(for view: NSView) {
            invalidated.append(view)
            super.invalidateCursorRects(for: view)
        }

        func wasInvalidated(_ view: NSView) -> Bool { invalidated.contains { $0 === view } }
    }

    /// `ListTestSupport.host`, in a window that records what AppKit is asked again.
    private func host(store: MailStoring, query: ConversationQuery = ConversationQuery()) -> (MessageListViewController, RecordingWindow) {
        let size = NSSize(width: 380, height: 700)
        let list = MessageListViewController(store: store, query: query, settings: Support.settings())
        let window = RecordingWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless],
                                     backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        window.setContentSize(size)
        list.accountsByID = [Support.accountA.id: Support.accountA, Support.accountB.id: Support.accountB]
        Support.spin(until: { list.layout.rowCount > 0 || !list.emptyView.isHidden }, timeout: 5)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return (list, window)
    }

    /// The rows in view keep their pointer at the top, after a scroll that recycles every row view, after a reload and
    /// after an edit; each of these asks AppKit again, and the table adds rects for the rows in view only.
    func testRowsKeepTheirPointerAsTheListScrollsReloadsAndChanges() throws {
        let now = Date()
        let store = try Support.store(threads: 60, now: now, spacing: 6 * 3_600)
        let (list, window) = host(store: store)
        let table = list.tableView
        func check(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            window.layoutIfNeeded()
            let recorder = CursorRectRecorder(window)
            let visible = table.rows(in: table.visibleRect)
            XCTAssertGreaterThan(visible.length, 3, file: file, line: line)
            var heads = 0
            for row in visible.location..<NSMaxRange(visible) {
                let rect = table.rect(ofRow: row).intersection(table.visibleRect)
                let isConversation = list.layout.conversationIndex(atRow: row) != nil
                if !isConversation { heads += 1 }
                XCTAssertEqual(recorder.cursors(atCentreOf: rect, in: table), [isConversation ? .pointingHand : .arrow],
                               "\(label): row \(row)", file: file, line: line)
            }
            if label == "at the top" { XCTAssertGreaterThan(heads, 0, "heads among the rows", file: file, line: line) }
            let inView = table.convert(table.visibleRect, to: nil).insetBy(dx: -0.5, dy: -0.5)
            XCTAssertTrue(recorder.rects(of: table).allSatisfy { inView.contains($0.rect) }, "\(label): the rows in view only",
                          file: file, line: line)
        }
        check("at the top")

        window.invalidated = []
        table.scroll(NSPoint(x: 0, y: table.rect(ofRow: 40).minY))
        XCTAssertTrue(window.wasInvalidated(table), "a scroll asks again")
        window.displayIfNeeded()
        check("scrolled")

        window.invalidated = []
        table.reloadData()
        XCTAssertTrue(window.wasInvalidated(table), "a reload asks again")
        check("reloaded")

        table.scroll(.zero)
        window.displayIfNeeded()
        window.invalidated = []
        let moved = list.conversations[3]
        try store.upsertMessages([MessageMetadata(
            id: MessageID(accountID: moved.id.accountID, providerID: "reply-moves-up"), conversationID: moved.id,
            subject: moved.subject, snippet: "Moving up", from: Support.senders[3], date: now.addingTimeInterval(60), roles: [.inbox],
            isRead: false, isStarred: false, hasAttachments: false
        )])
        XCTAssertTrue(Support.spin(until: { list.conversations.first?.id == moved.id }, timeout: 2))
        XCTAssertTrue(window.wasInvalidated(table), "an edit asks again")
        check("edited")
    }

    /// The failed tail's Retry keeps its own hand inside the tail's arrow; once it hides, the link and the table are both
    /// asked again and the tail is the arrow all over.
    func testTheFailedTailsRetryKeepsItsHand() throws {
        let store = PageFailingStore(base: try Support.store(threads: 30))
        let (list, window) = host(store: store, query: ConversationQuery(limit: 10))
        list.loadMore()
        let footerRow = try XCTUnwrap(list.layout.footerRow)
        func footer() -> ListFooterRowView? {
            list.tableView.rowView(atRow: footerRow, makeIfNecessary: false) as? ListFooterRowView
        }
        list.tableView.scrollRowToVisible(footerRow)
        window.displayIfNeeded()
        XCTAssertTrue(Support.spin(until: { footer()?.phase == .failed }, timeout: 2), "a failed page shows the failed tail")
        list.tableView.scrollRowToVisible(footerRow)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let tail = try XCTUnwrap(footer())
        let retry = try XCTUnwrap(tail.subviews.first { $0.accessibilityRole() == .button })
        XCTAssertFalse(retry.isHidden)
        var recorder = CursorRectRecorder(window)
        XCTAssertEqual(recorder.cursors(atCentreOf: retry.bounds, in: retry), [.pointingHand], "Retry's own hand alone")
        XCTAssertEqual(recorder.cursors(atCentreOf: NSRect(x: 8, y: tail.bounds.midY, width: 0, height: 0), in: tail), [.arrow],
                       "the tail's words do nothing")

        window.invalidated = []
        tail.phase = .loading
        XCTAssertTrue(window.wasInvalidated(retry) && window.wasInvalidated(list.tableView), "the link and the table are asked again")
        recorder = CursorRectRecorder(window)
        XCTAssertEqual(recorder.cursors(atCentreOf: retry.frame, in: tail), [.arrow])
    }
}
