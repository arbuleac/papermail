import JavaScriptCore
import XCTest
@testable import SSCore

/// The invitation card's payload (spec §5.14): every line display-ready from the stored facts, in this Mac's zone and,
/// when it differs, the event's; the states (open, answered, cancelled, the user's own event, waiting for permission);
/// and the JSON keys the shell reads.
final class InvitationCardPayloadTests: XCTestCase {
    private typealias F = ConversationFixtures
    /// Friday 7 March 2025, 15:00 UTC.
    private let now = F.utc(2025, 3, 7, 15, 0)

    private func invitation(
        method: CalendarInvitation.Method = .request,
        start: Date = F.utc(2025, 3, 11, 15, 0),
        end: Date = F.utc(2025, 3, 11, 16, 0),
        isAllDay: Bool = false,
        timeZoneID: String? = nil,
        location: String? = "Room 4",
        conferenceURL: String? = nil,
        userIsOrganizer: Bool = false,
        userResponse: InvitationResponse? = .needsAction,
        attendees: [CalendarInvitation.Person]? = nil
    ) -> CalendarInvitation {
        CalendarInvitation(
            method: method, uid: "uid-1", title: "Design review", start: start, end: end, isAllDay: isAllDay,
            isFloating: isAllDay, timeZoneID: timeZoneID, location: location, conferenceURL: conferenceURL,
            organizer: CalendarInvitation.Person(name: "Ada Lovelace", address: "ada@example.com"),
            attendees: attendees ?? [
                CalendarInvitation.Person(name: "Ada Lovelace", address: "ada@example.com", response: .accepted),
                CalendarInvitation.Person(name: nil, address: "me@example.com", response: .needsAction),
                CalendarInvitation.Person(name: "Bob", address: "bob@example.com", response: .accepted),
            ],
            repeats: "Every week on Tuesday", userAddress: "me@example.com", userResponse: userResponse,
            userIsOrganizer: userIsOrganizer, calendarText: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"
        )
    }

    private func card(_ invitation: CalendarInvitation, reply: InvitationResponse? = nil, waiting: Bool = false,
                      builder: RenderPayloadBuilder = F.builder, roles: Set<MailboxRole> = [.inbox]) throws -> RenderPayload.Invitation {
        var message = F.message("m1", roles: roles)
        message.invitationReply = reply
        var body = F.body(html: "<p>Invitation</p>")
        body.invitation = invitation
        let payload = builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts,
                                    invitationPermissionNeeded: waiting ? [F.accountID] : [], now: now)
        return try XCTUnwrap(payload.messages.first?.invitation)
    }

    func testAnOpenInvitation() throws {
        let open = try card(invitation())
        XCTAssertEqual(open.title, "Design review")
        XCTAssertEqual(open.when, "Tue 11 Mar · 15:00 – 16:00")
        XCTAssertNil(open.whenElsewhere, "the event's zone is not named when it is this Mac's")
        XCTAssertEqual(open.repeats, "Every week on Tuesday")
        XCTAssertEqual(open.location, "Room 4")
        XCTAssertNil(open.locationURL)
        XCTAssertEqual(open.organizer, "Ada Lovelace")
        XCTAssertEqual(open.guests, "You, Bob", "the user first, the organizer on their own line")
        XCTAssertTrue(open.canAnswer)
        XCTAssertNil(open.response)
        XCTAssertFalse(open.isCancelled)
        XCTAssertFalse(open.needsPermission)
        XCTAssertTrue(open.canOpen)
    }

    func testTheAnswerGivenHereWinsOverTheOneStated() throws {
        XCTAssertEqual(try card(invitation(userResponse: .accepted)).response, .accepted, "answered elsewhere (Graph knows)")
        XCTAssertEqual(try card(invitation(userResponse: .accepted), reply: .declined).response, .declined)
        XCTAssertNil(try card(invitation(userResponse: .needsAction)).response)
    }

    func testACancelledEventOffersNoAnswer() throws {
        let cancelled = try card(invitation(method: .cancel, userResponse: .accepted), reply: .accepted)
        XCTAssertTrue(cancelled.isCancelled)
        XCTAssertFalse(cancelled.canAnswer)
        XCTAssertNil(cancelled.response)
        XCTAssertTrue(cancelled.canOpen, "Calendar can still take the cancellation")
    }

    func testTheUsersOwnEventOffersNoAnswer() throws {
        let own = try card(invitation(userIsOrganizer: true))
        XCTAssertFalse(own.canAnswer)
        XCTAssertEqual(own.organizer, "You")
    }

    /// The organizer updated the invitation since: a later message in the conversation carries the same event (or the
    /// same occurrence) with a higher SEQUENCE. The earlier card offers no answer, so none repeats a revision the
    /// organizer replaced, its times and its SEQUENCE; only the latest is answered. An occurrence the update does not
    /// name keeps its own answers.
    func testAnInvitationTheOrganizerUpdatedSinceOffersNoAnswer() throws {
        func body(_ invitation: CalendarInvitation) -> StoredBody {
            var body = F.body(html: "<p>Invitation</p>")
            body.invitation = invitation
            return body
        }
        var older = invitation(userResponse: .accepted)
        older.sequence = 1
        var newer = invitation(start: F.utc(2025, 3, 11, 16, 0), end: F.utc(2025, 3, 11, 17, 0))
        newer.sequence = 2
        var occurrence = invitation()
        occurrence.recurrenceID = F.utc(2025, 3, 18, 15, 0)
        var first = F.message("m1", date: F.utc(2025, 3, 1, 9, 0))
        first.invitationReply = .accepted
        let second = F.message("m2", date: F.utc(2025, 3, 2, 9, 0))
        let third = F.message("m3", date: F.utc(2025, 3, 3, 9, 0))
        let payload = F.builder.build(messages: [first, second, third],
                                      bodies: [first.id: body(older), second.id: body(newer), third.id: body(occurrence)],
                                      accounts: F.accounts, now: now)
        func card(_ message: MessageMetadata) throws -> RenderPayload.Invitation {
            try XCTUnwrap(payload.messages.first { $0.id == RenderPayload.messageKey(for: message.id) }?.invitation)
        }
        XCTAssertFalse(try card(first).canAnswer, "updated since: no answers")
        XCTAssertNil(try card(first).response, "and no answer shown chosen on it")
        XCTAssertTrue(try card(first).canOpen)
        XCTAssertTrue(try card(second).canAnswer, "the latest revision is answered")
        XCTAssertTrue(try card(third).canAnswer, "an occurrence the update does not name")
    }

    /// With the same SEQUENCE, DTSTAMP says which revision is later. Without both stamps neither is: a forwarded copy of
    /// the same revision, or Microsoft's (Graph reads the event as it is now), leaves each card as it is.
    func testWithTheSameSequenceTheLaterStampIsTheLatestRevision() throws {
        func cards(_ firstStamp: Date?, _ secondStamp: Date?) -> [Bool] {
            var older = invitation()
            older.stamp = firstStamp
            var newer = invitation()
            newer.stamp = secondStamp
            var bodies: [MessageID: StoredBody] = [:]
            let messages = [F.message("m1", date: F.utc(2025, 3, 1, 9, 0)), F.message("m2", date: F.utc(2025, 3, 2, 9, 0))]
            for (message, invitation) in zip(messages, [older, newer]) {
                var body = F.body(html: "<p>Invitation</p>")
                body.invitation = invitation
                bodies[message.id] = body
            }
            let payload = F.builder.build(messages: messages, bodies: bodies, accounts: F.accounts, now: now)
            return payload.messages.map { $0.invitation?.canAnswer ?? false }
        }
        XCTAssertEqual(cards(F.utc(2025, 3, 1, 9, 0), F.utc(2025, 3, 2, 9, 0)), [false, true])
        XCTAssertEqual(cards(F.utc(2025, 3, 2, 9, 0), F.utc(2025, 3, 1, 9, 0)), [true, false], "the stamp decides, not the mail's date")
        XCTAssertEqual(cards(nil, F.utc(2025, 3, 2, 9, 0)), [true, true])
        XCTAssertEqual(cards(F.utc(2025, 3, 1, 9, 0), F.utc(2025, 3, 1, 9, 0)), [true, true])
    }

    func testAnAnswerWaitingForPermissionAsksOnItsCard() throws {
        XCTAssertTrue(try card(invitation(), reply: .accepted, waiting: true).needsPermission)
        XCTAssertFalse(try card(invitation(), reply: nil, waiting: true).needsPermission, "nothing waits on a card not answered here")
        XCTAssertFalse(try card(invitation(), reply: .accepted, waiting: false).needsPermission)
    }

    func testAnEventInAnotherZoneIsShownInBoth() throws {
        // 15:00 UTC is 10:00 in New York (EST) on 11 March 2025, after the US switch to daylight time: 11:00 EDT.
        let newYork = try card(invitation(timeZoneID: "America/New_York"))
        XCTAssertEqual(newYork.when, "Tue 11 Mar · 15:00 – 16:00")
        XCTAssertEqual(newYork.whenElsewhere, "Tue 11 Mar · 11:00 – 12:00 Eastern Time")
        let berlin = try card(invitation(timeZoneID: "Europe/Berlin"),
                              builder: RenderPayloadBuilder(calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_GB"),
                                                            timeZone: TimeZone(identifier: "Europe/Paris")!))
        XCTAssertNil(berlin.whenElsewhere, "a zone at the same offset says nothing new")
    }

    func testAllDayAndLongEvents() throws {
        XCTAssertEqual(try card(invitation(start: F.utc(2025, 3, 12), end: F.utc(2025, 3, 13), isAllDay: true)).when, "Wed 12 Mar · All day")
        XCTAssertEqual(try card(invitation(start: F.utc(2025, 3, 12), end: F.utc(2025, 3, 15), isAllDay: true)).when,
                       "Wed 12 Mar – Fri 14 Mar · All day", "the end is exclusive")
        XCTAssertEqual(try card(invitation(start: F.utc(2025, 3, 11, 22), end: F.utc(2025, 3, 12, 2))).when,
                       "Tue 11 Mar, 22:00 – Wed 12 Mar, 02:00")
        XCTAssertEqual(try card(invitation(start: F.utc(2026, 1, 6, 9), end: F.utc(2026, 1, 6, 9))).when,
                       "Tue, 6 Jan 2026 · 09:00", "another year is named, as the locale writes it; an instant has no end")
        // All-day dates read the same in any zone: shown as written, not shifted into this Mac's.
        let tokyo = RenderPayloadBuilder(calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_GB"),
                                         timeZone: TimeZone(identifier: "Pacific/Honolulu")!)
        XCTAssertEqual(try card(invitation(start: F.utc(2025, 3, 12), end: F.utc(2025, 3, 13), isAllDay: true), builder: tokyo).when,
                       "Wed 12 Mar · All day")
    }

    func testAWebAddressIsALinkAndTheGuestsAreCappedAtFour() throws {
        let people = (1...7).map { CalendarInvitation.Person(name: "Guest \($0)", address: "g\($0)@example.com") }
        let linked = try card(invitation(location: "https://meet.example.com/abc", conferenceURL: "https://meet.example.com/abc",
                                         attendees: people))
        XCTAssertEqual(linked.locationURL, "https://meet.example.com/abc")
        XCTAssertNil(linked.conferenceURL, "the same link is not shown twice")
        XCTAssertEqual(linked.guests, "Guest 1, Guest 2, Guest 3, Guest 4 +3 more")
        XCTAssertEqual(try self.card(invitation(conferenceURL: "https://teams.example.com/l/1")).conferenceURL, "https://teams.example.com/l/1")
    }

    func testDraftsAndMessagesWithoutAnInvitationHaveNoCard() throws {
        var body = F.body(html: "<p>Draft</p>")
        body.invitation = invitation()
        let draft = F.message("d1", roles: [.drafts])
        let plain = F.message("m2")
        let payload = F.builder.build(messages: [draft, plain], bodies: [draft.id: body, plain.id: F.body(html: "<p>Hi</p>")],
                                      accounts: F.accounts, now: now)
        XCTAssertTrue(payload.messages.allSatisfy { $0.invitation == nil })
    }

    func testTheCardTravelsUnderTheKeysTheShellReads() throws {
        var message = F.message("m1")
        message.invitationReply = .tentative
        var body = F.body(html: "<p>Invitation</p>")
        body.invitation = invitation(timeZoneID: "America/New_York", conferenceURL: "https://teams.example.com/l/1")
        let payload = F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts,
                                      invitationPermissionNeeded: [F.accountID], now: now)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try payload.jsonString().utf8)) as? [String: Any])
        let card = try XCTUnwrap(((object["messages"] as? [[String: Any]])?.first)?["invitation"] as? [String: Any])
        XCTAssertEqual(card.keys.sorted(), [
            "canAnswer", "canOpen", "conferenceURL", "guests", "isCancelled", "location", "needsPermission", "organizer", "repeats",
            "response", "title", "when", "whenElsewhere",
        ])
        XCTAssertEqual(card["response"] as? String, "tentative", "the answer travels by the name the shell compares")
        for key in card.keys {
            XCTAssertTrue(ConversationShellAssets.js.contains("inv." + key), "the shell never reads `\(key)`")
        }
        for answer in InvitationResponse.answers {
            XCTAssertTrue(ConversationShellAssets.js.contains("'" + answer.rawValue + "'"), "the shell never offers `\(answer.rawValue)`")
        }
        // A message without one carries no key at all, so the snapshot of message keys is unchanged.
        let plain = F.builder.build(messages: [F.message("m2")], bodies: [:], accounts: F.accounts, now: now)
        let plainObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try plain.jsonString().utf8)) as? [String: Any])
        XCTAssertNil(((plainObject["messages"] as? [[String: Any]])?.first)?["invitation"])
    }

    /// The shell's script runs in JavaScriptCore without a DOM; this only proves it still parses with the card in it.
    func testTheShellScriptStillParses() throws {
        let context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        _ = context.evaluateScript("(function () { return function () {" + ConversationShellAssets.js + "}; })();")
        XCTAssertNil(exception)
    }
}
