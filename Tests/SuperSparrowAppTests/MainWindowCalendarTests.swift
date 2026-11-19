import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The calendar in the main window (spec §5.54, §5.1, §3.2, §6, §6.1): the day column on by default and kept by D, folded to
/// its strip in a narrow window and opened over the reader from it, the week in place of both with the reader hidden, the
/// keys and menus that turn them, the column following the selection, time set aside with B or a dropped row and taken
/// back with Z, Remove and its undo, and B in a reader window. On a fixed clock and calendar: Thursday 19 November 2026,
/// 11:40 in Berlin, Monday weeks.
@MainActor
final class MainWindowCalendarTests: XCTestCase {
    private typealias Support = CalendarTestSupport
    private typealias Pane = Quire.Layout.CalendarPane

    private var harnesses: [MainWindowHarness] = []
    private var pasteboards: [NSPasteboard] = []
    private var opened: [URL] = []

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { _ = NSApplication.shared }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for harness in harnesses { harness.close() }
            harnesses = []
            for pasteboard in pasteboards { pasteboard.releaseGlobally() }
            pasteboards = []
            opened = []
        }
        super.tearDown()
    }

    // MARK: Helpers

    private func harness(settings: AppSettings? = nil, accounts: Bool = true, clock: Support.Clock = Support.Clock()) throws -> MainWindowHarness {
        let harness = try MainWindowHarness(accounts: accounts, settings: settings, calendar: Support.calendar, now: { clock.now })
        harnesses.append(harness)
        harness.controller.openCalendarURL = { [weak self] url in self?.opened.append(url) }
        layOut(harness)
        return harness
    }

    private func layOut(_ harness: MainWindowHarness) {
        harness.controller.window?.layoutIfNeeded()
        harness.controller.splitView.layoutSubtreeIfNeeded()
        harness.controller.desk.view.layoutSubtreeIfNeeded()
    }

    private func resize(_ harness: MainWindowHarness, width: CGFloat) {
        harness.controller.window?.setContentSize(NSSize(width: width, height: 800))
        layOut(harness)
    }

    private func close(_ harness: MainWindowHarness) {
        harness.close()
        harnesses.removeAll { $0 === harness }
    }

    private func select(_ id: ConversationID, in harness: MainWindowHarness) {
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
    }

    /// Selects `id` and waits for the calendar to have read its invitation and times.
    private func selectAndWait(_ id: ConversationID, in harness: MainWindowHarness) {
        select(id, in: harness)
        harness.spin { harness.controller.calendarState.selection?.conversationID == id }
    }

    private func conversation(_ index: Int, in harness: MainWindowHarness) -> ConversationID {
        harness.list.conversations[index].id
    }

    private func newest(in id: ConversationID, of harness: MainWindowHarness) throws -> MessageMetadata {
        try XCTUnwrap(try harness.environment.store.messages(in: id).max { $0.date < $1.date })
    }

    /// Gives `id`'s newest message an invitation from `start` to `end`, as the reader's card would read it.
    private func invite(_ id: ConversationID, in harness: MainWindowHarness, start: Date, end: Date) throws -> MessageID {
        let message = try newest(in: id, of: harness)
        let account = id.accountID == Support.accountA.id ? Support.accountA : Support.accountB
        let invitation = CalendarInvitation(method: .request, uid: "uid-\(id.providerID)", title: "Design review", start: start, end: end,
                                            location: "Bay 4", organizer: .init(name: "Rachel Kim", address: "rachel@contoso.test"),
                                            userAddress: account.email, userResponse: .needsAction)
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: nil, text: ""), renderedHTML: "", plainText: "",
                                                          invitation: invitation), for: message.id)
        return message.id
    }

    /// Has `id`'s newest message name a time ahead, as the hydrator finds it.
    private func nameTime(_ id: ConversationID, in harness: MainWindowHarness, at start: Date) throws {
        let message = try newest(in: id, of: harness)
        try harness.environment.store.saveMailTimes([MailTime(messageID: message.id, start: start, phrase: "3pm")], for: message.id)
    }

    private func events(_ harness: MainWindowHarness) throws -> [CalendarEvent] {
        try harness.environment.store.calendarEvents(in: DateInterval(start: Support.day(1), end: Support.day(31, month: 12)),
                                                     accountIDs: nil)
    }

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    private func press(_ characters: String, keyCode: UInt16, in window: NSWindow) throws {
        KeyboardRouter.keyWindowForTests = window
        defer { KeyboardRouter.keyWindowForTests = nil }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: keyCode))
        NSApp.sendEvent(event)
    }

    /// A drag of `id`'s row, written by the list itself.
    private func drag(_ id: ConversationID, in harness: MainWindowHarness) throws -> FakeDraggingInfo {
        let list = harness.list
        let index = try XCTUnwrap(list.conversations.firstIndex { $0.id == id })
        let row = try XCTUnwrap(list.layout.row(ofConversation: index))
        let item = try XCTUnwrap(list.tableView(list.tableView, pasteboardWriterForRow: row))
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        pasteboard.writeObjects([item])
        return FakeDraggingInfo(pasteboard: pasteboard, source: list.tableView, mask: [.copy, .move])
    }

    // MARK: Placement

    func testTheColumnShowsByDefaultAndDKeepsItsChoiceForTheNextWindow() throws {
        let settings = ListTestSupport.settings()
        var harness = try self.harness(settings: settings)
        var desk = harness.controller.desk
        XCTAssertEqual(desk.placement, .column, "on by default")
        XCTAssertFalse(desk.column.isHidden)
        XCTAssertFalse(desk.column.isOverlay)
        XCTAssertEqual(desk.column.frame.width, Pane.columnWidth)
        XCTAssertEqual(desk.column.frame.maxX, desk.view.bounds.width, "at the reader's trailing edge")
        XCTAssertEqual(desk.conversationPane.view.frame.width, desk.view.bounds.width - Pane.columnWidth, accuracy: 0.5)
        XCTAssertEqual(harness.reader.header.layoutToggles[.day]?.isOn, true, "the header's Day button is on")
        XCTAssertEqual(harness.reader.header.layoutToggles[.day]?.toolTip, "Hide Day  D")
        XCTAssertEqual(harness.reader.header.layoutToggles[.week]?.toolTip, "Show Week  W")

        XCTAssertTrue(harness.controller.perform(.toggleDayColumn))
        XCTAssertEqual(desk.placement, .none)
        XCTAssertTrue(desk.column.isHidden)
        XCTAssertTrue(desk.strip.isHidden)
        XCTAssertEqual(desk.conversationPane.view.frame.width, desk.view.bounds.width, accuracy: 0.5, "the reader takes its 240 pt back")
        XCTAssertFalse(settings.showsDayColumn, "kept in the app's settings")
        XCTAssertEqual(harness.reader.header.layoutToggles[.day]?.isOn, false)
        XCTAssertEqual(harness.reader.header.layoutToggles[.day]?.toolTip, "Show Day  D")

        close(harness)
        harness = try self.harness(settings: settings)
        desk = harness.controller.desk
        XCTAssertEqual(desk.placement, .none, "a new window opens as the last was left")
        // The header's Day button does what D does.
        let day = try XCTUnwrap(harness.reader.header.layoutToggles[.day])
        day.performClick(nil)
        XCTAssertEqual(desk.placement, .column)
        XCTAssertTrue(settings.showsDayColumn)
    }

    func testANarrowWindowFoldsTheColumnToItsStripWhichOpensItOverTheReader() throws {
        let harness = try self.harness()
        let desk = harness.controller.desk
        resize(harness, width: 960)
        XCTAssertEqual(desk.placement, .strip, "960 less the rail and the list leaves no 640 for a reader and the column")
        XCTAssertFalse(desk.strip.isHidden)
        XCTAssertTrue(desk.column.isHidden)
        XCTAssertEqual(desk.strip.frame.width, Pane.stripWidth)
        XCTAssertEqual(desk.strip.frame.maxX, desk.view.bounds.width)
        XCTAssertGreaterThanOrEqual(desk.conversationPane.view.frame.width, Quire.Layout.Window.readerMinWidth, "the reader keeps 400")
        XCTAssertEqual(harness.reader.header.layoutToggles[.day]?.isOn, false, "Day is off while folded")

        // A click on the strip opens the column over the reader's edge, just before the strip.
        XCTAssertTrue(desk.strip.accessibilityPerformPress())
        XCTAssertTrue(desk.isOverlayOpen)
        XCTAssertFalse(desk.column.isHidden)
        XCTAssertTrue(desk.column.isOverlay)
        XCTAssertEqual(desk.column.frame.maxX, desk.strip.frame.minX)
        XCTAssertTrue(desk.strip.isOpen)
        XCTAssertFalse(desk.readerCover.isHidden, "a click in the reader closes it")
        XCTAssertEqual(harness.reader.header.layoutToggles[.day]?.isOn, true)

        // Esc closes it (row 11), D closes it, and a click in the reader closes it and does nothing else.
        XCTAssertTrue(harness.controller.perform(.clearSearch))
        XCTAssertFalse(desk.isOverlayOpen)
        XCTAssertTrue(desk.column.isHidden)
        XCTAssertTrue(harness.controller.perform(.toggleDayColumn))
        XCTAssertTrue(desk.isOverlayOpen, "D opens it too")
        XCTAssertTrue(harness.controller.perform(.toggleDayColumn))
        XCTAssertFalse(desk.isOverlayOpen)
        desk.setOverlayOpen(true)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: harness.controller.window?.windowNumber ?? 0, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        desk.readerCover.mouseDown(with: click)
        XCTAssertFalse(desk.isOverlayOpen)
        XCTAssertTrue(desk.readerCover.isHidden)

        // Widening the window until the column fits puts it in place.
        desk.setOverlayOpen(true)
        resize(harness, width: 1_304)
        XCTAssertEqual(desk.placement, .column)
        XCTAssertFalse(desk.isOverlayOpen)
        XCTAssertFalse(desk.column.isOverlay)
        XCTAssertFalse(desk.column.isHidden)
    }

    func testTheListMaximumGivesUpTheStripWhileTheColumnIsOn() throws {
        let harness = try self.harness()
        // The split's autosave writes the test process's own defaults: a list dragged wide here would open every later
        // window's list that wide. Forgetting it leaves them the first run's default placement, as before any test.
        defer {
            close(harness)
            UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames MainSplit")
        }
        resize(harness, width: 1_440)
        let split = harness.controller.splitView
        let list = split.arrangedSubviews[1]
        split.setPosition(split.arrangedSubviews[0].frame.maxX + 600, ofDividerAt: 1)
        layOut(harness)
        XCTAssertEqual(list.frame.width, ListPaneViewController.maximumWidth - Pane.stripWidth, accuracy: 1, "480 less 28")
        XCTAssertTrue(harness.controller.perform(.toggleDayColumn))
        split.setPosition(split.arrangedSubviews[0].frame.maxX + 600, ofDividerAt: 1)
        layOut(harness)
        XCTAssertEqual(list.frame.width, ListPaneViewController.maximumWidth, accuracy: 1, "480 with the column hidden")
    }

    // MARK: The week

    func testWShowsTheWeekHidingTheReaderAndReturnsToTheDayItLeftAfterPaging() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let desk = controller.desk
        let state = controller.calendarState
        let reader = desk.conversationPane.view
        XCTAssertTrue(controller.perform(.nextDay))
        XCTAssertEqual(state.shownDay, Support.day(20))

        XCTAssertTrue(controller.perform(.toggleWeek))
        XCTAssertEqual(desk.placement, .week)
        XCTAssertEqual(state.span, .week)
        XCTAssertFalse(desk.week.isHidden)
        XCTAssertTrue(desk.column.isHidden)
        XCTAssertTrue(reader.isHidden, "the reader is hidden")
        XCTAssertTrue(reader.superview === desk.view, "never taken out of the window: its pooled web views stay")
        XCTAssertNotNil(harness.reader.view.window)
        XCTAssertEqual(state.shownWeekDays.first, Support.day(16), "the week of the column's day")

        // [ ] and T turn the week, never the day the column will show.
        XCTAssertTrue(controller.perform(.nextDay))
        XCTAssertEqual(state.shownWeekDays.first, Support.day(23))
        XCTAssertTrue(controller.perform(.nextDay))
        XCTAssertTrue(controller.perform(.previousDay))
        XCTAssertEqual(state.shownWeekDays.first, Support.day(23))
        XCTAssertEqual(state.shownDay, Support.day(20))

        XCTAssertTrue(controller.perform(.toggleWeek))
        XCTAssertEqual(desk.placement, .column)
        XCTAssertEqual(state.span, .day)
        XCTAssertFalse(reader.isHidden)
        XCTAssertTrue(desk.week.isHidden)
        XCTAssertEqual(state.shownDay, Support.day(20), "back on the day it showed before the week opened")

        // D from the week goes back too.
        XCTAssertTrue(controller.perform(.toggleWeek))
        XCTAssertTrue(controller.perform(.toggleDayColumn))
        XCTAssertEqual(desk.placement, .column)
    }

    func testADaysHeadingInTheWeekGoesBackOnThatDay() throws {
        let harness = try self.harness()
        let controller = harness.controller
        XCTAssertTrue(controller.perform(.toggleWeek))
        controller.desk.week.layoutSubtreeIfNeeded()
        controller.openWeekHeading(day: Support.day(17))
        XCTAssertEqual(controller.desk.placement, .column)
        XCTAssertEqual(controller.calendarState.shownDay, Support.day(17))
    }

    func testBracketsAndTTurnTheDayAndTheWeekOnlyWhileOneShows() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let state = controller.calendarState
        XCTAssertTrue(controller.perform(.nextDay))
        XCTAssertTrue(controller.perform(.nextDay))
        XCTAssertEqual(state.shownDay, Support.day(21))
        XCTAssertTrue(controller.perform(.previousDay))
        XCTAssertEqual(state.shownDay, Support.day(20))
        XCTAssertTrue(controller.perform(.today))
        XCTAssertEqual(state.shownDay, Support.day(19))

        XCTAssertTrue(controller.perform(.toggleWeek))
        XCTAssertTrue(controller.perform(.previousDay))
        XCTAssertEqual(state.shownWeekDays.first, Support.day(9))
        XCTAssertTrue(controller.perform(.today))
        XCTAssertEqual(state.shownWeekDays.first, Support.day(16), "this week")
        XCTAssertTrue(controller.perform(.toggleWeek))

        // With the column hidden (or folded to its strip) there is nothing to turn: the keys pass on.
        XCTAssertTrue(controller.perform(.toggleDayColumn))
        XCTAssertFalse(controller.perform(.nextDay))
        XCTAssertFalse(controller.perform(.today))
        XCTAssertEqual(state.shownDay, Support.day(19))
        XCTAssertTrue(controller.perform(.toggleDayColumn))
        resize(harness, width: 960)
        XCTAssertFalse(controller.perform(.previousDay), "the strip alone turns nothing")
    }

    func testTheWeeksInvitationCardAnswersAsTheReadersDoesAndEscHidesIt() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let id = conversation(1, in: harness)
        let message = try invite(id, in: harness, start: Support.at(13, 30, on: Support.day(20)), end: Support.at(14, 30, on: Support.day(20)))
        XCTAssertTrue(controller.perform(.toggleWeek))
        selectAndWait(id, in: harness)
        let week = controller.desk.week
        harness.spin { week.invitationCard != nil }
        let card = try XCTUnwrap(week.invitationCard)
        XCTAssertEqual(card.buttons.map(\.title), ["Accept", "Tentative", "Decline"])
        card.buttons[0].performClick(nil)
        XCTAssertEqual(try harness.environment.store.message(message)?.invitationReply, .accepted, "stored as the reader's card stores it")
        XCTAssertNil(harness.toastMessage, "no toast, no undo (§5.14)")

        harness.spin { week.invitationCard != nil }
        XCTAssertTrue(controller.perform(.clearSearch), "Esc's row 12")
        XCTAssertNil(week.invitationCard)
        XCTAssertEqual(controller.desk.placement, .week, "the week stays")
    }

    // MARK: Following the mail

    func testJAndKTurnTheColumnToAnInvitationsDayAndAMailsTimeAndBack() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let state = controller.calendarState
        let plain = conversation(0, in: harness)
        let invited = conversation(1, in: harness)
        let timed = conversation(2, in: harness)
        _ = try invite(invited, in: harness, start: Support.at(10, on: Support.day(24)), end: Support.at(11, on: Support.day(24)))
        try nameTime(timed, in: harness, at: Support.at(15, on: Support.day(25)))

        selectAndWait(plain, in: harness)
        XCTAssertEqual(state.shownDay, Support.day(19), "a mail about no time leaves the column where it was")
        XCTAssertTrue(controller.perform(.next))
        harness.spin { state.selection?.conversationID == invited }
        XCTAssertEqual(state.shownDay, Support.day(24), "the invitation's day")
        XCTAssertTrue(controller.perform(.next))
        harness.spin { state.selection?.conversationID == timed }
        XCTAssertEqual(state.shownDay, Support.day(25), "the day the mail names")
        XCTAssertTrue(controller.perform(.previous))
        XCTAssertTrue(controller.perform(.previous))
        harness.spin { state.selection?.conversationID == plain }
        XCTAssertEqual(state.shownDay, Support.day(19), "moving past turns it back")

        // The day the user turns to is where it goes back to.
        XCTAssertTrue(controller.perform(.nextDay))
        selectAndWait(invited, in: harness)
        XCTAssertEqual(state.shownDay, Support.day(24))
        selectAndWait(plain, in: harness)
        XCTAssertEqual(state.shownDay, Support.day(20))

        // While the week shows, the week follows.
        XCTAssertTrue(controller.perform(.toggleWeek))
        selectAndWait(timed, in: harness)
        XCTAssertEqual(state.shownWeekDays.first, Support.day(23))
        XCTAssertTrue(controller.perform(.toggleWeek))
        XCTAssertEqual(state.shownDay, Support.day(25), "and the column comes back on the selected mail's day")
    }

    // MARK: Setting time aside

    func testBSetsTimeAsideAtTheMailsTimeWithAToastAndZTakesItBack() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let id = conversation(2, in: harness)
        try nameTime(id, in: harness, at: Support.at(15, on: Support.day(25)))
        selectAndWait(id, in: harness)
        let newest = try newest(in: id, of: harness)

        XCTAssertTrue(controller.perform(.blockTime))
        let block = try XCTUnwrap(try events(harness).first)
        XCTAssertEqual(block.start, Support.at(15, on: Support.day(25)))
        XCTAssertEqual(block.end, Support.at(15, 30, on: Support.day(25)))
        XCTAssertEqual(block.accountID, id.accountID)
        XCTAssertEqual(block.title, newest.subject)
        XCTAssertEqual(block.sourceMessage, newest.id)
        XCTAssertEqual(block.sync, .creating)
        XCTAssertNotNil(block.clientKey)
        XCTAssertEqual(harness.toastMessage, "Blocked Wed 15:00 - 15:30")
        XCTAssertEqual(controller.calendarState.shownDay, Support.day(25), "the column turns to it")
        let undo = NSMenuItem(title: "", action: #selector(MainWindow.undo(_:)), keyEquivalent: "z")
        XCTAssertTrue(controller.validateEditUndo(undo))
        XCTAssertEqual(undo.title, "Undo Block Time")

        XCTAssertTrue(controller.perform(.undo), "Z")
        XCTAssertTrue(try events(harness).isEmpty, "a block the provider never had goes at once")
        XCTAssertEqual(harness.toastMessage, "Undid Block Time")
    }

    func testBWithoutATimeTakesTheFirstFreeHalfHourAndCommandZTakesItBack() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let id = conversation(0, in: harness)
        let busy = Support.event("busy", account: Support.accountB, title: "Busy", start: Support.at(11, 30), end: Support.at(12, 30))
        try Support.write([busy], to: harness.environment.store)
        selectAndWait(id, in: harness)
        XCTAssertTrue(controller.perform(.blockTime))
        let block = try XCTUnwrap(try events(harness).first { $0.id != busy.id })
        XCTAssertEqual(block.start, Support.at(12, 30), "the first free half hour, on the quarter hour, after now and what is busy")
        XCTAssertEqual(harness.toastMessage, "Blocked 12:30 - 13:00")
        controller.performUndo(controller.commandZTarget(textCanUndo: false))
        XCTAssertFalse(try events(harness).contains { $0.id == block.id }, "⌘Z")

        // Nothing or several selected: B beeps and sets nothing aside.
        harness.selectFirst(2)
        XCTAssertTrue(controller.perform(.blockTime))
        XCTAssertEqual(try events(harness).count, 1)
    }

    func testBOnAnInvitationOnlyPointsToItsCard() throws {
        let harness = try self.harness()
        let id = conversation(1, in: harness)
        _ = try invite(id, in: harness, start: Support.at(16), end: Support.at(17))
        selectAndWait(id, in: harness)
        XCTAssertTrue(harness.controller.perform(.blockTime))
        XCTAssertTrue(try events(harness).isEmpty)
        XCTAssertEqual(harness.toastMessage, "Answer the invitation to put it in your calendar")
    }

    func testARowDroppedOnTheColumnSetsTimeAsideAtTheSnappedTimeAndOnADayCellAtItsFirstFreeHalfHour() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let id = conversation(3, in: harness)
        let timeline = controller.desk.column.timeline
        timeline.layoutSubtreeIfNeeded()
        let fit = try XCTUnwrap(timeline.fit)
        let info = try drag(id, in: harness)
        info.draggingLocation = timeline.convert(NSPoint(x: timeline.dayX(0) + 40,
                                                         y: timeline.hoursTop + CGFloat(fit.y(forMinute: 14 * 60 + 20))), to: nil)
        XCTAssertEqual(timeline.draggingUpdated(info), .copy)
        XCTAssertTrue(timeline.performDragOperation(info))
        let dropped = try XCTUnwrap(try events(harness).first)
        XCTAssertEqual(dropped.start, Support.at(14, 15), "snapped to the quarter hour")
        XCTAssertEqual(dropped.accountID, id.accountID)
        XCTAssertEqual(harness.toastMessage, "Blocked 14:15 - 14:45")

        // A day cell: that day's first free half hour, from 09:00 on a later day (Friday is the fifth of a Monday week).
        let cells = controller.desk.column.cells
        let friday = try drag(id, in: harness)
        let rect = cells.cellRect(4)
        friday.draggingLocation = cells.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        XCTAssertEqual(cells.draggingUpdated(friday), .copy)
        XCTAssertTrue(cells.performDragOperation(friday))
        let second = try XCTUnwrap(try events(harness).first { $0.id != dropped.id })
        XCTAssertEqual(second.start, Support.at(9, on: Support.day(20)))
        XCTAssertEqual(harness.toastMessage, "Blocked Fri 09:00 - 09:30")

        // A day already past has no free half hour left: it says so and sets nothing aside.
        let tuesday = try drag(id, in: harness)
        let past = cells.cellRect(1)
        tuesday.draggingLocation = cells.convert(NSPoint(x: past.midX, y: past.midY), to: nil)
        XCTAssertTrue(cells.performDragOperation(tuesday))
        XCTAssertEqual(try events(harness).count, 2)
        XCTAssertEqual(harness.toastMessage, "No free half hour on Tue 17 Nov")
    }

    func testRemoveTakesTimeSetAsideOffAndItsUndoPutsItBack() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let id = conversation(0, in: harness)
        selectAndWait(id, in: harness)
        XCTAssertTrue(controller.perform(.blockTime))
        let block = try XCTUnwrap(try events(harness).first)
        // Remove, from the block's details.
        let model = controller.desk.column.details.model(for: block)
        let remove = try XCTUnwrap(model.actions.first { $0.title == "Remove" })
        remove.handler()
        XCTAssertTrue(try events(harness).filter(\.isShown).isEmpty)
        XCTAssertEqual(harness.toastMessage, "Removed 11:45 - 12:15")
        XCTAssertTrue(controller.perform(.undo))
        let back = try XCTUnwrap(try events(harness).first)
        XCTAssertEqual(back.start, block.start)
        XCTAssertEqual(back.sourceMessage, block.sourceMessage)
        XCTAssertEqual(harness.toastMessage, "Undid Remove Block")
    }

    func testBInAReaderWindowSetsTimeAsideForItsConversationWithItsOwnToast() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let id = conversation(2, in: harness)
        try nameTime(id, in: harness, at: Support.at(15, on: Support.day(20)))
        select(id, in: harness)
        let reader = try XCTUnwrap(controller.openInNewWindow(id))
        XCTAssertFalse(reader.perform(.toggleDayColumn), "D, W, [, ] and T pass to the page there")
        XCTAssertFalse(reader.perform(.toggleWeek))
        XCTAssertFalse(reader.perform(.nextDay))
        XCTAssertFalse(reader.perform(.today))
        XCTAssertTrue(reader.perform(.blockTime))
        let block = try XCTUnwrap(try events(harness).first)
        XCTAssertEqual(block.start, Support.at(15, on: Support.day(20)))
        XCTAssertEqual(reader.toastView.slip?.message, "Blocked Fri 15:00 - 15:30", "the window's toast")
        XCTAssertNotNil(reader.window, "the window stays open")
        let blockItem = item(#selector(ReaderWindowController.blockTimeForSelection(_:)))
        XCTAssertTrue(reader.validateMenuItem(blockItem))
        reader.close()
    }

    // MARK: Keys and menus

    func testTheKeyTableKeepsGSequencesShiftAndTyping() {
        func command(_ key: String, _ modifiers: NSEvent.ModifierFlags = [], pendingG: Bool = false) -> KeyCommand? {
            KeyboardRouter.command(characters: key, keyCode: 0, modifiers: modifiers, pendingG: pendingG, readerFocused: false).command
        }
        XCTAssertEqual(command("d"), .toggleDayColumn)
        XCTAssertEqual(command("w"), .toggleWeek)
        XCTAssertEqual(command("["), .previousDay)
        XCTAssertEqual(command("]"), .nextDay)
        XCTAssertEqual(command("t"), .today)
        XCTAssertEqual(command("b"), .blockTime)
        XCTAssertNil(command("D", .shift), "⇧ variants are not the calendar's")
        XCTAssertNil(command("T", .shift))
        XCTAssertNil(command("b", .command), "⌘B is the menu's")
        XCTAssertEqual(command("d", pendingG: true), .goTo(.drafts), "G D stays Drafts")
        XCTAssertEqual(command("t", pendingG: true), .goTo(.sent), "G T stays Sent")
        XCTAssertTrue(Quire.cheatSheet.flatMap(\.rows).contains { $0.keys == "D W" }, "the cheat sheet lists them")
        XCTAssertTrue(Quire.cheatSheet.flatMap(\.rows).contains { $0.keys == "B" })
    }

    func testKeysAreInertWhileTypingAndGSequencesKeepTheirs() throws {
        let harness = try self.harness()
        let window = try XCTUnwrap(harness.controller.window)
        let desk = harness.controller.desk
        harness.controller.listPane.focusSearch()
        XCTAssertTrue(KeyboardRouter.isTextInput(window.firstResponder))
        try press("d", keyCode: 2, in: window)
        try press("w", keyCode: 13, in: window)
        XCTAssertEqual(desk.placement, .column, "D and W in the search field are text")

        XCTAssertTrue(window.makeFirstResponder(harness.list.tableView))
        try press("g", keyCode: 5, in: window)
        try press("d", keyCode: 2, in: window)
        XCTAssertEqual(harness.list.query.view, .drafts, "G then D is Drafts")
        XCTAssertEqual(desk.placement, .column, "never the day column")
        try press("d", keyCode: 2, in: window)
        XCTAssertEqual(desk.placement, .none, "D alone is")
    }

    func testTheQuickReplyKeepsTheKeysAsText() throws {
        let harness = try self.harness()
        let window = try XCTUnwrap(harness.controller.window)
        let id = conversation(0, in: harness)
        select(id, in: harness)
        harness.spin { !harness.reader.currentMessages.isEmpty }
        guard harness.reader.focusQuickReply(all: false) else { throw XCTSkip("no quick reply in this window") }
        XCTAssertTrue(KeyboardRouter.isTextInput(window.firstResponder))
        try press("w", keyCode: 13, in: window)
        try press("b", keyCode: 11, in: window)
        XCTAssertEqual(harness.controller.desk.placement, .column)
        XCTAssertTrue(try events(harness).isEmpty)
    }

    func testMenusAreTitledByWhatShowsAndEnabledWhereTheyApply() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let day = item(#selector(MainWindowController.toggleDayColumn(_:)))
        let week = item(#selector(MainWindowController.toggleWeek(_:)))
        let previous = item(#selector(MainWindowController.previousCalendarDay(_:)))
        let next = item(#selector(MainWindowController.nextCalendarDay(_:)))
        let today = item(#selector(MainWindowController.calendarToday(_:)))
        let block = item(#selector(MainWindowController.blockTimeForSelection(_:)))

        XCTAssertTrue(controller.validateMenuItem(day))
        XCTAssertEqual(day.title, "Hide Day")
        XCTAssertTrue(controller.validateMenuItem(week))
        XCTAssertEqual(week.title, "Show Week")
        XCTAssertTrue(controller.validateMenuItem(previous))
        XCTAssertEqual(previous.title, "Previous Day")
        XCTAssertTrue(controller.validateMenuItem(today))
        XCTAssertEqual(today.title, "Today")
        XCTAssertFalse(controller.validateMenuItem(block), "nothing selected")
        select(conversation(0, in: harness), in: harness)
        XCTAssertTrue(controller.validateMenuItem(block), "one conversation")
        harness.selectFirst(2)
        XCTAssertFalse(controller.validateMenuItem(block), "several")

        XCTAssertTrue(controller.perform(.toggleWeek))
        XCTAssertTrue(controller.validateMenuItem(week))
        XCTAssertEqual(week.title, "Hide Week")
        XCTAssertTrue(controller.validateMenuItem(day))
        XCTAssertEqual(day.title, "Show Day")
        XCTAssertTrue(controller.validateMenuItem(next))
        XCTAssertEqual(next.title, "Next Week")
        XCTAssertTrue(controller.validateMenuItem(today))
        XCTAssertEqual(today.title, "This Week")
        XCTAssertTrue(controller.perform(.toggleWeek))

        XCTAssertTrue(controller.perform(.toggleDayColumn))
        XCTAssertFalse(controller.validateMenuItem(previous), "nothing to turn with the column hidden")
        XCTAssertFalse(controller.validateMenuItem(today))
        XCTAssertTrue(controller.validateMenuItem(day))
        XCTAssertEqual(day.title, "Show Day")

        // The welcome screen has none of them.
        let welcome = try self.harness(accounts: false)
        for item in [day, week, previous, next, today, block] {
            XCTAssertFalse(welcome.controller.validateMenuItem(item), "\(String(describing: item.action)) on the welcome screen")
        }
    }

    func testTheMenuBarHasTheCalendarsItems() {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let all = items(bar)
        let expected: [(Selector, String)] = [
            (#selector(MainWindowController.toggleDayColumn(_:)), "d"), (#selector(MainWindowController.toggleWeek(_:)), "w"),
            (#selector(MainWindowController.previousCalendarDay(_:)), "["), (#selector(MainWindowController.nextCalendarDay(_:)), "]"),
            (#selector(MainWindowController.calendarToday(_:)), "t"), (#selector(MainWindowController.blockTimeForSelection(_:)), "b"),
        ]
        for (action, key) in expected {
            let item = all.first { $0.action == action }
            XCTAssertEqual(item?.keyEquivalent, key, "\(action)")
            XCTAssertEqual(item?.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]), [], "a single key")
        }
    }

    // MARK: Links and Connect

    func testLinksOpenOnlyWebAddresses() throws {
        let harness = try self.harness()
        let controller = harness.controller
        controller.openURL(try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij")))
        controller.openURL(try XCTUnwrap(URL(string: "javascript:alert(1)")))
        controller.openURL(try XCTUnwrap(URL(string: "file:///etc/passwd")))
        controller.openURL(try XCTUnwrap(URL(string: "http://example.com")))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://meet.google.com/abc-defg-hij"])
    }

    func testConnectAsksEachAccountInTurnAndStopsAtARefusal() throws {
        let harness = try self.harness()
        let controller = harness.controller
        var asked: [AccountID] = []
        var answers: [(Bool) -> Void] = []
        controller.onConnectCalendar = { account, done in
            asked.append(account.id)
            answers.append(done)
        }
        controller.connect(accountIDs: [Support.accountA.id, Support.accountB.id])
        XCTAssertEqual(asked, [Support.accountA.id])
        XCTAssertTrue(controller.calendarState.isConnecting)
        answers[0](true)
        XCTAssertEqual(asked, [Support.accountA.id, Support.accountB.id], "one after another")
        answers[1](true)
        XCTAssertFalse(controller.calendarState.isConnecting)

        controller.connect(accountIDs: [Support.accountA.id, Support.accountB.id])
        answers[2](false)
        XCTAssertEqual(asked.count, 3, "a refusal ends the round")
        XCTAssertFalse(controller.calendarState.isConnecting)
    }

    // MARK: Scope and the demo

    func testTheRailsScopeNarrowsTheCalendar() throws {
        let harness = try self.harness()
        let controller = harness.controller
        XCTAssertEqual(controller.calendarState.scope, .all)
        controller.strip.selectShortcut(2)
        XCTAssertEqual(controller.calendarState.scope, .account(Support.accountB.id))
        controller.strip.selectShortcut(0)
        XCTAssertEqual(controller.calendarState.scope, .all)
    }

    func testTheDemoWindowShowsBothCalendarsAndALaterSample() throws {
        let harness = try MainWindowHarness(accounts: false, demo: true)
        harnesses.append(harness)
        harness.environment.start()
        let state = harness.controller.calendarState
        ListTestSupport.spin(until: { Set(state.events.map(\.accountID)).count == 2 }, timeout: 20)
        XCTAssertEqual(Set(state.events.map(\.accountID)).count, 2, "both demo accounts' calendars")
        ListTestSupport.spin(until: { !harness.controller.snoozes.isEmpty }, timeout: 20)
        XCTAssertFalse(harness.controller.snoozes.isEmpty, "a conversation comes back from Later, so its mark shows")
    }
}
