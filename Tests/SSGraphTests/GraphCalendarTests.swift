import Foundation
import SSCore
import XCTest
@testable import SSGraph

/// Outlook's default calendar through Graph (docs/ARCHITECTURE.md, "Calendar"): the window read through `calendarView`
/// in UTC, page after page; time set aside for a mail created busy and without attendees on `/me/events`, and deleted
/// there; and the calendar's refusals. Every request goes to the stub protocol.
final class GraphCalendarTests: GraphTestCase {
    private static let calendarScopes = "Mail.ReadWrite Mail.Send User.Read Calendars.ReadWrite profile openid"
    private let calendarViewPath = "/v1.0/me/calendarView"
    private let nextLink = "https://graph.microsoft.com/v1.0/me/calendarView?startDateTime=2026-10-18T00%3A00%3A00Z&endDateTime=2026-12-27T00%3A00%3A00Z&%24select=id%2Csubject&%24top=200&%24skip=200"

    override func setUp() {
        super.setUp()
        tokens.scopes = Self.calendarScopes
    }

    /// The window `CalendarWindow.around` gives for the frozen now, on a Mac in UTC: 18 October up to 28 December 2026.
    private var window: DateInterval {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return CalendarWindow.around(now, calendar: utc)
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    // MARK: Fixtures

    /// One event of a `calendarView` page as Graph returns it under the calendar `$select` and
    /// `Prefer: outlook.timezone="UTC"`, recorded and anonymized.
    static func event(id: String, subject: String = "Roadmap review", start: String = "2026-11-03T13:00:00.0000000",
                      end: String = "2026-11-03T14:00:00.0000000", timeZone: String = "UTC", isAllDay: Bool = false,
                      response: String = "accepted", isOrganizer: Bool = false, showAs: String = "busy",
                      isCancelled: Bool = false, type: String = "singleInstance",
                      onlineMeeting: String = "null", onlineMeetingUrl: String = "null",
                      transactionId: String? = nil) -> String {
        let transaction = transactionId.map { #", "transactionId": "\#($0)""# } ?? ""
        return """
        {"@odata.etag": "W/\\"DwAAABYAAAA\\"", "id": "\(id)", "subject": "\(subject)", "isAllDay": \(isAllDay),
         "isCancelled": \(isCancelled), "isOrganizer": \(isOrganizer), "showAs": "\(showAs)", "type": "\(type)",
         "iCalUId": "040000008200E00074C5B7101A82E00800000000\(id.filter(\.isLetter).uppercased())",
         "lastModifiedDateTime": "2026-10-28T10:15:02.1234567Z",
         "webLink": "https://outlook.office365.com/owa/?itemid=\(id)%3D&exvsurl=1&path=/calendar/item",
         "onlineMeetingUrl": \(onlineMeetingUrl), "onlineMeeting": \(onlineMeeting),
         "responseStatus": {"response": "\(response)", "time": "2026-10-28T10:15:00Z"},
         "start": {"dateTime": "\(start)", "timeZone": "\(timeZone)"},
         "end": {"dateTime": "\(end)", "timeZone": "\(timeZone)"},
         "location": {"displayName": "Bay 4", "locationType": "default", "uniqueIdType": "unknown"},
         "organizer": {"emailAddress": {"name": "Rachel Kim", "address": "rachel.kim@northwind.test"}}\(transaction)}
        """
    }

    private func page(_ events: [String], nextLink: String? = nil) -> String {
        let context = #""@odata.context": "https://graph.microsoft.com/v1.0/$metadata#users('x')/calendarView(id,subject)""#
        let next = nextLink.map { #", "@odata.nextLink": "\#($0)""# } ?? ""
        return "{\(context), \"value\": [\(events.joined(separator: ",\n"))]\(next)}"
    }

    /// Answers the calendar read with `events` in one page.
    private func routeCalendar(_ events: [String]) {
        route { request in
            guard request.method == "GET", request.path == self.calendarViewPath else { return nil }
            return .json(self.page(events))
        }
    }

    private func read(_ events: [String]) async throws -> [CalendarEvent] {
        routeCalendar(events)
        return try await makeProvider().calendarEvents(in: window).events
    }

    private func readOne(_ event: String) async throws -> CalendarEvent {
        let events = try await read([event])
        XCTAssertEqual(events.count, 1)
        return try XCTUnwrap(events.first)
    }

    /// What Exchange answers a token without a calendar scope.
    private let accessDenied = Reply.json(#"{"error": {"code": "ErrorAccessDenied", "message": "Access is denied. Check credentials and try again."}}"#,
                                          status: 403)

    // MARK: Reading

    func testAReadAsksForTheWindowInUTCAndFollowsEveryPage() async throws {
        route { request in
            guard request.method == "GET", request.path == self.calendarViewPath else { return nil }
            if request.query["$skip"] == "200" {
                return .json(self.page([Self.event(id: "AAMkTWO", start: "2026-11-04T09:00:00.0000000", end: "2026-11-04T09:30:00.0000000")]))
            }
            return .json(self.page([Self.event(id: "AAMkONE")], nextLink: self.nextLink))
        }
        let listing = try await makeProvider().calendarEvents(in: window)

        XCTAssertEqual(listing.events.map(\.providerID), ["AAMkONE", "AAMkTWO"], "both pages are read")
        XCTAssertEqual(listing.requestCount, 2, "one request per page")
        let sent = requests(to: calendarViewPath)
        XCTAssertEqual(sent.count, 2)
        let first = try XCTUnwrap(sent.first)
        XCTAssertEqual(first.query["startDateTime"], "2026-10-18T00:00:00Z")
        XCTAssertEqual(first.query["endDateTime"], "2026-12-28T00:00:00Z")
        XCTAssertEqual(first.query["$select"], "id,subject,start,end,isAllDay,location,showAs,responseStatus,isCancelled,isOrganizer,onlineMeeting,onlineMeetingUrl,webLink,organizer,iCalUId,lastModifiedDateTime,type,transactionId")
        XCTAssertEqual(first.query["$top"], "200")
        XCTAssertEqual(sent.last?.url.absoluteString, nextLink, "the second page is the nextLink as given")
        for request in sent {
            let prefer = request.header("Prefer") ?? ""
            XCTAssertTrue(prefer.contains("outlook.timezone=\"UTC\""), "every page asks for UTC: \(prefer)")
            XCTAssertTrue(prefer.contains("IdType=\"ImmutableId\""), "ids stay the ones the store keys by: \(prefer)")
            XCTAssertEqual(request.header("Authorization"), "Bearer token-1")
        }
    }

    func testATimedEventIsTheInstantGraphNamesInUTC() async throws {
        let event = try await readOne(Self.event(id: "AAMkONE"))

        XCTAssertEqual(event.id, CalendarEvent.localID(accountID: accountID, providerID: "AAMkONE"))
        XCTAssertEqual(event.accountID, accountID)
        XCTAssertEqual(event.providerID, "AAMkONE")
        XCTAssertEqual(event.title, "Roadmap review")
        XCTAssertEqual(event.location, "Bay 4")
        XCTAssertEqual(event.start, date("2026-11-03T13:00:00Z"))
        XCTAssertEqual(event.end, date("2026-11-03T14:00:00Z"))
        XCTAssertFalse(event.isAllDay)
        XCTAssertEqual(event.response, .accepted)
        XCTAssertFalse(event.isFree)
        XCTAssertNil(event.joinURL)
        XCTAssertEqual(event.webURL, "https://outlook.office365.com/owa/?itemid=AAMkONE%3D&exvsurl=1&path=/calendar/item")
        XCTAssertEqual(event.organizer, "Rachel Kim")
        XCTAssertEqual(event.invitationUID, "040000008200E00074C5B7101A82E00800000000AAMKONE")
        XCTAssertNil(event.sourceMessage)
        XCTAssertNil(event.clientKey)
        XCTAssertEqual(event.sync, .synced)
        XCTAssertEqual(event.updatedAt?.timeIntervalSince1970 ?? 0, date("2026-10-28T10:15:02Z").timeIntervalSince1970 + 0.123, accuracy: 0.001)
    }

    /// A time in a zone Graph names despite the preference (a Windows name) is still read as the instant it is there.
    func testATimeInANamedZoneIsReadInThatZone() async throws {
        let event = try await readOne(Self.event(id: "AAMkONE", start: "2026-11-03T14:00:00.0000000", end: "2026-11-03T15:00:00.0000000",
                                                 timeZone: "W. Europe Standard Time"))
        XCTAssertEqual(event.start, date("2026-11-03T13:00:00Z"))
        XCTAssertEqual(event.end, date("2026-11-03T14:00:00Z"))
    }

    /// All-day events are written at midnight of their own dates, whatever zone Graph names beside them. They are kept
    /// as those dates at UTC midnight (floating), never shifted, so a Mac west of Greenwich (here California, -08:00,
    /// the app's default zone, which `Calendar.current` and a new DateFormatter take) draws them on their own days.
    func testAnAllDayEventKeepsItsDatesWhereverTheMacIs() async throws {
        let macZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = macZone }
        XCTAssertLessThan(Calendar.current.timeZone.secondsFromGMT(for: now), 0, "the Mac is west of Greenwich for this test")
        XCTAssertLessThan(DateFormatter().timeZone.secondsFromGMT(for: now), 0)

        let events = try await read([
            Self.event(id: "AAMkUTC", start: "2026-11-12T00:00:00.0000000", end: "2026-11-14T00:00:00.0000000", isAllDay: true,
                       showAs: "free"),
            Self.event(id: "AAMkPACIFIC", start: "2026-11-12T00:00:00.0000000", end: "2026-11-14T00:00:00.0000000",
                       timeZone: "Pacific Standard Time", isAllDay: true, showAs: "free"),
            Self.event(id: "AAMkTOKYO", start: "2026-11-12T00:00:00.0000000", end: "2026-11-14T00:00:00.0000000",
                       timeZone: "Tokyo Standard Time", isAllDay: true, showAs: "free"),
        ])
        XCTAssertEqual(events.count, 3)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        for event in events {
            XCTAssertTrue(event.isAllDay, event.providerID ?? "")
            XCTAssertEqual(event.start, date("2026-11-12T00:00:00Z"), event.providerID ?? "")
            XCTAssertEqual(event.end, date("2026-11-14T00:00:00Z"), "the end is exclusive: \(event.providerID ?? "")")
            XCTAssertEqual(utc.component(.day, from: event.start), 12, "floating: its date read as UTC")
            XCTAssertEqual(Calendar.current.component(.day, from: event.start), 11,
                           "read as an instant here it would fall a day early, which is why the day is held floating")
            XCTAssertFalse(event.isBusy, "an all-day event marks the day, not its hours")
        }
    }

    /// Graph's date-times are read by hand (a DateFormatter costs too much a parse for a whole window): every UTC wall
    /// clock reads as the instant a formatter would give, a time beside a zone that changes its offset lands on the
    /// right side of the change, and anything but a whole date and time to the second reads as nothing.
    func testEventTimesAreReadExactly() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var instant = date("1999-12-31T23:00:00Z")
        while instant < date("2032-03-01T00:00:00Z") {
            let text = formatter.string(from: instant) + ".0000000"
            let read = try XCTUnwrap(GraphEventTime.read(GraphDateTimeZone(dateTime: text, timeZone: "UTC")), text)
            XCTAssertEqual(read.date, instant, text)
            XCTAssertEqual(read.day, Date(timeIntervalSince1970: (instant.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400), text)
            instant.addTimeInterval(97 * 3_600 + 13 * 60 + 7)
        }

        func read(_ text: String, _ zone: String) -> Date? {
            GraphEventTime.read(GraphDateTimeZone(dateTime: text, timeZone: zone))?.date
        }
        XCTAssertEqual(read("2028-02-29T23:59:59.9990000", "UTC"), date("2028-02-29T23:59:59Z"), "a leap day")
        XCTAssertEqual(read("2026-11-03T13:00:00", "UTC"), date("2026-11-03T13:00:00Z"), "no fraction")
        XCTAssertEqual(read("2026-11-03T13:00:00.0000000", "Unknown Zone"), date("2026-11-03T13:00:00Z"), "a zone not known reads as UTC")
        XCTAssertEqual(read("2026-03-29T03:30:00.0000000", "W. Europe Standard Time"), date("2026-03-29T01:30:00Z"),
                       "just after Berlin moves to summer time")
        XCTAssertEqual(read("2026-03-29T01:30:00.0000000", "W. Europe Standard Time"), date("2026-03-29T00:30:00Z"),
                       "just before it")
        XCTAssertEqual(read("2026-10-25T01:30:00.0000000", "W. Europe Standard Time"), date("2026-10-24T23:30:00Z"),
                       "summer time still, before it ends")
        XCTAssertEqual(read("2026-11-01T09:00:00.0000000", "Pacific Standard Time"), date("2026-11-01T17:00:00Z"),
                       "the morning Los Angeles leaves summer time")
        for text in ["2026-02-29T00:00:00", "2026-13-01T00:00:00", "2026-11-03T24:00:00", "2026-11-03T13:00:00Z",
                     "2026-11-03 13:00:00", "2026-11-03T13:00", "2026-11-03", "", "2026-11-03T13:00:00.12a"] {
            XCTAssertNil(read(text, "UTC"), text)
        }
    }

    func testEachAnswerReadsAsTheEventsResponse() async throws {
        let cases: [(response: String, isOrganizer: Bool, expected: CalendarEvent.Response)] = [
            ("organizer", true, .organizer),
            ("accepted", false, .accepted),
            ("tentativelyAccepted", false, .tentative),
            ("declined", false, .declined),
            ("notResponded", false, .needsAction),
            ("none", false, .needsAction),
            ("none", true, .organizer),
        ]
        let events = try await read(cases.enumerated().map { index, item in
            Self.event(id: "AAMk\(index)", response: item.response, isOrganizer: item.isOrganizer)
        })
        XCTAssertEqual(events.map(\.response), cases.map(\.expected), "declined is kept, so a refresh does not bring it back as new")
        for (event, item) in zip(events, cases) {
            if item.expected == .organizer {
                XCTAssertNil(event.organizer, "the user organized it: \(item.response)")
            } else {
                XCTAssertEqual(event.organizer, "Rachel Kim", item.response)
            }
        }
        XCTAssertFalse(try XCTUnwrap(events.first { $0.response == .declined }).isShown, "declined is never drawn")
    }

    func testTheOrganizersAddressStandsInForAMissingName() async throws {
        let json = Self.event(id: "AAMkONE").replacingOccurrences(of: #""name": "Rachel Kim", "#, with: "")
        let event = try await readOne(json)
        XCTAssertEqual(event.organizer, "rachel.kim@northwind.test")
    }

    func testCancelledEventsAreLeftOut() async throws {
        let events = try await read([
            Self.event(id: "AAMkKEPT"),
            Self.event(id: "AAMkCANCELLED", isCancelled: true),
        ])
        XCTAssertEqual(events.map(\.providerID), ["AAMkKEPT"])
    }

    func testTimeShownAsFreeIsDrawnButNeverBusy() async throws {
        let events = try await read(["free", "tentative", "busy", "oof", "workingElsewhere"].map { Self.event(id: "AAMk\($0)", showAs: $0) })
        XCTAssertEqual(events.map(\.isFree), [true, false, false, false, false])
        XCTAssertEqual(events.map(\.isBusy), [false, true, true, true, true])
    }

    func testTheTeamsJoinAddressAndTheOlderOne() async throws {
        let events = try await read([
            Self.event(id: "AAMkTEAMS", onlineMeeting: #"{"joinUrl": "https://teams.microsoft.test/l/meetup-join/roadmap"}"#,
                       onlineMeetingUrl: #""https://legacy.example.test/join/roadmap""#),
            Self.event(id: "AAMkLEGACY", onlineMeetingUrl: #""https://legacy.example.test/join/roadmap""#),
            Self.event(id: "AAMkNOTWEB", onlineMeeting: #"{"joinUrl": "tel:+15550100"}"#),
        ])
        XCTAssertEqual(events.map(\.joinURL), [
            "https://teams.microsoft.test/l/meetup-join/roadmap", "https://legacy.example.test/join/roadmap", nil,
        ], "Join opens a web address only")
    }

    func testABlockReadBackCarriesItsClientKey() async throws {
        let event = try await readOne(Self.event(id: "AAMkBLOCK", response: "organizer", isOrganizer: true,
                                                 transactionId: "0f1e2d3c4b5a69788796a5b4c3d2e1f0"))
        XCTAssertEqual(event.clientKey, "0f1e2d3c4b5a69788796a5b4c3d2e1f0", "the store matches it to the row that asked for it")
    }

    // MARK: Time set aside

    private let clientKey = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"

    private var block: CalendarEvent {
        CalendarEvent(id: "acct-graph-1|local-1", accountID: accountID, providerID: nil, title: "Quarterly numbers",
                      start: date("2026-11-02T15:00:00Z"), end: date("2026-11-02T15:30:00Z"),
                      sourceMessage: MessageID(accountID: accountID, providerID: "M-1"), clientKey: clientKey, sync: .creating)
    }

    /// `POST /me/events` answers 201 with the whole event, recorded and anonymized.
    private var created: String {
        """
        {"@odata.context": "https://graph.microsoft.com/v1.0/$metadata#users('x')/events/$entity",
         "@odata.etag": "W/\\"DwAAABYAAAB\\"", "id": "AAMkBLOCK=", "createdDateTime": "2026-11-01T10:00:01.2345678Z",
         "lastModifiedDateTime": "2026-11-01T10:00:01.5000000Z", "changeKey": "DwAAABYAAAB", "categories": [],
         "transactionId": "\(clientKey)", "originalStartTimeZone": "UTC", "originalEndTimeZone": "UTC",
         "iCalUId": "040000008200E00074C5B7101A82E00800000000B10C", "reminderMinutesBeforeStart": 15, "isReminderOn": false,
         "hasAttachments": false, "subject": "Quarterly numbers", "bodyPreview": "Set aside in SuperSparrow for: Quarterly numbers",
         "importance": "normal", "sensitivity": "normal", "isAllDay": false, "isCancelled": false, "isOrganizer": true,
         "responseRequested": true, "seriesMasterId": null, "showAs": "busy", "type": "singleInstance",
         "webLink": "https://outlook.office365.com/owa/?itemid=AAMkBLOCK%3D&exvsurl=1&path=/calendar/item",
         "onlineMeetingUrl": null, "isOnlineMeeting": false, "onlineMeetingProvider": "unknown", "isDraft": false,
         "responseStatus": {"response": "organizer", "time": "0001-01-01T00:00:00Z"},
         "body": {"contentType": "text", "content": "Set aside in SuperSparrow for: Quarterly numbers"},
         "start": {"dateTime": "2026-11-02T15:00:00.0000000", "timeZone": "UTC"},
         "end": {"dateTime": "2026-11-02T15:30:00.0000000", "timeZone": "UTC"},
         "location": {"displayName": "", "locationType": "default", "uniqueIdType": "unknown", "address": {}, "coordinates": {}},
         "locations": [], "recurrence": null, "attendees": [],
         "organizer": {"emailAddress": {"name": "Alex Morgan", "address": "alex@northwind.test"}}, "onlineMeeting": null}
        """
    }

    func testABlockIsCreatedBusyWithoutAttendeesOrReminder() async throws {
        route { request in
            guard request.method == "POST", request.path == "/v1.0/me/events" else { return nil }
            return .json(self.created, status: 201)
        }
        let settled = try await makeProvider().createCalendarEvent(block)

        let post = try XCTUnwrap(requests(to: "/v1.0/me/events").first)
        XCTAssertEqual(post.method, "POST")
        XCTAssertEqual(post.header("Content-Type"), "application/json")
        XCTAssertTrue(post.header("Prefer")?.contains("outlook.timezone=\"UTC\"") ?? false)
        let json = post.json()
        XCTAssertEqual(Set(json.keys), ["subject", "start", "end", "showAs", "isReminderOn", "body", "transactionId"],
                       "no attendees: Exchange sends nobody an invitation")
        XCTAssertEqual(json["subject"] as? String, "Quarterly numbers")
        XCTAssertEqual(json["start"] as? [String: String], ["dateTime": "2026-11-02T15:00:00", "timeZone": "UTC"])
        XCTAssertEqual(json["end"] as? [String: String], ["dateTime": "2026-11-02T15:30:00", "timeZone": "UTC"])
        XCTAssertEqual(json["showAs"] as? String, "busy")
        XCTAssertEqual(json["isReminderOn"] as? Bool, false)
        XCTAssertEqual(json["body"] as? [String: String],
                       ["contentType": "text", "content": "Set aside in SuperSparrow for: Quarterly numbers"])
        XCTAssertEqual(json["transactionId"] as? String, clientKey, "a create sent again finds the first one's copy")

        XCTAssertEqual(settled.id, block.id, "the local id is kept")
        XCTAssertEqual(settled.providerID, "AAMkBLOCK=")
        XCTAssertEqual(settled.clientKey, clientKey)
        XCTAssertEqual(settled.sourceMessage, block.sourceMessage)
        XCTAssertEqual(settled.sync, .synced)
        XCTAssertEqual(settled.webURL, "https://outlook.office365.com/owa/?itemid=AAMkBLOCK%3D&exvsurl=1&path=/calendar/item")
        XCTAssertEqual(settled.updatedAt, date("2026-11-01T10:00:01Z").addingTimeInterval(0.5))
        XCTAssertEqual(settled.title, "Quarterly numbers")
        XCTAssertEqual(settled.start, block.start)
        XCTAssertEqual(settled.end, block.end)
        XCTAssertEqual(settled.response, .organizer)
        XCTAssertNil(settled.organizer)
        XCTAssertNil(settled.location)
        XCTAssertFalse(settled.isFree)
    }

    /// Should Graph refuse a create whose `transactionId` it has seen rather than hand the first copy back, the copy is
    /// found over the block's own half hour.
    func testACreateRefusedAsADuplicateHandsBackTheCopyAlreadyMade() async throws {
        route { request in
            switch (request.method, request.path) {
            case ("POST", "/v1.0/me/events"):
                return .json(#"{"error": {"code": "ErrorDuplicateTransactionId", "message": "A duplicate transaction id was found."}}"#,
                             status: 409)
            case ("GET", self.calendarViewPath):
                return .json(self.page([Self.event(id: "AAMkOTHER", start: "2026-11-02T15:00:00.0000000", end: "2026-11-02T16:00:00.0000000"),
                                        self.created]))
            default:
                return nil
            }
        }
        let settled = try await makeProvider().createCalendarEvent(block)
        XCTAssertEqual(settled.providerID, "AAMkBLOCK=")
        XCTAssertEqual(settled.id, block.id)
        XCTAssertEqual(settled.sync, .synced)
        let lookup = try XCTUnwrap(requests(to: calendarViewPath).first)
        XCTAssertEqual(lookup.query["startDateTime"], "2026-11-02T15:00:00Z")
        XCTAssertEqual(lookup.query["endDateTime"], "2026-11-02T15:30:00Z")
    }

    func testADuplicateRefusalWithoutTheCopyStaysAFailure() async {
        route { request in
            switch (request.method, request.path) {
            case ("POST", "/v1.0/me/events"): return .json(#"{"error": {"code": "Conflict", "message": "Conflict."}}"#, status: 409)
            case ("GET", self.calendarViewPath): return .json(self.page([]))
            default: return nil
            }
        }
        await expectProviderError({ try await self.makeProvider().createCalendarEvent(self.block) }) { $0.serverStatus == 409 }
    }

    func testABlockIsDeletedOnItsEvent() async throws {
        route { request in
            guard request.method == "DELETE", request.path == "/v1.0/me/events/AAMkBLOCK=" else { return nil }
            return .status(204)
        }
        try await makeProvider().deleteCalendarEvent(providerID: "AAMkBLOCK=")
        XCTAssertEqual(requests.map(\.method), ["DELETE"])
    }

    func testDeletingAnEventAlreadyGoneIsDone() async throws {
        route { request in
            guard request.method == "DELETE" else { return nil }
            return .json(Fixtures.notFoundError, status: 404)
        }
        try await makeProvider().deleteCalendarEvent(providerID: "AAMkBLOCK=")
        XCTAssertEqual(requests.count, 1)
    }

    // MARK: Permission and failures

    func testThePermissionIsTheCalendarScopeTheTokenHolds() async {
        tokens.scopes = nil
        let unknown = await makeProvider().hasCalendarPermission()
        XCTAssertFalse(unknown, "unknown scopes grant nothing")
        tokens.scopes = OAuthEndpoints.microsoftScope
        let mailOnly = await makeProvider().hasCalendarPermission()
        XCTAssertFalse(mailOnly)
        tokens.scopes = "Calendars.Read"
        let readOnly = await makeProvider().hasCalendarPermission()
        XCTAssertFalse(readOnly, "a block needs to write")
        tokens.scopes = OAuthEndpoints.microsoftScope + " " + OAuthEndpoints.microsoftCalendarScope
        let granted = await makeProvider().hasCalendarPermission()
        XCTAssertTrue(granted)
        tokens.scopes = Self.calendarScopes
        let short = await makeProvider().hasCalendarPermission()
        XCTAssertTrue(short, "Microsoft lists Graph's scopes without the resource too")
        XCTAssertTrue(requests.isEmpty, "no request")
    }

    func testWithoutTheCalendarScopeA403IsAMissingPermission() async throws {
        tokens.scopes = OAuthEndpoints.microsoftScope
        let insufficient = Reply.json(#"{"error": {"code": "Authorization_RequestDenied", "message": "Insufficient privileges to complete the operation."}}"#,
                                      status: 403)
        route { request in request.method == "POST" ? insufficient : self.accessDenied }
        let provider = makeProvider()
        await expectCalendarError(.permissionMissing) { _ = try await provider.calendarEvents(in: self.window) }
        await expectCalendarError(.permissionMissing) { _ = try await provider.createCalendarEvent(self.block) }
        await expectCalendarError(.permissionMissing) { try await provider.deleteCalendarEvent(providerID: "AAMkBLOCK=") }
    }

    /// A token that holds the scope and is refused all the same (an organization's policy) keeps the 403: calling it a
    /// missing permission would ask the user to connect again and again to no effect.
    func testA403ToATokenHoldingTheScopeStaysAFailure() async {
        route { _ in self.accessDenied }
        await expectProviderError({ try await self.makeProvider().calendarEvents(in: self.window) }) { $0.serverStatus == 403 }
    }

    func testARefusedTokenIsUnauthorized() async {
        route { _ in .json(#"{"error": {"code": "InvalidAuthenticationToken", "message": "Access token has expired."}}"#, status: 401) }
        await expectProviderError({ try await self.makeProvider().calendarEvents(in: self.window) }) { $0.isUnauthorized }
        XCTAssertEqual(tokens.invalidations, 2, "one retry with a fresh token, then the token's problem as for mail")
    }

    func testAThrottleCarriesItsRetryAfter() async {
        route { _ in .json(#"{"error": {"code": "ApplicationThrottled", "message": "Too many requests."}}"#, status: 429,
                           headers: ["Retry-After": "7"]) }
        await expectProviderError({ try await self.makeProvider().calendarEvents(in: self.window) }) { $0.retryAfter == 7 }
        await expectProviderError({ try await self.makeProvider().createCalendarEvent(self.block) }) { $0.retryAfter == 7 }
        await expectProviderError({ try await self.makeProvider().deleteCalendarEvent(providerID: "AAMkBLOCK=") }) { $0.retryAfter == 7 }
    }

    func testTheServiceFailingIsANetworkFailure() async {
        route { _ in .json(#"{"error": {"code": "ServiceUnavailable", "message": "busy"}}"#, status: 503) }
        await expectProviderError({ try await self.makeProvider().calendarEvents(in: self.window) }) { $0.isNetwork }
    }

    func testAListingThatNeverEndsFails() async {
        route { request in
            guard request.path == self.calendarViewPath else { return nil }
            return .json(self.page([], nextLink: self.nextLink))
        }
        await expectProviderError({ try await self.makeProvider().calendarEvents(in: self.window) }) { $0.isDecoding }
        XCTAssertEqual(requests.count, GraphProvider.maxCalendarPages)
    }

    private func expectCalendarError(_ expected: CalendarProviderError, file: StaticString = #filePath, line: UInt = #line,
                                     _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CalendarProviderError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
