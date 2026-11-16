import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// A two-finger swipe on a row (spec §5.7, Swipe), drawn by the list itself: Archive on the trailing edge and Mark as Read
/// or Unread on the leading one, each the key's change (E, U) on that one row through the key's path (store first,
/// queued, the toast, coalescing and Undo), offered only where the key would change the row; the same actions for
/// VoiceOver; and the open button's close rules.
///
/// No test can move fingers on a trackpad, so the scroll phases and deltas a swipe sends are handed to the list's swipe as
/// the table hands it every scroll event (`RowSwipeController.handle`), and once through the table's own `scrollWheel`.
@MainActor
final class SwipeToArchiveTests: XCTestCase {
    private typealias Scroll = RowSwipeGesture.Scroll

    override func tearDown() async throws {
        Quire.Motion.finishAll()
        try await super.tearDown()
    }

    // MARK: Helpers

    private func tableRow(_ index: Int, _ harness: MainWindowHarness) throws -> Int {
        try harness.list.tableRow(ofConversation: index)
    }

    private func rowView(_ index: Int, _ harness: MainWindowHarness) throws -> ConversationRowView {
        try harness.list.rowView(ofConversation: index)
    }

    private func swipe(_ index: Int, by distance: CGFloat, in harness: MainWindowHarness, lift: Bool = true) throws {
        try harness.list.drag(index, by: distance, lift: lift)
    }

    /// A swipe carried across the row: the change, at once.
    private func fullSwipe(_ index: Int, _ edge: RowSwipe.Edge, in harness: MainWindowHarness) throws {
        let width = harness.list.tableView.bounds.width
        try harness.list.drag(index, by: edge == .trailing ? -width : width)
    }

    @discardableResult
    private func open(_ index: Int, _ edge: RowSwipe.Edge, in harness: MainWindowHarness,
                      file: StaticString = #filePath, line: UInt = #line) throws -> QuireSwipeButton {
        try harness.list.openButton(index, edge, file: file, line: line)
    }

    private func cell(forConversation index: Int, in harness: MainWindowHarness) throws -> ConversationCellView {
        let row = try tableRow(index, harness)
        return try XCTUnwrap(harness.list.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ConversationCellView)
    }

    private func inInbox(_ id: ConversationID, _ harness: MainWindowHarness) throws -> Bool {
        try harness.environment.store.messages(in: id).contains(where: \.isInInbox)
    }

    private func queued(_ change: MetadataChange, _ harness: MainWindowHarness) throws -> Set<MessageID> {
        let store = harness.environment.store
        let all = try [ListTestSupport.accountA.id, ListTestSupport.accountB.id].flatMap { try store.pendingOperations(accountID: $0, limit: 100) }
        return Set(all.filter { $0.change == change }.flatMap(\.targets))
    }

    private func select(_ id: ConversationID, _ harness: MainWindowHarness) {
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
    }

    private func assertAtRest(_ view: ConversationRowView, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(view.swipeOffset, 0, message, file: file, line: line)
        XCTAssertNil(view.swipeButton, message, file: file, line: line)
    }

    // MARK: Archive

    func testAFullTrailingSwipeArchivesTheRowAsEDoes() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        select(harness.list.conversations[0].id, harness)
        let id = harness.list.conversations[2].id
        // Under the fingers: the content slid left, Archive's button behind it.
        try swipe(2, by: -60, in: harness, lift: false)
        let view = try rowView(2, harness)
        XCTAssertEqual(view.swipeOffset, -60)
        let button = try XCTUnwrap(view.swipeButton)
        XCTAssertEqual(button.kind, .archive)
        XCTAssertEqual(button.title, "Archive", "the menu's command, a verb (§4.13)")
        XCTAssertTrue(button.kind.fill === NSColor.qSwipeArchive, "Archive's fill, the live token (§5.7)")
        XCTAssertEqual(button.kind.symbolName, Quire.Icon.archive)
        XCTAssertEqual(button.frame, NSRect(x: view.bounds.width - 60, y: 0, width: 60, height: view.bounds.height),
                       "the full height of all it uncovered")
        let swiped = try tableRow(2, harness)
        harness.list.swipe.handle(Scroll(phase: .changed, dx: -harness.list.tableView.bounds.width, dy: 0), atRow: swiped)
        harness.list.swipe.handle(Scroll(phase: .ended), atRow: swiped)

        XCTAssertFalse(try inInbox(id, harness), "archived in the store at once")
        let wanted = Set(try harness.environment.store.messages(in: id).map(\.id))
        XCTAssertTrue(wanted.isSubset(of: try queued(.archive, harness)), "and queued for the engine")
        XCTAssertEqual(harness.toastMessage, "Archived", "E's toast")
        let undo = try XCTUnwrap(harness.controller.listPane.toastView.slip?.actionButton)
        XCTAssertEqual(undo.title, "Undo")
        XCTAssertEqual(undo.keycap, "Z")
        harness.spin { !harness.list.conversations.contains { $0.id == id } }
        XCTAssertFalse(harness.list.conversations.contains { $0.id == id }, "the row leaves the Inbox")
        XCTAssertEqual(harness.list.selectedConversationID, harness.list.conversations[0].id,
                       "a swipe acts on its own row and leaves the selection where it was")
        Quire.Motion.finishAll()
        harness.list.tableView.enumerateAvailableRowViews { rowView, _ in
            guard let rowView = rowView as? ConversationRowView else { return }
            self.assertAtRest(rowView, "no row is left slid out")
        }

        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(undo.action), to: undo.target, from: undo), "the toast's Undo")
        XCTAssertTrue(try inInbox(id, harness), "Undo brings the mail back")
        XCTAssertEqual(harness.toastMessage, "Undid Archive")
        harness.spin { harness.list.conversations.contains { $0.id == id } }
        XCTAssertEqual(harness.list.selectedConversationID, id, "and selects it, as an undo of E does")
    }

    /// Let go short of a full swipe, the button stays open; a click on it is the change.
    func testClickingTheOpenButtonArchives() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        select(harness.list.conversations[0].id, harness)
        let id = harness.list.conversations[2].id
        let button = try open(2, .trailing, in: harness)
        XCTAssertEqual(button.frame.width, QuireSwipeButton.openWidth(title: "Archive", textSize: .default))
        XCTAssertEqual(button.currentLayout.labelAlpha, 1, "open, the label shows whole")
        XCTAssertTrue(try inInbox(id, harness), "opening it changes nothing")
        // The click lands on the button, not on the row's cell under it.
        let table = harness.list.tableView
        let centre = table.superview!.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), from: button.superview)
        XCTAssertTrue(table.hitTest(centre) === button, "the open button takes the click")
        XCTAssertTrue(button.accessibilityPerformPress(), "pressed")
        XCTAssertFalse(try inInbox(id, harness), "archived")
        XCTAssertEqual(harness.toastMessage, "Archived")
        harness.spin { !harness.list.conversations.contains { $0.id == id } }
        XCTAssertEqual(harness.list.selectedConversationID, harness.list.conversations[0].id, "the selection stays")
    }

    func testSwipingTheSelectedRowMovesTheSelectionOnAsE() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        let next = harness.list.conversations[2].id
        select(id, harness)
        try fullSwipe(1, .trailing, in: harness)
        harness.spin { harness.list.selectedConversationID != id }
        XCTAssertEqual(harness.list.selectedConversationID, next, "the row below takes the selection")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Archive", "Z reaches it")
    }

    /// Several swipes within the coalescing window are one step, as several presses of E are (§5.30).
    func testSwipesInQuickSuccessionAreOneToastAndOneUndo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let ids = [harness.list.conversations[1].id, harness.list.conversations[3].id]
        try fullSwipe(1, .trailing, in: harness)
        harness.spin { !harness.list.conversations.contains { $0.id == ids[0] } }
        let index = try XCTUnwrap(harness.list.conversations.firstIndex { $0.id == ids[1] })
        try fullSwipe(index, .trailing, in: harness)
        XCTAssertEqual(harness.toastMessage, "Archived 2 conversations")
        harness.spin { !harness.list.conversations.contains { ids.contains($0.id) } }
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertTrue(try ids.allSatisfy { try inInbox($0, harness) }, "one Z brings both back")
    }

    /// A refresh closes the open button, so it can never act on whatever row a refresh moved under it; and a swipe the
    /// fingers are still making when the rows move does nothing more.
    func testARefreshClosesTheButtonSoItNeverActsOnAnotherRow() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[3].id
        try open(3, .trailing, in: harness)
        let view = try rowView(3, harness)
        try harness.environment.engine.perform(.archive, on: harness.list.conversations[0].id)
        harness.spin { harness.list.conversations.firstIndex { $0.id == id } == 2 }
        Quire.Motion.finishAll()
        XCTAssertFalse(harness.list.swipe.gesture.isOpen)
        assertAtRest(view, "closed by the refresh")

        // Under the fingers when the rows move: the rest of the gesture moves and changes nothing.
        let row = try tableRow(2, harness)
        try swipe(2, by: -60, in: harness, lift: false)
        try harness.environment.engine.perform(.archive, on: harness.list.conversations[0].id)
        harness.spin { harness.list.conversations.firstIndex { $0.id == id } == 1 }
        harness.list.swipe.handle(Scroll(phase: .changed, dx: -400, dy: 0), atRow: row)
        harness.list.swipe.handle(Scroll(phase: .ended), atRow: row)
        Quire.Motion.finishAll()
        XCTAssertTrue(try inInbox(id, harness), "nothing archived")
        XCTAssertTrue(try harness.list.conversations.allSatisfy { try inInbox($0.id, harness) })
    }

    // MARK: Colours

    /// The two edges in their own colours, which follow the theme on a button already out: its fill is the live token,
    /// and the list marks it for drawing again on every theme change (§5.7, §4.16).
    func testTheEdgesWearTheirOwnColoursAndFollowTheTheme() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let environment = QuireEnvironment.shared
        let saved = environment.overrides
        defer { environment.setOverrides(saved) }
        func force(_ theme: QuireTheme) {
            environment.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false,
                                           theme: theme))
        }
        func hex(_ color: NSColor, _ mode: QuireMode) -> String {
            let c = mode.performAsCurrent { color.usingColorSpace(.sRGB) }!
            return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                          Int((c.blueComponent * 255).rounded()))
        }
        XCTAssertEqual(try open(1, .trailing, in: harness).kind, .archive)
        harness.list.swipe.close(animated: false)
        let unread = try open(1, .leading, in: harness)
        XCTAssertEqual(unread.kind, .markUnread)
        XCTAssertEqual(unread.title, "Mark as Unread")
        for mode in QuireMode.allCases {
            var seen: [QuireTheme: [String]] = [:]
            for theme in QuireTheme.allCases {
                force(theme)
                XCTAssertTrue(unread.needsDisplay, "\(theme): the open button is drawn again")
                unread.needsDisplay = false
                let fills = [hex(QuireSwipeAction.archive.fill, mode), hex(unread.kind.fill, mode)]
                XCTAssertNotEqual(fills[0], fills[1], "\(theme) \(mode.rawValue): the edges never look alike")
                XCTAssertEqual(fills, [hex(.qSwipeArchive, mode), hex(.qSwipeRead, mode)], "\(theme) \(mode.rawValue)")
                seen[theme] = fills
            }
            XCTAssertEqual(Set(seen.values.map { $0[0] }).count, QuireTheme.allCases.count, "\(mode.rawValue): Archive per theme")
            XCTAssertEqual(Set(seen.values.map { $0[1] }).count, QuireTheme.allCases.count, "\(mode.rawValue): the grey per theme")
        }
    }

    // MARK: Where E would change nothing

    func testTheTrashOffersNoArchive() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[0].id
        try harness.environment.engine.perform(.trash, on: id)
        XCTAssertTrue(harness.controller.perform(.goTo(.trash)))
        harness.spin { harness.list.query.view == .trash && harness.list.conversations.contains { $0.id == id } }
        let index = try XCTUnwrap(harness.list.conversations.firstIndex { $0.id == id })
        let offer = try XCTUnwrap(harness.list.swipeRow(atTableRow: try tableRow(index, harness)))
        XCTAssertNil(offer.trailing, "E beeps there, so no button")
        XCTAssertNotNil(offer.leading, "U works in the Trash")
        try swipe(index, by: -200, in: harness, lift: false)
        let view = try rowView(index, harness)
        assertAtRest(view, "the content does not move toward an edge that offers nothing")
        let swiped = try tableRow(index, harness)
        harness.list.swipe.handle(Scroll(phase: .ended), atRow: swiped)
        XCTAssertEqual(try cell(forConversation: index, in: harness).accessibilityCustomActions()?.map(\.name),
                       [try XCTUnwrap(offer.leading).title], "nor for VoiceOver")
    }

    func testHeadsAndTheTailOfferNothing() throws {
        let harness = try MainWindowHarness(threads: 40)
        defer { harness.close() }
        let list = harness.list
        let others = list.layout.items.indices.filter { list.layout.conversationIndex(atRow: $0) == nil }
        XCTAssertFalse(others.isEmpty, "a running head at least")
        for row in others {
            XCTAssertNil(list.swipeRow(atTableRow: row), "row \(row)")
            var scrolled = 0
            let event = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
            list.swipe.handle(Scroll(phase: .began, dx: -20, dy: 0), atRow: row, event: event) { _ in scrolled += 1 }
            list.swipe.handle(Scroll(phase: .changed, dx: -40, dy: 0), atRow: row, event: event) { _ in scrolled += 1 }
            list.swipe.handle(Scroll(phase: .ended), atRow: row, event: event) { _ in scrolled += 1 }
            XCTAssertEqual(scrolled, 3, "row \(row): a sideways gesture there is the table's")
            XCTAssertNil(list.swipe.gesture.row)
        }
    }

    /// In Later E ends the snooze and leaves the mail archived; the swipe's Archive does the same.
    func testInLaterArchiveEndsTheSnooze() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        let store = harness.environment.store
        let targets = try store.messages(in: id).filter(\.isInInbox).map(\.id)
        try store.setSnoozes([Snooze.Change(conversationID: id, until: Date().addingTimeInterval(86_400))],
                             enqueueing: [SSCore.Operation(accountID: id.accountID, change: .archive, targets: targets)], at: Date())
        harness.spin { harness.controller.snoozes.count == 1 }
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.query.view == .later && harness.list.conversations.count == 1 }

        XCTAssertEqual(harness.list.swipeRow(atTableRow: try tableRow(0, harness))?.trailing?.title, "Archive")
        try fullSwipe(0, .trailing, in: harness)
        XCTAssertEqual(try store.snoozes().count, 0, "the snooze ends")
        XCTAssertFalse(try inInbox(id, harness), "and the mail stays archived")
        XCTAssertEqual(harness.toastMessage, "Archived", "E's toast in Later")
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [id], "Undo puts the snooze back")
    }

    // MARK: Read and unread

    func testALeadingSwipeMarksReadOrUnreadAsUDoes() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        // Every third thread is unread: the first is, the second is not.
        let unread = harness.list.conversations[0]
        let read = harness.list.conversations[1]
        XCTAssertGreaterThan(unread.unreadCount, 0)
        XCTAssertEqual(read.unreadCount, 0)

        let markRead = try open(0, .leading, in: harness)
        XCTAssertEqual(markRead.title, "Mark as Read")
        XCTAssertEqual(markRead.kind, .markRead)
        XCTAssertEqual(markRead.kind.symbolName, Quire.Icon.markRead, "the envelope the menus and the toast show")
        XCTAssertEqual(markRead.frame.minX, 0, "on the leading edge")
        let markUnread = try open(1, .leading, in: harness)
        XCTAssertEqual(markUnread.title, "Mark as Unread")
        XCTAssertEqual(markUnread.kind.symbolName, Quire.Icon.markUnread)
        XCTAssertNil(try rowView(0, harness).swipeButton, "one row open at a time")
        for button in [markRead, markUnread] {
            XCTAssertTrue(button.kind.fill === NSColor.qSwipeRead, "the quiet grey, never Archive's fill (§5.7)")
        }
        harness.list.swipe.close(animated: false)

        try fullSwipe(0, .leading, in: harness)
        XCTAssertTrue(try harness.environment.store.messages(in: unread.id).allSatisfy(\.isRead), "read in the store at once")
        XCTAssertNil(harness.toastMessage, "as with U, the row itself shows the change")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Mark as Read", "Z still reaches it")
        harness.spin { harness.list.conversations.first { $0.id == unread.id }?.unreadCount == 0 }
        Quire.Motion.finishAll()
        assertAtRest(try rowView(0, harness), "the row settles back and shows the change")
        XCTAssertEqual(harness.list.swipeRow(atTableRow: try tableRow(0, harness))?.leading?.title, "Mark as Unread", "the button follows the row")
    }

    // MARK: Close rules

    /// An open button closes on a scroll of the list, a click anywhere but on it, Esc, a selection change and another
    /// row's swipe; a click on it is no close.
    func testTheOpenButtonClosesOnTheCloseRules() throws {
        let harness = try MainWindowHarness(threads: 40)
        defer { harness.close() }
        let list = harness.list
        let window = try XCTUnwrap(list.view.window)
        func closed(_ rule: String, file: StaticString = #filePath, line: UInt = #line) throws {
            Quire.Motion.finishAll()
            XCTAssertNotEqual(list.swipe.gesture.row?.id, list.conversations[1].id, rule, file: file, line: line)
            assertAtRest(try rowView(1, harness), rule, file: file, line: line)
        }
        func click(at point: NSPoint, in view: NSView) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        // The list scrolls.
        try open(1, .trailing, in: harness)
        let clip = list.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 20))
        list.scrollView.reflectScrolledClipView(clip)
        try closed("a scroll")
        clip.scroll(to: .zero)
        list.scrollView.reflectScrolledClipView(clip)

        // A trackpad scroll up or down closes it as it starts.
        try open(1, .trailing, in: harness)
        let other = try tableRow(4, harness)
        list.swipe.handle(Scroll(phase: .began, dx: 0, dy: -8), atRow: other)
        list.swipe.handle(Scroll(phase: .ended), atRow: other)
        try closed("a trackpad scroll")

        // Esc, and nothing else hears it.
        try open(1, .trailing, in: harness)
        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                 context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(list.swipe.consumes(esc), "Esc goes no further")
        try closed("Esc")
        XCTAssertFalse(list.swipe.consumes(esc), "with nothing open Esc is everyone else's")

        // A click on the button is the button's; a click anywhere else closes it and goes on.
        let button = try open(1, .trailing, in: harness)
        XCTAssertFalse(list.swipe.consumes(try click(at: NSPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)))
        XCTAssertTrue(list.swipe.gesture.isOpen, "a click on the button is no close")
        let elsewhere = try rowView(3, harness)
        XCTAssertFalse(list.swipe.consumes(try click(at: NSPoint(x: 40, y: 10), in: elsewhere)), "the click goes on to the row")
        try closed("a click elsewhere")

        // The selection changes.
        try open(1, .trailing, in: harness)
        select(list.conversations[5].id, harness)
        try closed("a selection change")

        // Another row's swipe.
        try open(1, .trailing, in: harness)
        try open(2, .leading, in: harness)
        try closed("another row's swipe")
        XCTAssertTrue(list.swipe.gesture.isOpen, "the other row is open")
        XCTAssertEqual(list.swipe.gesture.row?.id, list.conversations[2].id)
    }

    /// The row follows the fingers whatever Reduce Motion says; letting go settles it over `dur.standard` with motion, and
    /// puts it where it settles at once without.
    func testReduceMotionSettlesAtOnce() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let environment = QuireEnvironment.shared
        let saved = environment.overrides
        defer { environment.setOverrides(saved) }
        for reduce in [false, true] {
            environment.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: reduce, reduceTransparency: false))
            Quire.Motion.finishAll()
            let row = try tableRow(1, harness)
            let view = try rowView(1, harness)
            try swipe(1, by: -50, in: harness, lift: false)
            XCTAssertEqual(view.swipeOffset, -50, "Reduce Motion \(reduce): under the fingers")
            harness.list.swipe.handle(Scroll(phase: .ended), atRow: row)
            if reduce {
                XCTAssertFalse(view.isSettlingSwipe, "no settle runs")
                XCTAssertEqual(view.swipeOffset, -QuireSwipeButton.openWidth(title: "Archive", textSize: .default), "open at once")
            } else {
                XCTAssertTrue(view.isSettlingSwipe, "it settles open")
                XCTAssertEqual(view.swipeOffset, -50, "from where it was let go of")
                harness.spin { !view.isSettlingSwipe }
                XCTAssertEqual(view.swipeOffset, -QuireSwipeButton.openWidth(title: "Archive", textSize: .default), "and lands open")
            }
            harness.list.swipe.close()
            if reduce { assertAtRest(view, "closed at once") }
            Quire.Motion.finishAll()
            assertAtRest(view, "closed")
        }
    }

    /// The content draws where the fingers put it: the row's own fill and the cell's lines move together, and nothing is
    /// left where the button is.
    func testTheContentSlidesWithTheFingers() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let view = try rowView(1, harness)
        let cell = try cell(forConversation: 1, in: harness)
        let cellFrame = cell.frame
        try swipe(1, by: 72, in: harness, lift: false)
        XCTAssertEqual(view.swipeOffset, 72)
        XCTAssertEqual(cell.swipeOffset, 72, "the cell draws moved with the row")
        XCTAssertEqual(cell.frame, cellFrame, "no frame moves, so the table's layout cannot undo it")
        XCTAssertEqual(view.swipeButton?.frame, NSRect(x: 0, y: 0, width: 72, height: view.bounds.height))
        view.layoutSubtreeIfNeeded()
        harness.list.tableView.tile()
        XCTAssertEqual(cell.swipeOffset, 72)
        XCTAssertEqual(view.swipeOffset, 72)
        let swiped = try tableRow(1, harness)
        harness.list.swipe.handle(Scroll(phase: .ended), atRow: swiped)
        harness.list.swipe.close(animated: false)
        assertAtRest(view, "closed")
        XCTAssertEqual(cell.swipeOffset, 0)
    }

    // MARK: Scrolling

    /// The swipe takes only sideways gestures over rows: the list still scrolls up and down, with a trackpad's phases or a
    /// mouse's wheel, through the table's own scroll events; and a sideways scroll that is no swipe (a wheel's tilt) never
    /// moves it sideways.
    func testTheListStillScrollsAndNeverSideways() throws {
        let harness = try MainWindowHarness(threads: 40)
        defer { harness.close() }
        let list = harness.list
        // A scroll view scrolls only in a window that is ordered in: this one, off every screen, invisible and taking no
        // clicks.
        let window = try XCTUnwrap(list.view.window)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let clip = list.scrollView.contentView
        XCTAssertGreaterThan(list.tableView.bounds.height, clip.bounds.height, "a list taller than its pane")
        func wheel(dx: Int32, dy: Int32, phase: Int64? = nil) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            if let phase { event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase) }
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        list.tableView.scrollWheel(with: try wheel(dx: -80, dy: 0))
        XCTAssertEqual(clip.bounds.origin.x, 0, "never sideways")
        XCTAssertEqual(clip.bounds.origin.y, 0)
        list.tableView.scrollWheel(with: try wheel(dx: 0, dy: -120))
        harness.spin { clip.bounds.origin.y > 0 }
        XCTAssertGreaterThan(clip.bounds.origin.y, 0, "down the list with a wheel")
        XCTAssertEqual(clip.bounds.origin.x, 0)

        // A trackpad's scroll up and down: every event, the first one included, goes back to the table. (AppKit scrolls
        // for phased events only from a real trackpad, so this counts what reaches the table rather than the distance.)
        let row = try tableRow(3, harness)
        var events = [try wheel(dx: 0, dy: -10, phase: 1)]
        for _ in 0..<6 { events.append(try wheel(dx: 0, dy: -30, phase: 2)) }
        events.append(try wheel(dx: 0, dy: 0, phase: 4))
        var reached: [NSEvent] = []
        for event in events {
            list.swipe.handle(RowSwipeController.scroll(from: event), atRow: row, event: event) { reached.append($0) }
        }
        XCTAssertEqual(reached, events, "and with a trackpad's phases")
        XCTAssertNil(list.swipe.gesture.row, "which is no swipe")
        // Fingers that rest before they move: the first event waits for the second, then both go to the table, in order.
        let resting = [try wheel(dx: 0, dy: 0, phase: 1), try wheel(dx: 0, dy: -30, phase: 2), try wheel(dx: 0, dy: 0, phase: 4)]
        reached = []
        for event in resting {
            list.swipe.handle(RowSwipeController.scroll(from: event), atRow: row, event: event) { reached.append($0) }
        }
        XCTAssertEqual(reached, resting)
        for event in events { list.tableView.scrollWheel(with: event) }
        XCTAssertEqual(try rowView(3, harness).swipeOffset, 0, "the row under the fingers never moves")
    }

    /// A trackpad's sideways scroll, as AppKit delivers it to the table, swipes the row under the pointer.
    func testATrackpadsSidewaysScrollThroughTheTableSwipesTheRowUnderThePointer() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        guard let screen = NSScreen.screens.first else { throw XCTSkip("no screen to place the events on") }
        let list = harness.list
        let table = list.tableView
        let rect = table.rect(ofRow: try tableRow(2, harness))
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ dx: Int32, phase: Int64) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            // An event made without a window says where it happened on the screen, which is where the table reads it.
            event.location = CGPoint(x: point.x, y: screen.frame.height - point.y)
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        let first = try event(-6, phase: 1)
        XCTAssertEqual(table.row(at: table.convert(first.locationInWindow, from: nil)), try tableRow(2, harness), "the event lands on the row")
        // The fingers move left: the deltas follow the content, which follows the fingers only under natural scrolling.
        let sign: Int32 = first.isDirectionInvertedFromDevice ? 1 : -1
        table.scrollWheel(with: try event(-6 * sign, phase: 1))
        for _ in 0..<5 { table.scrollWheel(with: try event(-10 * sign, phase: 2)) }
        let view = try rowView(2, harness)
        XCTAssertEqual(view.swipeOffset, -56, accuracy: 0.5, "the row follows the fingers to the left")
        XCTAssertEqual(view.swipeButton?.kind, .archive)
        XCTAssertEqual(list.scrollView.contentView.bounds.origin, .zero, "and the list does not scroll")
        table.scrollWheel(with: try event(0, phase: 4))
        Quire.Motion.finishAll()
        XCTAssertEqual(view.swipeOffset, -QuireSwipeButton.openWidth(title: "Archive", textSize: .default), "let go past half: open")
        list.swipe.close(animated: false)
    }

    // MARK: VoiceOver

    func testTheRowsVoiceOverActionsAreTheSwipes() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        let actions = try XCTUnwrap(try cell(forConversation: 1, in: harness).accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Archive", "Mark as Unread"], "Archive first")
        XCTAssertEqual(actions[0].handler?(), true)
        XCTAssertFalse(try inInbox(id, harness), "archived through E's path")
        XCTAssertEqual(harness.toastMessage, "Archived")
    }

    /// The open button is a button VoiceOver can find and press, named by its words.
    func testTheOpenButtonIsAButtonForVoiceOver() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        let button = try open(1, .trailing, in: harness)
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), "Archive")
        XCTAssertTrue(try rowView(1, harness).accessibilityChildren()?.contains { ($0 as AnyObject) === button } ?? false)
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertFalse(try inInbox(id, harness))
    }

    /// The list on its own, with no host to apply them, offers neither a swipe nor a VoiceOver action.
    func testAListWithoutAHostOffersNothing() throws {
        let store = try ListTestSupport.store(threads: 6)
        let (list, _) = ListTestSupport.host(store: store, settings: ListTestSupport.settings())
        let row = try XCTUnwrap(list.layout.row(ofConversation: 0))
        XCTAssertNil(list.swipeRow(atTableRow: row))
        let cell = try XCTUnwrap(list.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ConversationCellView)
        XCTAssertNil(cell.accessibilityCustomActions())
    }
}
