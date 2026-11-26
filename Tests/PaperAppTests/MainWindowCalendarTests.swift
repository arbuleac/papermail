import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

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

    /// `characters` as the key produces them; `ignoring` the key's own character, without the modifiers (⌥5 types [ on
    /// a German layout, so it arrives as “[” ignoring “5”).
    private func press(_ characters: String, ignoring: String? = nil, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                       in window: NSWindow) throws {
        KeyboardRouter.keyWindowForTests = window
        defer { KeyboardRouter.keyWindowForTests = nil }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                                                   isARepeat: false, keyCode: keyCode))
        NSApp.sendEvent(event)
    }

    /// Waits `seconds` on the main run loop, for timers that must not fire.
    private func wait(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
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
        XCTAssertFalse(desk.column.header.showsDayToggle, "no account has granted the calendar permission: no toggle")
        XCTAssertEqual(desk.column.header.weekButton.toolTip, "Show Week  W")

        XCTAssertTrue(harness.controller.perform(.toggleDayColumn))
        XCTAssertEqual(desk.placement, .none)
        XCTAssertTrue(desk.column.isHidden)
        XCTAssertTrue(desk.strip.isHidden)
        XCTAssertEqual(desk.conversationPane.view.frame.width, desk.view.bounds.width, accuracy: 0.5, "the reader takes its 240 pt back")
        XCTAssertFalse(settings.showsDayColumn, "kept in the app's settings")

        close(harness)
        harness = try self.harness(settings: settings)
        desk = harness.controller.desk
        XCTAssertEqual(desk.placement, .none, "a new window opens as the last was left")
        XCTAssertTrue(harness.controller.perform(.toggleDayColumn))
        XCTAssertEqual(desk.placement, .column)
        XCTAssertTrue(settings.showsDayColumn)
    }

    // MARK: The calendar toggle

    /// Every account's calendar read, as the engine says once it has looked (`AccountSyncStatus.calendar`).
    private func grantCalendarAccess(_ harness: MainWindowHarness, _ granted: Bool = true) {
        harness.controller.calendarState.statusesChanged(harness.controller.accounts.map {
            AccountSyncStatus(accountID: $0.id, phase: .idle, calendar: granted ? .current(Support.at(11)) : .notConnected)
        })
        layOut(harness)
    }

    func testTheReaderHeaderHoldsNoCalendarButton() throws {
        let harness = try self.harness()
        grantCalendarAccess(harness)
        select(conversation(0, in: harness), in: harness)
        layOut(harness)
        let header = harness.reader.header
        let calendarButtons = header.subviews.compactMap { $0 as? QuireIconButton }
            .filter { ["Day", "Week"].contains($0.accessibilityLabel() ?? "") }
        XCTAssertTrue(calendarButtons.isEmpty, "the message's actions only (§5.12)")
    }

    func testWithCalendarAccessTheToggleAlwaysStandsAtTheTrailingEdge() throws {
        let settings = ListTestSupport.settings()
        var harness = try self.harness(settings: settings)
        var desk = harness.controller.desk
        grantCalendarAccess(harness)
        XCTAssertTrue(settings.hasCalendarAccess, "remembered for the next launch's first frame")

        // Shown: the toggle ends the column's kicker line, on, after ‹ Today ›, above the week button.
        let header = desk.column.header
        XCTAssertEqual(desk.placement, .column)
        XCTAssertTrue(header.showsDayToggle)
        XCTAssertFalse(header.dayToggle.isHidden)
        XCTAssertTrue(header.dayToggle.isOn)
        XCTAssertEqual(header.dayToggle.toolTip, "Hide Day  D")
        let toggle = header.dayToggle.alignmentRect(forFrame: header.dayToggle.frame)
        let next = header.next.alignmentRect(forFrame: header.next.frame)
        let week = header.weekButton.alignmentRect(forFrame: header.weekButton.frame)
        XCTAssertEqual(toggle.maxX, header.bounds.width - Pane.navTrailing, accuracy: 0.5)
        XCTAssertEqual(toggle.minX - next.maxX, Pane.dayToggleGap, accuracy: 0.5)
        XCTAssertEqual(toggle.midX, week.midX, accuracy: 0.5, "the two calendar buttons on one vertical line")
        XCTAssertTrue(header.keyViews.contains(header.dayToggle))

        // Hidden: the column folds to its strip at the trailing edge, whose glyph is the same toggle.
        header.dayToggle.performClick(nil)
        layOut(harness)
        XCTAssertEqual(desk.placement, .strip)
        XCTAssertFalse(settings.showsDayColumn)
        XCTAssertTrue(desk.column.isHidden)
        XCTAssertFalse(desk.strip.isHidden)
        XCTAssertEqual(desk.strip.frame.maxX, desk.view.bounds.width)
        XCTAssertEqual(desk.conversationPane.view.frame.width, desk.view.bounds.width - Pane.stripWidth, accuracy: 0.5,
                       "the reader takes all but the strip back")
        XCTAssertFalse(desk.isOverlayOpen)

        // In a window with room, a click on the strip puts the column back in place, not over the reader; D as well.
        XCTAssertTrue(desk.strip.accessibilityPerformPress())
        XCTAssertEqual(desk.placement, .column)
        XCTAssertFalse(desk.isOverlayOpen)
        XCTAssertTrue(settings.showsDayColumn)
        XCTAssertTrue(harness.controller.perform(.toggleDayColumn))
        XCTAssertEqual(desk.placement, .strip)
        XCTAssertTrue(harness.controller.perform(.toggleDayColumn))
        XCTAssertEqual(desk.placement, .column)

        // A narrow window: the strip opens the column over the reader, whose header then has no toggle of its own.
        resize(harness, width: 960)
        XCTAssertEqual(desk.placement, .strip)
        XCTAssertTrue(desk.strip.accessibilityPerformPress())
        XCTAssertTrue(desk.isOverlayOpen)
        XCTAssertFalse(header.showsDayToggle, "over the reader, the strip's glyph is the toggle")
        XCTAssertTrue(harness.controller.perform(.clearSearch))
        resize(harness, width: 1_304)

        // The next window, hidden, has its strip from the first frame, before the engine has looked at any account.
        XCTAssertTrue(harness.controller.perform(.toggleDayColumn))
        close(harness)
        harness = try self.harness(settings: settings)
        desk = harness.controller.desk
        XCTAssertEqual(desk.placement, .strip)
        XCTAssertFalse(desk.strip.isHidden)
    }

    func testWithoutCalendarAccessThereIsNoToggleAndAHiddenColumnGoes() throws {
        let settings = ListTestSupport.settings()
        let harness = try self.harness(settings: settings)
        let desk = harness.controller.desk
        grantCalendarAccess(harness)
        XCTAssertTrue(desk.column.header.showsDayToggle)
        grantCalendarAccess(harness, false)
        XCTAssertFalse(settings.hasCalendarAccess)
        XCTAssertFalse(desk.column.header.showsDayToggle, "every account known to lack the permission")
        XCTAssertTrue(desk.column.header.dayToggle.isHidden)
        XCTAssertFalse(desk.column.header.keyViews.contains(desk.column.header.dayToggle))
        XCTAssertTrue(harness.controller.perform(.toggleDayColumn))
        XCTAssertEqual(desk.placement, .none)
        XCTAssertTrue(desk.strip.isHidden)
        XCTAssertEqual(desk.conversationPane.view.frame.width, desk.view.bounds.width, accuracy: 0.5)
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

        // A click on the strip opens the column over the reader's edge, just before the strip.
        XCTAssertTrue(desk.strip.accessibilityPerformPress())
        XCTAssertTrue(desk.isOverlayOpen)
        XCTAssertFalse(desk.column.isHidden)
        XCTAssertTrue(desk.column.isOverlay)
        XCTAssertEqual(desk.column.frame.maxX, desk.strip.frame.minX)
        XCTAssertTrue(desk.strip.isOpen)
        XCTAssertFalse(desk.readerCover.isHidden, "a click in the reader closes it")

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
        harness.spin { week.selectionDetails != nil }
        let card = try XCTUnwrap(week.selectionDetails)
        XCTAssertEqual(Array(card.buttons.map(\.title).prefix(3)), ["Accept", "Tentative", "Decline"])
        card.buttons[0].performClick(nil)
        XCTAssertEqual(try harness.environment.store.message(message)?.invitationReply, .accepted, "stored as the reader's card stores it")
        XCTAssertNil(harness.toastMessage, "no toast, no undo (§5.14)")

        harness.spin { week.selectionDetails != nil }
        XCTAssertTrue(controller.perform(.clearSearch), "Esc's row 12")
        XCTAssertNil(week.selectionDetails)
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
        XCTAssertTrue(try events(harness).filter(\.isShown).isEmpty, "a block still being created leaves the calendar at once")
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
        XCTAssertFalse(try events(harness).contains { $0.id == block.id && $0.isShown }, "⌘Z")

        // Nothing or several selected: B beeps and sets nothing aside.
        harness.selectFirst(2)
        XCTAssertTrue(controller.perform(.blockTime))
        XCTAssertEqual(try events(harness).filter(\.isShown).count, 1)
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
        harness.spin { controller.desk.column.timeline.placed(withID: block.id) != nil }
        controller.desk.column.timeline.activate(.event(block.id))
        let card = try XCTUnwrap(controller.desk.column.details.card)
        let remove = try XCTUnwrap(card.buttons.first { $0.title == "Remove" })
        remove.performClick(nil)
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
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["Paper"])))
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

    // MARK: Now, for B

    /// The clock moves only while a calendar is on screen; B reads now afresh, with the column hidden too.
    func testBWithTheColumnHiddenSetsTimeAsideFromTheRealNow() throws {
        let settings = ListTestSupport.settings()
        settings.showsDayColumn = false
        let clock = Support.Clock() // 11:40
        let harness = try self.harness(settings: settings, clock: clock)
        XCTAssertEqual(harness.controller.desk.placement, .none)
        clock.now = Support.at(15, 10)
        let id = conversation(0, in: harness)
        select(id, in: harness)
        XCTAssertTrue(harness.controller.perform(.blockTime))
        let block = try XCTUnwrap(try events(harness).first)
        XCTAssertEqual(block.start, Support.at(15, 15), "the first free half hour from 15:10, not from when the window opened")
        XCTAssertEqual(harness.toastMessage, "Blocked 15:15 - 15:45")
    }

    /// B in a reader window while the main window's calendar shows nothing: a time the mail named that has passed is
    /// never set aside.
    func testBInAReaderWindowNeverSetsAsideATimeThatHasPassed() throws {
        let settings = ListTestSupport.settings()
        settings.showsDayColumn = false
        let clock = Support.Clock()
        let harness = try self.harness(settings: settings, clock: clock)
        let id = conversation(1, in: harness)
        try nameTime(id, in: harness, at: Support.at(13))
        clock.now = Support.at(14)
        let reader = try XCTUnwrap(harness.controller.openInNewWindow(id))
        defer { reader.close() }
        XCTAssertTrue(reader.perform(.blockTime))
        let block = try XCTUnwrap(try events(harness).first)
        XCTAssertEqual(block.start, Support.at(14), "the first free half hour from now, 13:00 being past")
    }

    // MARK: Where B looks

    /// The week shows no one day: with Sunday-first weeks, B from next week passes over its Sunday.
    func testBInTheWeekPassesOverItsFirstDayWhenItIsASunday() throws {
        var sundayFirst = Support.calendar
        sundayFirst.firstWeekday = 1
        let clock = Support.Clock()
        let harness = try MainWindowHarness(accounts: true, calendar: sundayFirst, now: { clock.now })
        harnesses.append(harness)
        layOut(harness)
        let controller = harness.controller
        XCTAssertTrue(controller.perform(.toggleWeek))
        XCTAssertTrue(controller.perform(.nextDay))
        XCTAssertEqual(controller.calendarState.shownWeekDays.first, Support.day(22), "Sun 22 - Sat 28 Nov")
        selectAndWait(conversation(0, in: harness), in: harness)
        XCTAssertTrue(controller.perform(.blockTime))
        let block = try XCTUnwrap(try events(harness).first)
        XCTAssertEqual(block.start, Support.at(9, on: Support.day(23)), "Monday 09:00, never Sunday's")
    }

    /// What is set aside already is read from the store: with the column back on today, a second B never sets the mail's
    /// time, weeks away, aside again.
    func testBTwiceNeverSetsTheSameMailTimeAsideTwice() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let id = conversation(2, in: harness)
        let named = Support.at(15, on: Support.day(10, month: 12))
        try nameTime(id, in: harness, at: named)
        selectAndWait(id, in: harness)
        XCTAssertTrue(controller.perform(.blockTime))
        XCTAssertEqual(controller.calendarState.shownDay, Support.day(10, month: 12), "the column turned to it")
        XCTAssertTrue(controller.perform(.today))
        XCTAssertTrue(controller.perform(.blockTime))
        let blocks = try events(harness).filter { $0.sourceMessage != nil }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.filter { $0.start == named }.count, 1, "one block at the time the mail names, the next at a free half hour")
    }

    /// B looks only through days the store holds: near the end of the kept window it stops there rather than take a day
    /// it knows nothing of for a free one.
    func testBNeverLooksPastTheDaysTheStoreHolds() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let state = controller.calendarState
        let window = state.keptWindow
        let lastDay = try XCTUnwrap(Support.calendar.date(byAdding: .day, value: -1, to: window.end))
        // Every working hour of the window's last week is taken.
        var busy: [CalendarEvent] = []
        for offset in 0..<7 {
            let day = try XCTUnwrap(Support.calendar.date(byAdding: .day, value: -offset, to: lastDay))
            busy.append(Support.event("busy-\(offset)", title: "Busy", start: Support.at(0, on: day), end: Support.at(23, 59, on: day)))
        }
        let read = DateInterval(start: Support.day(26, month: 10), end: window.end.addingTimeInterval(86_400 * 30))
        try harness.environment.store.replaceCalendarEvents(busy, accountID: Support.accountA.id, window: read)
        let firstBusy = try XCTUnwrap(Support.calendar.date(byAdding: .day, value: -6, to: lastDay))
        controller.selectDay(firstBusy)
        selectAndWait(conversation(0, in: harness), in: harness)
        XCTAssertTrue(controller.perform(.blockTime))
        XCTAssertTrue(try events(harness).filter { $0.sourceMessage != nil }.isEmpty, "nothing past the window's last day")
    }

    // MARK: The reader under the week

    /// J and K while the week shows: the hidden reader marks nothing read; it does once it shows again.
    func testMailSelectedUnderTheWeekStaysUnreadUntilTheReaderShows() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let store = harness.environment.store
        XCTAssertTrue(controller.perform(.toggleWeek))
        let unread = try XCTUnwrap(harness.list.conversations.first { row in
            ((try? store.messages(in: row.id)) ?? []).contains { !$0.isRead }
        }?.id)
        select(unread, in: harness)
        harness.spin { controller.conversation.currentConversationID == unread }
        wait(1.2)
        XCTAssertTrue(try store.messages(in: unread).contains { !$0.isRead }, "mail behind the week is not read")

        XCTAssertTrue(controller.perform(.toggleWeek))
        harness.spin { (try? store.messages(in: unread).allSatisfy(\.isRead)) == true }
        XCTAssertTrue(try store.messages(in: unread).allSatisfy(\.isRead), "read once the reader shows it")
    }

    /// R while the week shows opens the composer (the quick reply is hidden with the reader), and what acts on the
    /// reader's page waits for it.
    func testReplyAndReaderCommandsWhileTheWeekShowsNeverReachTheHiddenReader() throws {
        let harness = try self.harness()
        let controller = harness.controller
        defer { for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() } }
        let id = conversation(0, in: harness)
        selectAndWait(id, in: harness)
        harness.spin { controller.conversation.currentConversationID == id }
        let find = item(#selector(MainWindowController.findInConversation(_:)))
        let before = controller.validateMenuItem(find)
        XCTAssertTrue(controller.perform(.toggleWeek))
        let composers = ComposeWindowRegistry.shared.openControllers.count
        XCTAssertTrue(controller.perform(.reply))
        let responder = controller.window?.firstResponder as? NSView
        XCTAssertFalse(responder?.isHiddenOrHasHiddenAncestor ?? false, "focus never goes to a field no one can see")
        XCTAssertFalse(KeyboardRouter.isTextInput(controller.window?.firstResponder))
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.count, composers + 1, "the reply opens in a composer")
        XCTAssertFalse(controller.validateMenuItem(find), "Find in Conversation waits for the reader")
        XCTAssertFalse(controller.validateMenuItem(item(#selector(MainWindowController.nextMessage(_:)))))
        XCTAssertTrue(controller.perform(.toggleWeek))
        XCTAssertEqual(controller.validateMenuItem(find), before)
    }

    // MARK: Midnight

    /// Left open overnight, the column shows the new today, and J and K go back to it, not to yesterday.
    func testTheColumnTurnsAtMidnightAndTheSelectionGoesBackToTheNewToday() throws {
        let clock = Support.Clock()
        let harness = try self.harness(clock: clock)
        let controller = harness.controller
        let state = controller.calendarState
        let invited = conversation(1, in: harness)
        _ = try invite(invited, in: harness, start: Support.at(10, on: Support.day(24)), end: Support.at(11, on: Support.day(24)))
        selectAndWait(conversation(0, in: harness), in: harness)
        XCTAssertEqual(state.shownDay, Support.day(19))

        clock.now = Support.at(8, on: Support.day(20))
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertEqual(state.shownDay, Support.day(20))
        XCTAssertEqual(controller.desk.column.header.kicker, "Today")
        selectAndWait(invited, in: harness)
        XCTAssertEqual(state.shownDay, Support.day(24))
        selectAndWait(conversation(2, in: harness), in: harness)
        XCTAssertEqual(state.shownDay, Support.day(20), "back on the new today")

        // A day the user turned to stays theirs.
        XCTAssertTrue(controller.perform(.nextDay))
        clock.now = Support.at(8, on: Support.day(21))
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertEqual(state.shownDay, Support.day(21), "the 21st, chosen yesterday, is today now")
        selectAndWait(invited, in: harness)
        selectAndWait(conversation(0, in: harness), in: harness)
        XCTAssertEqual(state.shownDay, Support.day(21))
    }

    // MARK: Days outside the kept window

    /// Days turned to past the kept window show what the store holds and are read once; a hidden calendar asks nothing.
    func testDaysOutsideTheKeptWindowAreReadOnce() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let state = controller.calendarState
        var asked: [DateInterval?] = []
        controller.readCalendars = { asked.append($0) }
        func day(_ day: Int, month: Int) -> Date {
            Support.calendar.date(from: DateComponents(year: 2027, month: month, day: day))!
        }
        // Monday 1 March 2027, past the eight weeks ahead the engine keeps.
        controller.selectDay(day(1, month: 3))
        XCTAssertEqual(asked, [state.shownRange], "the column's week")
        XCTAssertEqual(state.shownRange.start, day(1, month: 3))
        XCTAssertTrue(controller.perform(.nextDay))
        XCTAssertTrue(controller.perform(.today))
        controller.selectDay(day(1, month: 3))
        XCTAssertEqual(asked.count, 1, "a week is asked for once")

        XCTAssertTrue(controller.perform(.toggleWeek))
        XCTAssertEqual(asked.count, 1, "the week of the column's day was asked for already")
        XCTAssertTrue(controller.perform(.nextDay))
        XCTAssertEqual(asked.count, 2, "the next week")
        XCTAssertEqual(asked.last??.start, day(8, month: 3))

        XCTAssertTrue(controller.perform(.toggleWeek))
        XCTAssertTrue(controller.perform(.toggleDayColumn))
        XCTAssertEqual(controller.desk.placement, .none)
        controller.selectDay(day(1, month: 4))
        XCTAssertEqual(asked.count, 2, "a hidden calendar asks for nothing")
        XCTAssertTrue(controller.perform(.toggleDayColumn))
        XCTAssertEqual(asked.count, 3, "until it shows, with the window")
        XCTAssertEqual(asked.last??.start, day(29, month: 3))
        XCTAssertTrue(controller.perform(.toggleDayColumn))
        XCTAssertTrue(controller.perform(.toggleDayColumn))
        XCTAssertEqual(asked.last ?? nil, nil, "inside what was asked, the window alone")
    }

    // MARK: The hidden column

    /// With the column hidden J and K cost the calendar nothing; it reads the selection as it comes back, already on
    /// its day.
    func testAHiddenColumnFollowsNothingAndCatchesUpAsItShows() throws {
        let settings = ListTestSupport.settings()
        settings.showsDayColumn = false
        let harness = try self.harness(settings: settings)
        let controller = harness.controller
        let state = controller.calendarState
        let invited = conversation(1, in: harness)
        _ = try invite(invited, in: harness, start: Support.at(10, on: Support.day(24)), end: Support.at(11, on: Support.day(24)))
        select(conversation(0, in: harness), in: harness)
        select(invited, in: harness)
        wait(0.2)
        XCTAssertNil(state.selectedConversation, "nothing is read for a calendar no one sees")
        XCTAssertEqual(state.shownDay, Support.day(19))

        XCTAssertTrue(controller.perform(.toggleDayColumn))
        XCTAssertEqual(state.selection?.conversationID, invited, "read at once")
        XCTAssertEqual(state.shownDay, Support.day(24), "the column comes on on the invitation's day")
        XCTAssertTrue(controller.perform(.toggleDayColumn))
        XCTAssertNil(state.selectedConversation)
    }

    // MARK: Undo and the overlay

    /// A block already gone when its undo comes (removed in the provider's calendar, and dropped by a read) has nothing
    /// to take back: no “Undid”, and the step leaves the history.
    func testUndoingABlockThatIsGoneSaysNothingWorked() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let store = harness.environment.store
        selectAndWait(conversation(0, in: harness), in: harness)
        XCTAssertTrue(controller.perform(.blockTime))
        let block = try XCTUnwrap(try events(harness).first)
        var created = block
        created.providerID = "provider-block"
        created.sync = .synced
        XCTAssertTrue(try store.settleCalendarEvent(id: block.id, created: created))
        try store.replaceCalendarEvents([], accountID: block.accountID,
                                        window: DateInterval(start: Support.day(1), end: Support.day(31, month: 12)))
        XCTAssertTrue(try events(harness).isEmpty)
        XCTAssertTrue(controller.perform(.undo))
        XCTAssertNotEqual(harness.toastMessage, "Undid Block Time")
        let undo = NSMenuItem(title: "", action: #selector(MainWindow.undo(_:)), keyEquivalent: "z")
        _ = controller.validateEditUndo(undo)
        XCTAssertNotEqual(undo.title, "Undo Block Time", "the step is gone")
    }

    /// A click in the reader closes the column opened over it, and focus that was in it goes back to the list, as with
    /// Esc and D.
    func testAClickInTheReaderClosingTheColumnGivesTheKeyboardBackToTheList() throws {
        let harness = try self.harness()
        let controller = harness.controller
        let desk = controller.desk
        resize(harness, width: 960)
        desk.setOverlayOpen(true)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(desk.column.cells))
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: 1))
        desk.readerCover.mouseDown(with: click)
        XCTAssertFalse(desk.isOverlayOpen)
        XCTAssertTrue(controller.isListFocused)
    }

    // MARK: Keys on other layouts

    /// Where [ and ] take Option (German ⌥5 and ⌥6), they still turn the day.
    func testBracketsTypedWithOptionTurnTheDay() throws {
        let harness = try self.harness()
        let window = try XCTUnwrap(harness.controller.window)
        let state = harness.controller.calendarState
        XCTAssertTrue(window.makeFirstResponder(harness.list.tableView))
        try press("]", ignoring: "6", keyCode: 22, modifiers: .option, in: window)
        XCTAssertEqual(state.shownDay, Support.day(20))
        try press("[", ignoring: "5", keyCode: 23, modifiers: .option, in: window)
        try press("[", ignoring: "5", keyCode: 23, modifiers: .option, in: window)
        XCTAssertEqual(state.shownDay, Support.day(18))
        XCTAssertNil(KeyboardRouter.optionBracket(produced: "“", modifiers: .option), "⌥[ on a US layout types a quote")
        XCTAssertNil(KeyboardRouter.optionBracket(produced: "[", modifiers: [.option, .command]))
        XCTAssertNil(KeyboardRouter.optionBracket(produced: "[", modifiers: []), "the key table's")
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
