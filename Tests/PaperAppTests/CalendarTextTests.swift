import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// The calendar's words (spec §5.54, §4.13), and where time set aside goes (B, a row dropped on a day cell).
@MainActor
final class CalendarTextTests: XCTestCase {
    private typealias Support = CalendarTestSupport

    private let text = CalendarText(calendar: CalendarTestSupport.calendar)
    private let now = CalendarTestSupport.at(11, 40)

    func testTheKickerSaysWhereTheDayIsFromToday() {
        XCTAssertEqual(text.kicker(for: Support.today, now: now), "Today")
        XCTAssertEqual(text.kicker(for: Support.day(20), now: now), "Tomorrow")
        XCTAssertEqual(text.kicker(for: Support.day(18), now: now), "Yesterday")
        XCTAssertEqual(text.kicker(for: Support.day(16), now: now), "Earlier this week")
        XCTAssertEqual(text.kicker(for: Support.day(22), now: now), "Later this week")
        XCTAssertEqual(text.kicker(for: Support.day(24), now: now), "Next week")
        XCTAssertEqual(text.kicker(for: Support.day(10), now: now), "Last week")
        XCTAssertEqual(text.kicker(for: Support.day(8, month: 12), now: now), "In 3 weeks")
        XCTAssertEqual(text.kicker(for: Support.day(5), now: now), "2 weeks ago")
        XCTAssertEqual(text.weekKicker(for: Support.day(16), now: now), "This week")
        XCTAssertEqual(text.weekKicker(for: Support.day(30), now: now), "In 2 weeks")
    }

    func testHeadlinesAndTimes() {
        XCTAssertEqual(text.headline(Support.today, now: now), "Thursday 19 Nov")
        let nextYear = text.headline(Support.calendar.date(byAdding: .year, value: 1, to: Support.today)!, now: now)
        XCTAssertTrue(nextYear.hasPrefix("Friday") && nextYear.hasSuffix("19 Nov 2027"), "the year outside this one: \(nextYear)")
        XCTAssertEqual(text.weekHeadline(text.week(containing: Support.today), now: now), "16 - 22 November")
        XCTAssertEqual(text.weekHeadline(text.week(containing: Support.day(1, month: 12)), now: now), "30 November - 6 December")
        XCTAssertEqual(text.range(Support.at(13), Support.at(14)), "13:00 - 14:00", "spaced hyphen, never a long dash")
        XCTAssertEqual(text.spokenRange(Support.at(13), Support.at(14)), "13:00 to 14:00")
        XCTAssertEqual(text.hourLabel(9, on: Support.today), "09:00")
        XCTAssertEqual(text.foldLabel(from: 0, to: 8, on: Support.today), "00:00 - 08:00")
        XCTAssertEqual(text.spokenFold(from: 0, to: 8, on: Support.today), "Nothing from 00:00 to 08:00")
        XCTAssertEqual(text.ghost(Support.at(13, 30), Support.at(14)), "Thu 13:30 - 14:00")
        XCTAssertEqual(text.week(containing: Support.today).map { text.weekday($0) }, ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
    }

    func testTwelveHourClocksSayAMAndPM() {
        var calendar = Support.calendar
        calendar.locale = Locale(identifier: "en_US")
        let us = CalendarText(calendar: calendar)
        XCTAssertTrue(us.usesTwelveHours)
        // The locale's own space before AM (a narrow no-break space in recent ones).
        XCTAssertEqual(us.hourLabel(9, on: Support.today).replacingOccurrences(of: "\u{202F}", with: " "), "9 AM")
        XCTAssertTrue(us.range(Support.at(13), Support.at(14)).contains("PM"))
    }

    func testWhenAnEventIsReadsAsTheInvitationCardWritesIt() {
        let timed = Support.event("t", title: "T", start: Support.at(13), end: Support.at(14))
        XCTAssertEqual(text.when(timed, now: now), "Thu 19 Nov · 13:00 - 14:00")
        let allDay = Support.event("a", title: "A", start: Support.floating(19), end: Support.floating(20), isAllDay: true)
        XCTAssertEqual(text.when(allDay, now: now), "Thu 19 Nov · All day")
        let days = Support.event("d", title: "D", start: Support.floating(17), end: Support.floating(20), isAllDay: true)
        XCTAssertEqual(text.when(days, now: now), "Tue 17 Nov - Thu 19 Nov · All day")
        let late = Support.event("l", title: "L", start: Support.at(22), end: Support.at(2, on: Support.day(20)))
        XCTAssertEqual(text.when(late, now: now), "Thu 19 Nov, 22:00 - Fri 20 Nov, 02:00")
        XCTAssertEqual(CalendarText.serviceName(of: "https://meet.google.com/abc"), "Google Meet")
        XCTAssertEqual(CalendarText.serviceName(of: "https://teams.microsoft.com/l/x"), "Teams")
        XCTAssertEqual(CalendarText.serviceName(of: "https://contoso.zoom.us/j/1"), "Zoom")
        XCTAssertEqual(CalendarText.serviceName(of: "https://example.com/call"), "Video call")
    }

    /// The provider's word for the call wins over the address's host; each service has its words.
    func testTheStatedServiceNamesTheCall() {
        XCTAssertEqual(CalendarText.serviceName(of: "https://example.com/call", stated: .teams), "Teams")
        XCTAssertEqual(CalendarText.serviceName(of: "https://meet.google.com/abc", stated: .other), "Video call")
        XCTAssertEqual(CallService.allCases.map(CalendarText.serviceName),
                       ["Google Meet", "Teams", "Zoom", "Webex", "Skype", "Video call"])
    }

    // MARK: Setting time aside

    func testABlockIsThirtyMinutesTitledWithTheSubject() throws {
        let store = try Support.store()
        let conversation = ConversationID(accountID: Support.accountB.id, providerID: "t")
        let message = MessageID(accountID: Support.accountB.id, providerID: "m")
        try store.upsertMessages([MessageMetadata(id: message, conversationID: conversation, subject: "  ", snippet: "", from: nil,
                                                  date: Support.at(8), roles: [.inbox], isRead: true, isStarred: false,
                                                  hasAttachments: false)])
        let block = try XCTUnwrap(CalendarBlock.event(for: conversation, at: Support.at(15), store: store))
        XCTAssertEqual(block.title, "No subject")
        XCTAssertEqual(block.accountID, Support.accountB.id, "in the calendar of the mail's account")
        XCTAssertEqual(block.end.timeIntervalSince(block.start), 30 * 60)
        XCTAssertEqual(block.sourceMessage, message)
        XCTAssertEqual(block.sync, .creating)
        XCTAssertNotNil(block.clientKey)
        XCTAssertFalse(block.isFree)
        XCTAssertNil(CalendarBlock.event(for: ConversationID(accountID: Support.accountB.id, providerID: "none"), at: Support.at(15),
                                         store: store))
    }

    func testBUsesTheMailsTimeElseTheFirstFreeHalfHour() throws {
        let store = try Support.store()
        try Support.write([Support.event("busy", title: "Busy", start: Support.at(11, 30), end: Support.at(13, 10)),
                           Support.event("free", title: "Free", start: Support.at(13, 15), end: Support.at(15), isFree: true)], to: store)
        let conversation = ConversationID(accountID: Support.accountA.id, providerID: "t")
        let message = MessageID(accountID: Support.accountA.id, providerID: "m")
        try store.upsertMessages([MessageMetadata(id: message, conversationID: conversation, subject: "Lease", snippet: "", from: nil,
                                                  date: Support.at(8), roles: [.inbox], isRead: true, isStarred: false,
                                                  hasAttachments: false)])
        let state = Support.state(store: store)
        defer { state.tearDown() }
        XCTAssertNil(state.blockStart(from: Support.today, dayIsShown: true), "nothing selected")
        state.select(conversation)
        XCTAssertTrue(Support.spin(until: { state.selection != nil }))
        XCTAssertEqual(state.blockStart(from: Support.today, dayIsShown: true), Support.at(13, 15),
                       "after 11:40 the first free half hour on the quarter hour; free time is not busy")
        XCTAssertEqual(state.blockStart(from: Support.day(21), dayIsShown: false), Support.at(9, on: Support.day(23)),
                       "a Saturday not shown is passed over")
        XCTAssertEqual(state.blockStart(from: Support.day(21), dayIsShown: true), Support.at(9, on: Support.day(21)))
        XCTAssertEqual(state.firstFreeHalfHour(on: Support.day(20)), Support.at(9, on: Support.day(20)))

        try store.saveMailTimes([MailTime(messageID: message, start: Support.at(16, on: Support.day(24)), phrase: "Tuesday at 4")],
                                for: message)
        state.reloadSelection()
        XCTAssertTrue(Support.spin(until: { state.selection?.mailTimes.isEmpty == false }))
        XCTAssertEqual(state.blockStart(from: Support.today, dayIsShown: true), Support.at(16, on: Support.day(24)),
                       "the time the mail names wins")
    }
}
