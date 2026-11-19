import AppKit
import os
import SSCore
import SSDesign

/// Everything the day column, its strip and the week draw, read from the store and kept current (spec §5.54): each
/// account's events for the days around the shown ones, what is snoozed (Later) or waits to be sent (Send Later), the
/// selected conversation's invitation and the times its mail names, each account's calendar state, and now.
///
/// The shell sets the inputs (the shown day and week, the span, the scope, the accounts, the selection) and the views
/// observe it. The only reads on the main thread are the store's events for the shown range, delivered by its
/// observation; the selection's invitations and mail times, and Later's subjects, are read on a utility queue, so
/// following J and K costs a refit at most (the 16 ms budget), and opening the column or the week a range read and a fit
/// (50 ms). While no calendar shows the shell selects nothing, so J and K cost the calendar nothing at all.
@MainActor
final class CalendarState {
    typealias StatusObserver = (@escaping @Sendable ([AccountSyncStatus]) -> Void) -> StoreObservation

    let store: MailStoring
    private(set) var calendar: Calendar
    private(set) var text: CalendarText
    let clock: CalendarClock

    /// Now, as the clock last read it: the now line, “Today”, which mail times are still ahead.
    var now: Date { clock.now }

    // MARK: Inputs the shell sets

    /// The day the column (and its strip) shows; any instant of it.
    var shownDay: Date {
        didSet {
            // Setting it again here calls no observer: the day's first instant is what is kept.
            let day = calendar.startOfDay(for: shownDay)
            if day != shownDay { shownDay = day }
            guard oldValue != shownDay else { return }
            shownDidChange()
        }
    }

    /// Any day of the week the week view shows. Turning the week never moves the column's day (spec §5.54).
    var shownWeek: Date {
        didSet {
            let day = calendar.startOfDay(for: shownWeek)
            if day != shownWeek { shownWeek = day }
            guard oldValue != shownWeek else { return }
            shownDidChange()
        }
    }

    var span: CalendarSpan = .day {
        didSet { if oldValue != span { shownDidChange() } }
    }

    var scope: CalendarScope = .all {
        didSet { if oldValue != scope { contentDidChange() } }
    }

    /// The accounts, in the rail's order: their inks and names.
    var accounts: [Account] = [] {
        didSet {
            guard oldValue != accounts else { return }
            accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            contentDidChange()
            notify(.statuses)
        }
    }

    /// The window's key state for the margin rule (`selRule`, `selRuleIdle` while not key, §3.4); nil follows each
    /// view's window.
    var isWindowKey: Bool? {
        didSet { if oldValue != isWindowKey { notify(.windowKey) } }
    }

    /// Connect is asking an account for the calendar permission: its button shows its loading state.
    var isConnecting = false {
        didSet { if oldValue != isConnecting { notify(.statuses) } }
    }

    // MARK: What the store holds

    /// Every account's events overlapping `observedRange`, as the store lists them (declined and deleting included).
    private(set) var events: [CalendarEvent] = []
    /// The interval `events` covers: the shown days' week with a week either side, so [ and ] turn without a read.
    private(set) var observedRange: DateInterval?
    private(set) var snoozes: [Snooze] = []
    private(set) var pendingSends: [PendingSendSummary] = []
    /// The subjects of the conversations snoozed into the observed range, read off the main thread.
    private(set) var laterSubjects: [ConversationID: String] = [:]
    private(set) var calendarStates: [AccountID: CalendarSyncState] = [:]
    private(set) var accountsByID: [AccountID: Account] = [:]

    /// The conversation the list has selected, and what the calendar knows of it once read.
    private(set) var selectedConversation: ConversationID?
    private(set) var selection: CalendarSelection?

    /// Bumped whenever what any view draws may have changed.
    private(set) var contentVersion = 0

    private var eventObservation: StoreObservation?
    private var eventGeneration = 0
    private var snoozeObservation: StoreObservation?
    private var sendObservation: StoreObservation?
    private var statusObservation: StoreObservation?
    private var conversationObservation: StoreObservation?
    private var selectionGeneration = 0
    private var subjectGeneration = 0
    private var observers: [WeakObserver] = []
    private var cache: [[Date]: CalendarContent] = [:]
    private var systemObservers: [NSObjectProtocol] = []
    private let reader = DispatchQueue(label: "io.supersparrow.calendar.reads", qos: .userInitiated)
    /// The selection read wanted last: a read queued behind it on `reader` is skipped, never run for nothing.
    private let latestSelectionRead = OSAllocatedUnfairLock(initialState: 0)
    /// What the selection's read used of its messages when it was last read: a write that changes none of it (a star,
    /// a mark, any message of any other conversation) reads nothing again.
    private var observedInputs: [SelectionInputs]?
    /// Today as the shown days last knew it: at midnight, what showed it moves on to the new today.
    private var lastToday: Date

    /// - Parameters:
    ///   - observeStatus: the engine's account statuses (`MailClient.observeStatus`), for the foot's Connect.
    ///   - now: where the clock reads now; tests move it.
    init(store: MailStoring, calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init,
         observeStatus: StatusObserver? = nil) {
        self.store = store
        self.calendar = calendar
        text = CalendarText(calendar: calendar)
        clock = CalendarClock(calendar: calendar, source: now)
        let today = calendar.startOfDay(for: clock.now)
        shownDay = today
        shownWeek = today
        lastToday = today
        accounts = (try? store.accounts()) ?? []
        accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        clock.onTick = { [weak self] dayChanged in self?.clockDidTick(dayChanged: dayChanged) }
        observeRange()
        snoozeObservation = store.observeSnoozes { [weak self] snoozes in
            MainActor.assumeIsolated { self?.snoozesChanged(snoozes) }
        }
        sendObservation = store.observePendingSends { [weak self] sends in
            MainActor.assumeIsolated { self?.sendsChanged(sends) }
        }
        if let observeStatus {
            statusObservation = observeStatus { [weak self] statuses in
                MainActor.assumeIsolated { self?.statusesChanged(statuses) }
            }
        }
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            systemObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemCalendarDidChange() }
            })
        }
    }

    /// The state over the engine's store and its statuses.
    convenience init(client: MailClient, calendar: Calendar = .autoupdatingCurrent) {
        self.init(store: client.store, calendar: calendar, observeStatus: { [weak client] onChange in
            client?.observeStatus(onChange: onChange) ?? StoreObservation {}
        })
    }

    /// Stops every observation and the clock; the window calls it when it closes.
    func tearDown() {
        for observation in [eventObservation, snoozeObservation, sendObservation, statusObservation, conversationObservation] {
            observation?.cancel()
        }
        eventObservation = nil
        snoozeObservation = nil
        sendObservation = nil
        statusObservation = nil
        conversationObservation = nil
        clock.invalidate()
        for observer in systemObservers { NotificationCenter.default.removeObserver(observer) }
        systemObservers.removeAll()
        observers.removeAll()
    }

    // MARK: Observers

    /// `first` puts the observer ahead of the others: the window, which turns the shown day as a selection's context lands,
    /// so the views refit once for the new day rather than first for the old one.
    func addObserver(_ observer: CalendarStateObserver, first: Bool = false) {
        observers.removeAll { $0.value == nil || $0.value === observer }
        if first {
            observers.insert(WeakObserver(value: observer), at: 0)
        } else {
            observers.append(WeakObserver(value: observer))
        }
    }

    func removeObserver(_ observer: CalendarStateObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
    }

    private func notify(_ change: CalendarChange) {
        for observer in observers {
            observer.value?.calendarState(self, didChange: change)
        }
    }

    private func contentDidChange(also change: CalendarChange = []) {
        contentVersion += 1
        cache.removeAll(keepingCapacity: true)
        notify(change.union(.content))
    }

    // MARK: Days

    /// The seven days of the week `shownDay` is in: the column's day cells.
    var shownDayWeek: [Date] { text.week(containing: shownDay) }

    /// The seven days the week view shows.
    var shownWeekDays: [Date] { text.week(containing: shownWeek) }

    var today: Date { calendar.startOfDay(for: now) }

    private func shownDidChange() {
        observeRange()
        notify(.shown)
    }

    /// The days the span shows: the column's week (its day cells) or the week view's.
    var shownRange: DateInterval {
        let days = span == .day ? shownDayWeek : shownWeekDays
        let start = days.first ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: days.last ?? start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// The days the engine keeps every calendar read for (`CalendarWindow`): two weeks back to eight ahead of today.
    var keptWindow: DateInterval { CalendarWindow.around(now, calendar: calendar) }

    /// The shown days, when some lie outside `keptWindow`: what the shell asks the engine to read once
    /// (`MailClient.refreshCalendars(accountID:covering:)`), the store's copies showing meanwhile.
    var shownRangeOutsideWindow: DateInterval? {
        let range = shownRange, window = keptWindow
        return range.start < window.start || range.end > window.end ? range : nil
    }

    /// Re-subscribes when the needed days leave what is observed, to their week with a week either side: [ and ] then
    /// turn within the range, and each turn costs no read. The store delivers the current value at once.
    private func observeRange() {
        let needed = shownRange
        if let observedRange, observedRange.start <= needed.start, observedRange.end >= needed.end { return }
        let start = calendar.date(byAdding: .day, value: -7, to: needed.start) ?? needed.start
        let end = calendar.date(byAdding: .day, value: 7, to: needed.end) ?? needed.end
        let range = DateInterval(start: start, end: end)
        eventObservation?.cancel()
        eventGeneration += 1
        let generation = eventGeneration
        observedRange = range
        eventObservation = store.observeCalendarEvents(in: range) { [weak self] events in
            MainActor.assumeIsolated {
                guard let self, self.eventGeneration == generation else { return }
                self.eventsChanged(events)
            }
        }
        readLaterSubjects()
    }

    private func eventsChanged(_ events: [CalendarEvent]) {
        guard events != self.events else { return }
        self.events = events
        contentDidChange()
    }

    // MARK: Later and Send Later

    private func snoozesChanged(_ snoozes: [Snooze]) {
        guard snoozes != self.snoozes else { return }
        self.snoozes = snoozes
        readLaterSubjects()
        contentDidChange()
    }

    private func sendsChanged(_ sends: [PendingSendSummary]) {
        let held = sends.filter { $0.status == .later }
        guard held != pendingSends else { return }
        pendingSends = held
        contentDidChange()
    }

    /// The subjects of the conversations coming back inside the observed range, read off the main thread (a snooze
    /// names only its conversation).
    private func readLaterSubjects() {
        guard let range = observedRange else { return }
        let missing = snoozes.filter { range.contains($0.dueAt) && laterSubjects[$0.conversationID] == nil }
            .map(\.conversationID)
        guard !missing.isEmpty else { return }
        subjectGeneration += 1
        let generation = subjectGeneration
        let store = self.store
        reader.async { [weak self] in
            var subjects: [ConversationID: String] = [:]
            for id in missing {
                let messages = (try? store.messages(in: id)) ?? []
                subjects[id] = messages.max { $0.date < $1.date }?.subject ?? ""
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.subjectGeneration == generation else { return }
                    self.laterSubjects.merge(subjects) { _, new in new }
                    self.contentDidChange()
                }
            }
        }
    }

    // MARK: Statuses

    private func statusesChanged(_ statuses: [AccountSyncStatus]) {
        let states = Dictionary(statuses.map { ($0.accountID, Self.withoutDates($0.calendar)) }, uniquingKeysWith: { _, last in last })
        guard states != calendarStates else { return }
        calendarStates = states
        notify(.statuses)
    }

    /// A state with its dates dropped: every read publishes `.current` at a new instant, once a minute per account,
    /// and nothing drawn tells one instant from another, so no view relays out or refits for it.
    private static func withoutDates(_ state: CalendarSyncState) -> CalendarSyncState {
        switch state {
        case .current: return .current(.distantPast)
        case .failing: return .failing(lastRead: nil)
        case .unknown, .notConnected, .apiDisabled: return state
        }
    }

    /// The scope's accounts that have not granted the calendar permission: the foot offers Connect.
    var accountsToConnect: [AccountID] {
        accounts.filter { scope.includes($0.id) && calendarStates[$0.id] == .notConnected }.map(\.id)
    }

    /// The scope's Google accounts whose OAuth client has the Calendar API turned off.
    var accountsWithCalendarAPIOff: [AccountID] {
        accounts.filter { scope.includes($0.id) && calendarStates[$0.id] == .apiDisabled }.map(\.id)
    }

    // MARK: Inks and names

    func ink(for accountID: AccountID) -> NSColor {
        .qAccount(accountsByID[accountID]?.inkSlot ?? 0)
    }

    func accountName(_ accountID: AccountID) -> String {
        accountsByID[accountID].map(AccountLabels.name(for:)) ?? ""
    }

    func providerKind(_ accountID: AccountID) -> ProviderKind? {
        accountsByID[accountID]?.kind
    }

    // MARK: Selection

    /// The list's selection moved (nil for none or several). What the calendar draws of it is read off the main thread;
    /// until then nothing of the previous one stays drawn. `readNow` reads it at once instead: a calendar coming on
    /// screen, which then shows the selection's day in its first frame rather than turning a moment later.
    func select(_ conversation: ConversationID?, readNow: Bool = false) {
        guard conversation != selectedConversation else { return }
        selectedConversation = conversation
        let previous = selection
        selection = nil
        conversationObservation?.cancel()
        conversationObservation = nil
        observedInputs = nil
        // A read still on its way is for the previous selection.
        selectionGeneration += 1
        let generation = selectionGeneration
        latestSelectionRead.withLock { $0 = generation }
        if let conversation, readNow { selection = CalendarSelection.read(conversation, from: store) }
        if drawsSomething(previous) || drawsSomething(selection) { contentDidChange(also: .selection) } else { notify(.selection) }
        guard let conversation else { return }
        if !readNow { readSelection(conversation) }
        // An answer given in the reader, or a message arriving, changes what is drawn: read again, but only when a
        // message, its date, subject, draft role or answer changed. The store reports every write to the messages
        // table, whichever account or conversation it touched; the first value, delivered as the observation starts,
        // only says where it starts from.
        conversationObservation = store.observeConversation(conversation) { [weak self] messages in
            MainActor.assumeIsolated {
                guard let self, self.selectedConversation == conversation else { return }
                let inputs = messages.map(SelectionInputs.init)
                defer { self.observedInputs = inputs }
                guard let previous = self.observedInputs, previous != inputs else { return }
                self.readSelection(conversation)
            }
        }
    }

    /// What `CalendarSelection.read` uses of a message: its invitation and mail times come with its body, which
    /// `reloadSelection` follows.
    private struct SelectionInputs: Equatable {
        var id: MessageID
        var date: Date
        var subject: String
        var isDraft: Bool
        var invitationReply: InvitationResponse?

        init(_ message: MessageMetadata) {
            id = message.id
            date = message.date
            subject = message.subject
            isDraft = message.roles.contains(.drafts)
            invitationReply = message.invitationReply
        }
    }

    /// Reads the selection's context again: its mail times were saved after it was selected, say.
    func reloadSelection() {
        guard let selectedConversation else { return }
        readSelection(selectedConversation)
    }

    private func readSelection(_ conversation: ConversationID) {
        selectionGeneration += 1
        let generation = selectionGeneration
        let latest = latestSelectionRead
        latest.withLock { $0 = generation }
        let store = self.store
        reader.async { [weak self] in
            // J held down queues a read per row; only the last is wanted.
            guard latest.withLock({ $0 }) == generation else { return }
            let read = CalendarSelection.read(conversation, from: store)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.selectionGeneration == generation, self.selectedConversation == conversation else { return }
                    let previous = self.selection
                    guard previous != read else { return }
                    self.selection = read
                    if self.drawsSomething(previous) || self.drawsSomething(read) {
                        self.contentDidChange(also: .selection)
                    } else {
                        self.notify(.selection)
                    }
                }
            }
        }
    }

    /// Whether a selection puts anything on the calendar: an invitation, a time, or time set aside for it.
    private func drawsSomething(_ selection: CalendarSelection?) -> Bool {
        guard let selection else { return false }
        if selection.invitation != nil || !selection.mailTimes.isEmpty { return true }
        return events.contains { $0.sourceMessage.map(selection.messageIDs.contains) == true }
    }

    /// The selection's invitation drawn from its mail, as the fit lays it out.
    var selectionPencil: CalendarEvent? {
        guard let selection, let invitation = selection.invitation, let message = selection.invitationMessage else { return nil }
        return CalendarFit.pencil(for: invitation, message: message, timeZone: calendar.timeZone, response: selection.response)
    }

    /// The selection's invitation and what it overlaps, as the card counts it (every account, §5.14).
    var selectionOverlap: CalendarFit.InvitationOverlap? {
        guard let invitation = selection?.invitation else { return nil }
        let pencil = selectionPencil
        return CalendarFit.invitationOverlap(uid: invitation.uid, near: pencil?.start, in: events, pencil: pencil)
    }

    /// The day the selection is about, which J and K turn the column to (spec §5.54, “It follows the mail”): its
    /// invitation's, else the first time its mail names that is still ahead. Nil leaves the column where it is.
    var selectionDay: Date? {
        if let pencil = selectionPencil, !pencil.isAllDay { return calendar.startOfDay(for: pencil.start) }
        if let pencil = selectionPencil {
            var utc = calendar
            utc.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
            let parts = utc.dateComponents([.year, .month, .day], from: pencil.start)
            return calendar.date(from: parts).map { calendar.startOfDay(for: $0) }
        }
        if let time = selection?.mailTimes.first(where: { $0.start > now }) { return calendar.startOfDay(for: time.start) }
        return nil
    }

    // MARK: Content

    /// What a view of `days` draws (each a day's first instant), built once per change and shared by the views that
    /// show the same days.
    func content(for days: [Date]) -> CalendarContent {
        if let cached = cache[days], cached.version == contentVersion { return cached }
        let built = buildContent(for: days)
        if cache.count > 4 { cache.removeAll(keepingCapacity: true) }
        cache[days] = built
        return built
    }

    private func buildContent(for days: [Date]) -> CalendarContent {
        guard let first = days.first, let last = days.last else { return .empty }
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        let interval = DateInterval(start: first, end: max(first, end))
        // A day either side, for all-day events held at UTC midnight (floating): the fit matches them by date.
        let wide = DateInterval(start: first.addingTimeInterval(-86_400), end: interval.end.addingTimeInterval(86_400))
        var shown = events.filter { $0.isShown && scope.includes($0.accountID) && $0.overlaps(wide) }

        var selected: Set<String> = []
        var hatches: [String: [DateInterval]] = [:]
        var overlapTitles: [String: [String]] = [:]
        var pencilID: String?
        var marks: [CalendarMark] = []

        if let selection, scope.includes(selection.conversationID.accountID) {
            let mine = shown.filter { $0.sourceMessage.map(selection.messageIDs.contains) == true }
            selected.formUnion(mine.map(\.id))
            if let overlap = selectionOverlap {
                let event = overlap.event
                if CalendarFit.isPencil(event) {
                    if event.isShown, event.overlaps(wide) {
                        shown.append(event)
                        pencilID = event.id
                    }
                }
                if event.isShown {
                    selected.insert(event.id)
                    if !overlap.overlaps.isEmpty {
                        hatches[event.id] = overlap.overlaps.map(\.interval)
                        overlapTitles[event.id] = overlap.overlaps.map(\.event.title)
                    }
                }
            }
            // The times the mail names, until time is set aside there.
            let setAside = Set(mine.map(\.start))
            var seen: Set<Date> = []
            for time in selection.mailTimes where time.start > now && interval.contains(time.start)
                && !setAside.contains(time.start) && seen.insert(time.start).inserted {
                let id = "mail|\(time.messageID.providerID)|\(Int(time.start.timeIntervalSince1970))"
                marks.append(CalendarMark(id: id, kind: .mailTime(selection.conversationID, time.messageID), start: time.start,
                                          span: max(60, time.duration ?? Self.blockLength), title: time.phrase))
            }
        }
        for snooze in snoozes where interval.contains(snooze.dueAt) && scope.includes(snooze.conversationID.accountID) {
            let id = snooze.conversationID
            marks.append(CalendarMark(id: "later|\(id.accountID.rawValue)|\(id.providerID)", kind: .later(id), start: snooze.dueAt,
                                      span: 60, title: laterSubjects[id] ?? ""))
        }
        for send in pendingSends where interval.contains(send.sendAfter) && scope.includes(send.accountID) {
            marks.append(CalendarMark(id: "send|\(send.id)", kind: .sendLater(id: send.id, accountID: send.accountID),
                                      start: send.sendAfter, span: 60, title: send.subject))
        }
        return CalendarContent(days: days, events: shown, marks: marks, selectedEventIDs: selected, hatches: hatches,
                               overlapTitles: overlapTitles, pencilID: pencilID, version: contentVersion)
    }

    /// Time set aside is 30 minutes (`calendarPane.blockMinutes`).
    nonisolated static let blockLength = TimeInterval(Quire.Layout.CalendarPane.blockMinutes) * 60

    // MARK: Now

    private func clockDidTick(dayChanged: Bool) {
        if dayChanged {
            turnToToday()
            contentDidChange(also: .day)
            return
        }
        // A time the mail names that has just passed leaves the calendar.
        if let selection, selection.mailTimes.contains(where: { $0.start <= now && $0.start > now.addingTimeInterval(-Quire.Motion.nowTick * 2) }) {
            contentDidChange(also: .now)
            return
        }
        notify(.now)
    }

    /// Midnight passed (spec §5.54, Now): a column that showed today shows the new today, and a week that showed this
    /// week shows the new today's, as a page-a-day calendar turns; a day or a week the user turned to stays where it is.
    private func turnToToday() {
        let old = lastToday
        lastToday = today
        guard old != lastToday else { return }
        if shownDay == old { shownDay = lastToday }
        if text.week(containing: shownWeek) == text.week(containing: old) { shownWeek = lastToday }
    }

    private func systemCalendarDidChange() {
        var updated = Calendar.autoupdatingCurrent
        updated.locale = calendar.locale ?? .autoupdatingCurrent
        calendar = updated
        text = CalendarText(calendar: updated)
        clock.setCalendar(updated)
        contentDidChange(also: .day)
    }
}

/// An observer held weakly, so a view that goes away leaves the state.
private struct WeakObserver {
    weak var value: CalendarStateObserver?
}
