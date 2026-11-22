import Foundation
import PaperCore
import XCTest
@testable import PaperGmail

/// Gmail and invitations (docs/ARCHITECTURE.md, "Calendar invitations"): the MIME walk keeps the text/calendar part
/// for the sync-time reader, and an answer marks the user's own Google Calendar copy through the Calendar API, then
/// mails the organizer an iMIP reply, behind the calendar.events scope. Every request goes to the stub server.
final class GmailInvitationTests: XCTestCase {
    private let server = StubServer.shared

    override func setUp() {
        super.setUp()
        server.reset()
    }

    override func tearDown() {
        server.reset()
        super.tearDown()
    }

    static let ics = """
        BEGIN:VCALENDAR\r
        METHOD:REQUEST\r
        BEGIN:VEVENT\r
        UID:5h0v6l1b@google.com\r
        DTSTART:20261110T150000Z\r
        DTEND:20261110T160000Z\r
        SUMMARY:Design review\r
        ORGANIZER;CN=Ben Carter:mailto:ben@contoso.test\r
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:ada@example.com\r
        END:VEVENT\r
        END:VCALENDAR\r

        """

    /// A Google Calendar invitation: the calendar as the last alternative, inline, and again as invite.ics.
    private func googleInvitation(calendarInline: Bool = true, calendarFileOnly: Bool = false) -> String {
        let calendar = Base64URL.encode(Data(Self.ics.utf8))
        let calendarPart = calendarInline
            ? #"{"partId": "0.2", "mimeType": "text/calendar", "filename": "", "headers": [{"name": "Content-Type", "value": "text/calendar; charset=\"UTF-8\"; method=REQUEST"}], "body": {"size": 300, "data": "\#(calendar)"}}"#
            : #"{"partId": "0.2", "mimeType": "text/calendar", "filename": "", "headers": [], "body": {"size": 300, "attachmentId": "ATT_CAL_PART"}}"#
        let alternatives = [
            #"{"partId": "0.0", "mimeType": "text/plain", "filename": "", "headers": [], "body": {"size": 5, "data": "\#(Base64URL.encode(Data("Hello".utf8)))"}}"#,
            #"{"partId": "0.1", "mimeType": "text/html", "filename": "", "headers": [], "body": {"size": 12, "data": "\#(Base64URL.encode(Data("<p>Hello</p>".utf8)))"}}"#,
        ] + (calendarFileOnly ? [] : [calendarPart])
        return """
            {"id": "inv1", "threadId": "t9", "labelIds": ["INBOX"], "historyId": "1", "internalDate": "1730462400000",
             "payload": {"partId": "", "mimeType": "multipart/mixed", "filename": "", "headers": [], "body": {"size": 0}, "parts": [
               {"partId": "0", "mimeType": "multipart/alternative", "filename": "", "headers": [], "body": {"size": 0},
                "parts": [\(alternatives.joined(separator: ","))]},
               {"partId": "1", "mimeType": "application/ics", "filename": "invite.ics",
                "headers": [{"name": "Content-Disposition", "value": "attachment; filename=\\"invite.ics\\""}],
                "body": {"size": 300, "attachmentId": "ATT_INVITE_ICS"}}
             ]}}
            """
    }

    // MARK: Sync time

    func testTheCalendarAlternativeIsKeptForTheReaderAndTheFileStaysListed() async throws {
        server.on("GET", "/users/me/messages/inv1", .json(googleInvitation()))
        let body = try await TestSupport.makeProvider().body(for: "inv1")
        XCTAssertEqual(body.calendar, Self.ics)
        XCTAssertEqual(body.html, "<p>Hello</p>", "the calendar never joins the HTML or text")
        XCTAssertEqual(body.text, "Hello")
        XCTAssertEqual(body.attachments.map(\.filename), ["invite.ics"], "the file stays a chip")
        XCTAssertTrue(server.requests(to: "/attachments/ATT_INVITE_ICS").isEmpty, "the inline part needs no fetch")
    }

    func testAnExternalizedCalendarPartIsFetchedWithTheBody() async throws {
        server.on("GET", "/users/me/messages/inv1", .json(googleInvitation(calendarInline: false)))
        server.on("GET", "/users/me/messages/inv1/attachments/ATT_CAL_PART",
                  .json(#"{"size": 300, "data": "\#(Base64URL.encode(Data(Self.ics.utf8)))"}"#))
        let body = try await TestSupport.makeProvider().body(for: "inv1")
        XCTAssertEqual(body.calendar, Self.ics)
    }

    func testAnInvitationSentOnlyAsAFileIsReadFromTheFile() async throws {
        server.on("GET", "/users/me/messages/inv1", .json(googleInvitation(calendarFileOnly: true)))
        server.on("GET", "/users/me/messages/inv1/attachments/ATT_INVITE_ICS",
                  .json(#"{"size": 300, "data": "\#(Base64URL.encode(Data(Self.ics.utf8)))"}"#))
        let body = try await TestSupport.makeProvider().body(for: "inv1")
        XCTAssertEqual(body.calendar, Self.ics)
        XCTAssertEqual(body.attachments.map(\.filename), ["invite.ics"])
    }

    /// A calendar file far larger than the reader reads (a term's timetable, a calendar export) is no invitation:
    /// it stays a chip and is never downloaded with the body.
    func testALargeCalendarFileIsNotFetchedWithTheBody() async throws {
        let large = googleInvitation(calendarFileOnly: true)
            .replacingOccurrences(of: #""size": 300, "attachmentId": "ATT_INVITE_ICS""#, with: #""size": 40000000, "attachmentId": "ATT_INVITE_ICS""#)
        server.on("GET", "/users/me/messages/inv1", .json(large))
        let body = try await TestSupport.makeProvider().body(for: "inv1")
        XCTAssertNil(body.calendar)
        XCTAssertEqual(body.text, "Hello")
        XCTAssertEqual(body.attachments.map(\.filename), ["invite.ics"], "still offered as a file")
        XCTAssertTrue(server.requests(to: "/attachments/ATT_INVITE_ICS").isEmpty)
    }

    /// The calendar is an extra: a request for it that fails the way a retry would not mend leaves the body without a
    /// card; one the next request would meet too (the network, a throttle) fails the fetch so it is tried again.
    func testACalendarThatCannotBeFetchedLeavesTheBodyWithoutACard() async throws {
        server.on("GET", "/users/me/messages/inv1", .json(googleInvitation(calendarFileOnly: true)))
        server.on("GET", "/users/me/messages/inv1/attachments/ATT_INVITE_ICS",
                  .json(#"{"error": {"code": 500, "message": "backend"}}"#, status: 500))
        let body = try await TestSupport.makeProvider().body(for: "inv1")
        XCTAssertNil(body.calendar)
        XCTAssertEqual(body.html, "<p>Hello</p>", "the message keeps its body")

        server.on("GET", "/users/me/messages/inv1/attachments/ATT_INVITE_ICS", .failure(URLError(.notConnectedToInternet)))
        do {
            _ = try await TestSupport.makeProvider().body(for: "inv1")
            XCTFail("expected a network failure")
        } catch {
            guard case .network? = error as? ProviderError else { return XCTFail("\(error)") }
        }
    }

    func testAMessageWithoutACalendarHasNone() throws {
        let body = GmailBodyParser.body(from: try JSONDecoder().decode(GmailMessage.self, from: Data(GmailFixtures.fullMessage.utf8)))
        XCTAssertNil(body.calendar)
    }

    // MARK: Answering

    private let answer = InvitationAnswer(
        response: .accepted, uid: "5h0v6l1b@google.com", sequence: 2,
        title: "Design review", start: ISO8601DateFormatter().date(from: "2026-11-10T15:00:00Z")!,
        end: ISO8601DateFormatter().date(from: "2026-11-10T16:00:00Z")!,
        organizer: EmailAddress(name: "Ben Carter", address: "ben@contoso.test"),
        attendee: EmailAddress(name: "Ada Lovelace", address: "ada@example.com")
    )

    private let granted = OAuthEndpoints.googleScope + " " + OAuthEndpoints.googleCalendarScope

    private func provider(scopes: String? = nil) -> GmailProvider {
        TestSupport.makeProvider(tokens: FakeTokenProvider(scopes: scopes ?? granted))
    }

    private let calendarCopy = """
        {"kind": "calendar#events", "items": [
          {"id": "series1", "iCalUID": "5h0v6l1b@google.com", "status": "confirmed",
           "attendees": [
             {"email": "ben@contoso.test", "organizer": true, "responseStatus": "accepted"},
             {"email": "ada@example.com", "self": true, "responseStatus": "needsAction", "comment": "kept"},
             {"email": "room@resource.calendar.google.com", "resource": true, "responseStatus": "accepted"}
           ]}
        ]}
        """

    func testAnAnswerNeedsTheCalendarScope() async {
        let change = MetadataChange.answerInvitation(answer)
        let without = await provider(scopes: OAuthEndpoints.googleScope).missingPermission(for: change)
        XCTAssertEqual(without, .calendar)
        let unknown = await TestSupport.makeProvider().missingPermission(for: change)
        XCTAssertEqual(unknown, .calendar, "a token whose scopes are unknown grants nothing")
        let with = await provider().missingPermission(for: change)
        XCTAssertNil(with)
        let archive = await provider(scopes: OAuthEndpoints.googleScope).missingPermission(for: .archive)
        XCTAssertNil(archive, "mail changes need nothing more")
    }

    func testAnAnswerMarksTheCalendarCopyThenMailsTheOrganizerAnIMIPReply() async throws {
        server.on("GET", "/calendar/v3/calendars/primary/events", .json(calendarCopy))
        server.on("PATCH", "/calendar/v3/calendars/primary/events/series1", .json(#"{"id": "series1"}"#))
        server.on("POST", "/users/me/messages/send", .json(GmailFixtures.sendResponse))

        try await provider().apply(.answerInvitation(answer), to: ["inv1", "inv2"])

        let paths = server.requests.map(\.path)
        XCTAssertEqual(paths, ["/calendar/v3/calendars/primary/events", "/calendar/v3/calendars/primary/events/series1",
                               "/gmail/v1/users/me/messages/send"], "the copy first, then one mail however many copies were named")
        let list = try XCTUnwrap(server.requests(to: "/calendar/v3/calendars/primary/events").first)
        XCTAssertEqual(list.url.host, "www.googleapis.com")
        XCTAssertEqual(list.query["iCalUID"], ["5h0v6l1b@google.com"])
        let patch = try XCTUnwrap(server.requests(to: "/events/series1").first)
        XCTAssertEqual(patch.method, "PATCH")
        XCTAssertEqual(patch.query["sendUpdates"], ["none"], "the iMIP reply is what tells the organizer")
        let attendees = try XCTUnwrap(patch.jsonBody["attendees"] as? [[String: Any]])
        XCTAssertEqual(attendees.count, 3, "a patch replaces the list, so every entry goes back")
        XCTAssertEqual(attendees[1]["responseStatus"] as? String, "accepted")
        XCTAssertEqual(attendees[1]["comment"] as? String, "kept", "fields it does not know go back as they came")
        XCTAssertEqual(attendees[0]["responseStatus"] as? String, "accepted")

        let send = try XCTUnwrap(server.requests(to: "/users/me/messages/send").first)
        XCTAssertNil(send.jsonBody["threadId"])
        let mime = String(decoding: try XCTUnwrap(Base64URL.decode(try XCTUnwrap(send.jsonBody["raw"] as? String))), as: UTF8.self)
        XCTAssertTrue(mime.contains("From: Ada Lovelace <ada@example.com>\r\n"))
        XCTAssertTrue(mime.contains("To: Ben Carter <ben@contoso.test>\r\n"))
        XCTAssertTrue(mime.contains("Subject: Accepted: Design review\r\n"))
        XCTAssertTrue(mime.contains("Content-Type: text/calendar; charset=\"UTF-8\"; method=REPLY\r\n"))
        let calendar = try XCTUnwrap(Self.decodedPart("text/calendar", in: mime))
        XCTAssertTrue(calendar.contains("METHOD:REPLY\r\n"))
        XCTAssertTrue(calendar.contains("UID:5h0v6l1b@google.com\r\n"))
        XCTAssertTrue(calendar.contains("SEQUENCE:2\r\n"))
        XCTAssertTrue(calendar.contains("ORGANIZER;CN=Ben Carter:mailto:ben@contoso.test\r\n"))
        XCTAssertTrue(calendar.contains("ATTENDEE;CN=Ada Lovelace;PARTSTAT=ACCEPTED:mailto:ada@example.com\r\n"))
        XCTAssertTrue(calendar.contains("DTSTART:20261110T150000Z\r\n"))
        let text = try XCTUnwrap(Self.decodedPart("text/plain", in: mime))
        XCTAssertEqual(text, "Ada Lovelace has accepted this invitation.")
    }

    /// Invited at an alias, the user is not matched at sync time (no recipient is taken for them), so the answer names
    /// the account. Their own calendar copy knows the alias as them (`self`), and the reply names that address.
    func testTheReplyNamesTheAddressTheUsersCalendarCopyKnowsThemBy() async throws {
        var fromAccount = answer
        fromAccount.attendee = EmailAddress(name: "Ada", address: "ada.account@example.com")
        server.on("GET", "/calendar/v3/calendars/primary/events", .json(calendarCopy))
        server.on("PATCH", "/calendar/v3/calendars/primary/events/series1", .json(#"{"id": "series1"}"#))
        server.on("POST", "/users/me/messages/send", .json(GmailFixtures.sendResponse))

        try await provider().apply(.answerInvitation(fromAccount), to: ["inv1"])

        let send = try XCTUnwrap(server.requests(to: "/users/me/messages/send").first)
        let mime = String(decoding: try XCTUnwrap(Base64URL.decode(try XCTUnwrap(send.jsonBody["raw"] as? String))), as: UTF8.self)
        XCTAssertTrue(mime.contains("From: Ada <ada@example.com>\r\n"), mime)
        let calendar = try XCTUnwrap(Self.decodedPart("text/calendar", in: mime))
        XCTAssertTrue(calendar.contains("ATTENDEE;CN=Ada;PARTSTAT=ACCEPTED:mailto:ada@example.com\r\n"), calendar)
        XCTAssertFalse(calendar.contains("ada.account@"))
    }

    func testWithoutACalendarCopyTheMailStillGoes() async throws {
        server.on("GET", "/calendar/v3/calendars/primary/events", .json(#"{"items": []}"#))
        server.on("POST", "/users/me/messages/send", .json(GmailFixtures.sendResponse))
        try await provider().apply(.answerInvitation(answer), to: ["inv1"])
        XCTAssertEqual(server.requests.map(\.method), ["GET", "POST"])
    }

    func testACalendarTheClientCannotReachIsSkippedAndTheMailStillGoes() async throws {
        server.on("GET", "/calendar/v3/calendars/primary/events",
                  .json(#"{"error": {"code": 403, "message": "Google Calendar API has not been used in project 1 before or it is disabled.", "errors": [{"reason": "accessNotConfigured"}]}}"#, status: 403))
        server.on("POST", "/users/me/messages/send", .json(GmailFixtures.sendResponse))
        try await provider().apply(.answerInvitation(answer), to: ["inv1"])
        XCTAssertEqual(server.requests(to: "/users/me/messages/send").count, 1)
    }

    func testAnAnswerAlreadyOnTheCopyIsNotPatchedAgain() async throws {
        server.on("GET", "/calendar/v3/calendars/primary/events",
                  .json(calendarCopy.replacingOccurrences(of: "\"needsAction\", \"comment\"", with: "\"accepted\", \"comment\"")))
        server.on("POST", "/users/me/messages/send", .json(GmailFixtures.sendResponse))
        try await provider().apply(.answerInvitation(answer), to: ["inv1"])
        XCTAssertTrue(server.requests.allSatisfy { $0.method != "PATCH" })
    }

    func testAnAnswerToOneOccurrencePatchesThatOccurrenceOnly() async throws {
        var occurrence = answer
        occurrence.recurrenceID = ISO8601DateFormatter().date(from: "2026-11-17T15:00:00Z")
        server.on("GET", "/calendar/v3/calendars/primary/events", .json("""
            {"items": [
              {"id": "series1", "attendees": [{"email": "ada@example.com", "self": true, "responseStatus": "needsAction"}]},
              {"id": "series1_20261117T150000Z", "recurringEventId": "series1",
               "originalStartTime": {"dateTime": "2026-11-17T16:00:00+01:00"},
               "attendees": [{"email": "ada@example.com", "self": true, "responseStatus": "needsAction"}]}
            ]}
            """))
        server.on("PATCH", "/events/series1_20261117T150000Z", .json(#"{"id": "x"}"#))
        server.on("POST", "/users/me/messages/send", .json(GmailFixtures.sendResponse))
        try await provider().apply(.answerInvitation(occurrence), to: ["inv1"])
        XCTAssertEqual(server.requests.filter { $0.method == "PATCH" }.map(\.path), ["/calendar/v3/calendars/primary/events/series1_20261117T150000Z"])
        let mime = String(decoding: try XCTUnwrap(Base64URL.decode(try XCTUnwrap(server.requests(to: "/messages/send").first?.jsonBody["raw"] as? String))), as: UTF8.self)
        XCTAssertTrue(try XCTUnwrap(Self.decodedPart("text/calendar", in: mime)).contains("RECURRENCE-ID:20261117T150000Z\r\n"))
    }

    /// The reply's Message-ID comes from the answer, so the outbox's retry of a send whose reply was lost (Gmail took
    /// it) finds that message in the mailbox and does not mail the organizer again.
    func testARetryAfterASendWhoseReplyWasLostDoesNotMailTheOrganizerAgain() async throws {
        var once = answer
        once.replyID = "3f2c9a4e-1b7d-4c55-9e0a-6d8f2b1c7e90"
        let sent = SentLog()
        server.on("GET", "/calendar/v3/calendars/primary/events", .json(#"{"items": []}"#))
        server.on("GET", "/users/me/messages") { request in
            let query = request.query["q"]?.first ?? ""
            return .json(sent.contains(query) ? #"{"messages": [{"id": "sent-1", "threadId": "t1"}], "resultSizeEstimate": 1}"#
                                              : #"{"resultSizeEstimate": 0}"#)
        }
        server.on("POST", "/users/me/messages/send") { request in
            let raw = String(decoding: Base64URL.decode(request.jsonBody["raw"] as? String ?? "") ?? Data(), as: UTF8.self)
            sent.record(raw)
            // Gmail sent it, but the reply never arrives.
            return .failure(URLError(.networkConnectionLost))
        }

        do {
            try await provider().apply(.answerInvitation(once), to: ["inv1"])
            XCTFail("expected the lost reply to fail the answer")
        } catch {
            guard case .network? = error as? ProviderError else { return XCTFail("\(error)") }
        }
        try await provider().apply(.answerInvitation(once), to: ["inv1"])

        XCTAssertEqual(server.requests(to: "/users/me/messages/send").count, 1, "one mail to the organizer")
        let searches = server.requests.filter { $0.path.hasSuffix("/users/me/messages") }
        XCTAssertEqual(searches.count, 2, "each attempt looks before it mails")
        XCTAssertEqual(searches.first?.query["q"], ["rfc822msgid:invitation-reply-3f2c9a4e-1b7d-4c55-9e0a-6d8f2b1c7e90@example.com"])
        XCTAssertEqual(searches.first?.query["includeSpamTrash"], ["true"])
        let mime = try XCTUnwrap(sent.messages.first)
        XCTAssertTrue(mime.contains("Message-ID: <invitation-reply-3f2c9a4e-1b7d-4c55-9e0a-6d8f2b1c7e90@example.com>\r\n"), mime)
    }

    func testAnAnswerFromTheEngineCarriesAReplyIDOfItsOwn() throws {
        let invitation = CalendarInvitation(
            method: .request, uid: "u", title: "t", start: Date(), end: Date(),
            organizer: CalendarInvitation.Person(address: "ben@contoso.test"),
            attendees: [CalendarInvitation.Person(address: "ada@example.com")], userAddress: "ada@example.com"
        )
        let first = try XCTUnwrap(InvitationAnswer(.accepted, to: invitation, accountEmail: "ada@example.com", accountName: nil, previous: nil))
        let second = try XCTUnwrap(InvitationAnswer(.accepted, to: invitation, accountEmail: "ada@example.com", accountName: nil, previous: nil))
        XCTAssertNotNil(first.replyID)
        XCTAssertNotEqual(first.replyID, second.replyID, "each answer the user gives is its own message")
        XCTAssertNotNil(GmailProvider.replyMessageID(try XCTUnwrap(first.replyID), from: "ada@example.com"))
        XCTAssertNil(GmailProvider.replyMessageID("a>b@c", from: "ada@example.com"), "only the plain token this app makes")
    }

    func testAFailedMailFailsTheAnswerSoTheOutboxTriesAgain() async {
        server.on("GET", "/calendar/v3/calendars/primary/events", .json(#"{"items": []}"#))
        server.on("POST", "/users/me/messages/send", .json(#"{"error": {"code": 500, "message": "backend"}}"#, status: 500))
        do {
            try await provider().apply(.answerInvitation(answer), to: ["inv1"])
            XCTFail("expected a failure")
        } catch {
            guard case .server(let status, _)? = error as? ProviderError else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 500)
        }
    }

    func testAThrottledCalendarCallFailsTheAnswerBeforeAnyMail() async {
        server.on("GET", "/calendar/v3/calendars/primary/events", .json(#"{"error": {"code": 429, "message": "slow down"}}"#, status: 429))
        do {
            try await provider().apply(.answerInvitation(answer), to: ["inv1"])
            XCTFail("expected a throttle")
        } catch {
            guard case .throttled? = error as? ProviderError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(server.requests(to: "/users/me/messages/send").isEmpty)
    }

    /// The decoded text of the first part of `type` in a MIME message whose parts are base64, as MIMEBuilder writes.
    static func decodedPart(_ type: String, in mime: String) -> String? {
        guard let header = mime.range(of: "Content-Type: \(type);") else { return nil }
        guard let start = mime.range(of: "\r\n\r\n", range: header.upperBound..<mime.endIndex) else { return nil }
        let rest = mime[start.upperBound...]
        let end = rest.range(of: "\r\n--")?.lowerBound ?? rest.endIndex
        let base64 = rest[..<end].replacingOccurrences(of: "\r\n", with: "")
        return Data(base64Encoded: base64).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// The raw messages a stubbed `messages.send` received, and the `rfc822msgid:` queries that find them.
private final class SentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var raws: [String] = []

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return raws
    }

    func record(_ raw: String) {
        lock.lock(); defer { lock.unlock() }
        raws.append(raw)
    }

    func contains(_ query: String) -> Bool {
        guard query.hasPrefix("rfc822msgid:") else { return false }
        let id = query.dropFirst("rfc822msgid:".count)
        return messages.contains { $0.contains("Message-ID: <\(id)>\r\n") }
    }
}
