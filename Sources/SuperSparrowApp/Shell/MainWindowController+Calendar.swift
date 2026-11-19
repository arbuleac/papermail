import AppKit
import SSCore
import SSDesign

/// The days the calendar goes back to, and what it last followed (spec §5.54, “It follows the mail”). The day the column
/// shows is never stored: these live as long as the window.
struct CalendarFollow {
    /// The selection the column last turned for, and the day it named.
    struct Followed: Equatable {
        var conversation: ConversationID?
        var day: Date?
    }

    /// The day the user last chose for the column ([ ], T, a day cell, a day's heading in the week): where the column
    /// goes back to when the selection names no day. Today until then, and it turns at midnight while it is today.
    var day: Date
    /// The same for the week.
    var week: Date
    var last: Followed?
    /// Today as `day` and `week` last knew it.
    var today: Date
    /// The shown days outside the kept window the engine was asked to read: each once.
    var rangesAsked: Set<DateInterval> = []

    init(day: Date) {
        self.day = day
        week = day
        today = day
    }
}

/// The calendar in the main window (spec §5.54): the day column at the reader's edge (D), its strip and the column opened
/// over the reader, the week in their place (W), the keys that turn them, the column following the selection, time set
/// aside for a mail (B, a dropped row, the mail's time) and removed, with their toasts and undo, and Connect.
///
/// The views (Calendar/) read only `CalendarState`; every change goes through `MailClient`, store first, as the mail
/// actions do, and joins the undo history (§6.1) as an external step.
extension MainWindowController: CalendarViewDelegate, CalendarStateObserver {
    func wireCalendar() {
        desk.column.delegate = self
        desk.week.delegate = self
        desk.strip.delegate = self
        // Under the desk, not the window's content view (the split view, whose subviews are its panes).
        desk.column.details.hostView = desk.view
        desk.week.details.hostView = desk.view
        desk.onPlacementChange = { [weak self] in self?.calendarPlacementDidChange() }
        // A click in the reader closes the column opened over it as Esc and D do, focus in it going back to the list.
        desk.onCoverClick = { [weak self] in _ = self?.closeCalendarOverlay() }
        calendarState.addObserver(self, first: true)
        // The calendar's toggle stands at the trailing edge from the first frame when an earlier launch saw access.
        calendarAccessMayHaveChanged()
        // A body the reader fetched may carry the invitation or the times the calendar marks (§5.54).
        conversation.onBodyArrived = { [weak self] id in
            guard let self, self.calendarState.selectedConversation == id else { return }
            self.calendarState.reloadSelection()
        }
        calendarPlacementDidChange()
    }

    // MARK: What shows

    /// D (spec §5.54): back to the reader and the day while the week shows; what a click on the strip does while the
    /// column is folded to it; otherwise show or hide the column, kept for the next launch.
    func toggleDay() {
        if desk.isWeekShown {
            leaveWeek(on: nil, columnOn: true)
        } else if desk.placement == .strip {
            openStrip()
        } else {
            setColumnOn(!desk.isColumnOn)
        }
    }

    /// W: the week in the reader's place and the column's, or the reader and the column back.
    func toggleWeekView() {
        if desk.isWeekShown {
            leaveWeek(on: nil, columnOn: nil)
        } else {
            showWeek()
        }
    }

    private func setColumnOn(_ on: Bool) {
        let focusWasInColumn = isFocused(in: desk.column)
        if !isSnapshot { settings.showsDayColumn = on }
        desk.setColumnOn(on)
        applyColumnWidths()
        if focusWasInColumn, !on { focusList() }
    }

    /// The week opens on the week of the column's day; turning it never moves that day (§5.54).
    private func showWeek() {
        let state = calendarState
        state.shownWeek = state.shownDay
        calendarFollow.week = state.shownWeek
        state.span = .week
        // The reader is hidden, not removed: focus in it goes back to the list, which keeps the keyboard.
        let focusWasInReader = isReaderFocused || isFocused(in: desk.column)
        desk.setWeekShown(true)
        // Mail no one can see is not read: the reader under the week marks nothing read until it shows again (§5.54).
        conversation.isOnScreen = false
        if focusWasInReader { focusList() }
    }

    /// Back to the reader and the column: on `day` (a day's heading), else on the day the column showed before the week
    /// opened, or the selected mail's since. `columnOn` true (D) shows the column too.
    private func leaveWeek(on day: Date?, columnOn: Bool?) {
        let state = calendarState
        if let day {
            state.shownDay = day
            calendarFollow.day = state.shownDay
        }
        state.span = .day
        if columnOn == true, !desk.isColumnOn { setColumnOn(true) }
        let focusWasInWeek = isFocused(in: desk.week)
        desk.setWeekShown(false)
        // The conversation shows again: it is read, and its failed mark seen, as when it was selected (§5.7, §8.5).
        conversation.isOnScreen = true
        if focusWasInWeek { focusList() }
    }

    /// Esc's row 11 (§6.1): the column opened over the reader's edge closes back to its strip, and focus that was in it
    /// returns to the list. False when it was not open.
    func closeCalendarOverlay() -> Bool {
        guard desk.isOverlayOpen else { return false }
        let focusWasInColumn = isFocused(in: desk.column)
        desk.setOverlayOpen(false)
        if focusWasInColumn { focusList() }
        return true
    }

    /// A calendar coming on screen reads the selection at once, so it shows the selected mail's day in its first frame,
    /// and asks the engine for a fresh read; one going away lets the selection go, so J and K cost the calendar nothing
    /// while it is hidden (§5.54).
    private func calendarPlacementDidChange() {
        let onScreen = desk.placement != .none
        if onScreen != wasCalendarOnScreen {
            wasCalendarOnScreen = onScreen
            selectInCalendar(shownSelection, readNow: onScreen)
            // Nothing selected, or what was selected while it was hidden, is followed as J and K would have.
            if onScreen { followSelection() }
            // Shown days outside the kept window are read with it; otherwise the window alone.
            if onScreen, !readShownDaysOutsideWindow() { readCalendars(nil) }
        }
    }

    /// The calendar's toggle stays at the trailing edge once some account has granted the calendar permission (§5.54).
    /// The engine says so after its first look at each account; until then the window goes by what the last launch saw,
    /// so a hidden column's strip is there from the first frame rather than pushing the reader over a moment later.
    func calendarAccessMayHaveChanged() {
        let known = calendarState.calendarAccess
        if let known, !isSnapshot, settings.hasCalendarAccess != known { settings.hasCalendarAccess = known }
        let access = known ?? (isSnapshot ? false : settings.hasCalendarAccess)
        guard access != desk.hasCalendarAccess else { return }
        desk.setCalendarAccess(access)
        applyColumnWidths()
    }

    func isFocused(in view: NSView) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    /// Focus is in the day column or the week (Esc's row 14 returns it to the list).
    var isCalendarFocused: Bool { isFocused(in: desk.column) || isFocused(in: desk.week) }

    /// The calendar's stops in the window's Tab loop, after the reader's (§3.4): the column's while it shows, or the week's.
    var calendarKeyViews: [NSView] {
        switch desk.placement {
        case .week: return desk.week.keyViews
        case .column, .strip: return desk.isDayShowing ? desk.column.keyViews : []
        case .none: return []
        }
    }

    // MARK: Following the selection

    func calendarState(_ state: CalendarState, didChange change: CalendarChange) {
        if change.contains(.statuses) { calendarAccessMayHaveChanged() }
        if change.contains(.day) { followNewDay() }
        if change.contains(.selection) { followSelection() }
        if change.contains(.shown) { readShownDaysOutsideWindow() }
    }

    /// The list's selection, for the calendar (one conversation, else none): only while a calendar shows. Hidden, the
    /// column follows nothing and reads nothing, and it catches up as it comes back (`calendarPlacementDidChange`).
    func selectInCalendar(_ ids: [ConversationID], readNow: Bool = false) {
        let id = desk.placement == .none || ids.count != 1 ? nil : ids.first
        calendarState.select(id, readNow: readNow)
    }

    /// J and K move the column (or the week) only when the selected conversation is about a time: to its invitation's
    /// day, or the day its mail names; anything else puts it back on the day the user was on (§5.54). Nothing moves until
    /// the conversation's context has been read, so the column turns once, not twice.
    private func followSelection() {
        let state = calendarState
        guard desk.placement != .none else { return }
        if let selected = state.selectedConversation, state.selection?.conversationID != selected { return }
        let day = state.selectionDay
        let followed = CalendarFollow.Followed(conversation: state.selectedConversation, day: day)
        guard followed != calendarFollow.last else { return }
        calendarFollow.last = followed
        state.shownDay = day ?? calendarFollow.day
        if state.span == .week { state.shownWeek = day ?? calendarFollow.week }
    }

    /// Midnight passed: the day the column goes back to turns with it while it was today, as the shown day does
    /// (`CalendarState`); a day the user chose stays.
    private func followNewDay() {
        let state = calendarState
        let old = calendarFollow.today
        guard old != state.today else { return }
        calendarFollow.today = state.today
        if calendarFollow.day == old { calendarFollow.day = state.today }
        if state.text.week(containing: calendarFollow.week) == state.text.week(containing: old) { calendarFollow.week = state.today }
    }

    /// Days turned to outside the kept window (`CalendarWindow`) show what the store holds and are read once, for every
    /// account, with the window (spec §5.54); a hidden calendar asks for nothing. Returns whether it asked.
    @discardableResult
    private func readShownDaysOutsideWindow() -> Bool {
        guard desk.placement != .none, let range = calendarState.shownRangeOutsideWindow,
              calendarFollow.rangesAsked.insert(range).inserted else { return false }
        readCalendars(range)
        return true
    }

    // MARK: Turning the page

    func turnDay(by days: Int) {
        let state = calendarState
        if state.span == .week {
            state.shownWeek = state.calendar.date(byAdding: .day, value: days, to: state.shownWeek) ?? state.shownWeek
            calendarFollow.week = state.shownWeek
        } else {
            state.shownDay = state.calendar.date(byAdding: .day, value: days, to: state.shownDay) ?? state.shownDay
            calendarFollow.day = state.shownDay
        }
    }

    func goToToday() {
        let state = calendarState
        if state.span == .week {
            state.shownWeek = state.today
            calendarFollow.week = state.shownWeek
        } else {
            state.shownDay = state.today
            calendarFollow.day = state.shownDay
        }
    }

    func selectDay(_ day: Date) {
        calendarState.shownDay = day
        calendarFollow.day = calendarState.shownDay
    }

    func openWeekHeading(day: Date) {
        leaveWeek(on: day, columnOn: true)
    }

    /// The strip's glyph is the calendar's toggle: in a window wide enough for the column it shows the column in place
    /// (the column was hidden), and in one too narrow it opens or closes the column over the reader's edge.
    func openStrip() {
        if !desk.isNarrow, !desk.isColumnOn {
            setColumnOn(true)
        } else if desk.isOverlayOpen {
            _ = closeCalendarOverlay()
        } else {
            desk.setOverlayOpen(true)
        }
    }

    func toggleDayColumn() { toggleDay() }

    func toggleWeek() { toggleWeekView() }

    /// The calendar shows `start`'s day: where time was just set aside (§5.54).
    private func turnCalendar(to start: Date) {
        let state = calendarState
        if state.span == .week { state.shownWeek = start } else { state.shownDay = start }
    }

    // MARK: Setting time aside

    /// B in the main window (spec §5.54): 30 minutes for the one selected conversation, at the first time its mail names
    /// that is still ahead, else at the first free half hour from the day the column (or the week) shows. A selected
    /// invitation is answered on its card instead; nothing or several selected beep.
    func blockTimeForSelection() -> Bool {
        guard !isSeveralSelected, let id = list.selectedConversationID else {
            NSSound.beep()
            return true
        }
        // Now, read afresh: the clock moves only while a calendar is on screen, and B works without one.
        calendarState.clock.tick()
        let context = calendarContext(of: id)
        if context.invitation != nil {
            calendarNotice(CalendarCopy.answerInvitation)
            return true
        }
        let from = blockSearchStart
        guard let start = calendarState.blockStart(for: context, from: from.day, dayIsShown: from.isShown) else {
            NSSound.beep()
            return true
        }
        setAside(id, at: start)
        return true
    }

    /// B in a reader window (§5.49): as with the day column hidden, from today; its toast and undo are that window's.
    func blockTime(from reader: ReaderWindowController) {
        act(in: reader, closing: false) {
            calendarState.clock.tick()
            let id = reader.conversationID
            let context = calendarContext(of: id)
            if context.invitation != nil {
                calendarNotice(CalendarCopy.answerInvitation)
                return
            }
            guard let start = calendarState.blockStart(for: context, from: calendarState.today, dayIsShown: false) else {
                NSSound.beep()
                return
            }
            setAside(id, at: start)
        }
    }

    /// Where B looks for a free half hour: the day the column shows (in full, over the reader or as its strip), the week's
    /// first day while the week shows, today while the column is hidden (`CalendarState.blockStart` never starts before
    /// today). The week shows no one day, so its Saturday and Sunday are passed over as any other's.
    private var blockSearchStart: (day: Date, isShown: Bool) {
        let state = calendarState
        switch desk.placement {
        case .week: return (state.shownWeekDays.first ?? state.today, false)
        case .column, .strip: return (state.shownDay, true)
        case .none: return (state.today, false)
        }
    }

    /// What the calendar knows of `id`: the state's, once read for the selection, else read now (B pressed before the
    /// selection's read landed, or a reader window's conversation). An action, not a frame.
    private func calendarContext(of id: ConversationID) -> CalendarSelection {
        if let selection = calendarState.selection, selection.conversationID == id { return selection }
        return CalendarSelection.read(id, from: environment.store)
    }

    func blockTime(for conversation: ConversationID, at start: Date) {
        setAside(conversation, at: start)
    }

    func blockTimeFirstFree(for conversation: ConversationID, on day: Date) {
        calendarState.clock.tick()
        guard let start = calendarState.firstFreeHalfHour(on: day) else {
            calendarNotice(CalendarCopy.noFreeHalfHour(calendarState.text.shortDay(day, now: calendarState.now)))
            return
        }
        setAside(conversation, at: start)
    }

    /// Sets 30 minutes aside for `id` from `start`: stored first (`creating`) and drawn at once, sent by the engine. One
    /// step of the undo history, with its toast (“Blocked 15:00 - 15:30 · Undo”); the calendar turns to it.
    @discardableResult
    func setAside(_ id: ConversationID, at start: Date) -> Bool {
        let engine = environment.engine
        guard accountsByID[id.accountID] != nil, let event = CalendarBlock.event(for: id, at: start, store: environment.store) else {
            NSSound.beep()
            return false
        }
        do {
            try engine.addCalendarEvent(event)
        } catch {
            Self.log.error("setting time aside failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return false
        }
        let words = CalendarCopy.blocked(calendarState.text.toastSpan(event.start, event.end, now: calendarState.now))
        recordExternalUndo(command: CalendarCopy.blockCommand, accounts: [id.accountID], toast: words,
                           symbol: Quire.Icon.blockTime) { [weak self] in
            // A block already gone (removed in the provider's calendar, and dropped by a read) has nothing to take
            // back: the step goes with a beep, and the next ⌘Z reaches the one before (§6.1).
            let removed: CalendarEvent?
            do {
                removed = try engine.removeCalendarEvent(id: event.id)
            } catch {
                Self.log.error("undoing time set aside failed: \(String(describing: error), privacy: .public)")
                NSSound.beep()
                return
            }
            guard removed != nil else {
                NSSound.beep()
                return
            }
            self?.confirmUndo(of: CalendarCopy.blockCommand)
        }
        turnCalendar(to: start)
        return true
    }

    /// Remove, in the details of time set aside from this Mac: off the calendar at once and from the provider after; its
    /// toast's Undo sets it aside again where it was.
    func removeEvent(_ event: CalendarEvent) {
        let engine = environment.engine
        let removed: CalendarEvent?
        do {
            removed = try engine.removeCalendarEvent(id: event.id)
        } catch {
            Self.log.error("removing time set aside failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return
        }
        guard let asWas = removed else { return }
        let words = CalendarCopy.removed(calendarState.text.toastSpan(asWas.start, asWas.end, now: calendarState.now))
        recordExternalUndo(command: CalendarCopy.removeCommand, accounts: [asWas.accountID], toast: words,
                           symbol: Quire.Icon.blockTime) { [weak self] in
            do {
                _ = try engine.restoreCalendarEvent(asWas)
            } catch {
                Self.log.error("undoing a removal failed: \(String(describing: error), privacy: .public)")
                NSSound.beep()
                return
            }
            self?.confirmUndo(of: CalendarCopy.removeCommand)
        }
    }

    /// A notice with nothing to undo, where the step was asked (§5.30, Calendar notice): 2000 ms, no contrail.
    private func calendarNotice(_ words: String) {
        toasts.show(words, kind: .confirmation, symbol: Quire.Icon.dayColumn, in: stepToastHost)
    }

    // MARK: Links, mail, answers

    /// Join, Open in Google Calendar or Outlook: web addresses only, as the reader's invitation links (§5.14), and https;
    /// the setup guide's step from the foot, when the app bundles it.
    func openURL(_ url: URL) {
        if url.isFileURL {
            guard url == Bundle.main.url(forResource: "OAUTH-SETUP", withExtension: "md") else { return }
            openCalendarURL(url)
            return
        }
        guard let checked = CalendarText.link(url.absoluteString) else {
            NSSound.beep()
            return
        }
        openCalendarURL(checked)
    }

    /// Show the mail, in the details of time set aside for a mail: its conversation selected.
    func showMail(_ message: MessageID) {
        guard let id = (try? environment.store.message(message))?.conversationID else {
            NSSound.beep()
            return
        }
        showConversation(id)
    }

    /// A pencilled invitation, or Show the mail on a Later mark: that conversation selected.
    func selectConversation(_ id: ConversationID) {
        showConversation(id)
    }

    /// Selects `id` in the list, switching the list to a view that holds it when this one does not (as a notification's
    /// click does): its Inbox while any of it is there, Later while it is snoozed, else All Mail.
    func showConversation(_ id: ConversationID) {
        guard accountsByID[id.accountID] != nil else { return }
        if !list.conversations.contains(where: { $0.id == id }) {
            let messages = (try? environment.store.messages(in: id)) ?? []
            let view: MailboxView
            if messages.contains(where: \.isInInbox) {
                view = .inbox
            } else if snoozes.contains(where: { $0.conversationID == id }) {
                view = .later
            } else {
                view = .all
            }
            showView(view, unifying: !scopeIncludes(id.accountID))
        }
        list.selectedConversationID = id
        present(selection: [id])
    }

    /// Show the mail, in the details of a Send Later mark: its row in the Outbox.
    func showPendingSend(id: String) {
        guard let send = calendarState.pendingSends.first(where: { $0.id == id }) else { return }
        let row = SendLaterConversation.conversationID(sendID: id, account: send.accountID)
        if listView != .outbox { showView(.outbox, unifying: !scopeIncludes(send.accountID)) }
        list.selectedConversationID = row
        present(selection: [row])
    }

    /// Accept · Tentative · Decline on the week's invitation card: as on the reader's card (§5.14), no toast and no undo.
    func answerInvitation(_ response: InvitationResponse, for message: MessageID) {
        do {
            try environment.engine.answerInvitation(response, to: message)
        } catch {
            Self.log.error("answering an invitation failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }

    // MARK: Connect

    /// Connect, in the foot: each account lacking the calendar permission is asked in turn, through the sign-in Reconnect
    /// uses (its browser, its alerts); a refusal or a cancel ends the round, and Connect stays for another.
    func connect(accountIDs: [AccountID]) {
        guard calendarConnectQueue.isEmpty, pendingSignIn == nil else { return }
        calendarConnectQueue = accountIDs.compactMap { accountsByID[$0] }
        connectNextCalendar()
    }

    private func connectNextCalendar() {
        guard let account = calendarConnectQueue.first, let onConnectCalendar else {
            calendarConnectQueue = []
            calendarState.isConnecting = false
            return
        }
        calendarState.isConnecting = true
        onConnectCalendar(account) { [weak self] granted in
            guard let self else { return }
            if granted, !self.calendarConnectQueue.isEmpty {
                self.calendarConnectQueue.removeFirst()
            } else {
                self.calendarConnectQueue = []
            }
            self.connectNextCalendar()
        }
    }

    // MARK: Menu items (§5.35)

    /// View › Hide Day or Show Day (D).
    @objc func toggleDayColumn(_ sender: Any?) { toggleDay() }
    /// View › Show Week or Hide Week (W).
    @objc func toggleWeek(_ sender: Any?) { toggleWeekView() }
    /// View › Previous Day ([), Previous Week while the week shows.
    @objc func previousCalendarDay(_ sender: Any?) { _ = perform(.previousDay) }
    /// View › Next Day (]), Next Week while the week shows.
    @objc func nextCalendarDay(_ sender: Any?) { _ = perform(.nextDay) }
    /// View › Today (T), This Week while the week shows.
    @objc func calendarToday(_ sender: Any?) { _ = perform(.today) }
    /// Message › Block Time (B).
    @objc func blockTimeForSelection(_ sender: Any?) { _ = blockTimeForSelection() }

    /// Titles follow what shows; [ ] and T only while the column or the week shows; Block Time while one conversation is
    /// selected (§5.35).
    func validateCalendarItem(_ item: NSMenuItem) -> Bool {
        let week = desk.placement == .week
        switch item.action {
        case #selector(toggleDayColumn(_:)):
            item.title = desk.isDayShowing ? "Hide Day" : "Show Day"
            return true
        case #selector(toggleWeek(_:)):
            item.title = week ? "Hide Week" : "Show Week"
            return true
        case #selector(previousCalendarDay(_:)):
            item.title = week ? "Previous Week" : "Previous Day"
            return desk.isCalendarShowing
        case #selector(nextCalendarDay(_:)):
            item.title = week ? "Next Week" : "Next Day"
            return desk.isCalendarShowing
        case #selector(calendarToday(_:)):
            item.title = week ? "This Week" : "Today"
            return desk.isCalendarShowing
        case #selector(blockTimeForSelection(_:)):
            return !isSeveralSelected && list.selectedConversationID != nil
        default:
            return true
        }
    }
}

/// The calendar's toast words (spec §5.30): time set aside and removed, with the day as a row's time names it, and the
/// notices that have nothing to undo.
enum CalendarCopy {
    /// Edit › Undo's names for the steps (“Undo Block Time”), and their confirmations (“Undid Block Time”).
    static let blockCommand = "Block Time"
    static let removeCommand = "Remove Block"

    static let answerInvitation = "Answer the invitation to put it in your calendar"

    /// “Blocked 15:00 - 15:30”, “Blocked Fri 10:00 - 10:30”, “Blocked 26 Nov 13:30 - 14:00”.
    static func blocked(_ span: String) -> String { "Blocked " + span }

    static func removed(_ span: String) -> String { "Removed " + span }

    /// “No free half hour on Sat 21 Nov”.
    static func noFreeHalfHour(_ day: String) -> String { "No free half hour on " + day }
}
