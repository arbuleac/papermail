import Foundation
import XCTest
@testable import SSCore

/// The demo's calendars (`DemoCalendar`, served by `DemoMailProvider` as a `CalendarProvider`) and its mail that names a
/// time: what demo mode and its snapshots show in the day column and the week.
final class DemoCalendarTests: XCTestCase {
    private let reference = Date()
    private let gmail = Account(id: AccountID("demo-gmail"), kind: .gmail, email: DemoProfile.gmail.email,
                                displayName: "Alex Morgan", addedAt: Date())
    private let outlook = Account(id: AccountID("demo-outlook"), kind: .microsoft, email: DemoProfile.outlook.email,
                                  displayName: "Alex Morgan", addedAt: Date())
    private var calendar: Calendar { DemoCalendar.macCalendar }

    private func service() -> DemoMailService {
        DemoMailService(reference: reference, liveInterval: 3_600)
    }

    private func calendarProvider(_ account: Account, in service: DemoMailService) throws -> CalendarProvider {
        try XCTUnwrap(service.provider(for: account) as? CalendarProvider, "the demo provider reads a calendar")
    }

    private func events(_ account: Account, in service: DemoMailService? = nil) async throws -> [CalendarEvent] {
        let provider = try calendarProvider(account, in: service ?? self.service())
        return try await provider.calendarEvents(in: CalendarWindow.around(reference, calendar: calendar)).events
    }

    private func day(_ offset: Int) -> DateInterval {
        let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: reference))!
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    // MARK: Reads

    func testEachDemoAccountReadsACalendarAroundToday() async throws {
        let service = service()
        let window = CalendarWindow.around(reference, calendar: calendar)
        for account in [gmail, outlook] {
            let provider = try calendarProvider(account, in: service)
            let hasPermission = await provider.hasCalendarPermission()
            XCTAssertTrue(hasPermission, "the demo needs no Connect")
            let listing = try await provider.calendarEvents(in: window)
            XCTAssertEqual(listing.requestCount, 1)
            let events = listing.events
            XCTAssertGreaterThan(events.count, 10, account.email)
            XCTAssertTrue(events.allSatisfy { $0.overlaps(window) && $0.sync == .synced && $0.accountID == account.id })
            XCTAssertTrue(events.allSatisfy { $0.id == CalendarEvent.localID(accountID: account.id, providerID: $0.providerID ?? "") })
            XCTAssertEqual(Set(events.map(\.id)).count, events.count, "one id per event")
            XCTAssertEqual(events.map(\.start), events.map(\.start).sorted())
            XCTAssertTrue(events.allSatisfy { $0.webURL?.contains(".test/") == true }, "every link goes nowhere real")

            // A narrower window reads only what overlaps it.
            let today = day(0)
            let todays = try await provider.calendarEvents(in: today).events
            XCTAssertEqual(todays.map(\.id), events.filter { $0.overlaps(today) }.map(\.id))
        }
    }

    func testTheWorkCalendarHasAStandupEachWeekdayAndAFullWeek() async throws {
        let events = try await events(outlook)
        let window = CalendarWindow.around(reference, calendar: calendar)
        let standups = events.filter { $0.title == "Standup" }
        var weekdays = 0
        var offset = -CalendarWindow.daysBack
        while day(offset).start < window.end {
            let interval = day(offset)
            let standup = standups.filter { interval.contains($0.start) }
            if calendar.isDateInWeekend(interval.start) {
                XCTAssertTrue(standup.isEmpty, "no standup at the weekend")
            } else {
                weekdays += 1
                XCTAssertEqual(standup.count, 1)
                XCTAssertEqual(standup.first.map { calendar.component(.hour, from: $0.start) }, 9)
                XCTAssertNotNil(standup.first?.joinURL)
            }
            offset += 1
        }
        XCTAssertEqual(standups.count, weekdays)

        // Every working day this week has more than its standup.
        for offset in 0..<7 where !calendar.isDateInWeekend(day(offset).start) {
            let shown = events.filter { $0.isShown && !$0.isAllDay && $0.overlaps(day(offset)) && $0.title != "Standup" }
            XCTAssertFalse(shown.isEmpty, "day \(offset) has a meeting besides the standup")
        }
        XCTAssertTrue(events.contains { $0.isFree && $0.isShown }, "focus time is shown free")
        XCTAssertTrue(events.contains { $0.response == .declined }, "a declined event is kept, never drawn")
        XCTAssertTrue(events.contains { $0.response == .tentative })
        try assertOneFloatingAllDayEvent(in: events)
    }

    func testThePersonalCalendarHasAnEveningConcertAndAnAllDayBirthday() async throws {
        let events = try await events(gmail)
        let concert = try XCTUnwrap(events.first { $0.title.hasPrefix("Jazz") })
        XCTAssertGreaterThanOrEqual(calendar.component(.hour, from: concert.start), 18, "out of hours")
        XCTAssertTrue(concert.isBusy)
        XCTAssertTrue(events.contains { $0.response == .declined })
        XCTAssertFalse(events.contains { $0.title == "Climbing night" }, "a cancelled event is left out")
        try assertOneFloatingAllDayEvent(in: events)
    }

    private func assertOneFloatingAllDayEvent(in events: [CalendarEvent], file: StaticString = #filePath, line: UInt = #line) throws {
        let allDay = events.filter(\.isAllDay)
        XCTAssertEqual(allDay.count, 1, file: file, line: line)
        let event = try XCTUnwrap(allDay.first, file: file, line: line)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.startOfDay(for: event.start), event.start, "held floating: midnight UTC", file: file, line: line)
        XCTAssertEqual(event.end.timeIntervalSince(event.start), 86_400, file: file, line: line)
        XCTAssertFalse(event.isBusy, "an all-day event marks the day, not its hours", file: file, line: line)
    }

    /// Google and Exchange put an invitation on the calendar when it arrives, under its UID: each of the demo's is there,
    /// and the dinner and the critique each overlap another busy event, which the card and the calendar show.
    func testEveryInvitationIsOnItsCalendarAndTheOpenOnesOverlapAnotherEvent() async throws {
        for (account, profile) in [(gmail, DemoProfile.gmail), (outlook, DemoProfile.outlook)] {
            let events = try await events(account)
            let invitations = DemoInvitations.invitations(for: profile, reference: reference)
                .compactMap { CalendarInvitationReader.invitation(fromICS: $0.calendar, userAddresses: [profile.email]) }
            XCTAssertFalse(invitations.isEmpty)
            for invitation in invitations {
                let own = events.filter { $0.invitationUID == invitation.uid }
                if invitation.isCancelled {
                    XCTAssertTrue(own.isEmpty, "\(invitation.title): cancelled, so not on the calendar")
                    continue
                }
                let first = try XCTUnwrap(own.first, invitation.title)
                XCTAssertEqual(first.start, invitation.start, invitation.title)
                XCTAssertEqual(first.end, invitation.end, invitation.title)
                XCTAssertEqual(first.title, invitation.title)
                if invitation.repeats != nil {
                    XCTAssertGreaterThan(own.count, 1, "\(invitation.title): a repeat, expanded")
                }
                guard invitation.userResponse == .needsAction else { continue }
                XCTAssertEqual(first.response, .needsAction, "\(invitation.title): pencilled in until answered")
                let span = DateInterval(start: invitation.start, end: invitation.end)
                let overlapping = events.filter { $0.invitationUID != invitation.uid && $0.isBusy && $0.overlaps(span) }
                XCTAssertFalse(overlapping.isEmpty, "\(invitation.title): another event overlaps it")
            }
        }
    }

    func testTheSameReferenceGivesTheSameCalendar() async throws {
        let first = try await events(outlook, in: service())
        let second = try await events(outlook, in: service())
        XCTAssertEqual(first, second)
    }

    // MARK: Writes

    func testTimeSetAsideIsCreatedOnceAndRemoved() async throws {
        let service = service()
        for account in [gmail, outlook] {
            let provider = try calendarProvider(account, in: service)
            let window = CalendarWindow.around(reference, calendar: calendar)
            let before = try await provider.calendarEvents(in: window).events
            let start = day(1).start.addingTimeInterval(13 * 3_600)
            let source = MessageID(accountID: account.id, providerID: "m1")
            let block = CalendarEvent(id: CalendarEvent.newLocalID(accountID: account.id), accountID: account.id, providerID: nil,
                                      title: "Contoso rollout", start: start, end: start.addingTimeInterval(1_800),
                                      sourceMessage: source, clientKey: CalendarEvent.newClientKey(), sync: .creating)

            let created = try await provider.createCalendarEvent(block)

            let providerID = try XCTUnwrap(created.providerID)
            XCTAssertEqual(created.id, block.id, "the local id is kept")
            XCTAssertEqual(created.clientKey, block.clientKey)
            XCTAssertEqual(created.sourceMessage, source)
            XCTAssertEqual(created.sync, .synced)
            XCTAssertNotNil(created.webURL)
            XCTAssertNotNil(created.updatedAt)
            if account.kind == .gmail { XCTAssertEqual(providerID, block.clientKey, "Google takes the key as the event's id") }

            var read = try await provider.calendarEvents(in: window).events
            let copy = try XCTUnwrap(read.first { $0.providerID == providerID })
            XCTAssertEqual(copy.id, CalendarEvent.localID(accountID: account.id, providerID: providerID))
            XCTAssertEqual(copy.clientKey, block.clientKey, "a read reports the key back")
            XCTAssertEqual(copy.title, "Contoso rollout")
            XCTAssertTrue(copy.isBusy)
            XCTAssertEqual(read.count, before.count + 1)

            // A create retried after a lost reply returns the copy already made.
            let again = try await provider.createCalendarEvent(block)
            XCTAssertEqual(again.providerID, providerID)
            read = try await provider.calendarEvents(in: window).events
            XCTAssertEqual(read.count, before.count + 1)

            try await provider.deleteCalendarEvent(providerID: providerID)
            read = try await provider.calendarEvents(in: window).events
            XCTAssertEqual(read.map(\.id), before.map(\.id))
            try await provider.deleteCalendarEvent(providerID: providerID)
        }
    }

    func testAnAnswerReachesTheDemoCalendar() async throws {
        let service = service()
        let provider = service.provider(for: gmail)
        let calendarProvider = try calendarProvider(gmail, in: service)
        let dinner = DemoInvitations.dinnerStart(reference: reference)
        let answer = InvitationAnswer(response: .accepted, uid: DemoInvitations.dinnerUID, title: "Sam's birthday dinner", start: dinner,
                                      end: dinner.addingTimeInterval(DemoInvitations.dinnerLength),
                                      organizer: DemoCatalog.sam.email, attendee: DemoProfile.gmail.me)

        try await provider.apply(.answerInvitation(answer), to: [])

        let events = try await calendarProvider.calendarEvents(in: CalendarWindow.around(reference, calendar: calendar)).events
        XCTAssertEqual(events.first { $0.invitationUID == DemoInvitations.dinnerUID }?.response, .accepted)
    }

    // MARK: Mail that names a time

    /// Each demo mailbox has a recent mail whose words name a time on a working day ahead, which the detector finds.
    func testEachMailboxHasARecentMailThatNamesATime() async throws {
        let service = service()
        let expected: [(account: Account, hour: Int, duration: TimeInterval?)] = [(gmail, 15, nil), (outlook, 14, 3_600)]
        for (account, hour, duration) in expected {
            let provider = service.provider(for: account)
            let mail = try XCTUnwrap(DemoCalendar.timeMails(for: DemoProfile.profile(for: account.kind), reference: reference).first)
            let page = try await provider.bootstrap(page: nil, limit: 500)
            let metadata = try XCTUnwrap(page.messages.first { $0.subject == mail.subject })
            XCTAssertTrue(metadata.isInInbox)
            XCTAssertNil(metadata.listUnsubscribe)
            let body = try await provider.body(for: metadata.id.providerID)
            let plainText = HTMLSanitizer().sanitize(body, messageID: metadata.id).plainText

            let found = MailTimeDetector.shared.times(in: plainText, messageID: metadata.id, received: metadata.date, now: Date())

            let time = try XCTUnwrap(found.first, account.email)
            XCTAssertEqual(found.count, 1)
            XCTAssertEqual(calendar.component(.hour, from: time.start), hour)
            XCTAssertFalse(calendar.isDateInWeekend(time.start), "a working day")
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: reference), to: calendar.startOfDay(for: time.start)).day
            XCTAssertTrue((2...4).contains(days ?? 0), "two to four days ahead, got \(String(describing: days))")
            XCTAssertEqual(time.duration, duration)
        }
    }

    /// The whole path in demo mode: the engine stores the time mail's body and hands the store the time it names.
    func testTheEngineFindsTheDemosMailTimesWhenItStoresTheBodies() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DemoCalendarTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MailTimeRecordingStore(base: InMemoryMailStore())
        var tuning = SyncTuning()
        tuning.pollInterval = 0.1
        let service = service()
        let engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(),
                                providerFactory: { service.provider(for: $0) }, tuning: tuning, attachmentCacheDirectory: folder)
        engine.start()
        let accounts = try await DemoSeeder.seedIfNeeded(engine)
        let subjects = Set(DemoProfile.all.flatMap { DemoCalendar.timeMails(for: $0, reference: reference).map(\.subject) })
        try await waitUntil("each time mail's body is stored and its time handed to the store", timeout: 30) {
            let found = store.savedMailTimes.compactMap { try? store.message($0.message)?.subject }
            return subjects.isSubset(of: Set(found))
        }
        let phrases = store.savedMailTimes.flatMap(\.times).map(\.phrase)
        XCTAssertTrue(phrases.contains { $0.hasSuffix("at 3pm") }, "\(phrases)")
        XCTAssertTrue(phrases.contains { $0.hasSuffix("from 2 to 3pm") }, "\(phrases)")
        XCTAssertEqual(Set(store.savedMailTimes.map(\.message.accountID)), Set(accounts.map(\.id)))
        await engine.stopAndWait()
    }
}
