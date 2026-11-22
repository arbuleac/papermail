import Foundation
import PaperCore
import XCTest
@testable import PaperGmail

/// Google Calendar for the day column and the week (docs/ARCHITECTURE.md, "Calendar"): the window read from the
/// primary calendar page by page, how each event maps, the create and delete of time set aside for a mail, and the
/// Calendar API's refusals. Every request goes to the stub server.
final class GmailCalendarTests: XCTestCase {
    private let server = StubServer.shared
    private let eventsPath = "/calendar/v3/calendars/primary/events"
    private let granted = OAuthEndpoints.googleScope + " " + OAuthEndpoints.googleCalendarScope
    private let account = TestSupport.accountID

    override func setUp() {
        super.setUp()
        server.reset()
    }

    override func tearDown() {
        server.reset()
        super.tearDown()
    }

    /// An address with a `+`, which a link must escape.
    private let address = "ada+work@example.com"

    private func provider(tokens: FakeTokenProvider? = nil, accountEmail: String? = nil) -> GmailProvider {
        TestSupport.makeProvider(tokens: tokens ?? FakeTokenProvider(scopes: granted), accountEmail: accountEmail)
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private var window: DateInterval {
        DateInterval(start: date("2026-11-04T22:00:00Z"), end: date("2026-12-30T22:00:00Z"))
    }

    /// Both pages, the second answered only when the first's token is asked for.
    private func stubBothPages() {
        server.on("GET", eventsPath) { request in
            request.query["pageToken"] == ["CiAKGjBpNDd2Nmp2Zml2cXRwYjBpOXA"]
                ? .json(GoogleCalendarFixtures.lastPage)
                : .json(GoogleCalendarFixtures.firstPage)
        }
    }

    private func readAll() async throws -> CalendarListing {
        stubBothPages()
        return try await provider().calendarEvents(in: window)
    }

    private func event(_ providerID: String, in listing: CalendarListing) throws -> CalendarEvent {
        try XCTUnwrap(listing.events.first { $0.providerID == providerID }, "\(providerID) is missing")
    }

    /// What a call threw, whatever its type.
    private func thrown(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            XCTFail("expected an error")
            return nil
        } catch {
            return error
        }
    }

    // MARK: Permission

    func testThePermissionIsReadFromTheTokensScopesWithoutARequest() async {
        let with = await provider().hasCalendarPermission()
        XCTAssertTrue(with)
        let mailOnly = await provider(tokens: FakeTokenProvider(scopes: OAuthEndpoints.googleScope)).hasCalendarPermission()
        XCTAssertFalse(mailOnly)
        let unknown = await provider(tokens: FakeTokenProvider(scopes: nil)).hasCalendarPermission()
        XCTAssertFalse(unknown, "a token whose scopes are unknown grants nothing")
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: Reading the window

    func testTheWindowIsReadFromThePrimaryCalendarAPageAtATime() async throws {
        let listing = try await readAll()

        let pages = server.requests(to: eventsPath)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(listing.requestCount, 2, "one request per page, charged to the Calendar API's own quota")
        for page in pages {
            XCTAssertEqual(page.method, "GET")
            XCTAssertEqual(page.url.host, "www.googleapis.com")
            XCTAssertEqual(page.query["timeMin"], ["2026-11-04T22:00:00Z"])
            XCTAssertEqual(page.query["timeMax"], ["2026-12-30T22:00:00Z"])
            XCTAssertEqual(page.query["singleEvents"], ["true"], "Google expands repeats; the app never does")
            XCTAssertEqual(page.query["orderBy"], ["startTime"])
            XCTAssertEqual(page.query["showDeleted"], ["false"])
            XCTAssertEqual(page.query["maxResults"], ["2500"], "the most Google gives a page: one request for a busy window")
            XCTAssertEqual(page.query["prettyPrint"], ["false"], "no indentation to download and parse")
            XCTAssertEqual(page.query["fields"], [GmailProvider.calendarFields])
            XCTAssertEqual(page.header("Authorization"), "Bearer token-1")
        }
        XCTAssertNil(pages[0].query["pageToken"])
        XCTAssertEqual(pages[1].query["pageToken"], ["CiAKGjBpNDd2Nmp2Zml2cXRwYjBpOXA"])
        XCTAssertEqual(listing.events.map(\.providerID), [
            "7k2m4n6p8r0t2v4x6z8b0d2f4h", "zoomcall0001", "alldayown001", "holiday00001", "declined0001", "unanswered01",
            "absence00001", "focus0000001", "0123456789abcdef0123456789abcdef", "freeevent001", "untitled0001",
        ])
        for event in listing.events {
            XCTAssertEqual(event.id, CalendarEvent.localID(accountID: account, providerID: try XCTUnwrap(event.providerID)))
            XCTAssertEqual(event.accountID, account)
            XCTAssertEqual(event.sync, .synced)
            XCTAssertNil(event.sourceMessage)
        }
    }

    func testTheFieldsMaskAsksForEverythingTheMapperReads() {
        for field in ["id", "status", "summary", "location", "start", "end", "transparency", "attendees(self,responseStatus)",
                      "organizer(self,displayName,email)", "hangoutLink", "conferenceData(entryPoints(entryPointType,uri))",
                      "htmlLink", "iCalUID", "updated", "eventType", "extendedProperties/private"] {
            XCTAssertTrue(GmailProvider.calendarFields.contains(field), field)
        }
        XCTAssertTrue(GmailProvider.calendarFields.hasPrefix("items("))
        XCTAssertTrue(GmailProvider.calendarFields.hasSuffix("),nextPageToken"))
    }

    func testAnEmptyWindowIsOneRequest() async throws {
        server.on("GET", eventsPath, .json(GoogleCalendarFixtures.emptyPage))
        let listing = try await provider().calendarEvents(in: window)
        XCTAssertTrue(listing.events.isEmpty)
        XCTAssertEqual(listing.requestCount, 1)
    }

    func testAListingThatNeverEndsFailsRatherThanReportPartOfTheWindow() async {
        // Every page names the same next page.
        server.on("GET", eventsPath, .json(GoogleCalendarFixtures.firstPage))
        let error = await thrown { _ = try await self.provider().calendarEvents(in: self.window) }
        guard case .decoding? = error as? ProviderError else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(server.requests(to: eventsPath).count, 2)
    }

    func testAllDayEventsAreHeldAsFloatingUTCMidnightsWithTheirEndExclusive() async throws {
        let listing = try await readAll()

        let day = try event("alldayown001", in: listing)
        XCTAssertTrue(day.isAllDay)
        XCTAssertEqual(day.start, date("2026-11-20T00:00:00Z"))
        XCTAssertEqual(day.end, date("2026-11-21T00:00:00Z"))

        let holiday = try event("holiday00001", in: listing)
        XCTAssertTrue(holiday.isAllDay)
        XCTAssertEqual(holiday.start, date("2026-11-23T00:00:00Z"))
        XCTAssertEqual(holiday.end, date("2026-11-26T00:00:00Z"), "three days, the 26th not among them")
        XCTAssertFalse(holiday.isBusy, "an all-day event marks the day, not its hours")
    }

    func testTimedEventsAreTheInstantsTheirOffsetsName() async throws {
        let listing = try await readAll()

        let bucharest = try event("7k2m4n6p8r0t2v4x6z8b0d2f4h", in: listing)
        XCTAssertFalse(bucharest.isAllDay)
        XCTAssertEqual(bucharest.start, date("2026-11-19T13:00:00Z"))
        XCTAssertEqual(bucharest.end, date("2026-11-19T14:00:00Z"))

        let newYork = try event("zoomcall0001", in: listing)
        XCTAssertEqual(newYork.start, date("2026-11-19T15:30:00Z"))
        XCTAssertEqual(newYork.end, date("2026-11-19T16:15:00Z"))

        let utc = try event("declined0001", in: listing)
        XCTAssertEqual(utc.start, date("2026-11-19T13:00:00Z"))

        let absence = try event("absence00001", in: listing)
        XCTAssertFalse(absence.isAllDay, "a timed absence stays timed, even from midnight to midnight")
        XCTAssertEqual(absence.start, date("2026-11-26T22:00:00Z"))
    }

    func testTheResponseIsTheUsersOwnAnswerOrOrganizerForTheirOwnEvents() async throws {
        let listing = try await readAll()
        let responses = Dictionary(uniqueKeysWithValues: listing.events.map { ($0.providerID ?? "", $0.response) })

        XCTAssertEqual(responses["7k2m4n6p8r0t2v4x6z8b0d2f4h"], .accepted)
        XCTAssertEqual(responses["zoomcall0001"], .tentative)
        XCTAssertEqual(responses["declined0001"], .declined, "kept so a refresh does not bring it back as new")
        XCTAssertEqual(responses["unanswered01"], .needsAction)
        XCTAssertEqual(responses["alldayown001"], .organizer, "organized by the user")
        XCTAssertEqual(responses["0123456789abcdef0123456789abcdef"], .organizer, "no attendees: the user's own")
        XCTAssertEqual(responses["untitled0001"], .accepted)
        XCTAssertFalse(try event("declined0001", in: listing).isShown)
    }

    func testCancelledEventsAndWorkingLocationsAreLeftOutWhileAbsenceAndFocusTimeStay() async throws {
        let listing = try await readAll()
        let ids = Set(listing.events.compactMap(\.providerID))

        XCTAssertFalse(ids.contains("standup_20261120T080000Z"), "a cancelled occurrence")
        XCTAssertFalse(ids.contains("workloc00001"), "where the user works is not time they are busy")
        XCTAssertTrue(ids.contains("absence00001"))
        XCTAssertTrue(ids.contains("focus0000001"))
        XCTAssertTrue(try event("focus0000001", in: listing).isBusy)
    }

    func testAnEventShownAsFreeIsFree() async throws {
        let listing = try await readAll()

        let gym = try event("freeevent001", in: listing)
        XCTAssertTrue(gym.isFree)
        XCTAssertFalse(gym.isBusy)
        XCTAssertFalse(try event("7k2m4n6p8r0t2v4x6z8b0d2f4h", in: listing).isFree, "opaque when Google says nothing")
    }

    func testTheJoinLinkIsMeetsOrTheConferencesVideoEntryWhenItIsAWebAddress() async throws {
        let listing = try await readAll()

        XCTAssertEqual(try event("7k2m4n6p8r0t2v4x6z8b0d2f4h", in: listing).joinURL, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(try event("zoomcall0001", in: listing).joinURL, "https://us02web.zoom.us/j/81234567890",
                       "the video entry, not the first entry")
        XCTAssertNil(try event("untitled0001", in: listing).joinURL, "a link the user clicks never opens another scheme")
        XCTAssertNil(try event("declined0001", in: listing).joinURL)
    }

    /// The window opens only https, so an http link (an on-premises call server, an older link) is never offered as a
    /// Join or Open in that would do nothing.
    func testOnlyHttpsLinksAreKept() async throws {
        server.on("GET", eventsPath, .json(#"""
        {"items": [
          {"id": "plainhttp001", "status": "confirmed", "start": {"dateTime": "2026-11-19T09:00:00Z"},
           "end": {"dateTime": "2026-11-19T09:30:00Z"}, "hangoutLink": "http://meet.example.test/abc",
           "htmlLink": "http://www.google.com/calendar/event?eid=cGxhaW5odHRwMDAx"},
          {"id": "httpthenvid1", "status": "confirmed", "start": {"dateTime": "2026-11-19T10:00:00Z"},
           "end": {"dateTime": "2026-11-19T10:30:00Z"}, "hangoutLink": "http://meet.example.test/abc",
           "conferenceData": {"entryPoints": [{"entryPointType": "video", "uri": "https://us02web.zoom.us/j/1"}]}}
        ]}
        """#))
        let listing = try await provider().calendarEvents(in: window)

        let plain = try event("plainhttp001", in: listing)
        XCTAssertNil(plain.joinURL)
        XCTAssertNil(plain.webURL)
        XCTAssertEqual(try event("httpthenvid1", in: listing).joinURL, "https://us02web.zoom.us/j/1", "the next candidate that is https")
    }

    func testTheEventKeepsItsLinkOrganizerUIDAndWhenItChanged() async throws {
        let listing = try await readAll()

        let review = try event("7k2m4n6p8r0t2v4x6z8b0d2f4h", in: listing)
        XCTAssertEqual(review.title, "Design review")
        XCTAssertEqual(review.location, "Room 4")
        XCTAssertEqual(review.webURL, "https://www.google.com/calendar/event?eid=N2sybTRuNnA4cjB0MnY0eDZ6OGIwZDJmNGggYWRhQGV4YW1wbGUuY29t")
        XCTAssertEqual(review.organizer, "Ben Carter")
        XCTAssertEqual(review.invitationUID, "5h0v6l1b@google.com")
        XCTAssertEqual(try XCTUnwrap(review.updatedAt).timeIntervalSince(date("2026-11-18T09:12:44Z")), 0.123, accuracy: 0.0005)
        XCTAssertNil(review.clientKey)

        XCTAssertEqual(try event("zoomcall0001", in: listing).organizer, "carol@fabrikam.test", "the address when no name")
        XCTAssertNil(try event("alldayown001", in: listing).organizer, "nil when the user organized it")
        XCTAssertEqual(try event("declined0001", in: listing).updatedAt, date("2026-11-16T12:00:00Z"))

        let untitled = try event("untitled0001", in: listing)
        XCTAssertEqual(untitled.title, "")
        XCTAssertNil(untitled.location)
        XCTAssertNil(untitled.webURL)
    }

    func testTimeSetAsideOnAMacReportsItsClientKey() async throws {
        let listing = try await readAll()

        let block = try event("0123456789abcdef0123456789abcdef", in: listing)
        XCTAssertEqual(block.clientKey, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(block.title, "Q3 budget")
        XCTAssertEqual(block.start, date("2026-11-21T11:00:00Z"))
        XCTAssertEqual(block.end, date("2026-11-21T11:30:00Z"))
    }

    /// A block made before the app was renamed carries its key under the old property; the current one wins when both do.
    func testABlockMadeBeforeTheRenameKeepsItsClientKey() {
        let legacy = LegacyIdentity.googleCalendarClientKeyProperty
        XCTAssertEqual(GoogleCalendarMapper.clientKey([legacy: " 0123456789abcdef "]), "0123456789abcdef")
        XCTAssertEqual(GoogleCalendarMapper.clientKey([GoogleCalendarMapper.clientKeyProperty: "fedcba9876543210", legacy: "0123456789abcdef"]),
                       "fedcba9876543210")
        XCTAssertEqual(GoogleCalendarMapper.clientKey([GoogleCalendarMapper.clientKeyProperty: " ", legacy: "0123456789abcdef"]),
                       "0123456789abcdef", "a blank current key is none")
        XCTAssertNil(GoogleCalendarMapper.clientKey(["otherApp": "x"]))
        XCTAssertNil(GoogleCalendarMapper.clientKey(nil))
    }

    func testFloatingDaysReadOnlyRealDates() {
        XCTAssertEqual(GoogleCalendarMapper.floatingDay("2028-02-29"), date("2028-02-29T00:00:00Z"))
        XCTAssertNil(GoogleCalendarMapper.floatingDay("2026-02-30"))
        XCTAssertNil(GoogleCalendarMapper.floatingDay("2026-13-01"))
        XCTAssertNil(GoogleCalendarMapper.floatingDay("20261120"))
    }

    // MARK: Creating time set aside

    /// A block as the engine hands it over: its thread id filled in from the store (`sourceThreadID`), unless `threadID`
    /// is nil, as for a row that never had it.
    private func block(clientKey: String? = "0123456789abcdef0123456789abcdef", threadID: String? = "18c2f0000aaa1111") -> CalendarEvent {
        var event = CalendarEvent(
            id: "acct-test|local-1", accountID: account, providerID: nil, title: "Q3 budget",
            start: date("2026-11-19T13:00:00Z"), end: date("2026-11-19T13:30:00Z"),
            sourceMessage: MessageID(accountID: account, providerID: "18c2f3a4b5c6d7e8"), clientKey: clientKey, sync: .creating
        )
        event.sourceThreadID = threadID
        return event
    }

    func testABlockIsCreatedUnderItsKeyBusyWithNoRemindersNoAttendeesAndALinkToTheConversation() async throws {
        server.on("POST", eventsPath, .json(GoogleCalendarFixtures.inserted))

        let created = try await provider(accountEmail: address).createCalendarEvent(block())

        XCTAssertEqual(server.requests.count, 1, "the thread id came with the block: Gmail is asked nothing")
        let insert = try XCTUnwrap(server.requests(to: eventsPath).first)
        XCTAssertEqual(insert.method, "POST")
        XCTAssertEqual(insert.url.host, "www.googleapis.com")
        XCTAssertEqual(insert.query["sendUpdates"], ["none"])
        XCTAssertEqual(insert.header("Content-Type"), "application/json; charset=UTF-8")
        let body = insert.jsonBody
        XCTAssertEqual(Set(body.keys), ["id", "summary", "description", "start", "end", "transparency", "visibility", "reminders",
                                        "extendedProperties"],
                       "no attendees, so Google mails nobody")
        XCTAssertEqual(body["id"] as? String, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(body["summary"] as? String, "Q3 budget")
        XCTAssertEqual(body["description"] as? String,
                       "Set aside in Paper for: Q3 budget https://mail.google.com/mail/?authuser=ada%2Bwork%40example.com#all/18c2f0000aaa1111",
                       "the link opens the block's own account, whichever the browser signed in first")
        XCTAssertEqual(body["start"] as? [String: String], ["dateTime": "2026-11-19T13:00:00Z"])
        XCTAssertEqual(body["end"] as? [String: String], ["dateTime": "2026-11-19T13:30:00Z"])
        XCTAssertEqual(body["transparency"] as? String, "opaque")
        XCTAssertEqual(body["visibility"] as? String, "private", "others who see the calendar see only that it is busy")
        XCTAssertEqual(body["reminders"] as? [String: Bool], ["useDefault": false])
        XCTAssertEqual((body["extendedProperties"] as? [String: Any])?["private"] as? [String: String],
                       ["paperKey": "0123456789abcdef0123456789abcdef"])

        XCTAssertEqual(created.id, "acct-test|local-1", "the local id is kept")
        XCTAssertEqual(created.providerID, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(created.webURL, "https://www.google.com/calendar/event?eid=MDEyMzQ1Njc4OWFiY2RlZg")
        XCTAssertEqual(try XCTUnwrap(created.updatedAt).timeIntervalSince(date("2026-11-19T11:02:03Z")), 0.456, accuracy: 0.0005)
        XCTAssertEqual(created.invitationUID, "0123456789abcdef0123456789abcdef@google.com")
        XCTAssertEqual(created.sourceMessage, MessageID(accountID: account, providerID: "18c2f3a4b5c6d7e8"))
        XCTAssertEqual(created.clientKey, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(created.start, date("2026-11-19T13:00:00Z"))
        XCTAssertEqual(created.end, date("2026-11-19T13:30:00Z"))
        XCTAssertEqual(created.sync, .synced)
    }

    func testACreateWhoseEarlierAttemptLandedReturnsThatCopy() async throws {
        server.on("POST", eventsPath, .json(GoogleCalendarFixtures.duplicate, status: 409))
        server.on("GET", eventsPath + "/0123456789abcdef0123456789abcdef", .json(GoogleCalendarFixtures.inserted))

        let created = try await provider().createCalendarEvent(block())

        XCTAssertEqual(server.requests(to: eventsPath).filter { $0.method == "POST" }.count, 1, "no second copy")
        XCTAssertEqual(server.requests(to: eventsPath + "/0123456789abcdef0123456789abcdef").first?.method, "GET")
        XCTAssertEqual(created.providerID, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(created.webURL, "https://www.google.com/calendar/event?eid=MDEyMzQ1Njc4OWFiY2RlZg")
        XCTAssertEqual(created.sync, .synced)
    }

    func testACopyDeletedSinceItsCreateIsRefusedNotMadeAgain() async {
        server.on("POST", eventsPath, .json(GoogleCalendarFixtures.duplicate, status: 409))
        server.on("GET", eventsPath + "/0123456789abcdef0123456789abcdef",
                  .json(#"{"id": "0123456789abcdef0123456789abcdef", "status": "cancelled"}"#))

        let error = await thrown { _ = try await self.provider().createCalendarEvent(self.block()) }

        guard case .server(409, _)? = error as? ProviderError else { return XCTFail("\(String(describing: error))") }
    }

    /// A block whose thread id was not handed over (a row from before the engine filled it in) asks Gmail for it.
    func testWithoutTheThreadIDGmailIsAskedForIt() async throws {
        server.on("GET", "/users/me/messages/18c2f3a4b5c6d7e8", .json(GoogleCalendarFixtures.messageThread))
        server.on("POST", eventsPath, .json(GoogleCalendarFixtures.inserted))

        _ = try await provider(accountEmail: address).createCalendarEvent(block(threadID: nil))

        let lookup = try XCTUnwrap(server.requests(to: "/users/me/messages/18c2f3a4b5c6d7e8").first)
        XCTAssertEqual(lookup.query["format"], ["minimal"])
        XCTAssertEqual(lookup.query["fields"], ["id,threadId"])
        let insert = try XCTUnwrap(server.requests(to: eventsPath).first)
        XCTAssertEqual(insert.jsonBody["description"] as? String,
                       "Set aside in Paper for: Q3 budget https://mail.google.com/mail/?authuser=ada%2Bwork%40example.com#all/18c2f0000aaa1111")
    }

    func testAThreadIDThatIsNoneIsNeverPutInALink() async throws {
        server.on("GET", "/users/me/messages/18c2f3a4b5c6d7e8", .json(GoogleCalendarFixtures.messageThread))
        server.on("POST", eventsPath, .json(GoogleCalendarFixtures.inserted))

        _ = try await provider().createCalendarEvent(block(threadID: "../x?y#z"))

        XCTAssertEqual(server.requests(to: "/users/me/messages/18c2f3a4b5c6d7e8").count, 1, "asked of Gmail instead")
        let insert = try XCTUnwrap(server.requests(to: eventsPath).first)
        XCTAssertEqual(insert.jsonBody["description"] as? String,
                       "Set aside in Paper for: Q3 budget https://mail.google.com/mail/#all/18c2f0000aaa1111",
                       "without the account's address the link is Gmail's plain one")
    }

    func testTheLinkNamesTheAccountByItsAddressEscaped() {
        XCTAssertEqual(GmailProvider.conversationLink(thread: "18c2f0000aaa1111", accountEmail: "ada+work@example.com"),
                       "https://mail.google.com/mail/?authuser=ada%2Bwork%40example.com#all/18c2f0000aaa1111")
        XCTAssertEqual(GmailProvider.conversationLink(thread: "18c2f0000aaa1111", accountEmail: "Zoë.o'neil@exämple.de"),
                       "https://mail.google.com/mail/?authuser=Zo%C3%AB.o%27neil%40ex%C3%A4mple.de#all/18c2f0000aaa1111",
                       "nothing beyond ASCII's unreserved characters goes in unescaped")
        XCTAssertEqual(GmailProvider.conversationLink(thread: "18c2f0000aaa1111", accountEmail: ""),
                       "https://mail.google.com/mail/#all/18c2f0000aaa1111", "a provider made only to sign in has no address")
        XCTAssertEqual(GmailProvider.conversationLink(thread: "18c2f0000aaa1111", accountEmail: nil),
                       "https://mail.google.com/mail/#all/18c2f0000aaa1111")
    }

    func testWithoutItsThreadTheDescriptionIsTheSentenceAlone() async throws {
        server.on("GET", "/users/me/messages/18c2f3a4b5c6d7e8", .json(GmailFixtures.notFoundError, status: 404))
        server.on("POST", eventsPath, .json(GoogleCalendarFixtures.inserted))

        _ = try await provider().createCalendarEvent(block(threadID: nil))

        let insert = try XCTUnwrap(server.requests(to: eventsPath).first)
        XCTAssertEqual(insert.jsonBody["description"] as? String, "Set aside in Paper for: Q3 budget")
    }

    func testABlockForNoMessageAsksGmailNothing() async throws {
        server.on("POST", eventsPath, .json(GoogleCalendarFixtures.inserted))
        var event = block(threadID: nil)
        event.sourceMessage = nil
        event.title = "Line one\nline two"

        _ = try await provider().createCalendarEvent(event)

        XCTAssertEqual(server.requests.count, 1)
        let insert = try XCTUnwrap(server.requests(to: eventsPath).first)
        XCTAssertEqual(insert.jsonBody["summary"] as? String, "Line one line two")
        XCTAssertEqual(insert.jsonBody["description"] as? String, "Set aside in Paper for: Line one line two",
                       "one plain line")
    }

    func testABlockWithoutASubjectIsNoSubject() async throws {
        server.on("POST", eventsPath, .json(GoogleCalendarFixtures.inserted))
        var event = block(threadID: nil)
        event.sourceMessage = nil
        event.title = "  "

        let created = try await provider().createCalendarEvent(event)

        let insert = try XCTUnwrap(server.requests(to: eventsPath).first)
        XCTAssertEqual(insert.jsonBody["summary"] as? String, "No subject")
        XCTAssertEqual(insert.jsonBody["description"] as? String, "Set aside in Paper for: No subject")
        XCTAssertEqual(created.title, "No subject")
    }

    func testAKeyGoogleWouldRefuseAsAnIDStaysOnlyInTheProperty() async throws {
        server.on("POST", eventsPath, .json(GoogleCalendarFixtures.inserted))

        _ = try await provider().createCalendarEvent(block(clientKey: "Not-Base32hex"))

        let body = try XCTUnwrap(server.requests(to: eventsPath).first).jsonBody
        XCTAssertNil(body["id"])
        XCTAssertEqual((body["extendedProperties"] as? [String: Any])?["private"] as? [String: String],
                       ["paperKey": "Not-Base32hex"])
        XCTAssertTrue(GmailProvider.isGoogleEventID(CalendarEvent.newClientKey()))
        XCTAssertFalse(GmailProvider.isGoogleEventID("abcd"), "five characters at least")
        XCTAssertFalse(GmailProvider.isGoogleEventID("0123456789wxyz"), "base32hex stops at v")
    }

    func testAnAllDayEventIsCreatedWithItsDates() {
        let start = GmailProvider.calendarTime(date("2026-11-20T00:00:00Z"), isAllDay: true)
        XCTAssertEqual(start.date, "2026-11-20")
        XCTAssertNil(start.dateTime)
    }

    func testARefusedCreateIsTheCalendarsRefusal() async {
        server.on("POST", eventsPath, .json(GoogleCalendarFixtures.scopeInsufficient, status: 403))

        let error = await thrown { _ = try await self.provider().createCalendarEvent(self.block()) }

        XCTAssertEqual(error as? CalendarProviderError, .permissionMissing)
    }

    // MARK: Deleting

    func testADeleteMailsNobody() async throws {
        server.on("DELETE", eventsPath + "/0123456789abcdef0123456789abcdef", .empty(status: 204))

        try await provider().deleteCalendarEvent(providerID: "0123456789abcdef0123456789abcdef")

        let delete = try XCTUnwrap(server.requests(to: eventsPath + "/0123456789abcdef0123456789abcdef").first)
        XCTAssertEqual(delete.method, "DELETE")
        XCTAssertEqual(delete.url.host, "www.googleapis.com")
        XCTAssertEqual(delete.query["sendUpdates"], ["none"])
    }

    func testAnEventAlreadyGoneOrDeletedCountsAsDeleted() async throws {
        server.on("DELETE", eventsPath + "/gone404", .json(GmailFixtures.notFoundError, status: 404))
        server.on("DELETE", eventsPath + "/gone410", .json(GoogleCalendarFixtures.gone, status: 410))

        try await provider().deleteCalendarEvent(providerID: "gone404")
        try await provider().deleteCalendarEvent(providerID: "gone410")

        XCTAssertEqual(server.requests(to: eventsPath + "/gone404").map(\.method), ["DELETE"])
        XCTAssertEqual(server.requests(to: eventsPath + "/gone410").map(\.method), ["DELETE"])
    }

    func testADeleteTheServiceFailsStillThrows() async {
        server.on("DELETE", eventsPath + "/block1", .json(GoogleCalendarFixtures.backendError, status: 500))
        let error = await thrown { try await self.provider().deleteCalendarEvent(providerID: "block1") }
        guard case .server(500, _)? = error as? ProviderError else { return XCTFail("\(String(describing: error))") }
    }

    // MARK: Refusals

    func testAMissingScopeIsPermissionMissing() async {
        for body in [GoogleCalendarFixtures.scopeInsufficient, GoogleCalendarFixtures.scopeInsufficientDetailsOnly] {
            server.reset()
            server.on("GET", eventsPath, .json(body, status: 403))
            let error = await thrown { _ = try await self.provider().calendarEvents(in: self.window) }
            XCTAssertEqual(error as? CalendarProviderError, .permissionMissing)
        }
    }

    func testTheAPITurnedOffIsAPIDisabled() async {
        for body in [GoogleCalendarFixtures.serviceDisabled, GoogleCalendarFixtures.serviceDisabledDetailsOnly] {
            server.reset()
            server.on("GET", eventsPath, .json(body, status: 403))
            let error = await thrown { _ = try await self.provider().calendarEvents(in: self.window) }
            XCTAssertEqual(error as? CalendarProviderError, .apiDisabled)
        }
        server.on("DELETE", eventsPath + "/block1", .json(GoogleCalendarFixtures.serviceDisabled, status: 403))
        let error = await thrown { try await self.provider().deleteCalendarEvent(providerID: "block1") }
        XCTAssertEqual(error as? CalendarProviderError, .apiDisabled, "every calendar call reads the refusal")
    }

    func testARateLimitForbiddenIsAThrottle() async {
        server.on("GET", eventsPath, .json(GoogleCalendarFixtures.rateLimitForbidden, status: 403))
        let error = await thrown { _ = try await self.provider().calendarEvents(in: self.window) }
        guard case .throttled? = error as? ProviderError else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(server.requests.count, 1, "a throttle is the engine's to wait out")
    }

    func testAnotherForbiddenIsAServerError() async {
        server.on("GET", eventsPath, .json(GoogleCalendarFixtures.writerAccessRequired, status: 403))
        let error = await thrown { _ = try await self.provider().calendarEvents(in: self.window) }
        guard case .server(403, let message)? = error as? ProviderError else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(message, "You need to have writer access to this calendar.")
    }

    func testA401RetriesOnceWithAFreshTokenThenIsTheTokensProblem() async throws {
        server.sequence("GET", eventsPath, [.json(GmailFixtures.unauthorizedError, status: 401), .json(GoogleCalendarFixtures.emptyPage)])
        let tokens = FakeTokenProvider(scopes: granted)
        _ = try await provider(tokens: tokens).calendarEvents(in: window)
        XCTAssertEqual(tokens.invalidations, 1)
        XCTAssertEqual(server.requests(to: eventsPath).map { $0.header("Authorization") }, ["Bearer token-1", "Bearer token-2"])

        server.reset()
        server.on("GET", eventsPath, .json(GmailFixtures.unauthorizedError, status: 401))
        let error = await thrown { _ = try await self.provider().calendarEvents(in: self.window) }
        guard case .unauthorized? = error as? ProviderError else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(server.requests(to: eventsPath).count, 2)
    }

    func testA429IsAThrottleWithItsRetryAfter() async {
        server.on("GET", eventsPath, .json(GoogleCalendarFixtures.tooManyRequests, status: 429, headers: ["Retry-After": "30"]))
        let error = await thrown { _ = try await self.provider().calendarEvents(in: self.window) }
        guard case .throttled(let retryAfter)? = error as? ProviderError else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(retryAfter, 30)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testTheServiceFailingIsAServerOrNetworkError() async {
        server.on("GET", eventsPath, .json(GoogleCalendarFixtures.backendError, status: 500))
        var error = await thrown { _ = try await self.provider().calendarEvents(in: self.window) }
        guard case .server(500, _)? = error as? ProviderError else { return XCTFail("\(String(describing: error))") }

        server.reset()
        server.on("GET", eventsPath, .json(GoogleCalendarFixtures.backendError, status: 503))
        error = await thrown { _ = try await self.provider().calendarEvents(in: self.window) }
        guard case .network? = error as? ProviderError else { return XCTFail("\(String(describing: error))") }
    }

    func testAnInvitationAnswerStillSkipsACalendarTheClientCannotReach() throws {
        // The answer's own calendar calls keep the shared mapping, so a disabled API never fails the reply mail.
        for body in [GoogleCalendarFixtures.serviceDisabled, GoogleCalendarFixtures.scopeInsufficient] {
            let mapped = try XCTUnwrap(GmailHTTPClient.error(status: 403, body: Data(body.utf8), retryAfter: nil))
            XCTAssertTrue(GmailProvider.skipsCalendarCopy(mapped))
        }
    }
}
