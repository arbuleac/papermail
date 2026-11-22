import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// A calendar over a throwaway store, on a fixed clock and a fixed calendar (Monday weeks, 24-hour times, Berlin), so
/// every fit, word and mark is the same on every Mac: Thursday 19 November 2026, 11:40.
@MainActor
enum CalendarTestSupport {
    nonisolated static let accountA = ListTestSupport.accountA
    nonisolated static let accountB = ListTestSupport.accountB

    nonisolated static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Thursday 19 November 2026.
    nonisolated static let today = day(19)

    nonisolated static func day(_ day: Int, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    nonisolated static func at(_ hour: Int, _ minute: Int = 0, on day: Date = today) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// 11:40 on the 19th; tests move it through `Clock`.
    final class Clock: @unchecked Sendable {
        var now = CalendarTestSupport.at(11, 40)
    }

    static func store(accounts: [Account] = [accountA, accountB]) throws -> InMemoryMailStore {
        let store = InMemoryMailStore()
        for account in accounts { try store.upsertAccount(account) }
        return store
    }

    static func state(store: MailStoring, clock: Clock = Clock(),
                      observeStatus: CalendarState.StatusObserver? = nil) -> CalendarState {
        CalendarState(store: store, calendar: calendar, now: { clock.now }, observeStatus: observeStatus)
    }

    nonisolated static func event(_ id: String, account: Account = accountA, title: String, start: Date, end: Date,
                      response: CalendarEvent.Response = .accepted, isAllDay: Bool = false, isFree: Bool = false,
                      joinURL: String? = nil, location: String? = nil, invitationUID: String? = nil,
                      sourceMessage: MessageID? = nil, sync: CalendarEvent.Sync = .synced,
                      webURL: String? = nil) -> CalendarEvent {
        CalendarEvent(id: CalendarEvent.localID(accountID: account.id, providerID: id), accountID: account.id, providerID: id,
                      title: title, location: location, start: start, end: end, isAllDay: isAllDay, response: response,
                      isFree: isFree, joinURL: joinURL, webURL: webURL, invitationUID: invitationUID,
                      sourceMessage: sourceMessage, sync: sync)
    }

    /// Writes `events` as one read of each account's calendar for the weeks around the 19th.
    static func write(_ events: [CalendarEvent], to store: MailStoring) throws {
        let window = DateInterval(start: day(26, month: 10), end: day(31, month: 12))
        for account in [accountA, accountB] {
            try store.replaceCalendarEvents(events.filter { $0.accountID == account.id }, accountID: account.id, window: window)
        }
    }

    /// A working week: a stand-up every morning, a review on Thursday at 13:00, a long Friday, a call today.
    nonisolated static func sampleWeek() -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        for offset in 0..<5 {
            let date = day(16 + offset)
            events.append(event("standup-\(offset)", account: accountB, title: "Standup", start: at(9, 30, on: date),
                                end: at(9, 45, on: date), joinURL: "https://teams.microsoft.com/l/meetup/\(offset)"))
        }
        events.append(event("review", title: "Roadmap review", start: at(13), end: at(14), location: "Bay 4",
                            webURL: "https://calendar.google.com/event?eid=review"))
        events.append(event("hiring", account: accountB, title: "Hiring sync", start: at(13, 30), end: at(14, 30)))
        events.append(event("call", title: "Contract call with Fabrikam", start: at(12), end: at(12, 45),
                            joinURL: "https://meet.google.com/abc-defg-hij"))
        events.append(event("design", account: accountB, title: "Design critique", start: at(15), end: at(16),
                            response: .needsAction, invitationUID: "critique-uid"))
        events.append(event("drinks", account: accountB, title: "Team drinks", start: at(17, 30), end: at(19, 30),
                            response: .tentative))
        events.append(event("vendor", account: accountB, title: "Vendor demo", start: at(10), end: at(11), response: .declined))
        events.append(event("golive", account: accountB, title: "Contoso go-live", start: floating(19), end: floating(20),
                            isAllDay: true))
        events.append(event("dinner", title: "Birthday dinner", start: at(19, 0, on: day(20)), end: at(21, 30, on: day(20))))
        return events
    }

    /// An all-day date as the store holds it: its UTC midnight.
    nonisolated static func floating(_ day: Int, month: Int = 11) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    /// `view` in an off-screen window of `size`, laid out and drawn.
    static func host(_ view: NSView, size: NSSize, appearance: NSAppearance? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return window
    }

    /// Runs the main run loop until `condition` holds: the state's reads off the main thread land there.
    @discardableResult
    static func spin(until condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        ListTestSupport.spin(until: condition, timeout: timeout)
    }

    /// What `view` draws, as a bitmap.
    static func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// Writes `bitmap` to `PAPER_RENDER_DIR` when it is set, for a person to look at.
    static func writeIfAsked(_ bitmap: NSBitmapImageRep, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["PAPER_RENDER_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// A delegate that records what the views asked for.
@MainActor
final class RecordingCalendarDelegate: CalendarViewDelegate {
    var calls: [String] = []
    var blocked: [(ConversationID, Date)] = []
    var blockedFirstFree: [(ConversationID, Date)] = []
    var selectedConversations: [ConversationID] = []
    var selectedDays: [Date] = []
    var openedURLs: [URL] = []
    var removed: [CalendarEvent] = []
    var answers: [(InvitationResponse, MessageID)] = []
    var connected: [[AccountID]] = []

    func turnDay(by days: Int) { calls.append("turnDay(\(days))") }
    func goToToday() { calls.append("goToToday") }
    func selectDay(_ day: Date) { selectedDays.append(day); calls.append("selectDay") }
    func openWeekHeading(day: Date) { calls.append("openWeekHeading") }
    func selectConversation(_ id: ConversationID) { selectedConversations.append(id); calls.append("selectConversation") }
    func blockTime(for conversation: ConversationID, at start: Date) { blocked.append((conversation, start)); calls.append("blockTime") }
    func blockTimeFirstFree(for conversation: ConversationID, on day: Date) {
        blockedFirstFree.append((conversation, day))
        calls.append("blockTimeFirstFree")
    }
    func removeEvent(_ event: CalendarEvent) { removed.append(event); calls.append("removeEvent") }
    func openURL(_ url: URL) { openedURLs.append(url); calls.append("openURL") }
    func showMail(_ message: MessageID) { calls.append("showMail") }
    func showPendingSend(id: String) { calls.append("showPendingSend") }
    func connect(accountIDs: [AccountID]) { connected.append(accountIDs); calls.append("connect") }
    func answerInvitation(_ response: InvitationResponse, for message: MessageID) {
        answers.append((response, message))
        calls.append("answerInvitation")
    }
    func openStrip() { calls.append("openStrip") }
    func toggleDayColumn() { calls.append("toggleDayColumn") }
    func toggleWeek() { calls.append("toggleWeek") }
}
