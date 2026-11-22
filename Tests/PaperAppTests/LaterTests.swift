import AppKit
import PaperCore
import PaperDesign
import WebKit
import XCTest
@testable import PaperApp

/// Later end to end in the main window (spec §5.45, §5.2, §5.7, §6): L's menu and where it hangs, snoozing through the
/// store with archive's selection, toast and undo, rescheduling and ending a snooze from Later, the conditional Later
/// tile with its scope, place, G L and refused drops, Later's rows and an Inbox row back from Later.
@MainActor
final class LaterTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for pasteboard in pasteboards { pasteboard.releaseGlobally() }
            pasteboards = []
        }
        super.tearDown()
    }

    // MARK: Helpers

    /// The window's fixed clock: the first Wednesday after today, at 09:20 on this Mac's clock. Always the same weekday,
    /// so the menu, its times and every preset (Next Week is not offered on a Sunday, This Evening not from 17:00) are the
    /// same whatever day the suite runs, Saturdays and Sundays included; and always ahead of the real clock, which the
    /// store's snoozes and the rows' Back tags are read against.
    private static let fixedWeekday = 4 // Wednesday
    private let morning: Date = {
        let calendar = Calendar.autoupdatingCurrent
        var day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        while calendar.component(.weekday, from: day) != LaterTests.fixedWeekday {
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return calendar.date(bySettingHour: 9, minute: 20, second: 0, of: day)!
    }()

    private struct PoppedMenu {
        var menu: NSMenu
        var point: NSPoint
        var view: NSView
    }

    /// A window whose Later menu is caught rather than tracked, on a fixed clock.
    private func harness(threads: Int = 8) throws -> (MainWindowHarness, () -> PoppedMenu?) {
        let harness = try MainWindowHarness(threads: threads)
        var popped: PoppedMenu?
        harness.controller.popUpLaterMenu = { menu, point, view in popped = PoppedMenu(menu: menu, point: point, view: view) }
        harness.controller.laterNow = { [morning] in morning }
        return (harness, { popped })
    }

    private var store: (MainWindowHarness) -> MailStoring { { $0.environment.store } }

    private func time(_ date: Date) -> String {
        let formatting = DateFormatting()
        return formatting.dueTime(for: date, reference: formatting.reference(now: morning))
    }

    private func preset(_ preset: LaterPreset) -> Date {
        preset.date(after: morning, calendar: .autoupdatingCurrent)!
    }

    /// Chooses `title` in the Later menu L popped, as a click would.
    private func choose(_ title: String, in popped: PoppedMenu?, file: StaticString = #filePath, line: UInt = #line) throws {
        let menu = try XCTUnwrap(popped?.menu, "L popped no menu", file: file, line: line)
        menu.update()
        let item = try XCTUnwrap(menu.items.first { name($0) == title }, file: file, line: line)
        XCTAssertTrue(item.isEnabled, "\(title) is enabled", file: file, line: line)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item), file: file, line: line)
    }

    /// A menu item's name without the time or sequence its attributed title sets after a tab.
    private func name(_ item: NSMenuItem) -> String {
        item.isSeparatorItem ? "—" : item.title.components(separatedBy: "\t")[0]
    }

    private func inInbox(_ id: ConversationID, _ harness: MainWindowHarness) throws -> Bool {
        try harness.environment.store.messages(in: id).contains(where: \.isInInbox)
    }

    private func snoozedIDs(_ harness: MainWindowHarness) throws -> [ConversationID] {
        try harness.environment.store.snoozes().map(\.conversationID)
    }

    /// Snoozes `ids` straight in the store, archiving them, until `due`; the window hears of it through its observation.
    private func snoozeInStore(_ ids: [ConversationID], until due: Date, _ harness: MainWindowHarness) throws {
        let store = harness.environment.store
        for id in ids {
            let targets = try store.messages(in: id).filter(\.isInInbox).map(\.id)
            try store.setSnoozes([Snooze.Change(conversationID: id, until: due)],
                                 enqueueing: [PaperCore.Operation(accountID: id.accountID, change: .archive, targets: targets)], at: Date())
        }
        harness.spin { harness.controller.snoozes.count >= ids.count }
    }

    private func cell(forConversation index: Int, _ harness: MainWindowHarness) throws -> ConversationCellView {
        let row = try XCTUnwrap(harness.list.layout.row(ofConversation: index))
        return try XCTUnwrap(harness.list.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ConversationCellView)
    }

    // MARK: The menu

    /// The fixed clock itself: a Wednesday morning ahead of now, when every preset is offered, so `preset(_:)` never
    /// meets one that is not (it used to trap on a Saturday run, whose tomorrow is a Sunday without Next Week).
    func testTheFixedClockIsAWednesdayMorningOfferingEveryPreset() {
        let calendar = Calendar.autoupdatingCurrent
        XCTAssertEqual(calendar.component(.weekday, from: morning), Self.fixedWeekday)
        XCTAssertGreaterThan(morning, Date())
        XCTAssertEqual(LaterPreset.offered(at: morning, calendar: calendar).map(\.preset), LaterPreset.allCases)
    }

    func testLOffersThePresetsWithTheirTimesThenPickADate() throws {
        let (harness, popped) = try harness()
        defer { harness.close() }
        harness.selectFirst(1)
        XCTAssertTrue(harness.controller.perform(.later))
        let menu = try XCTUnwrap(popped()?.menu)
        XCTAssertEqual(menu.items.map(name), ["Later Today", "This Evening", "Tomorrow", "Next Week", "—", "Pick a Date…"])
        let offered = LaterPreset.offered(at: morning, calendar: .autoupdatingCurrent)
        for (item, preset) in zip(menu.items, offered) {
            XCTAssertEqual(LaterMenu.date(of: item), preset.date)
            XCTAssertEqual(item.attributedTitle?.string, preset.preset.title + "\t" + time(preset.date), "the time beside it")
            let timeColour = item.attributedTitle?.attribute(.foregroundColor, at: preset.preset.title.count + 1, effectiveRange: nil) as? NSColor
            XCTAssertEqual(timeColour, .qInk3, "in ink3, as the title menu sets its sequences")
        }
        XCTAssertFalse(time(preset(.laterToday)).contains(" "), "today: the time alone")
        XCTAssertTrue(time(preset(.tomorrow)).contains(" "), "tomorrow: its day before the time")
    }

    /// The menu hangs from the selected row's text column, 4 pt under the row; with focus in the reader, from the
    /// header's Archive button.
    func testTheMenuHangsFromTheRowOrTheReadersHeader() throws {
        let (harness, popped) = try harness()
        defer { harness.close() }
        harness.selectFirst(1)
        harness.controller.window?.makeFirstResponder(harness.list.tableView)
        XCTAssertTrue(harness.controller.perform(.later))
        let row = try XCTUnwrap(harness.list.revealedRowRect(of: harness.list.conversations[0].id))
        XCTAssertTrue(popped()?.view === harness.list.tableView)
        XCTAssertEqual(popped()?.point, NSPoint(x: Quire.Layout.Row.textX, y: row.maxY + Quire.Layout.Menu.titleMenuOffsetY))

        // Focus in the reader (its page): the menu hangs from the header's Archive button instead.
        func webView(in view: NSView) -> NSView? {
            if view is WKWebView, !view.isHiddenOrHasHiddenAncestor { return view }
            return view.subviews.lazy.compactMap(webView(in:)).first
        }
        let page = try XCTUnwrap(webView(in: harness.reader.view), "the reader shows the conversation in a web view")
        XCTAssertTrue(harness.controller.window?.makeFirstResponder(page) == true)
        XCTAssertTrue(harness.controller.isReaderFocused)
        XCTAssertTrue(harness.controller.perform(.later))
        XCTAssertTrue(popped()?.view === harness.reader.header)
        let archive = harness.reader.header.menuAnchor
        XCTAssertEqual(archive.size, NSSize(width: Quire.Layout.ReaderHeader.actionSize, height: Quire.Layout.ReaderHeader.actionSize),
                       "the Archive button's square")
        XCTAssertEqual(popped()?.point, NSPoint(x: archive.minX, y: archive.maxY + Quire.Layout.Menu.titleMenuOffsetY))
    }

    func testNothingIsSnoozedFromTheTrashOrWithNothingSelected() throws {
        let (harness, popped) = try harness()
        defer { harness.close() }
        XCTAssertFalse(harness.controller.perform(.later), "nothing selected: the key goes on")
        XCTAssertNil(popped())
        let first = harness.list.conversations[0].id
        try harness.environment.engine.perform(.trash, on: first)
        _ = harness.controller.perform(.goTo(.trash))
        harness.spin { harness.list.conversations.contains { $0.id == first } }
        harness.list.selectedConversationID = first
        harness.list.onSelectionChange?(first)
        XCTAssertTrue(harness.controller.perform(.later), "spent, with a beep")
        XCTAssertNil(popped(), "no menu in the Trash")
        let item = NSMenuItem(title: "Later…", action: #selector(MainWindowController.laterSelection(_:)), keyEquivalent: "l")
        XCTAssertFalse(harness.controller.validateMenuItem(item), "Message › Later… is disabled there")
        XCTAssertTrue(try snoozedIDs(harness).isEmpty)
    }

    // MARK: Snoozing

    /// Store first, in one write; the row leaves the Inbox and the selection moves on as after E; the toast says when it
    /// comes back; Z puts it back in the Inbox through archive's own undo and ends the snooze.
    func testSnoozingArchivesAdvancesTheSelectionAndUndoes() throws {
        let (harness, popped) = try harness()
        defer { harness.close() }
        harness.selectFirst(1)
        let first = harness.list.conversations[0].id
        let second = harness.list.conversations[1].id
        XCTAssertTrue(harness.controller.perform(.later))
        try choose("Tomorrow", in: popped())

        XCTAssertEqual(try harness.environment.store.snoozes(), [Snooze(conversationID: first, dueAt: MailboxClockAligned(preset(.tomorrow)),
                                                                        createdAt: try XCTUnwrap(try harness.environment.store.snoozes().first).createdAt)])
        XCTAssertFalse(try inInbox(first, harness), "archived in the same write")
        let queued = try harness.environment.store.pendingOperations(accountID: first.accountID, limit: 10)
        XCTAssertEqual(queued.map(\.change), [.archive], "the ordinary archive, queued")
        XCTAssertEqual(harness.toastMessage, "Snoozed until \(time(preset(.tomorrow)))")
        harness.spin { !harness.list.conversations.contains { $0.id == first } }
        XCTAssertEqual(harness.list.selectedConversationID, second, "the selection moves on, as after E")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Snooze")

        XCTAssertTrue(harness.controller.perform(.undo))
        harness.spin { harness.list.conversations.contains { $0.id == first } }
        XCTAssertTrue(try snoozedIDs(harness).isEmpty, "the snooze is gone")
        XCTAssertTrue(try inInbox(first, harness))
        XCTAssertEqual(harness.toastMessage, "Undid Snooze")
        XCTAssertEqual(harness.list.selectedConversationID, first, "and selected, as an undo of an archive is")
        XCTAssertEqual(harness.controller.zTarget, .nothing)
    }

    func testSeveralSelectedMakeOneSnoozeOneToastAndOneUndo() throws {
        let (harness, popped) = try harness()
        defer { harness.close() }
        harness.selectFirst(3)
        let ids = Array(harness.list.conversations.prefix(3).map(\.id))
        XCTAssertTrue(harness.controller.perform(.later))
        try choose("Next Week", in: popped())
        XCTAssertEqual(Set(try snoozedIDs(harness)), Set(ids))
        XCTAssertEqual(harness.toastMessage, "Snoozed until \(time(preset(.nextWeek)))", "the time, not the count")
        harness.spin { !harness.list.conversations.contains { ids.contains($0.id) } }
        XCTAssertTrue(harness.controller.perform(.undo))
        harness.spin { ids.allSatisfy { id in harness.list.conversations.contains { $0.id == id } } }
        XCTAssertTrue(try snoozedIDs(harness).isEmpty)
        XCTAssertEqual(harness.list.selectedConversationIDs, ids)
    }

    /// The toast's time shows whole in a list of the default width, beside Undo and Z (§5.45, §5.30). A slip wider than
    /// the list less its margins cuts its message off at the tail, where the time is. For every time a preset offers on
    /// any morning or afternoon of two years, on the 24- and the 12-hour clock, the whole sentence fits: Next Week from
    /// the last Monday of December (29 Dec 2025, 28 Dec 2026) lands in January, written without the year. A date picked
    /// with Pick a Date can be wider (a 12-hour time late in the morning beside a long date, a year ahead), and there
    /// the words the window chooses fit.
    func testTheSnoozeToastShowsItsTimeInAListOfTheDefaultWidth() throws {
        // The list's 364 pt include its trailing hairline, a point on a 1× display.
        let room = Quire.Layout.List.defaultWidth - QuireHairline.width(backingScale: 1, increasedContrast: false) - 2 * Quire.Layout.Toast.sideMargin
        func width(_ message: String) -> CGFloat {
            let slip = QuireSlipView(kind: .undoable, message: message, symbolName: Quire.Icon.later)
            slip.setAction("Undo", keycap: "Z")
            return slip.intrinsicContentSize.width
        }
        for identifier in ["en_GB", "en_US", "en_AU"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: identifier)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
            let formatting = DateFormatting(locale: Locale(identifier: identifier), calendar: calendar, timeZone: calendar.timeZone)
            func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
                try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
            }
            var widest = (width: CGFloat(0), message: "")
            for year in [2025, 2026] {
                let days = try XCTUnwrap(calendar.range(of: .day, in: .year, for: try at(year, 6, 1, 12))).count
                for day in 1...days {
                    for hour in [8, 14] {
                        let now = try at(year, 1, day, hour)
                        let reference = formatting.reference(now: now)
                        for (_, date) in LaterPreset.offered(at: now, calendar: calendar) {
                            let message = MailActionCopy.snoozed(until: formatting.dueTime(for: date, reference: reference))
                            let measured = width(message)
                            if measured > widest.width { widest = (measured, message) }
                        }
                    }
                }
            }
            XCTAssertLessThanOrEqual(widest.width, room, "\(identifier): “\(widest.message)” is cut off")

            // Pick a Date from 8 November 2026: every day for fourteen months, at times that write wide.
            let reference = formatting.reference(now: try at(2026, 11, 8, 10))
            for offset in 1...425 {
                let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: try at(2026, 11, 8, 0)))
                for (hour, minute) in [(10, 0), (12, 44), (22, 45)] {
                    let date = try XCTUnwrap(calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day))
                    let time = formatting.dueTime(for: date, reference: reference)
                    let message = MailActionCopy.snoozed(until: time) { width($0) <= room }
                    XCTAssertTrue(message.hasSuffix(time), message)
                    XCTAssertLessThanOrEqual(width(message), room, "\(identifier): “\(message)” is cut off")
                }
            }
        }
    }

    /// Snoozed more than eleven months ahead, the time writes its year and the sentence would not fit: the window's toast
    /// shows the time whole without “Snoozed”.
    func testTheSnoozeToastKeepsItsTimeWhereTheSentenceWouldNotFit() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let id = harness.list.conversations[0].id
        let calendar = Calendar.autoupdatingCurrent
        let due = try XCTUnwrap(calendar.date(byAdding: .month, value: 13, to: preset(.tomorrow)))
        harness.controller.snooze([id], until: due)
        XCTAssertEqual(try snoozedIDs(harness), [id])
        let slip = try XCTUnwrap(harness.controller.listPane.toastView.slip)
        let room = harness.controller.listPane.toastView.slipRoom
        XCTAssertEqual(room, Quire.Layout.List.defaultWidth - QuireHairline.width(for: harness.list.view) - 2 * Quire.Layout.Toast.sideMargin,
                       accuracy: 0.01, "a list of the default width, its trailing hairline included")
        XCTAssertTrue(slip.message.hasSuffix(time(due)), slip.message)
        XCTAssertLessThanOrEqual(slip.intrinsicContentSize.width, room, "“\(slip.message)” is whole")
        let sentence = MailActionCopy.snoozed(until: time(due))
        let whole = QuireSlipView(kind: .undoable, message: sentence, symbolName: Quire.Icon.later)
        whole.setAction("Undo", keycap: "Z")
        XCTAssertEqual(slip.message, whole.intrinsicContentSize.width <= room ? sentence : "Until \(time(due))")
    }

    /// Pick a Date… opens on tomorrow at 09:00, refuses a time that is not ahead, and snoozes until the time chosen.
    func testPickADateSnoozesUntilTheChosenTime() throws {
        let (harness, popped) = try harness()
        defer { harness.close() }
        harness.selectFirst(1)
        let first = harness.list.conversations[0].id
        var shown: LaterDatePicker?
        var answer: ((Date?) -> Void)?
        harness.controller.presentLaterDatePicker = { picker, _, done in
            shown = picker
            answer = done
        }
        XCTAssertTrue(harness.controller.perform(.later))
        try choose(LaterMenu.pickDateTitle, in: popped())
        let picker = try XCTUnwrap(shown)
        XCTAssertEqual(picker.chosenDate, LaterPreset.tomorrowMorning(after: morning, calendar: .autoupdatingCurrent))
        XCTAssertEqual(picker.alert.buttons.map(\.title), ["Snooze", "Cancel"])
        XCTAssertEqual(picker.snoozeButton.keyEquivalent, "\r", "Snooze is the default")
        XCTAssertTrue(picker.snoozeButton.isEnabled)
        XCTAssertEqual(picker.calendarPicker.datePickerStyle, .clockAndCalendar)
        XCTAssertEqual(picker.timePicker.datePickerElements, .hourMinute)
        // Today, an hour ago: not ahead.
        picker.calendarPicker.dateValue = morning
        picker.timePicker.dateValue = morning.addingTimeInterval(-3_600)
        picker.updateSnoozeButton()
        XCTAssertFalse(picker.snoozeButton.isEnabled, "a time that has passed cannot be chosen")
        picker.timePicker.dateValue = morning.addingTimeInterval(3_600)
        picker.updateSnoozeButton()
        XCTAssertTrue(picker.snoozeButton.isEnabled)

        let chosen = try XCTUnwrap(picker.chosenDate)
        answer?(chosen)
        XCTAssertEqual(try harness.environment.store.snoozes().first?.conversationID, first)
        XCTAssertEqual(try harness.environment.store.snoozes().first?.dueAt.timeIntervalSince1970 ?? 0, chosen.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(harness.toastMessage, "Snoozed until \(time(chosen))")
    }

    /// On Microsoft # leaves the user's reply in Sent Items, so a conversation whose other mail is all in the Trash still
    /// lists in Sent, All Mail and a search, with nothing left to put away: L beeps, as E does when it changes nothing,
    /// rather than toast a snooze the store would drop, and in a selection the others are snoozed.
    func testAConversationWithNothingToPutAwayIsNotSnoozed() throws {
        let (harness, popped) = try harness()
        defer { harness.close() }
        let store = harness.environment.store
        // thread-1 is account B's (Microsoft): the first message trashed, the user's reply in Sent Items.
        let replied = ConversationID(accountID: ListTestSupport.accountB.id, providerID: "thread-1")
        var messages = try store.messages(in: replied)
        XCTAssertEqual(messages.count, 2)
        messages[0].roles = [.trash]
        messages[1].roles = [.sent]
        try store.upsertMessages(messages)
        XCTAssertTrue(harness.controller.perform(.goTo(.sent)))
        harness.spin { harness.list.query.view == .sent && harness.list.conversations.map(\.id) == [replied] }
        harness.selectFirst(1)

        XCTAssertTrue(harness.controller.perform(.later), "spent, with a beep")
        XCTAssertNil(popped(), "no menu: there is nothing to bring back")
        let context = harness.controller.selectionContextMenu()
        XCTAssertEqual(context.items.first { $0.title == "Later" }?.isEnabled, false)
        // Message › Later… or a date picked before the mail went: nothing written, nothing promised.
        harness.controller.snooze([replied], until: preset(.tomorrow))
        XCTAssertTrue(try snoozedIDs(harness).isEmpty)
        XCTAssertNil(harness.toastMessage, "no toast saying it will come back")
        XCTAssertEqual(harness.controller.zTarget, .nothing, "and nothing to undo")

        // With another conversation: that one is snoozed, this one stays as it is.
        let other = ConversationID(accountID: ListTestSupport.accountA.id, providerID: "thread-0")
        harness.controller.snooze([replied, other], until: preset(.tomorrow))
        XCTAssertEqual(try snoozedIDs(harness), [other])
        XCTAssertEqual(harness.toastMessage, "Snoozed until \(time(preset(.tomorrow)))")
        XCTAssertEqual(try store.messages(in: replied).map(\.roles), [[.trash], [.sent]])
    }

    // MARK: Later

    /// ⇧I in Later brings a conversation back now as its time would: the mail the snooze put away, not a message deleted
    /// on the web, which Move to Inbox's own rule would take out of the Trash alone, leaving the snoozed mail archived. A
    /// drop from Later on the Inbox tile does the same.
    func testBackNowFromLaterLeavesDeletedMailDeleted() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let store = harness.environment.store
        // thread-2 (account A, Gmail, three messages): the oldest deleted on the web.
        let id = ConversationID(accountID: ListTestSupport.accountA.id, providerID: "thread-2")
        var messages = try store.messages(in: id)
        XCTAssertEqual(messages.count, 3)
        messages[0].roles = [.trash]
        try store.upsertMessages(messages)
        try snoozeInStore([id], until: preset(.nextWeek), harness)
        XCTAssertEqual(try snoozedIDs(harness), [id], "the rest of it is put away")
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.query.view == .later && harness.list.conversations.map(\.id) == [id] }
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)

        XCTAssertTrue(harness.controller.perform(.moveToInbox))
        XCTAssertEqual(try store.messages(in: id).map(\.roles), [[.trash], [.inbox], [.inbox]], "the snoozed mail back, the deleted one deleted")
        XCTAssertTrue(try snoozedIDs(harness).isEmpty)

        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(try store.messages(in: id).map(\.roles), [[.trash], [], []])
        XCTAssertEqual(try snoozedIDs(harness), [id])
        harness.spin { harness.list.query.view == .later && harness.list.conversations.map(\.id) == [id] }

        XCTAssertTrue(harness.controller.drop([id], onto: .inbox))
        XCTAssertEqual(try store.messages(in: id).map(\.roles), [[.trash], [.inbox], [.inbox]])
        XCTAssertTrue(try snoozedIDs(harness).isEmpty)
    }

    /// The tile shows directly below Inbox only while something in the scope is snoozed, the folders below it, the
    /// hairline and All Mail one pitch lower; narrowed to an account with nothing snoozed it goes again.
    func testTheLaterTileFollowsTheScopeAndMovesTheFoldersBelowIt() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let strip = harness.controller.strip
        let later = strip.folderTiles[1]
        XCTAssertTrue(later.isHidden)
        XCTAssertFalse(harness.controller.showsLater)
        let fromA = try XCTUnwrap(harness.list.conversations.first { $0.id.accountID == ListTestSupport.accountA.id }).id
        try snoozeInStore([fromA], until: preset(.tomorrow), harness)
        XCTAssertTrue(harness.controller.showsLater)
        strip.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(later.isHidden)
        XCTAssertTrue(strip.folderTiles[5].isHidden, "nothing waits to go: no Outbox tile")
        let tops = strip.folderTiles.filter { !$0.isHidden }.map { $0.convert($0.tileRect, to: strip.view).minY }
        XCTAssertEqual(tops, [62, 106, 150, 194, 238, 282, 338], "Later at 106; Starred to Trash and All Mail one pitch down")
        XCTAssertEqual(strip.folderDividerRect.minY, 329, "the hairline moves with them")
        XCTAssertEqual(later.toolTip, "Later  G L")
        XCTAssertEqual(later.unreadCount, 0, "no badge")

        strip.selectShortcut(2) // account B: nothing snoozed there
        XCTAssertFalse(harness.controller.showsLater)
        XCTAssertTrue(later.isHidden)
        strip.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.folderTiles.filter { !$0.isHidden }.map { $0.convert($0.tileRect, to: strip.view).minY },
                       [62, 106, 150, 194, 238, 294])
        strip.selectShortcut(1)
        XCTAssertTrue(harness.controller.showsLater)
    }

    /// With the keyboard on the Later tile (Full Keyboard Access, ↑/↓ in the rail), the tile going as the last snooze in
    /// scope ends, or as ⌘2 narrows to an account with none, hands the keyboard to the Inbox tile, the view the window
    /// goes to, rather than leaving it on a hidden tile with no ring and dead arrows. Focus elsewhere stays where it is.
    func testTheFocusedLaterTileHandsTheKeyboardToInboxAsItGoes() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let strip = harness.controller.strip
        let window = try XCTUnwrap(harness.controller.window)
        let (inbox, later) = (strip.folderTiles[0], strip.folderTiles[1])
        let fromA = harness.list.conversations.filter { $0.id.accountID == ListTestSupport.accountA.id }.map(\.id)

        // Its time comes.
        try snoozeInStore([fromA[0]], until: preset(.nextWeek), harness)
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.query.view == .later && harness.list.conversations.count == 1 }
        XCTAssertTrue(window.makeFirstResponder(later), "the Later tile has the keyboard")
        _ = try harness.environment.store.returnDueSnoozes(at: preset(.nextWeek).addingTimeInterval(60), limit: 10) { id, messages in
            [PaperCore.Operation(accountID: id.accountID, change: .moveToInbox, targets: messages.filter { !$0.isInInbox }.map(\.id))]
        }
        harness.spin { !harness.controller.showsLater }
        XCTAssertTrue(later.isHidden)
        XCTAssertEqual(harness.list.query.view, .inbox)
        XCTAssertTrue(window.firstResponder === inbox, "the Inbox tile, not \(String(describing: window.firstResponder))")

        // ⌘2, to an account with nothing snoozed.
        try snoozeInStore([fromA[1]], until: preset(.nextWeek), harness)
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.query.view == .later && harness.list.conversations.count == 1 }
        XCTAssertTrue(window.makeFirstResponder(later))
        strip.selectShortcut(2)
        XCTAssertTrue(later.isHidden)
        XCTAssertTrue(window.firstResponder === inbox, "the Inbox tile, not \(String(describing: window.firstResponder))")

        // With the keyboard in the list, the tile goes and the list keeps it.
        strip.selectShortcut(1)
        XCTAssertFalse(later.isHidden)
        XCTAssertTrue(window.makeFirstResponder(harness.list.tableView))
        strip.selectShortcut(2)
        XCTAssertTrue(later.isHidden)
        XCTAssertTrue(window.firstResponder === harness.list.tableView)
    }

    /// G L opens Later while it shows and does nothing otherwise; Later's rows are the snoozed conversations, soonest
    /// first, each reading “Back …” in its time slot, under no running heads.
    func testGLOpensLaterWhoseRowsReadBackAndTheirTime() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.controller.perform(.goTo(.later)), "spent")
        XCTAssertEqual(harness.list.query.view, .inbox, "nothing snoozed: G L does nothing")

        let ids = Array(harness.list.conversations.prefix(3).map(\.id))
        try snoozeInStore([ids[0]], until: preset(.nextWeek), harness)
        try snoozeInStore([ids[1]], until: preset(.laterToday), harness)
        try snoozeInStore([ids[2]], until: preset(.tomorrow), harness)
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.query.view == .later && harness.list.conversations.count == 3 }
        XCTAssertEqual(harness.list.conversations.map(\.id), [ids[1], ids[2], ids[0]], "soonest first")
        XCTAssertEqual(harness.controller.strip.mailboxView, .later)
        XCTAssertEqual(harness.controller.listPane.header.masthead.title, "Later")
        XCTAssertFalse(harness.list.layout.items.contains { if case .head = $0 { return true } else { return false } })
        for (index, due) in [preset(.laterToday), preset(.tomorrow), preset(.nextWeek)].enumerated() {
            let cell = try cell(forConversation: index, harness)
            let formatting = DateFormatting()
            let expected = "Back " + formatting.dueTime(for: due, reference: formatting.reference(now: Date()))
            XCTAssertEqual(cell.content?.time.string, expected)
        }
    }

    /// In Later, L reschedules (Undo puts the old time back), E ends the snooze and leaves the mail archived, and ⇧I
    /// moves it back to the Inbox now; once the last snooze in view is gone the window returns to the Inbox, and an undo
    /// brings Later back with its row selected.
    func testActionsInLater() throws {
        let (harness, popped) = try harness()
        defer { harness.close() }
        let ids = Array(harness.list.conversations.prefix(2).map(\.id))
        try snoozeInStore([ids[0]], until: preset(.nextWeek), harness)
        try snoozeInStore([ids[1]], until: preset(.nextWeek), harness)
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.conversations.count == 2 }

        // L: a new time, kept on Undo.
        harness.list.selectedConversationID = ids[0]
        harness.list.onSelectionChange?(ids[0])
        XCTAssertTrue(harness.controller.perform(.later))
        try choose("Tomorrow", in: popped())
        XCTAssertEqual(try harness.environment.store.snoozes().first { $0.conversationID == ids[0] }?.dueAt, MailboxClockAligned(preset(.tomorrow)))
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(try harness.environment.store.snoozes().first { $0.conversationID == ids[0] }?.dueAt, MailboxClockAligned(preset(.nextWeek)),
                       "Undo puts the old time back")

        // E: no longer snoozed, still archived.
        harness.spin { harness.list.conversations.count == 2 }
        harness.list.selectedConversationID = ids[0]
        harness.list.onSelectionChange?(ids[0])
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertEqual(harness.toastMessage, "Archived")
        XCTAssertEqual(try snoozedIDs(harness), [ids[1]])
        XCTAssertFalse(try inInbox(ids[0], harness))
        harness.spin { harness.list.conversations.map(\.id) == [ids[1]] }
        XCTAssertEqual(harness.list.selectedConversationID, ids[1], "the selection moves on")

        // ⇧I on the last one: back in the Inbox, and the window with it, Later's tile gone.
        XCTAssertTrue(harness.controller.perform(.moveToInbox))
        XCTAssertEqual(harness.toastMessage, "Moved to Inbox")
        XCTAssertTrue(try inInbox(ids[1], harness))
        XCTAssertTrue(try snoozedIDs(harness).isEmpty)
        harness.spin { harness.list.query.view == .inbox }
        XCTAssertFalse(harness.controller.showsLater)
        XCTAssertTrue(harness.controller.strip.folderTiles[1].isHidden)
        XCTAssertNil(try harness.environment.store.conversations(ConversationQuery(view: .inbox)).first { $0.id == ids[1] }?.returnedAt,
                     "ended early: no return, no Back tag")

        // Undo: snoozed again, archived again, and Later shows it.
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(try snoozedIDs(harness), [ids[1]])
        XCTAssertFalse(try inInbox(ids[1], harness))
        harness.spin { harness.list.query.view == .later && harness.list.conversations.map(\.id) == [ids[1]] }
        XCTAssertEqual(harness.list.selectedConversationID, ids[1])
        XCTAssertTrue(harness.controller.showsLater)

        // E's undo, the archived one: snoozed again.
        harness.controller.snooze([ids[0]], until: preset(.nextWeek))
        XCTAssertEqual(Set(try snoozedIDs(harness)), Set(ids))
    }

    /// E in Later coalesces as E does everywhere (§5.30): a second press within the window while the toast shows updates
    /// that toast to “Archived 2 conversations”, and one Z puts both snoozes back and selects both. Once that toast has
    /// gone, the next E starts a toast of its own.
    func testEInLaterCoalescesIntoOneToastAndOneUndo() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let ids = Array(harness.list.conversations.prefix(3).map(\.id))
        try snoozeInStore(ids, until: preset(.nextWeek), harness)
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.query.view == .later && harness.list.conversations.count == 3 }

        select(ids[0], harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertEqual(harness.toastMessage, "Archived")
        let toast = harness.toasts.visibleID
        harness.spin { harness.list.conversations.count == 2 }
        select(ids[1], harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertEqual(harness.toastMessage, "Archived 2 conversations", "the same toast, counting both")
        XCTAssertEqual(harness.toasts.visibleID, toast)
        XCTAssertEqual(try snoozedIDs(harness), [ids[2]])
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Archive")
        harness.spin { harness.list.conversations.count == 1 }

        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(Set(try snoozedIDs(harness)), Set(ids), "one Z puts back both snoozes")
        XCTAssertEqual(harness.toastMessage, "Undid Archive")
        XCTAssertEqual(harness.controller.zTarget, .nothing, "and nothing is left to undo")
        harness.spin { harness.list.conversations.count == 3 }
        XCTAssertEqual(Set(harness.list.selectedConversationIDs), Set(ids.prefix(2)), "both selected, as an undo of E selects")

        // Its toast gone (Esc), the next E is a step of its own.
        select(ids[0], harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        harness.toasts.dismiss()
        harness.spin { harness.list.conversations.count == 2 }
        select(ids[1], harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertEqual(harness.toastMessage, "Archived")
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(Set(try snoozedIDs(harness)), Set(ids.suffix(2)), "Z undoes the second alone")
    }

    func testTrashingInLaterEndsTheSnoozeAndUndoBringsItBack() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let id = harness.list.conversations[0].id
        try snoozeInStore([id], until: preset(.nextWeek), harness)
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.conversations.count == 1 }
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        XCTAssertTrue(harness.controller.perform(.trash))
        XCTAssertEqual(harness.toastMessage, "Moved to Trash")
        XCTAssertTrue(try snoozedIDs(harness).isEmpty)
        harness.spin { harness.list.query.view == .inbox }
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(try snoozedIDs(harness), [id])
        let messages = try harness.environment.store.messages(in: id)
        XCTAssertTrue(messages.allSatisfy { !$0.roles.contains(.trash) && !$0.isInInbox }, "out of the Trash, archived")
        harness.spin { harness.list.query.view == .later }
    }

    /// The Later tile takes no drop; rows dragged from Later onto Inbox move back now (ending the snooze), which Undo
    /// puts back.
    func testTheLaterTileRefusesDropsAndAnInboxDropEndsTheSnooze() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let ids = Array(harness.list.conversations.prefix(2).map(\.id))
        try snoozeInStore([ids[0]], until: preset(.nextWeek), harness)
        let strip = harness.controller.strip
        strip.view.layoutSubtreeIfNeeded()
        // An Inbox row dragged over the Later tile: nothing lights, nothing is dropped.
        let inboxDrag = try dragOfRows([ids[1]], in: harness)
        let later = strip.folderTiles[1]
        aim(inboxDrag, at: later)
        XCTAssertEqual(strip.view.draggingEntered(inboxDrag), [])
        XCTAssertFalse(strip.view.performDragOperation(inboxDrag))
        strip.view.draggingExited(inboxDrag)
        XCTAssertFalse(harness.controller.acceptsDrop(of: [ids[1]], onto: .later))

        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.conversations.map(\.id) == [ids[0]] }
        XCTAssertTrue(harness.controller.drop([ids[0]], onto: .inbox))
        XCTAssertTrue(try inInbox(ids[0], harness))
        XCTAssertTrue(try snoozedIDs(harness).isEmpty)
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(try snoozedIDs(harness), [ids[0]])
    }

    // MARK: Back in the Inbox

    /// A conversation that came back sorts under Today by the time it came back, with the Back tag while it is unread;
    /// read, it keeps its place and loses the tag.
    func testAReturnedRowSortsUnderTodayWithItsBackTag() throws {
        let harness = try MainWindowHarness(threads: 10, spacing: 86_400)
        defer { harness.close() }
        let store = harness.environment.store
        let old = harness.list.conversations[8].id // eight days back
        let targets = try store.messages(in: old).map(\.id)
        try store.setSnoozes([Snooze.Change(conversationID: old, until: Date().addingTimeInterval(-60))],
                             enqueueing: [PaperCore.Operation(accountID: old.accountID, change: .archive, targets: targets)], at: Date().addingTimeInterval(-600))
        let now = Date()
        try store.returnDueSnoozes(at: now, limit: 10) { id, messages in
            [PaperCore.Operation(accountID: id.accountID, change: .moveToInbox, targets: messages.map(\.id), createdAt: now),
             PaperCore.Operation(accountID: id.accountID, change: .setRead(false), targets: [messages.last!.id], createdAt: now.addingTimeInterval(0.001))]
        }
        harness.spin { harness.list.conversations.first?.id == old }
        XCTAssertEqual(harness.list.conversations.first?.id, old, "above today's newer mail")
        guard case .head(.today)? = harness.list.layout.items.first else { return XCTFail("the first head is Today: \(harness.list.layout.items.prefix(2))") }
        let back = try cell(forConversation: 0, harness)
        XCTAssertEqual(back.content?.showsBackTag, true)
        let tag = try XCTUnwrap(back.backTagRect)
        XCTAssertEqual(tag.size, QuireTag.size(for: "Back"))
        XCTAssertEqual(back.content?.time.string, DateFormatting().string(for: now, reference: DateFormatting().reference(now: Date()), style: .timeOfDay),
                       "the time it came back, as Today's rows show times")
        XCTAssertTrue(back.content?.accessibilityLabel.contains("Back from Later") == true)

        try harness.environment.engine.perform(.setRead(true), on: targets)
        harness.spin { harness.list.conversations.first?.unreadCount == 0 }
        XCTAssertEqual(harness.list.conversations.first?.id, old, "read, it keeps its place")
        XCTAssertNil(try cell(forConversation: 0, harness).backTagRect, "and the tag goes")
    }

    /// Archive, Move to Trash and Snooze take a conversation back from Later out of the Inbox, which ends its mark; Z puts
    /// the row back where it was, first under Today, not eight rows down under its old date.
    func testAnUndoPutsAReturnedRowBackUnderToday() throws {
        let harness = try MainWindowHarness(threads: 10, spacing: 86_400)
        defer { harness.close() }
        let store = harness.environment.store
        let old = harness.list.conversations[8].id // eight days back
        let targets = try store.messages(in: old).map(\.id)
        try store.setSnoozes([Snooze.Change(conversationID: old, until: Date().addingTimeInterval(-60))],
                             enqueueing: [PaperCore.Operation(accountID: old.accountID, change: .archive, targets: targets)], at: Date().addingTimeInterval(-600))
        let now = Date()
        try store.returnDueSnoozes(at: now, limit: 10) { id, messages in
            [PaperCore.Operation(accountID: id.accountID, change: .moveToInbox, targets: messages.map(\.id), createdAt: now),
             PaperCore.Operation(accountID: id.accountID, change: .setRead(false), targets: [messages.last!.id], createdAt: now.addingTimeInterval(0.001))]
        }
        harness.spin { harness.list.conversations.first?.id == old }
        let mark = try XCTUnwrap(harness.list.conversations.first?.returnedAt)

        func assertBackUnderToday(_ step: String, line: UInt = #line) {
            harness.spin { harness.list.conversations.first?.id == old }
            XCTAssertEqual(harness.list.conversations.first?.id, old, "\(step): back first", line: line)
            XCTAssertEqual(harness.list.conversations.first?.returnedAt, mark, "\(step): with its mark", line: line)
            if case .head(.today)? = harness.list.layout.items.first {} else { XCTFail("\(step): under Today", line: line) }
        }
        // E and #, by drops on All Mail and Trash, which take E's and #'s paths without opening (and reading) the row.
        XCTAssertTrue(harness.controller.drop([old], onto: .all))
        harness.spin { harness.list.conversations.first?.id != old }
        XCTAssertTrue(harness.controller.perform(.undo))
        assertBackUnderToday("Archive")
        XCTAssertTrue(harness.controller.drop([old], onto: .trash))
        harness.spin { harness.list.conversations.first?.id != old }
        XCTAssertTrue(harness.controller.perform(.undo))
        assertBackUnderToday("Move to Trash")
        harness.controller.snooze([old], until: Date().addingTimeInterval(86_400))
        harness.spin { harness.list.conversations.first?.id != old }
        XCTAssertTrue(harness.controller.perform(.undo))
        assertBackUnderToday("Snooze")
        XCTAssertTrue(try snoozedIDs(harness).isEmpty)
    }

    // MARK: Searching and undoing around Later

    private func typeSearch(_ text: String, _ harness: MainWindowHarness) {
        harness.controller.listPane.header.search.query = text
        harness.controller.listPane.header.search.onQueryChange?(text)
        harness.spin { harness.list.query.searchText == text && !harness.list.conversations.isEmpty }
    }

    private func select(_ id: ConversationID, _ harness: MainWindowHarness) {
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
    }

    /// L follows the view a search looks through, not the rail's (§5.6, §5.45): `in:trash` results, typed from the Inbox,
    /// are refused as in the Trash, and a search typed in the Trash lists All Mail, whose rows L snoozes.
    func testLFollowsTheViewASearchLooksThrough() throws {
        let (harness, popped) = try harness()
        defer { harness.close() }
        let trashed = harness.list.conversations[0].id
        try harness.environment.engine.perform(.trash, on: trashed)
        typeSearch("in:trash", harness)
        XCTAssertEqual(harness.list.query.view, .trash)
        select(trashed, harness)
        XCTAssertTrue(harness.controller.perform(.later), "spent, with a beep")
        XCTAssertNil(popped(), "no menu for Trash results")
        let item = NSMenuItem(title: "Later…", action: #selector(MainWindowController.laterSelection(_:)), keyEquivalent: "l")
        XCTAssertFalse(harness.controller.validateMenuItem(item))

        _ = harness.controller.perform(.goTo(.trash))
        typeSearch("Project", harness)
        XCTAssertEqual(harness.list.query.view, .all, "a search typed in the Trash looks through All Mail")
        // The list still holds the `in:trash` result until this search's first page lands off the main thread.
        harness.spin { harness.list.conversations.contains { $0.id != trashed } }
        let result = try XCTUnwrap(harness.list.conversations.first { $0.id != trashed }?.id)
        select(result, harness)
        XCTAssertTrue(harness.controller.validateMenuItem(item))
        XCTAssertTrue(harness.controller.perform(.later))
        try choose("Tomorrow", in: popped())
        XCTAssertEqual(try snoozedIDs(harness), [result])
        XCTAssertFalse(try inInbox(result, harness))
    }

    /// A search typed in Later shows all mail, so when the last snooze in view ends (its time comes, or ⌘2 narrows to an
    /// account with none) the window goes back to the Inbox under the search, which stays with its results, selection
    /// and reader; clearing it lands in the Inbox.
    func testASearchTypedInLaterOutlivesLaterEmptying() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let fromA = harness.list.conversations.filter { $0.id.accountID == ListTestSupport.accountA.id }.map(\.id)
        try snoozeInStore([fromA[0]], until: preset(.nextWeek), harness)
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.query.view == .later && harness.list.conversations.count == 1 }
        typeSearch("Project", harness)
        harness.spin { harness.list.conversations.contains { $0.id != fromA[0] } }
        let reading = try XCTUnwrap(harness.list.conversations.first { $0.id != fromA[0] }, "\(harness.list.conversations.map(\.subject))").id
        select(reading, harness)

        // Its time comes.
        let back = try harness.environment.store.returnDueSnoozes(at: preset(.nextWeek).addingTimeInterval(60), limit: 10) { id, messages in
            [PaperCore.Operation(accountID: id.accountID, change: .moveToInbox, targets: messages.filter { !$0.isInInbox }.map(\.id))]
        }
        XCTAssertEqual(back, [fromA[0]])
        harness.spin { !harness.controller.showsLater }
        harness.spin { harness.controller.listPane.header.masthead.title == "Inbox" }
        XCTAssertEqual(harness.controller.listPane.header.masthead.title, "Inbox")
        XCTAssertEqual(harness.list.query.searchText, "Project", "the search stays")
        XCTAssertEqual(harness.controller.listPane.header.search.query, "Project", "and its field")
        XCTAssertEqual(harness.list.selectedConversationID, reading, "and the selection")
        XCTAssertEqual(harness.controller.conversation.currentConversationID, reading, "and the reader")

        clearSearch(harness)
        XCTAssertEqual(harness.list.query.view, .inbox, "cleared, the search lands in the Inbox")

        // ⌘2 from a search typed in Later, to an account with nothing snoozed.
        try snoozeInStore([fromA[1]], until: preset(.nextWeek), harness)
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.query.view == .later }
        typeSearch("Project", harness)
        harness.controller.strip.selectShortcut(2)
        XCTAssertFalse(harness.controller.showsLater)
        XCTAssertEqual(harness.list.query.searchText, "Project", "a scope change keeps the search, as in every view")
        XCTAssertEqual(harness.controller.listPane.header.search.query, "Project")
        clearSearch(harness)
        XCTAssertEqual(harness.list.query.view, .inbox)
    }

    private func clearSearch(_ harness: MainWindowHarness) {
        harness.controller.listPane.header.search.query = ""
        harness.controller.listPane.header.search.onQueryChange?("")
        harness.spin { harness.list.query.searchText == nil }
    }

    /// Z leaves the window in the view the user went to: Later comes back only when it emptied and sent the window to the
    /// Inbox (testActionsInLater), not after the user picked another view or typed a search.
    func testAnUndoOfAStepInLaterLeavesTheViewTheUserChose() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let ids = Array(harness.list.conversations.prefix(3).map(\.id))
        try snoozeInStore(ids, until: preset(.nextWeek), harness)
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.conversations.count == 3 }

        // # on one of three: Later keeps two; G I, a search, then Z.
        select(ids[0], harness)
        XCTAssertTrue(harness.controller.perform(.trash))
        harness.spin { harness.list.conversations.count == 2 }
        XCTAssertTrue(harness.controller.perform(.goTo(.inbox)))
        typeSearch("Project", harness)
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(Set(try snoozedIDs(harness)), Set(ids), "the snooze is back")
        XCTAssertEqual(harness.list.query.searchText, "Project", "the search stays")
        XCTAssertEqual(harness.controller.listPane.header.search.query, "Project")
        XCTAssertEqual(harness.controller.strip.mailboxView, .inbox)

        // E on one in Later, then G S, then Z: still Starred.
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.query.view == .later && harness.list.conversations.count == 3 }
        select(ids[1], harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertEqual(harness.toastMessage, "Archived")
        XCTAssertTrue(harness.controller.perform(.goTo(.starred)))
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(Set(try snoozedIDs(harness)), Set(ids))
        XCTAssertEqual(harness.list.query.view, .starred, "the view the user chose")
    }

    // MARK: Menus and keys

    func testMenusAndKeysNameLaterOnlyWhileItShows() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        XCTAssertEqual(KeyboardRouter.command(characters: "l", keyCode: 37, modifiers: [], pendingG: false, readerFocused: false).command, .later)
        XCTAssertEqual(KeyboardRouter.sequenceView(characters: "l"), .later)
        XCTAssertEqual(Quire.cheatSheet.flatMap(\.rows).filter { $0.keys == "L" || $0.keys == "G then L" }.map(\.label),
                       ["Snooze until later", "Later"])

        func titleMenu() -> [String] {
            let model = TitleMenu.Model(view: .inbox, inboxUnread: 0, scope: .unified, showsAccounts: false, unifiedUnread: 0, accounts: [],
                                        showsLater: harness.controller.showsLater)
            let action = #selector(MainWindowController.goToMailboxView(_:))
            return TitleMenu.build(model, target: self, viewAction: action, scopeAction: action)
                .items.filter { !$0.isSeparatorItem }.map(name)
        }
        let goLater = NSMenuItem(title: "Later", action: #selector(MainWindowController.goToMailboxView(_:)), keyEquivalent: "")
        goLater.tag = MailboxView.allCases.firstIndex(of: .later)!
        XCTAssertEqual(titleMenu(), ["Inbox", "Starred", "Sent", "Drafts", "Trash", "All Mail"])
        XCTAssertFalse(harness.controller.validateMenuItem(goLater))

        try snoozeInStore([harness.list.conversations[0].id], until: preset(.tomorrow), harness)
        XCTAssertEqual(titleMenu(), ["Inbox", "Later", "Starred", "Sent", "Drafts", "Trash", "All Mail"], "in the rail's place")
        XCTAssertTrue(harness.controller.validateMenuItem(goLater))
        // Message › Later… and the context menu's Later submenu.
        harness.selectFirst(1)
        let laterItem = NSMenuItem(title: "Later…", action: #selector(MainWindowController.laterSelection(_:)), keyEquivalent: "l")
        XCTAssertTrue(harness.controller.validateMenuItem(laterItem))
        let context = harness.controller.selectionContextMenu()
        let submenu = try XCTUnwrap(context.items.first { $0.title == "Later" }?.submenu)
        XCTAssertEqual(submenu.items.map(name), ["Later Today", "This Evening", "Tomorrow", "Next Week", "—", "Pick a Date…"])
    }

    func testAReturnIsNotNewMail() {
        let notifier = NewMailNotifier(settings: ListTestSupport.settings(), launchDate: Date().addingTimeInterval(-3_600))
        let account = ListTestSupport.accountA
        func row(_ id: String, returnedAt: Date?) -> ConversationSummary {
            ConversationSummary(id: ConversationID(accountID: account.id, providerID: id), subject: "Hello", snippet: "Hi",
                                participants: [EmailAddress(address: "ann@example.com")], latestDate: Date(), messageCount: 1, unreadCount: 1,
                                isStarred: false, hasAttachments: false, inInbox: true, inboxSection: .unknown,
                                latestMessageID: MessageID(accountID: account.id, providerID: id + "-m"), hasPendingOperations: false,
                                returnedAt: returnedAt)
        }
        _ = notifier.plan([], accounts: [account.id: account], now: Date())
        let posts = notifier.plan([row("back", returnedAt: Date()), row("new", returnedAt: nil)], accounts: [account.id: account], now: Date())
        XCTAssertEqual(posts.compactMap(\.conversation?.providerID), ["new"], "the Inbox badge and the Back tag say it came back")
    }

    // MARK: Drags

    private func dragOfRows(_ ids: [ConversationID], in harness: MainWindowHarness) throws -> FakeDraggingInfo {
        let list = harness.list
        var items: [NSPasteboardWriting] = []
        for id in ids {
            let index = try XCTUnwrap(list.conversations.firstIndex { $0.id == id })
            let row = try XCTUnwrap(list.layout.row(ofConversation: index))
            items.append(try XCTUnwrap(list.tableView(list.tableView, pasteboardWriterForRow: row)))
        }
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        pasteboard.writeObjects(items)
        return FakeDraggingInfo(pasteboard: pasteboard, source: list.tableView, mask: [.copy, .move])
    }

    private func aim(_ info: FakeDraggingInfo, at tile: AccountStripButton) {
        info.draggingLocation = tile.convert(NSPoint(x: tile.tileRect.midX, y: tile.tileRect.midY), to: nil)
    }
}

/// A date as the SQLite store reads it back: to the millisecond.
private func MailboxClockAligned(_ date: Date) -> Date {
    Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
}
