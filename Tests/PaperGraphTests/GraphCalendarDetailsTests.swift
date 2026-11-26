import Foundation
import PaperCore
import XCTest
@testable import PaperGraph

/// An event's details from Outlook through Graph: one GET of what the card shows (the body as HTML, read to text), one
/// more of the series master's recurrence when its words are not known; Teams' numbers and conference ID; the meeting
/// ID and passcode from the notes; answers known only on the organizer's copy. Each request is live spend.
final class GraphCalendarDetailsTests: GraphTestCase {
    private let facts = CalendarAccountFacts(email: "alex@northwind.test", timeZone: TimeZone(identifier: "Europe/Berlin")!,
                                             locale: Locale(identifier: "en_GB"))

    override func setUp() {
        super.setUp()
        tokens.scopes = "Mail.ReadWrite Mail.Send User.Read Calendars.ReadWrite profile openid"
    }

    private func read(_ value: CalendarDetailsRead?, file: StaticString = #filePath, line: UInt = #line) throws -> CalendarDetailsRead {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func routeEvent(_ id: String, _ json: String, master: String? = nil) {
        route { request in
            guard request.method == "GET" else { return nil }
            if request.path == "/v1.0/me/events/\(id)" { return .json(json) }
            if let master, request.path == "/v1.0/me/events/AAMkMASTER=" { return .json(master) }
            return nil
        }
    }

    func testTheReadSelectsWhatTheCardShowsInUTCAndTheSeriesWords() async throws {
        routeEvent("AAMkOCCURRENCE=", GraphCalendarDetailsFixtures.teamsOrganizerCopy, master: GraphCalendarDetailsFixtures.seriesMaster)
        let read = try self.read(try await makeProvider().calendarEventDetails(
            providerID: "AAMkOCCURRENCE=", seriesID: "AAMkMASTER=", knownRepeats: nil, account: facts))

        XCTAssertEqual(read.requestCount, 2, "both counted as live spend")
        XCTAssertEqual(read.version, "DwAAABYAAAB")
        let get = try XCTUnwrap(requests.first)
        XCTAssertEqual(get.query["$select"],
                       "body,organizer,attendees,isOrganizer,hideAttendees,onlineMeeting,onlineMeetingUrl,location,changeKey,seriesMasterId,type")
        XCTAssertTrue((get.header("Prefer") ?? "").contains("outlook.timezone=\"UTC\""))
        XCTAssertFalse((get.header("Prefer") ?? "").contains("outlook.body-content-type"), "the body comes as Graph gives it: HTML")
        XCTAssertEqual(requests.last?.query["$select"], "recurrence,originalStartTimeZone,start")
        XCTAssertEqual(read.details.repeats, "Every week on Friday, 12 times")
    }

    func testKnownWordsSpareTheSeriesRequest() async throws {
        routeEvent("AAMkOCCURRENCE=", GraphCalendarDetailsFixtures.teamsOrganizerCopy)
        let read = try self.read(try await makeProvider().calendarEventDetails(
            providerID: "AAMkOCCURRENCE=", seriesID: "AAMkMASTER=", knownRepeats: "Every week", account: facts))
        XCTAssertEqual(read.requestCount, 1)
    }

    func testTheOrganizersCopyKnowsEveryAnswerAndLeavesTheRoomOut() async throws {
        routeEvent("AAMkOCCURRENCE=", GraphCalendarDetailsFixtures.teamsOrganizerCopy)
        let details = try self.read(try await makeProvider().calendarEventDetails(
            providerID: "AAMkOCCURRENCE=", seriesID: nil, knownRepeats: "x", account: facts)).details
        XCTAssertTrue(details.userIsOrganizer)
        XCTAssertTrue(details.answersKnown)
        XCTAssertEqual(details.guests.map(\.name), ["Rachel Kim", "Marcus Bell", "Aisha Patel", "Tom Hughes"])
        XCTAssertEqual(details.guests.map(\.response), [.accepted, .tentative, .declined, .needsAction])
        XCTAssertEqual(details.guestCount, 4)
    }

    func testTeamsNumbersConferenceIDAndTheCodesInTheNotes() async throws {
        routeEvent("AAMkOCCURRENCE=", GraphCalendarDetailsFixtures.teamsOrganizerCopy)
        let details = try self.read(try await makeProvider().calendarEventDetails(
            providerID: "AAMkOCCURRENCE=", seriesID: nil, knownRepeats: "x", account: facts)).details
        let call = try XCTUnwrap(details.call)
        XCTAssertEqual(call.phones, [
            EventPhone(number: "+1 555-0134", dial: "+15550134,,601225430#", region: nil, pin: "601225430"),
            EventPhone(number: "+1 800-555-0199", dial: "+18005550199,,601225430#", region: nil, pin: "601225430"),
        ])
        XCTAssertEqual(call.pinLabel, .conferenceID)
        XCTAssertEqual(call.meetingID, "284 113 905 771")
        XCTAssertEqual(call.passcode, "Qx7bTe")
        XCTAssertNil(call.joinURL, "the event names its own call")
        let notes = try XCTUnwrap(details.notes)
        XCTAssertFalse(notes.text.contains("color"), "the style block never reaches the text")
        XCTAssertTrue(notes.text.hasPrefix("Weekly look at the reader and composer work.\n\nMicrosoft Teams meeting"), notes.text)
        XCTAssertEqual(notes.links.map(\.url), [
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x", "tel:+15550134,,601225430%23",
            "https://nam11.safelinks.protection.outlook.test/?url=https%3A%2F%2Fteams.microsoft.com%2FmeetingOptions",
        ])
    }

    func testAnAttendeesCopyNamesTheGuestsWithoutTheirAnswers() async throws {
        routeEvent("AAMkOCCURRENCE=", GraphCalendarDetailsFixtures.teamsAttendeeCopy)
        let details = try self.read(try await makeProvider().calendarEventDetails(
            providerID: "AAMkOCCURRENCE=", seriesID: nil, knownRepeats: "x", account: facts)).details
        XCTAssertFalse(details.answersKnown)
        XCTAssertEqual(details.guests.map(\.name), ["Alex Morgan", "Marcus Bell"], "the user first, the organizer left out")
        XCTAssertEqual(details.guests.first?.isSelf, true, "matched by the account's address, whatever its case")
        XCTAssertEqual(details.guests.map(\.response), [.needsAction, nil])
        XCTAssertEqual(details.organizer, EmailAddress(name: "Rachel Kim", address: "rachel.kim@northwind.test"))
    }

    func testHiddenGuestsAndAZoomCallInTheNotes() async throws {
        routeEvent("AAMkHIDDEN=", GraphCalendarDetailsFixtures.hiddenAttendees)
        let details = try self.read(try await makeProvider().calendarEventDetails(
            providerID: "AAMkHIDDEN=", seriesID: nil, knownRepeats: nil, account: facts)).details
        XCTAssertTrue(details.guestsHidden)
        XCTAssertTrue(details.guests.isEmpty)
        XCTAssertEqual(details.call?.joinURL, "https://acme.zoom.us/j/81234567890?pwd=x")
        XCTAssertEqual(details.call?.meetingID, "812 3456 7890")
        XCTAssertEqual(details.call?.passcode, "551902")
        XCTAssertEqual(requests.count, 1, "a single event: one request")
    }

    /// With no online meeting, the event's call is the one its row reads: a call address in the location, or the online
    /// meeting's address. The details then name no other from the notes, and the notes' codes go with that call.
    func testTheRowsCallFromTheLocationOrTheMeetingAddressIsTheCall() async throws {
        routeEvent("AAMkZOOM=", GraphCalendarDetailsFixtures.zoomInTheLocation)
        let provider = makeProvider()
        let zoom = try self.read(try await provider.calendarEventDetails(
            providerID: "AAMkZOOM=", seriesID: nil, knownRepeats: nil, account: facts)).details
        let zoomEvent = try JSONDecoder().decode(GraphEvent.self, from: Data(GraphCalendarDetailsFixtures.zoomInTheLocation.utf8))
        XCTAssertEqual(GraphCalendarMapper.joinURL(of: zoomEvent), "https://acme.zoom.us/j/81234567890?pwd=x", "the row's Join")
        let call = try XCTUnwrap(zoom.call)
        XCTAssertNil(call.joinURL, "the location names the call: the personal room the notes link to first is not it")
        XCTAssertEqual(call.meetingID, "812 3456 7890")
        XCTAssertEqual(call.passcode, "551902")

        routeEvent("AAMkSKYPE=", GraphCalendarDetailsFixtures.onlineMeetingURLOnly)
        let older = try self.read(try await provider.calendarEventDetails(
            providerID: "AAMkSKYPE=", seriesID: nil, knownRepeats: nil, account: facts)).details
        let olderEvent = try JSONDecoder().decode(GraphEvent.self, from: Data(GraphCalendarDetailsFixtures.onlineMeetingURLOnly.utf8))
        XCTAssertEqual(GraphCalendarMapper.joinURL(of: olderEvent), "https://meet.lync.northwind.test/rachel/K7P2")
        XCTAssertNil(older.call?.joinURL, "the online meeting's address is the call")
        XCTAssertEqual(older.call?.meetingID, "512 774 309 118")

        // A call only the body names is still found there (the row has none).
        routeEvent("AAMkHIDDEN=", GraphCalendarDetailsFixtures.hiddenAttendees)
        let bodyOnly = try self.read(try await provider.calendarEventDetails(
            providerID: "AAMkHIDDEN=", seriesID: nil, knownRepeats: nil, account: facts)).details
        XCTAssertEqual(bodyOnly.call?.joinURL, "https://acme.zoom.us/j/81234567890?pwd=x")
    }

    func testAGoneEventIsNil() async throws {
        route { request in
            request.method == "GET" ? .json(Fixtures.notFoundError, status: 404) : nil
        }
        let read = try await makeProvider().calendarEventDetails(providerID: "AAMkGONE=", seriesID: nil, knownRepeats: nil, account: facts)
        XCTAssertNil(read)
    }
}
