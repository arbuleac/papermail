import XCTest
@testable import PaperCore

/// The invitation card's overlap line (spec §5.14): “Overlaps 1:1 with Sam, 13:30 - 14:00”, from the calendar events the
/// store holds over the invitation's time, counted as the calendar's hatch counts them (§5.54), on the cards that can
/// say it; and how it travels to the shell and is kept with a render.
final class InvitationOverlapLineTests: XCTestCase {
    private typealias F = ConversationFixtures
    /// Friday 7 March 2025, 15:00 UTC.
    private let now = F.utc(2025, 3, 7, 15, 0)
    private let otherAccount = AccountID("acct-2")

    /// Tuesday 11 March 2025, 15:00 to 16:00 UTC, which the fixtures' builder shows as it is.
    private func invitation(
        method: CalendarInvitation.Method = .request,
        uid: String = "uid-1",
        sequence: Int = 0,
        start: Date = F.utc(2025, 3, 11, 15, 0),
        end: Date = F.utc(2025, 3, 11, 16, 0),
        isAllDay: Bool = false,
        isFloating: Bool = false,
        userAddress: String? = "me@example.com",
        userResponse: InvitationResponse? = .needsAction,
        userIsOrganizer: Bool = false
    ) -> CalendarInvitation {
        CalendarInvitation(
            method: method, uid: uid, sequence: sequence, title: "Design review", start: start, end: end, isAllDay: isAllDay,
            isFloating: isFloating, organizer: CalendarInvitation.Person(name: "Ada Lovelace", address: "ada@example.com"),
            attendees: [CalendarInvitation.Person(name: nil, address: "me@example.com", response: userResponse)],
            userAddress: userAddress, userResponse: userResponse, userIsOrganizer: userIsOrganizer
        )
    }

    private func event(_ id: String, _ title: String, _ start: Date, _ end: Date, account: AccountID? = nil,
                       response: CalendarEvent.Response = .accepted, isFree: Bool = false, isAllDay: Bool = false,
                       uid: String? = nil, sync: CalendarEvent.Sync = .synced) -> CalendarEvent {
        let account = account ?? F.accountID
        return CalendarEvent(id: CalendarEvent.localID(accountID: account, providerID: id), accountID: account, providerID: id,
                             title: title, start: start, end: end, isAllDay: isAllDay, response: response, isFree: isFree,
                             invitationUID: uid, sync: sync)
    }

    /// The card's line for one message carrying `invitation`, as the reader makes it: the cards that can say it, their
    /// lines from `events`, and the build.
    private func line(_ invitation: CalendarInvitation, events: [CalendarEvent], reply: InvitationResponse? = nil,
                      builder: RenderPayloadBuilder = F.builder) throws -> String? {
        var message = F.message("m1")
        message.invitationReply = reply
        var body = F.body(html: "<p>Invitation</p>")
        body.invitation = invitation
        let bodies = [message.id: body]
        let cards = builder.overlapCards(messages: [message], bodies: bodies)
        let lines = builder.overlapLines(for: cards, events: events, now: now)
        let payload = builder.build(messages: [message], bodies: bodies, accounts: F.accounts, invitationOverlaps: lines, now: now)
        return try XCTUnwrap(payload.messages.first?.invitation).overlap
    }

    // MARK: What it says

    func testNothingOverlappingSaysNothing() throws {
        XCTAssertNil(try line(invitation(), events: []))
        let touching = [
            event("before", "Standup", F.utc(2025, 3, 11, 14, 0), F.utc(2025, 3, 11, 15, 0)),
            event("after", "Retro", F.utc(2025, 3, 11, 16, 0), F.utc(2025, 3, 11, 17, 0)),
            event("other-day", "Design review prep", F.utc(2025, 3, 10, 15, 0), F.utc(2025, 3, 10, 16, 0)),
        ]
        XCTAssertNil(try line(invitation(), events: touching), "an event that ends as it starts, or starts as it ends, shares no time")
    }

    func testOneOverlapIsNamedWithTheTimeTheTwoShare() throws {
        let sam = event("sam", "1:1 with Sam", F.utc(2025, 3, 11, 15, 30), F.utc(2025, 3, 11, 16, 30))
        XCTAssertEqual(try line(invitation(), events: [sam]), "Overlaps 1:1 with Sam, 15:30 - 16:00")
        let inside = event("inside", "Coffee", F.utc(2025, 3, 11, 15, 15), F.utc(2025, 3, 11, 15, 45))
        XCTAssertEqual(try line(invitation(), events: [inside]), "Overlaps Coffee, 15:15 - 15:45")
        let elsewhere = event("other", "Dentist", F.utc(2025, 3, 11, 14, 30), F.utc(2025, 3, 11, 15, 30), account: otherAccount)
        XCTAssertEqual(try line(invitation(), events: [elsewhere]), "Overlaps Dentist, 15:00 - 15:30", "every account's calendar counts")
    }

    func testSeveralNameTheFirstByStartAndCountTheRest() throws {
        let events = [
            event("lunch", "Lunch & learn", F.utc(2025, 3, 11, 15, 45), F.utc(2025, 3, 11, 17, 0)),
            event("roadmap", "Roadmap", F.utc(2025, 3, 11, 15, 15), F.utc(2025, 3, 11, 15, 45), response: .tentative),
            event("hiring", "Hiring sync", F.utc(2025, 3, 11, 14, 30), F.utc(2025, 3, 11, 15, 30)),
        ]
        XCTAssertEqual(try line(invitation(), events: events), "Overlaps Hiring sync, 15:00 - 15:30, and 2 more")
        XCTAssertEqual(try line(invitation(), events: Array(events.prefix(2))), "Overlaps Roadmap, 15:15 - 15:45, and 1 more",
                       "a tentative event is busy")
    }

    func testAnEventWithNoTitleIsNamedSo() throws {
        let untitled = event("untitled", "  ", F.utc(2025, 3, 11, 15, 0), F.utc(2025, 3, 11, 16, 0))
        XCTAssertEqual(try line(invitation(), events: [untitled]), "Overlaps an event with no title, 15:00 - 16:00")
    }

    func testTimesFollowTheTwelveHourClock() throws {
        let american = RenderPayloadBuilder(calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"),
                                            timeZone: TimeZone(identifier: "UTC") ?? .current)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let sam = event("sam", "1:1 with Sam", F.utc(2025, 3, 11, 15, 30), F.utc(2025, 3, 11, 16, 30))
        let expected = "Overlaps 1:1 with Sam, " + formatter.string(from: F.utc(2025, 3, 11, 15, 30)) + " - "
            + formatter.string(from: F.utc(2025, 3, 11, 16, 0))
        XCTAssertEqual(try line(invitation(), events: [sam], builder: american), expected)
        XCTAssertTrue(expected.contains("PM"), "the system's 12-hour clock, as the When line follows it (§4.13)")
    }

    func testTheSharedTimeCarriesItsDayOnlyOffTheInvitationsFirstDay() throws {
        let late = invitation(start: F.utc(2025, 3, 11, 22, 0), end: F.utc(2025, 3, 12, 2, 0))
        let evening = event("evening", "Late call", F.utc(2025, 3, 11, 21, 0), F.utc(2025, 3, 11, 23, 0))
        XCTAssertEqual(try line(late, events: [evening]), "Overlaps Late call, 22:00 - 23:00")
        let night = event("night", "Night bus", F.utc(2025, 3, 12, 0, 30), F.utc(2025, 3, 12, 1, 0))
        XCTAssertEqual(try line(late, events: [night]), "Overlaps Night bus, Wed 12 Mar, 00:30 - 01:00")
        let across = event("across", "Watch", F.utc(2025, 3, 11, 23, 0), F.utc(2025, 3, 12, 1, 0))
        XCTAssertEqual(try line(late, events: [across]), "Overlaps Watch, Tue 11 Mar, 23:00 - Wed 12 Mar, 01:00")
        let toMidnight = event("midnight", "Wrap-up", F.utc(2025, 3, 11, 23, 0), F.utc(2025, 3, 12, 0, 0))
        XCTAssertEqual(try line(late, events: [toMidnight]), "Overlaps Wrap-up, 23:00 - 00:00", "a time that ends at midnight ends on its day")
    }

    // MARK: What counts

    func testTheInvitationsOwnEventIsNeverAnOverlap() throws {
        // Google and Exchange put the invitation in the calendar themselves, not answered (or tentative).
        let own = event("own", "Design review", F.utc(2025, 3, 11, 15, 0), F.utc(2025, 3, 11, 16, 0), response: .needsAction, uid: "uid-1")
        XCTAssertNil(try line(invitation(), events: [own]))
        let sam = event("sam", "1:1 with Sam", F.utc(2025, 3, 11, 15, 30), F.utc(2025, 3, 11, 16, 30))
        XCTAssertEqual(try line(invitation(), events: [own, sam]), "Overlaps 1:1 with Sam, 15:30 - 16:00", "and is not counted in the more")
        let elsewhere = event("own-2", "Design review", F.utc(2025, 3, 11, 15, 0), F.utc(2025, 3, 11, 16, 0), account: otherAccount,
                              uid: "uid-1")
        XCTAssertNil(try line(invitation(), events: [elsewhere]), "nor its copy in another account's calendar")
        let otherInvitation = event("theirs", "Vendor call", F.utc(2025, 3, 11, 15, 30), F.utc(2025, 3, 11, 16, 30),
                                    account: otherAccount, response: .needsAction, uid: "uid-9")
        XCTAssertEqual(try line(invitation(), events: [own, elsewhere, otherInvitation]), "Overlaps Vendor call, 15:30 - 16:00",
                       "another account's other invitation counts, as the calendar's card counts it")
    }

    func testARepeatingExchangeMeetingsOccurrenceIsTheInvitationsOwnEvent() throws {
        // Graph gives each occurrence its own iCalUId: the series' GlobalObjectId with the occurrence's date in it.
        let series = "040000008200E00074C5B7101A82E00800000000D0F3B1A2C8D4D901000000000000000010000000A1B2C3D4E5F60718293A4B5C6D7E8F90"
        var occurrence = Array(series)
        occurrence.replaceSubrange(32..<40, with: Array("07E9030B"))
        let own = event("own", "Design review", F.utc(2025, 3, 11, 15, 0), F.utc(2025, 3, 11, 16, 0), response: .needsAction,
                        uid: String(occurrence))
        XCTAssertNil(try line(invitation(uid: series), events: [own]))
    }

    func testDeclinedFreeAllDayAndRemovedEventsAreNotOverlaps() throws {
        let events = [
            event("declined", "Vendor demo", F.utc(2025, 3, 11, 15, 0), F.utc(2025, 3, 11, 16, 0), response: .declined),
            event("free", "Focus time", F.utc(2025, 3, 11, 15, 0), F.utc(2025, 3, 11, 16, 0), isFree: true),
            event("allday", "Contoso go-live", F.utc(2025, 3, 11), F.utc(2025, 3, 12), isAllDay: true),
            event("removed", "Set aside", F.utc(2025, 3, 11, 15, 0), F.utc(2025, 3, 11, 15, 30), sync: .deleting),
        ]
        XCTAssertNil(try line(invitation(), events: events))
        let waiting = event("creating", "Set aside for a mail", F.utc(2025, 3, 11, 15, 30), F.utc(2025, 3, 11, 16, 0), sync: .creating)
        XCTAssertEqual(try line(invitation(), events: events + [waiting]), "Overlaps Set aside for a mail, 15:30 - 16:00",
                       "time set aside on this Mac is busy before the provider has it")
    }

    func testDeclinedOnTheCalendarItSaysNothing() throws {
        let own = event("own", "Design review", F.utc(2025, 3, 11, 15, 0), F.utc(2025, 3, 11, 16, 0), response: .declined, uid: "uid-1")
        let sam = event("sam", "1:1 with Sam", F.utc(2025, 3, 11, 15, 30), F.utc(2025, 3, 11, 16, 30))
        XCTAssertNil(try line(invitation(), events: [own, sam]), "declined in the calendar, as the hatch has it")
    }

    func testAFloatingInvitationIsReadOnThisMacsClock() throws {
        // 15:00 to 16:00 written without a zone: on a Mac in Berlin (UTC+1 in March) that is 14:00 to 15:00 UTC.
        let berlin = RenderPayloadBuilder(calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_GB"),
                                          timeZone: TimeZone(identifier: "Europe/Berlin") ?? .current)
        let floating = invitation(isFloating: true)
        let call = event("call", "Call with Priya", F.utc(2025, 3, 11, 14, 30), F.utc(2025, 3, 11, 15, 30))
        XCTAssertEqual(try line(floating, events: [call], builder: berlin), "Overlaps Call with Priya, 15:30 - 16:00")
        let after = event("after", "Pottery", F.utc(2025, 3, 11, 15, 0), F.utc(2025, 3, 11, 16, 0))
        XCTAssertNil(try line(floating, events: [after], builder: berlin), "16:00 in Berlin, when the invitation has ended")
        let zoned = invitation()
        XCTAssertEqual(try line(zoned, events: [after], builder: berlin), "Overlaps Pottery, 16:00 - 17:00",
                       "a time with a zone is the instant it names")
    }

    // MARK: Which cards say it

    func testOnlyACardTheUserCanAnswerSaysIt() throws {
        let sam = [event("sam", "1:1 with Sam", F.utc(2025, 3, 11, 15, 30), F.utc(2025, 3, 11, 16, 30))]
        XCTAssertNil(try line(invitation(method: .cancel), events: sam), "a cancellation")
        XCTAssertNil(try line(invitation(userIsOrganizer: true), events: sam), "the user's own event")
        XCTAssertNil(try line(invitation(userAddress: nil), events: sam), "one not sent to this account")
        XCTAssertNil(try line(invitation(isAllDay: true, isFloating: true), events: sam), "an all-day invitation takes no hours")
        XCTAssertNil(try line(invitation(end: F.utc(2025, 3, 11, 15, 0)), events: sam), "one with no length")
    }

    func testItGoesWhenTheUserDeclinesAndComesBackWhenTheyAnswerAgain() throws {
        let sam = [event("sam", "1:1 with Sam", F.utc(2025, 3, 11, 15, 30), F.utc(2025, 3, 11, 16, 30))]
        XCTAssertNil(try line(invitation(), events: sam, reply: .declined))
        XCTAssertNil(try line(invitation(userResponse: .declined), events: sam), "declined as the invitation states it")
        XCTAssertEqual(try line(invitation(userResponse: .declined), events: sam, reply: .accepted), "Overlaps 1:1 with Sam, 15:30 - 16:00")
        XCTAssertEqual(try line(invitation(), events: sam, reply: .tentative), "Overlaps 1:1 with Sam, 15:30 - 16:00")
    }

    func testAnUpdatedCardSaysNothingAndTheLatestRevisionDoes() throws {
        let first = F.message("m1", date: F.utc(2025, 3, 1, 9, 0))
        let second = F.message("m2", date: F.utc(2025, 3, 2, 9, 0))
        var oldBody = F.body(html: "<p>Invitation</p>")
        oldBody.invitation = invitation()
        var newBody = F.body(html: "<p>Updated</p>")
        newBody.invitation = invitation(sequence: 1, start: F.utc(2025, 3, 11, 16, 0), end: F.utc(2025, 3, 11, 17, 0))
        let bodies = [first.id: oldBody, second.id: newBody]
        let cards = F.builder.overlapCards(messages: [first, second], bodies: bodies)
        XCTAssertEqual(cards.map(\.message), [second.id], "only the latest revision is answered, so only it says what it overlaps")
        let sam = event("sam", "1:1 with Sam", F.utc(2025, 3, 11, 15, 30), F.utc(2025, 3, 11, 16, 30))
        let lines = F.builder.overlapLines(for: cards, events: [sam], now: now)
        let payload = F.builder.build(messages: [first, second], bodies: bodies, accounts: F.accounts, invitationOverlaps: lines, now: now)
        XCTAssertEqual(payload.messages.map { $0.invitation?.overlap }, [nil, "Overlaps 1:1 with Sam, 16:00 - 16:30"])
    }

    func testTheCardsAndTheTimeTheCalendarIsReadOver() throws {
        let draft = F.message("d1", roles: [.drafts])
        let invited = F.message("m1")
        let plain = F.message("m2")
        let other = F.message("m3")
        var body = F.body(html: "<p>Invitation</p>")
        body.invitation = invitation()
        var otherBody = F.body(html: "<p>Another</p>")
        otherBody.invitation = invitation(uid: "uid-2", start: F.utc(2025, 3, 13, 9, 0), end: F.utc(2025, 3, 13, 9, 30))
        let bodies = [draft.id: body, invited.id: body, plain.id: F.body(html: "<p>Hi</p>"), other.id: otherBody]

        let cards = F.builder.overlapCards(messages: [draft, invited, plain, other], bodies: bodies)
        XCTAssertEqual(cards.map(\.message), [invited.id, other.id], "never a draft's, and only messages with an invitation")
        XCTAssertEqual(cards.map(\.uid), ["uid-1", "uid-2"])
        XCTAssertEqual(InvitationOverlaps(cards: cards).interval,
                       DateInterval(start: F.utc(2025, 3, 11, 15, 0), end: F.utc(2025, 3, 13, 9, 30)), "every card's time, joined")
        XCTAssertEqual(F.builder.overlapCards(messages: [invited], bodies: bodies, pending: [invited.id]), [],
                       "a reply still in the outbox carries no card")
        XCTAssertNil(InvitationOverlaps(cards: F.builder.overlapCards(messages: [plain], bodies: bodies)).interval,
                     "a conversation without a card reads no calendar")
        XCTAssertNil(InvitationOverlaps.none.interval)
    }

    // MARK: How it travels and is kept

    func testTheLineTravelsAsOverlapAndIsLeftOutWhenThereIsNone() throws {
        var body = F.body(html: "<p>Invitation</p>")
        body.invitation = invitation()
        let message = F.message("m1")
        func card(_ lines: [MessageID: String]) throws -> [String: Any] {
            let payload = F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts,
                                          invitationOverlaps: lines, now: now)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try payload.jsonString().utf8)) as? [String: Any])
            return try XCTUnwrap(((object["messages"] as? [[String: Any]])?.first)?["invitation"] as? [String: Any])
        }
        XCTAssertNil(try card([:])["overlap"], "no key at all, so a card without one keeps today's keys")
        XCTAssertEqual(try card([message.id: "Overlaps 1:1 with Sam, 15:30 - 16:00"])["overlap"] as? String,
                       "Overlaps 1:1 with Sam, 15:30 - 16:00")
        XCTAssertTrue(ConversationShellAssets.js.contains("inv.overlap"))
    }

    func testARenderKeepsItsLinesAndAChangedLineIsAChangedRender() {
        let message = F.message("m1")
        let card = InvitationOverlaps.Card(message: message.id, uid: "uid-1",
                                           span: DateInterval(start: F.utc(2025, 3, 11, 15, 0), end: F.utc(2025, 3, 11, 16, 0)))
        let saying = InvitationOverlaps(cards: [card], lines: [message.id: "Overlaps 1:1 with Sam, 15:30 - 16:00"])
        let rendered = RenderInputs(messages: [message], invitationOverlaps: saying) { _ in true }
        XCTAssertEqual(rendered.invitationOverlaps, saying)

        // A store change the slot hears of checks metadata and bodies; the lines it rendered stay as they were.
        var read = message
        read.isRead = false
        let fresh = rendered.refreshed(with: [read]) { _ in true }
        XCTAssertEqual(fresh.invitationOverlaps, saying)
        XCTAssertEqual(rendered.flagPatches(to: fresh)?.count, 1, "a read change still patches the flags alone")

        let silent = RenderInputs(messages: [message], invitationOverlaps: InvitationOverlaps(cards: [card])) { _ in true }
        XCTAssertNotEqual(rendered, silent)
        XCTAssertNil(rendered.flagPatches(to: silent), "a line that changed needs a payload")
    }
}
