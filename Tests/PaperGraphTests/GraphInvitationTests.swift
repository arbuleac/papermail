import Foundation
import PaperCore
import XCTest
@testable import PaperGraph

/// Microsoft Graph and invitations (docs/ARCHITECTURE.md, "Calendar invitations"): an event message's body brings its
/// event (one more request, only for meeting mail), read into the stored invitation at sync time; an answer accepts,
/// tentatively accepts or declines the event, behind Calendars.ReadWrite. Every request goes to the stub protocol.
final class GraphInvitationTests: GraphTestCase {
    /// An event message as `?$expand=microsoft.graph.eventMessage/event` returns it, recorded and anonymized.
    static func eventMessage(type: String = "#microsoft.graph.eventMessageRequest", meetingType: String = "meetingRequest",
                             isAllDay: Bool = false, start: String = "2026-11-03T13:00:00.0000000",
                             end: String = "2026-11-03T14:00:00.0000000") -> String {
        """
        {"@odata.context": "https://graph.microsoft.com/v1.0/$metadata#users('x')/messages/$entity",
         "@odata.type": "\(type)", "id": "M-EV", "subject": "Roadmap review", "meetingMessageType": "\(meetingType)",
         "isOutOfDate": false, "body": {"contentType": "text", "content": "Monthly look at the roadmap."},
         "event": {
           "@odata.etag": "W/\\"DwAAABYAAAA\\"", "id": "AAMkEVENT=", "subject": "Roadmap review",
           "iCalUId": "040000008200E00074C5B7101A82E00800000000A1B2C3D4", "isAllDay": \(isAllDay), "isCancelled": false,
           "isOrganizer": false, "responseRequested": true, "type": "seriesMaster",
           "originalStartTimeZone": "W. Europe Standard Time", "originalEndTimeZone": "W. Europe Standard Time",
           "responseStatus": {"response": "notResponded", "time": "0001-01-01T00:00:00Z"},
           "start": {"dateTime": "\(start)", "timeZone": "UTC"},
           "end": {"dateTime": "\(end)", "timeZone": "UTC"},
           "location": {"displayName": "Bay 4", "locationType": "default", "uniqueIdType": "unknown"},
           "organizer": {"emailAddress": {"name": "Rachel Kim", "address": "rachel.kim@northwind.test"}},
           "attendees": [
             {"type": "required", "status": {"response": "none", "time": "0001-01-01T00:00:00Z"},
              "emailAddress": {"name": "Alex Morgan", "address": "alex@northwind.test"}},
             {"type": "optional", "status": {"response": "tentativelyAccepted", "time": "2026-10-28T10:15:00Z"},
              "emailAddress": {"name": "Marcus Bell", "address": "marcus.bell@northwind.test"}},
             {"type": "resource", "status": {"response": "accepted", "time": "2026-10-28T10:15:00Z"},
              "emailAddress": {"name": "Bay 4 Room", "address": "bay4@northwind.test"}}
           ],
           "recurrence": {
             "pattern": {"type": "relativeMonthly", "interval": 1, "month": 0, "dayOfMonth": 0, "daysOfWeek": ["tuesday"],
                         "firstDayOfWeek": "sunday", "index": "first"},
             "range": {"type": "endDate", "startDate": "2026-11-03", "endDate": "2027-03-02",
                       "recurrenceTimeZone": "W. Europe Standard Time", "numberOfOccurrences": 0}
           },
           "onlineMeeting": {"joinUrl": "https://teams.microsoft.test/l/meetup-join/roadmap"}
         }}
        """
    }

    private let bodyReply = ##"{"@odata.type": "#microsoft.graph.eventMessageRequest", "id": "M-EV", "body": {"contentType": "html", "content": "<p>Monthly look at the roadmap.</p>"}}"##

    private func routeBody(event: Reply?) {
        route { request in
            guard request.method == "GET" else { return nil }
            switch request.path {
            case "/v1.0/me/messages/M-EV":
                if request.query["$expand"] != nil { return event }
                return .json(self.bodyReply)
            case "/v1.0/me/messages/M-EV/attachments": return .json(Fixtures.list([]))
            default: return nil
            }
        }
    }

    // MARK: Sync time

    func testAMeetingRequestBringsItsInvitationWithTheBody() async throws {
        routeBody(event: .json(Self.eventMessage()))
        let body = try await makeProvider().body(for: "M-EV")
        XCTAssertEqual(body.html, "<p>Monthly look at the roadmap.</p>", "the body is the first request's, as before")
        let invitation = try XCTUnwrap(body.invitation)
        XCTAssertEqual(invitation.method, .request)
        XCTAssertEqual(invitation.uid, "040000008200E00074C5B7101A82E00800000000A1B2C3D4")
        XCTAssertEqual(invitation.title, "Roadmap review")
        XCTAssertEqual(invitation.start, ISO8601DateFormatter().date(from: "2026-11-03T13:00:00Z"))
        XCTAssertEqual(invitation.end, ISO8601DateFormatter().date(from: "2026-11-03T14:00:00Z"))
        XCTAssertEqual(invitation.timeZoneID, "Europe/Berlin", "the Windows zone it was written in")
        XCTAssertEqual(invitation.location, "Bay 4")
        XCTAssertEqual(invitation.conferenceURL, "https://teams.microsoft.test/l/meetup-join/roadmap")
        XCTAssertEqual(invitation.organizer, CalendarInvitation.Person(name: "Rachel Kim", address: "rachel.kim@northwind.test"))
        XCTAssertEqual(invitation.attendees.map(\.address), ["alex@northwind.test", "marcus.bell@northwind.test"], "the room is left out")
        XCTAssertEqual(invitation.attendees.map(\.response), [.needsAction, .tentative])
        XCTAssertEqual(invitation.userResponse, .needsAction)
        XCTAssertFalse(invitation.userIsOrganizer)
        XCTAssertEqual(invitation.graphEventID, "AAMkEVENT=")
        XCTAssertNotNil(invitation.repeats)
        let calendar = try XCTUnwrap(invitation.calendarText, "a calendar file is written for Open in Calendar")
        XCTAssertTrue(calendar.contains("METHOD:REQUEST\r\n"))
        XCTAssertTrue(calendar.contains("UID:040000008200E00074C5B7101A82E00800000000A1B2C3D4\r\n"))
        // The repeat's days and end date are stated in the event's zone, so it is written there: in UTC it would expand
        // on UTC days, and Microsoft's end date (a DATE) is the end of that day in Berlin.
        XCTAssertTrue(calendar.contains("BEGIN:VTIMEZONE\r\nTZID:Europe/Berlin\r\n"), calendar)
        XCTAssertTrue(calendar.contains("DTSTART;TZID=Europe/Berlin:20261103T140000\r\n"))
        XCTAssertTrue(calendar.contains("RRULE:FREQ=MONTHLY;BYDAY=1TU;UNTIL=20270302T225959Z\r\n"))
        // What our reader makes of the file it wrote is the same event.
        let reread = try XCTUnwrap(CalendarInvitationReader.invitation(fromICS: calendar, userAddresses: ["alex@northwind.test"]))
        XCTAssertEqual(reread.start, invitation.start)
        XCTAssertEqual(reread.end, invitation.end)
        XCTAssertEqual(reread.uid, invitation.uid)
        XCTAssertEqual(reread.repeats, invitation.repeats)

        let expand = try XCTUnwrap(requests(to: "/v1.0/me/messages/M-EV").first { $0.query["$expand"] != nil })
        XCTAssertEqual(expand.query["$expand"], "microsoft.graph.eventMessage/event")
        XCTAssertTrue(expand.header("Prefer")?.contains("outlook.timezone=\"UTC\"") ?? false, "times come in UTC")
    }

    func testTheRepeatIsSaidInWords() throws {
        let message = try GraphJSON.decode(GraphMessage.self, from: Data(Self.eventMessage().utf8))
        let invitation = try XCTUnwrap(GraphInvitationMapper.invitation(from: message, locale: Locale(identifier: "en_GB")))
        XCTAssertEqual(invitation.repeats, "Every month on the first Tuesday, until 2 March 2027")
    }

    /// A repeat in a zone the Mac does not know (Outlook's own, or none named): Graph gives the times in UTC but the
    /// repeat's days and end date in that zone, which cannot be put in UTC without knowing it. Open in Calendar gets the
    /// first occurrence alone, at its exact time, rather than a repeat on the wrong days; the card still says how it
    /// repeats. A repeat in UTC itself is written whole.
    func testARepeatInAZoneTheMacDoesNotKnowIsHandedOverAsItsFirstOccurrence() throws {
        let zoneLine = #""originalStartTimeZone": "W. Europe Standard Time""#
        for replacement in [#""originalStartTimeZone": "Customized Time Zone""#, #""originalStartTimeZone": null"#] {
            let json = Self.eventMessage().replacingOccurrences(of: zoneLine, with: replacement)
            let message = try GraphJSON.decode(GraphMessage.self, from: Data(json.utf8))
            let invitation = try XCTUnwrap(GraphInvitationMapper.invitation(from: message, locale: Locale(identifier: "en_GB")))
            XCTAssertNil(invitation.timeZoneID, replacement)
            XCTAssertEqual(invitation.repeats, "Every month on the first Tuesday, until 2 March 2027", replacement)
            let calendar = try XCTUnwrap(invitation.calendarText)
            XCTAssertFalse(calendar.contains("RRULE"), calendar)
            XCTAssertFalse(calendar.contains("VTIMEZONE"), calendar)
            XCTAssertTrue(calendar.contains("DTSTART:20261103T130000Z\r\n"), calendar)
            let reread = try XCTUnwrap(CalendarInvitationReader.invitation(fromICS: calendar, userAddresses: ["alex@northwind.test"]))
            XCTAssertEqual(reread.start, invitation.start)
            XCTAssertEqual(reread.end, invitation.end)
            XCTAssertNil(reread.repeats)
        }

        let utc = Self.eventMessage().replacingOccurrences(of: zoneLine, with: #""originalStartTimeZone": "UTC""#)
        let inUTC = try XCTUnwrap(GraphInvitationMapper.invitation(from: try GraphJSON.decode(GraphMessage.self, from: Data(utc.utf8))))
        let calendar = try XCTUnwrap(inUTC.calendarText)
        XCTAssertTrue(calendar.contains("DTSTART:20261103T130000Z\r\n"), calendar)
        XCTAssertTrue(calendar.contains("RRULE:FREQ=MONTHLY;BYDAY=1TU;UNTIL=20270302T235959Z\r\n"), calendar)
    }

    func testRecurrencePatternsMapOntoRepeatRules() throws {
        func rule(_ json: String) throws -> RecurrenceRule? {
            GraphInvitationMapper.recurrenceRule(from: try GraphJSON.decode(GraphPatternedRecurrence.self, from: Data(json.utf8)))
        }
        XCTAssertEqual(try rule(#"{"pattern": {"type": "weekly", "interval": 2, "daysOfWeek": ["monday", "thursday"]}, "range": {"type": "numbered", "numberOfOccurrences": 10}}"#)?.rruleText,
                       "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;COUNT=10")
        XCTAssertEqual(try rule(#"{"pattern": {"type": "absoluteMonthly", "interval": 1, "dayOfMonth": 3}, "range": {"type": "noEnd"}}"#)?.rruleText,
                       "FREQ=MONTHLY;BYMONTHDAY=3")
        XCTAssertEqual(try rule(#"{"pattern": {"type": "relativeYearly", "interval": 1, "month": 10, "daysOfWeek": ["sunday"], "index": "last"}}"#)?.rruleText,
                       "FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10")
        XCTAssertEqual(try rule(#"{"pattern": {"type": "daily", "interval": 3}}"#)?.rruleText, "FREQ=DAILY;INTERVAL=3")
        XCTAssertNil(try rule(#"{"pattern": {"type": "hourly"}}"#))
    }

    func testAPlainMessageMakesNoSecondRequest() async throws {
        route { request in
            switch request.path {
            case "/v1.0/me/messages/M-1": return .json(Fixtures.htmlBody)
            case "/v1.0/me/messages/M-1/attachments": return .json(Fixtures.list([]))
            default: return nil
            }
        }
        let body = try await makeProvider().body(for: "M-1")
        XCTAssertNil(body.invitation)
        XCTAssertTrue(requests.allSatisfy { $0.query["$expand"] == nil })
    }

    func testACancellationReadsAsCancelled() async throws {
        routeBody(event: .json(Self.eventMessage(type: "#microsoft.graph.eventMessage", meetingType: "meetingCancelled")))
        let invitation = try await XCTUnwrapAsync(try await makeProvider().body(for: "M-EV").invitation)
        XCTAssertEqual(invitation.method, .cancel)
        XCTAssertFalse(invitation.isAnswerable)
        XCTAssertTrue(invitation.calendarText?.contains("METHOD:CANCEL") ?? false)
    }

    func testAResponseToTheOrganizerIsNoInvitation() async throws {
        routeBody(event: .json(Self.eventMessage(type: "#microsoft.graph.eventMessageResponse", meetingType: "meetingAccepted")))
        let body = try await makeProvider().body(for: "M-EV")
        XCTAssertNil(body.invitation)
    }

    func testAllDayEventsAreKeptAsTheirDays() async throws {
        routeBody(event: .json(Self.eventMessage(isAllDay: true, start: "2026-11-12T00:00:00.0000000", end: "2026-11-14T00:00:00.0000000")))
        let invitation = try await XCTUnwrapAsync(try await makeProvider().body(for: "M-EV").invitation)
        XCTAssertTrue(invitation.isAllDay)
        XCTAssertTrue(invitation.isFloating)
        XCTAssertNil(invitation.timeZoneID)
        XCTAssertEqual(invitation.start, ISO8601DateFormatter().date(from: "2026-11-12T00:00:00Z"))
        XCTAssertEqual(invitation.end, ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
    }

    /// Made in Berlin (the fixture's `originalStartTimeZone`), so the UTC preference moves its midnights to 23:00 the
    /// day before: the card and the pencil still show 12 and 13 November.
    func testAnAllDayEventMadeEastOfGreenwichKeepsItsOwnDays() async throws {
        routeBody(event: .json(Self.eventMessage(isAllDay: true, start: "2026-11-11T23:00:00.0000000", end: "2026-11-13T23:00:00.0000000")))
        let invitation = try await XCTUnwrapAsync(try await makeProvider().body(for: "M-EV").invitation)
        XCTAssertTrue(invitation.isAllDay)
        XCTAssertTrue(invitation.isFloating)
        XCTAssertEqual(invitation.start, ISO8601DateFormatter().date(from: "2026-11-12T00:00:00Z"))
        XCTAssertEqual(invitation.end, ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
    }

    func testAnEventThatCannotBeReadLeavesTheMessageWithoutACard() async throws {
        routeBody(event: .json(#"{"error": {"code": "ErrorInternalServerError", "message": "boom"}}"#, status: 500))
        let body = try await makeProvider().body(for: "M-EV")
        XCTAssertNil(body.invitation)
        XCTAssertEqual(body.html, "<p>Monthly look at the roadmap.</p>", "the body is stored all the same")
    }

    // MARK: An event the account cannot read

    /// What Exchange answers a token without a calendar scope that expands the event.
    private let accessDenied = Reply.json(#"{"error": {"code": "ErrorAccessDenied", "message": "Access is denied. Check credentials and try again."}}"#,
                                          status: 403)

    private func routeBody(event: Reply?, mime: Reply?, type: String = "#microsoft.graph.eventMessageRequest") {
        let body = bodyReply.replacingOccurrences(of: "#microsoft.graph.eventMessageRequest", with: type)
        route { request in
            guard request.method == "GET" else { return nil }
            switch request.path {
            case "/v1.0/me/messages/M-EV":
                if request.query["$expand"] != nil { return event }
                return .json(body)
            case "/v1.0/me/messages/M-EV/$value": return mime
            case "/v1.0/me/messages/M-EV/attachments": return .json(Fixtures.list([]))
            default: return nil
            }
        }
    }

    private var mimeRequests: [Request] { requests.filter { $0.path.hasSuffix("/$value") } }

    /// The user's case: an account that granted mail alone. The event is refused, so the calendar comes from the
    /// message's own MIME, which the hydrator reads as it reads Gmail's text/calendar part.
    func testAnEventTheAccountCannotReadLeavesTheCalendarTheMessageCarries() async throws {
        routeBody(event: accessDenied, mime: .bytes(GraphMIMECalendarTests.exchangeMIME()))
        let body = try await makeProvider().body(for: "M-EV")
        XCTAssertNil(body.invitation, "Graph's own reading, refused")
        XCTAssertEqual(body.calendar, GraphMIMECalendarTests.ics)
        XCTAssertEqual(body.html, "<p>Monthly look at the roadmap.</p>", "the body is the first request's, as before")
        XCTAssertEqual(mimeRequests.count, 1)
        XCTAssertEqual(mimeRequests.first?.headers["Accept"], "*/*")
    }

    func testACancellationsCalendarComesTheSameWay() async throws {
        let cancel = GraphMIMECalendarTests.ics.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:CANCEL")
        routeBody(event: accessDenied, mime: .bytes(GraphMIMECalendarTests.exchangeMIME(calendar: cancel)),
                  type: "#microsoft.graph.eventMessage")
        let body = try await makeProvider().body(for: "M-EV")
        XCTAssertEqual(body.calendar, cancel)
    }

    /// An event that reads but cannot be shown (no UID, no start: the Calendar Attendant has not put it on the calendar)
    /// leaves the message's calendar too.
    func testAnEventThatCannotBeShownLeavesTheCalendarTheMessageCarries() async throws {
        let noStart = Self.eventMessage().replacingOccurrences(of: #""start": {"dateTime": "2026-11-03T13:00:00.0000000", "timeZone": "UTC"},"#, with: "")
        routeBody(event: .json(noStart), mime: .bytes(GraphMIMECalendarTests.exchangeMIME()))
        let body = try await makeProvider().body(for: "M-EV")
        XCTAssertNil(body.invitation)
        XCTAssertEqual(body.calendar, GraphMIMECalendarTests.ics)
    }

    func testAnEventReadWholeFetchesNoMIME() async throws {
        routeBody(event: .json(Self.eventMessage()), mime: .bytes(GraphMIMECalendarTests.exchangeMIME()))
        let body = try await makeProvider().body(for: "M-EV")
        XCTAssertNotNil(body.invitation)
        XCTAssertNil(body.calendar)
        XCTAssertTrue(mimeRequests.isEmpty)
    }

    func testAResponseToTheOrganizerFetchesNoMIME() async throws {
        routeBody(event: accessDenied, mime: .bytes(GraphMIMECalendarTests.exchangeMIME()), type: "#microsoft.graph.eventMessageResponse")
        let body = try await makeProvider().body(for: "M-EV")
        XCTAssertNil(body.invitation)
        XCTAssertNil(body.calendar)
        XCTAssertTrue(mimeRequests.isEmpty, "a response carries no invitation to show")
    }

    func testAMIMEThatCannotBeReadLeavesTheMessageWithoutACard() async throws {
        routeBody(event: accessDenied, mime: .json(#"{"error": {"code": "ErrorInternalServerError"}}"#, status: 500))
        let body = try await makeProvider().body(for: "M-EV")
        XCTAssertNil(body.invitation)
        XCTAssertNil(body.calendar)
        XCTAssertEqual(body.html, "<p>Monthly look at the roadmap.</p>", "the body is stored all the same")
    }

    func testAThrottledMIMEFailsTheBodySoItIsFetchedAgain() async {
        routeBody(event: accessDenied, mime: .json(#"{"error": {"code": "TooManyRequests"}}"#, status: 429, headers: ["Retry-After": "7"]))
        await expectProviderError({ try await self.makeProvider().body(for: "M-EV") }) { error in
            if case .throttled = error { return true }
            return false
        }
    }

    func testAThrottledEventFailsTheBodySoItIsFetchedAgain() async {
        routeBody(event: .json(#"{"error": {"code": "TooManyRequests"}}"#, status: 429, headers: ["Retry-After": "7"]))
        await expectProviderError({ try await self.makeProvider().body(for: "M-EV") }) { error in
            if case .throttled = error { return true }
            return false
        }
    }

    // MARK: Answering

    private func answer(_ response: InvitationResponse, eventID: String? = "AAMkEVENT=") -> InvitationAnswer {
        InvitationAnswer(response: response, uid: "040000008200E00074C5B7101A82E00800000000A1B2C3D4", title: "Roadmap review",
                         start: now, end: now.addingTimeInterval(3_600),
                         organizer: EmailAddress(name: "Rachel Kim", address: "rachel.kim@northwind.test"),
                         attendee: EmailAddress(name: "Alex Morgan", address: "alex@northwind.test"), graphEventID: eventID)
    }

    func testAnAnswerNeedsCalendarsReadWrite() async {
        let change = MetadataChange.answerInvitation(answer(.accepted))
        tokens.scopes = OAuthEndpoints.microsoftScope
        let without = await makeProvider().missingPermission(for: change)
        XCTAssertEqual(without, .calendar)
        tokens.scopes = "Mail.ReadWrite Mail.Send User.Read Calendars.ReadWrite profile openid"
        let short = await makeProvider().missingPermission(for: change)
        XCTAssertNil(short, "Microsoft lists Graph's scopes without the resource too")
        tokens.scopes = OAuthEndpoints.microsoftScope + " " + OAuthEndpoints.microsoftCalendarScope
        let full = await makeProvider().missingPermission(for: change)
        XCTAssertNil(full)
        tokens.scopes = "Calendars.Read"
        let readOnly = await makeProvider().missingPermission(for: change)
        XCTAssertEqual(readOnly, .calendar, "reading the calendar is not answering")
    }

    /// The event's own answer, as `GET /me/events/{id}?$select=responseStatus,responseRequested` returns it.
    private func eventStatus(_ response: String, responseRequested: Bool? = true) -> Reply {
        let requested = responseRequested.map { #", "responseRequested": \#($0)"# } ?? ""
        return .json(#"{"@odata.etag": "W/\"x\"", "id": "AAMkEVENT=", "responseStatus": {"response": "\#(response)", "time": "0001-01-01T00:00:00Z"}\#(requested)}"#)
    }

    private func isStatusRead(_ request: Request, event: String = "AAMkEVENT=") -> Bool {
        request.method == "GET" && request.path == "/v1.0/me/events/" + event
            && request.query["$select"] == "responseStatus,responseRequested"
    }

    func testEachAnswerIsItsOwnCallOnTheEventAndSendsTheResponse() async throws {
        route { request in
            if self.isStatusRead(request) { return self.eventStatus("notResponded") }
            guard request.method == "POST", request.path.hasPrefix("/v1.0/me/events/AAMkEVENT=/") else { return nil }
            return .status(202)
        }
        for response in InvitationResponse.answers {
            try await makeProvider().apply(.answerInvitation(answer(response)), to: ["M-EV"])
        }
        let posts = requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.map(\.path), [
            "/v1.0/me/events/AAMkEVENT=/accept", "/v1.0/me/events/AAMkEVENT=/tentativelyAccept", "/v1.0/me/events/AAMkEVENT=/decline",
        ])
        XCTAssertEqual(requests.filter { self.isStatusRead($0) }.count, 3, "the event's own answer is read before each")
        for request in posts {
            XCTAssertEqual(request.json()["sendResponse"] as? Bool, true, "Exchange answers the organizer")
            XCTAssertEqual(request.header("Content-Type"), "application/json")
        }
    }

    /// The outbox retries an answer whose reply was lost although Exchange took it. Each POST mails the organizer, so an
    /// event that already states the answer is not answered again.
    func testAnEventThatAlreadyStatesTheAnswerIsNotAnsweredAgain() async throws {
        route { request in
            if self.isStatusRead(request) { return self.eventStatus("tentativelyAccepted") }
            return nil
        }
        try await makeProvider().apply(.answerInvitation(answer(.tentative)), to: ["M-EV"])
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" }, "no second response to the organizer")
        XCTAssertEqual(requests.count, 1)
    }

    func testWithoutAStoredEventTheAnswerLooksItUpFromTheMessage() async throws {
        route { request in
            if request.method == "GET", request.path == "/v1.0/me/messages/M-EV", request.query["$expand"] != nil {
                return .json(Self.eventMessage())
            }
            if self.isStatusRead(request) { return self.eventStatus("none") }
            if request.method == "POST", request.path == "/v1.0/me/events/AAMkEVENT=/accept" { return .status(202) }
            return nil
        }
        try await makeProvider().apply(.answerInvitation(answer(.accepted, eventID: nil)), to: ["M-EV"])
        XCTAssertEqual(requests.map(\.path), ["/v1.0/me/messages/M-EV", "/v1.0/me/events/AAMkEVENT=", "/v1.0/me/events/AAMkEVENT=/accept"])
    }

    /// An event that is gone (deleted on the phone without an answer, or the cancelled meeting removed) was answered by
    /// no one: the answer fails as not found, which the outbox gives up at once so the card puts the previous one back.
    func testAnAnswerToAnEventThatIsGoneFailsAsNotFound() async {
        route { request in
            if self.isStatusRead(request) { return self.eventStatus("notResponded") }
            guard request.method == "POST" else { return nil }
            return .json(Fixtures.notFoundError, status: 404)
        }
        await expectProviderError({ try await self.makeProvider().apply(.answerInvitation(self.answer(.accepted)), to: ["M-EV"]) }) { error in
            if case .notFound = error { return true }
            return false
        }
        StubURLProtocol.reset()
        route { request in
            if request.method == "GET", request.path == "/v1.0/me/messages/M-EV" { return .json(Fixtures.notFoundError, status: 404) }
            return nil
        }
        await expectProviderError({
            try await self.makeProvider().apply(.answerInvitation(self.answer(.tentative, eventID: nil)), to: ["M-EV"])
        }) { error in
            if case .notFound = error { return true }
            return false
        }
        XCTAssertEqual(requests.count, 1, "the event message is gone too: nothing to answer through")
    }

    /// Exchange removes the event a decline answers, so a retry of a decline that landed finds it gone: done, since the
    /// meeting is off the user's calendar either way.
    func testADeclineOfAnEventThatIsGoneIsDone() async throws {
        route { request in
            if self.isStatusRead(request) { return .json(Fixtures.notFoundError, status: 404) }
            return nil
        }
        try await makeProvider().apply(.answerInvitation(answer(.declined)), to: ["M-EV"])
        XCTAssertEqual(requests.count, 1)
    }

    /// An organizer who asked for no replies gets none: the answer still lands on the user's calendar, on both routes.
    func testAnOrganizerWhoAskedForNoRepliesGetsNone() async throws {
        for requested in [false, true, nil] as [Bool?] {
            StubURLProtocol.reset()
            route { request in
                if self.isStatusRead(request) { return self.eventStatus("notResponded", responseRequested: requested) }
                if request.method == "POST", request.path == "/v1.0/me/events/AAMkEVENT=/accept" { return .status(202) }
                return nil
            }
            try await makeProvider().apply(.answerInvitation(answer(.accepted)), to: ["M-EV"])
            let post = try XCTUnwrap(requests.first { $0.method == "POST" })
            XCTAssertEqual(post.json()["sendResponse"] as? Bool, requested != false, "responseRequested \(String(describing: requested))")
        }
    }

    /// An answer given from the calendar names no message: it answers the occurrence, or the series master for All
    /// Events, by the id it carries.
    func testAnAnswerFromTheCalendarAnswersTheEventItNames() async throws {
        for event in ["AAMkOCCURRENCE=", "AAMkMASTER="] {
            StubURLProtocol.reset()
            route { request in
                if self.isStatusRead(request, event: event) { return self.eventStatus("notResponded", responseRequested: false) }
                if request.method == "POST", request.path == "/v1.0/me/events/\(event)/tentativelyAccept" { return .status(202) }
                return nil
            }
            var queued = answer(.tentative, eventID: nil)
            queued.calendar = CalendarCopies(scope: .event(id: "acct|x"), providerEventID: event)
            try await makeProvider().apply(.answerInvitation(queued), to: [])
            XCTAssertEqual(requests.map(\.path), ["/v1.0/me/events/\(event)", "/v1.0/me/events/\(event)/tentativelyAccept"])
            XCTAssertEqual(requests.last?.json()["sendResponse"] as? Bool, false)
        }
    }

    /// A decline from the calendar of an event Exchange already took off (it removes what a decline answers) is done.
    func testADeclineFromTheCalendarOfAnEventThatIsGoneIsDone() async throws {
        route { request in
            if self.isStatusRead(request, event: "AAMkGONE=") { return .json(Fixtures.notFoundError, status: 404) }
            return nil
        }
        var queued = answer(.declined, eventID: nil)
        queued.calendar = CalendarCopies(scope: .event(id: "acct|x"), providerEventID: "AAMkGONE=")
        try await makeProvider().apply(.answerInvitation(queued), to: [])
        XCTAssertEqual(requests.count, 1)
    }

    func testAServerFailureFailsTheAnswerSoTheOutboxTriesAgain() async {
        route { request in
            if self.isStatusRead(request) { return self.eventStatus("notResponded") }
            guard request.method == "POST" else { return nil }
            return .json(#"{"error": {"code": "ErrorInternalServerError", "message": "boom"}}"#, status: 500)
        }
        await expectProviderError({ try await self.makeProvider().apply(.answerInvitation(self.answer(.accepted)), to: ["M-EV"]) }) { error in
            if case .server(let status, _) = error { return status == 500 }
            return false
        }
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
