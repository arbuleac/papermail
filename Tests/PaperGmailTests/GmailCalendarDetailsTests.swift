import Foundation
import PaperCore
import XCTest
@testable import PaperGmail

/// An event's details from Google Calendar (docs/ARCHITECTURE.md, "Calendar" › The calendar lane): one `events.get` of
/// the fields the card shows, one more for a series' rule when it is not known; guests without rooms and the organizer,
/// the user first; the conference's numbers and codes; the description as text with https and tel links only.
final class GmailCalendarDetailsTests: XCTestCase {
    private let server = StubServer.shared
    private let granted = OAuthEndpoints.googleScope + " " + OAuthEndpoints.googleCalendarScope
    private let facts = CalendarAccountFacts(email: "ada@example.com", timeZone: TimeZone(identifier: "Europe/Berlin")!,
                                             locale: Locale(identifier: "en_GB"))

    override func setUp() {
        super.setUp()
        server.reset()
    }

    override func tearDown() {
        server.reset()
        super.tearDown()
    }

    private func provider() -> GmailProvider {
        TestSupport.makeProvider(tokens: FakeTokenProvider(scopes: granted))
    }

    private let eventPath = "/calendar/v3/calendars/primary/events/standup_20261119T080000Z"
    private let seriesPath = "/calendar/v3/calendars/primary/events/standup"

    func testAnOccurrenceIsReadWithItsSeriesWordsInTwoRequests() async throws {
        server.on("GET", eventPath, .json(GoogleCalendarFixtures.eventDetailsMeet))
        server.on("GET", seriesPath, .json(GoogleCalendarFixtures.seriesParent))
        let read = try await XCTUnwrapAsync(try await provider().calendarEventDetails(
            providerID: "standup_20261119T080000Z", seriesID: "standup", knownRepeats: nil, account: facts))

        XCTAssertEqual(read.requestCount, 2)
        XCTAssertEqual(read.version, "\"3512345678901002\"")
        XCTAssertEqual(server.requests.map(\.path), [eventPath, seriesPath])
        let get = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(get.query["fields"], [GmailProvider.detailsFields])
        XCTAssertEqual(get.query["prettyPrint"], ["false"])
        XCTAssertEqual(server.requests.last?.query["fields"], ["recurrence,start"])
        XCTAssertEqual(read.details.repeats, "Every week on Thursday, 12 times")
    }

    func testKnownWordsSpareTheSeriesRequest() async throws {
        server.on("GET", eventPath, .json(GoogleCalendarFixtures.eventDetailsMeet))
        let read = try await XCTUnwrapAsync(try await provider().calendarEventDetails(
            providerID: "standup_20261119T080000Z", seriesID: "standup", knownRepeats: "Every week on Thursday", account: facts))
        XCTAssertEqual(read.requestCount, 1)
        XCTAssertEqual(read.details.repeats, "Every week on Thursday")
    }

    func testTheGuestsAreListedWithoutRoomsAndTheOrganizerTheUserFirst() async throws {
        server.on("GET", eventPath, .json(GoogleCalendarFixtures.eventDetailsMeet))
        let details = try await XCTUnwrapAsync(try await provider().calendarEventDetails(
            providerID: "standup_20261119T080000Z", seriesID: nil, knownRepeats: "x", account: facts)).details

        XCTAssertEqual(details.organizer, EmailAddress(name: "Erin Park", address: "erin@contoso.test"))
        XCTAssertFalse(details.userIsOrganizer)
        XCTAssertTrue(details.answersKnown)
        XCTAssertFalse(details.guestsHidden)
        XCTAssertEqual(details.guestCount, 7)
        XCTAssertEqual(details.guests.map(\.address), ["ada@example.com", "ben@contoso.test", "carol@fabrikam.test",
                                                       "dan@northwind.test", "fay@contoso.test", "gus@contoso.test", "hal@contoso.test"])
        XCTAssertEqual(details.guests.first?.isSelf, true)
        XCTAssertEqual(details.guests.map(\.response), [.needsAction, .accepted, .tentative, .declined, .needsAction, .accepted, .accepted])
        XCTAssertEqual(details.guests[1].name, "Ben Carter")
    }

    func testTheCallsNumberPinAndMorePhones() async throws {
        server.on("GET", eventPath, .json(GoogleCalendarFixtures.eventDetailsMeet))
        let call = try await XCTUnwrapAsync(try await provider().calendarEventDetails(
            providerID: "standup_20261119T080000Z", seriesID: nil, knownRepeats: "x", account: facts)).details.call
        XCTAssertEqual(call?.phones, [EventPhone(number: "+1 555-0188", dial: "+15550188,,248913557#", region: "US", pin: "248913557")])
        XCTAssertEqual(call?.pinLabel, .pin)
        XCTAssertEqual(call?.morePhonesURL, "https://tel.meet.example.test/abc-defg-hij?pin=248913557")
        XCTAssertNil(call?.joinURL, "the conference names its own")
    }

    func testTheNotesAreTextWithTheirSafeLinks() async throws {
        server.on("GET", eventPath, .json(GoogleCalendarFixtures.eventDetailsMeet))
        let notes = try await XCTUnwrapAsync(try await provider().calendarEventDetails(
            providerID: "standup_20261119T080000Z", seriesID: nil, knownRepeats: "x", account: facts)).details.notes
        XCTAssertEqual(notes?.text, "Agenda\nWeekly status.\n• Wins\n• Blockers\nNotes Call Erin Click")
        XCTAssertEqual(notes?.links.map(\.url), ["https://docs.example.test/notes", "tel:+15550100"])
        XCTAssertFalse(notes?.text.contains("tracker") ?? true)
    }

    func testAZoomAddOnsMeetingCodeAndPasscode() async throws {
        server.on("GET", "/calendar/v3/calendars/primary/events/zoomcall0001", .json(GoogleCalendarFixtures.eventDetailsZoomAddOn))
        let call = try await XCTUnwrapAsync(try await provider().calendarEventDetails(
            providerID: "zoomcall0001", seriesID: nil, knownRepeats: nil, account: facts)).details.call
        XCTAssertEqual(call?.meetingID, "812 3456 7890")
        XCTAssertEqual(call?.passcode, "551902")
        XCTAssertEqual(server.requests.count, 1, "a single event: one request")
    }

    func testHiddenGuestsAreNotListedAndANotesJoinAddressIsTaken() async throws {
        server.on("GET", "/calendar/v3/calendars/primary/events/hidden000001", .json(GoogleCalendarFixtures.eventDetailsHiddenGuests))
        let details = try await XCTUnwrapAsync(try await provider().calendarEventDetails(
            providerID: "hidden000001", seriesID: nil, knownRepeats: nil, account: facts)).details
        XCTAssertTrue(details.guestsHidden)
        XCTAssertTrue(details.guests.isEmpty)
        XCTAssertEqual(details.call?.joinURL, "https://acme.zoom.us/j/999", "a known call host in the notes")
    }

    func testAnExchangeOrganizersPlainDescriptionKeepsItsLinesLinksAndCallCodes() async throws {
        server.on("GET", "/calendar/v3/calendars/primary/events/exchteams0001", .json(GoogleCalendarFixtures.eventDetailsExchangeTeams))
        let details = try await XCTUnwrapAsync(try await provider().calendarEventDetails(
            providerID: "exchteams0001", seriesID: nil, knownRepeats: nil, account: facts)).details
        let notes = try XCTUnwrap(details.notes)
        XCTAssertTrue(notes.text.hasPrefix("Weekly look at the numbers.\nContact: Jane Doe <jane@fabrikam.test>\n"), notes.text)
        XCTAssertTrue(notes.text.contains("\nMeeting ID: 284 113 905 771\nPasscode: Qx7bTe\n"), "its lines kept")
        let join = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d"
        XCTAssertEqual(notes.links.first?.url, join, "the address in angle brackets is a link")
        XCTAssertEqual(details.call?.joinURL, join, "a known call host in the notes: the card's Call and Join")
        XCTAssertEqual(details.call?.meetingID, "284 113 905 771")
        XCTAssertEqual(details.call?.passcode, "Qx7bTe")
    }

    func testAGoneEventIsNil() async throws {
        server.on("GET", eventPath, .json(#"{"error": {"code": 404, "message": "Not Found"}}"#, status: 404))
        let read = try await provider().calendarEventDetails(providerID: "standup_20261119T080000Z", seriesID: nil, knownRepeats: nil,
                                                             account: facts)
        XCTAssertNil(read)
        server.reset()
        server.on("GET", eventPath, .json(#"{"error": {"code": 410, "message": "Gone"}}"#, status: 410))
        let gone = try await provider().calendarEventDetails(providerID: "standup_20261119T080000Z", seriesID: nil, knownRepeats: nil,
                                                             account: facts)
        XCTAssertNil(gone)
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
