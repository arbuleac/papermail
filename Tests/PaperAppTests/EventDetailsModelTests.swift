import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// What an event's details say (spec §5.54, “Event details”), word for word, without a view: the fixed clock is
/// Thursday 19 November 2026, 11:40 in Berlin.
@MainActor
final class EventDetailsModelTests: XCTestCase {
    private typealias Support = CalendarTestSupport
    private let text = CalendarText(calendar: CalendarTestSupport.calendar)

    private func model(_ event: CalendarEvent, details: CalendarEventDetails? = nil, answer: EventAnswerState? = nil,
                       related: RelatedInvitation? = nil, setAside: MessageMetadata?? = nil, kind: ProviderKind = .gmail,
                       permission: Bool = false, overlap: String? = nil, selected: ConversationID? = nil,
                       guestsExpanded: Bool = false, notesExpanded: Bool = false) -> EventDetailsModel {
        EventDetailsModel(.init(event: event, details: details, answer: answer, related: related, setAsideMessage: setAside,
                                accountName: kind == .gmail ? "Demo Gmail" : "Demo Outlook", kind: kind, permissionNeeded: permission,
                                overlap: overlap, selectedConversation: selected, guestsExpanded: guestsExpanded,
                                notesExpanded: notesExpanded, text: text, now: Support.at(11, 40)))
    }

    private func invited(_ response: CalendarEvent.Response = .needsAction, series: String? = nil, zone: String? = nil,
                         call: CallService? = nil, join: String? = nil, location: String? = nil) -> CalendarEvent {
        var event = Support.event("evt", title: "Design critique", start: Support.at(19), end: Support.at(20), response: response,
                                  joinURL: join, location: location, invitationUID: "uid-1",
                                  webURL: "https://outlook.example.test/item")
        event.seriesID = series
        event.timeZone = zone
        event.callService = call
        event.organizer = "Rachel Kim"
        return event
    }

    private func message(_ subject: String, roles: Set<MailboxRole> = [.inbox]) -> MessageMetadata {
        MessageMetadata(id: MessageID(accountID: Support.accountA.id, providerID: "m1"),
                        conversationID: ConversationID(accountID: Support.accountA.id, providerID: "c1"), subject: subject,
                        snippet: "", from: EmailAddress(name: "Rachel Kim", address: "rachel@example.test"), to: [],
                        date: Support.at(9, on: Support.day(12)), roles: roles, isRead: true, isStarred: false, hasAttachments: false)
    }

    private func words(_ row: EventDetailsModel.Row?) -> [String] {
        (row?.lines ?? []).map { $0.map(\.text).joined() }
    }

    // MARK: The top

    func testAnInvitationNotAnsweredReadsAsSpecified() {
        let card = model(invited(series: "S", zone: "America/Los_Angeles", call: .teams, join: "https://teams.microsoft.com/l/x",
                                 location: "Bay 4"),
                         details: CalendarEventDetails(repeats: "Every week on Thursday, 12 times"),
                         kind: .microsoft, overlap: "Overlaps Roadmap sync with Elena, 19:30 - 20:00")
        XCTAssertEqual(card.kicker, "Demo Outlook · Not answered")
        XCTAssertEqual(card.title, "Design critique")
        XCTAssertEqual(card.when, "Thu 19 Nov · 19:00 - 20:00")
        XCTAssertEqual(card.elsewhere, "Thu 19 Nov · 10:00 - 11:00 Pacific Time")
        XCTAssertEqual(card.repeats, "Every week on Thursday, 12 times")
        XCTAssertEqual(card.overlap, "Overlaps Roadmap sync with Elena, 19:30 - 20:00")
        XCTAssertEqual(card.answers, .init(chosen: nil, waiting: false, asksSpan: true))
        XCTAssertEqual(card.rows.map(\.label), ["Where", "Call", "Organizer"])
        XCTAssertEqual(words(card.rows.first { $0.label == "Call" }), ["Teams"])
        XCTAssertEqual(card.rows.first { $0.label == "Call" }?.copy?.value, "https://teams.microsoft.com/l/x", "copied as written")
        XCTAssertEqual(card.actions.map(\.title), ["Join", "Open in Outlook"])
        XCTAssertEqual(card.spokenTop, "Demo Outlook, not answered. Design critique. Thursday 19 November, 19:00 to 20:00.")
    }

    func testElsewhereFollowsTheTwelveHourSetting() {
        var calendar = Support.calendar
        calendar.locale = Locale(identifier: "en_US")
        let us = CalendarText(calendar: calendar)
        let card = EventDetailsModel(.init(event: invited(zone: "America/Los_Angeles"), accountName: "A", text: us, now: Support.today))
        XCTAssertTrue(card.elsewhere?.contains("10:00\u{202F}AM") == true, card.elsewhere ?? "")
        XCTAssertNil(model(invited(zone: "Europe/Paris")).elsewhere, "the same offset as this Mac's: nothing to say")
    }

    func testNoTitleIsAPlaceholderAndACancellationIsStruck() {
        var untitled = invited()
        untitled.title = ""
        let card = model(untitled)
        XCTAssertEqual(card.title, "No title")
        XCTAssertTrue(card.titleIsPlaceholder)

        let cancel = CalendarInvitation(method: .cancel, uid: "uid-1", sequence: 2, title: "Design critique", start: Support.at(19),
                                        end: Support.at(20))
        let cancelled = model(invited(), related: RelatedInvitation(message: message("Canceled: Design critique"), invitation: cancel))
        XCTAssertTrue(cancelled.isCancelled)
        XCTAssertEqual(cancelled.kicker, "Demo Gmail · Cancelled")
        XCTAssertNil(cancelled.answers, "nothing to answer")
        XCTAssertEqual(cancelled.accessibilityName, "Cancelled event: Design critique")
    }

    func testKindsSayWhatTheyAreAndOfferNoAnswer() {
        var focus = Support.event("f", title: "Focus time", start: Support.at(15), end: Support.at(17), response: .organizer, isFree: true)
        focus.kind = .focusTime
        XCTAssertEqual(model(focus).kicker, "Demo Gmail · Focus time")
        XCTAssertNil(model(focus).answers)
        let free = Support.event("g", title: "Gym", start: Support.at(18), end: Support.at(19), response: .organizer, isFree: true)
        XCTAssertEqual(model(free).kicker, "Demo Gmail · Free")
    }

    // MARK: Answers

    func testTheChosenAnswerAndItsWaitingAndFailedLines() {
        XCTAssertEqual(model(invited(.tentative)).answers?.chosen, .tentative)
        XCTAssertEqual(model(invited(.tentative)).kicker, "Demo Gmail · Tentative")
        let waiting = model(invited(.accepted), answer: .live(.accepted))
        XCTAssertEqual(waiting.answers, .init(chosen: .accepted, waiting: true, asksSpan: false))
        XCTAssertEqual(model(invited(), answer: .failed).answerLine, .failed)
        XCTAssertEqual(model(invited(.accepted), answer: .live(.accepted), permission: true).answerLine, .permission(Support.accountA.id))
        let outlook = model(invited(.declined), kind: .microsoft)
        XCTAssertEqual(outlook.answerLine, .outlookDecline)
        XCTAssertEqual(outlook.kicker, "Demo Outlook · Declined")
        XCTAssertNil(model(invited(.declined), overlap: "Overlaps x").overlap, "no overlap once declined")
    }

    func testAnOccurrenceWhoseMailIsForItAloneAsksNoSpan() {
        let occurrence = CalendarInvitation(method: .request, uid: "uid-1", recurrenceID: Support.at(19), title: "Design critique",
                                            start: Support.at(19), end: Support.at(20),
                                            organizer: .init(name: "Rachel Kim", address: "rachel@example.test"))
        let card = model(invited(series: "S"), related: RelatedInvitation(message: message("Design critique"), invitation: occurrence))
        XCTAssertEqual(card.answers?.asksSpan, false)
    }

    func testTheUsersOwnEventAndTimeSetAsideOfferNoAnswers() {
        let own = Support.event("o", title: "Fabrikam renewal call", start: Support.at(16), end: Support.at(16, 30), response: .organizer)
        let ownCard = model(own, details: CalendarEventDetails(userIsOrganizer: true, guests: [EventGuest(address: "s@x.test", response: .accepted)],
                                                               guestCount: 1, answersKnown: true))
        XCTAssertNil(ownCard.answers)
        XCTAssertEqual(words(ownCard.rows.first { $0.label == "Organizer" }), ["You"])
        XCTAssertEqual(words(ownCard.rows.first { $0.label == "Guests" }), ["Accepted: s@x.test"])

        let block = Support.event("b", title: "Lease renewal", start: Support.at(14, 30), end: Support.at(15), response: .organizer,
                                  sourceMessage: MessageID(accountID: Support.accountA.id, providerID: "m1"), sync: .creating)
        let blockCard = model(block, setAside: .some(message("Lease renewal")))
        XCTAssertEqual(blockCard.kicker, "Demo Gmail · Set aside for a mail")
        XCTAssertEqual(blockCard.status?.text, "Waiting to reach Google Calendar")
        XCTAssertNil(blockCard.answers)
        XCTAssertEqual(blockCard.actions.map(\.title), ["Remove"], "no Open in while it waits")
        XCTAssertEqual(blockCard.mail?.subject, "Lease renewal")
        XCTAssertEqual(blockCard.mail?.meta, "Rachel Kim · Thu 12 Nov")
        let gone = model(block, setAside: .some(nil))
        XCTAssertEqual(gone.mail?.subject, "The mail is no longer on this Mac.")
        XCTAssertNil(gone.mail?.message)
        var failed = block
        failed.sync = .failed
        XCTAssertEqual(model(failed, setAside: .some(nil)).status?.text, "Couldn't add this to Google Calendar.")
    }

    // MARK: Rows

    func testWhereIsLeftOutWhenItOnlyRepeatsTheCallAndNeverAMapsLink() {
        let teams = model(invited(join: "https://teams.microsoft.com/l/x", location: "Microsoft Teams Meeting"))
        XCTAssertFalse(teams.rows.contains { $0.label == "Where" })
        let place = model(invited(location: "Casa Lisboa, 24 Valencia Street"))
        let piece = place.rows.first { $0.label == "Where" }?.lines.first?.first
        XCTAssertEqual(piece?.text, "Casa Lisboa, 24 Valencia Street")
        XCTAssertNil(piece?.link, "a place is shown, never turned into a maps link")
        let web = model(invited(location: "https://rooms.example.test/b4"))
        XCTAssertEqual(web.rows.first { $0.label == "Where" }?.lines.first?.first?.link?.absoluteString, "https://rooms.example.test/b4")
    }

    func testTheCallsNumberPinCodesAndCopies() {
        let call = EventCall(meetingID: "284 113 905 771", passcode: "Qx7bTe",
                             phones: [EventPhone(number: "+44 20 7946 0000", dial: "+442079460000,,601225430#", region: "GB", pin: "601225430"),
                                      EventPhone(number: "+1 555-0134", dial: "+15550134,,601225430#", region: "US", pin: "601225430")],
                             pinLabel: .conferenceID, morePhonesURL: "https://dialin.example.test/more")
        let card = model(invited(join: "https://teams.microsoft.com/l/x"), details: CalendarEventDetails(call: call))
        let phone = card.rows.first { $0.label == "Phone" }
        let region = Locale.current.region?.identifier
        let first = region == "GB" ? "+44 20 7946 0000 (GB)" : region == "US" ? "+1 555-0134 (US)" : "+44 20 7946 0000 (GB)"
        XCTAssertEqual(words(phone).first, first, "this Mac's region first")
        XCTAssertEqual(words(phone).dropFirst().first, "Conference ID 601 225 430#")
        XCTAssertEqual(words(phone).last, "More phone numbers")
        XCTAssertEqual(phone?.lines.first?.first?.link?.scheme, "tel")
        XCTAssertTrue(phone?.lines.first?.first?.link?.absoluteString.hasSuffix("%23") == true, "a # is written %23")
        XCTAssertEqual(card.rows.first { $0.label == "Meeting ID" }?.copy?.item, .meetingID)
        XCTAssertEqual(card.rows.first { $0.label == "Passcode" }?.copy?.value, "Qx7bTe")
        XCTAssertEqual(EventDetailsModel.formattedPIN("248913557"), "248 913 557#")
        XCTAssertEqual(EventDetailsModel.formattedPIN("1234#"), "1234#", "a PIN with its # is as the provider writes it")
    }

    func testGuestsByAnswerCutAndShownWhole() {
        let people = ["Priya Raman", "Hannah Becker", "Sam Okafor", "Theo Nakamura", "Linda Morgan", "Ben Carter"].map {
            EventGuest(name: $0, address: $0.lowercased().replacingOccurrences(of: " ", with: ".") + "@x.test", response: .accepted)
        }
        let me = EventGuest(name: "Alex", address: "alex@x.test", response: .accepted, isSelf: true)
        let details = CalendarEventDetails(guests: [me] + people + [EventGuest(name: "Jordan Lee", address: "j@x.test", response: .tentative),
                                                                    EventGuest(name: "Maya Chen", address: "m@x.test", response: .declined)],
                                           guestCount: 50, answersKnown: true)
        let cut = model(invited(.accepted), details: details)
        XCTAssertEqual(words(cut.rows.first { $0.label == "Guests" }), [
            "Accepted: You, Priya Raman, Hannah Becker, Sam Okafor +3 more", "Tentative: Jordan Lee", "Declined: Maya Chen", "Show all 50",
        ])
        let whole = model(invited(.accepted), details: details, guestsExpanded: true)
        let lines = words(whole.rows.first { $0.label == "Guests" })
        XCTAssertEqual(lines.first, "Accepted: You, Priya Raman, Hannah Becker, Sam Okafor, Theo Nakamura, Linda Morgan, Ben Carter")
        XCTAssertEqual(Array(lines.suffix(2)), ["and 41 more", "Show fewer"])

        var unknown = details
        unknown.answersKnown = false
        unknown.guestCount = 9
        XCTAssertEqual(words(model(invited(), details: unknown).rows.first { $0.label == "Guests" }).first,
                       "You, Priya Raman, Hannah Becker, Sam Okafor +5 more")
        var hidden = details
        hidden.guestsHidden = true
        XCTAssertFalse(model(invited(), details: hidden).rows.contains { $0.label == "Guests" }, "the organizer hides them")
        let alone = CalendarEventDetails(guests: [me], guestCount: 1, answersKnown: true)
        XCTAssertFalse(model(invited(), details: alone).rows.contains { $0.label == "Guests" }, "“You” alone says nothing")
    }

    /// The details were read before the user answered: their own line says the answer the card shows (the store's row,
    /// or an answer on its way), never the one read earlier.
    func testTheUsersOwnLineFollowsTheAnswerTheCardShows() {
        let me = EventGuest(name: "Alex", address: "alex@x.test", response: .needsAction, isSelf: true)
        let priya = EventGuest(name: "Priya Raman", address: "p@x.test", response: .accepted)
        let details = CalendarEventDetails(guests: [me, priya], guestCount: 2, answersKnown: true)
        XCTAssertEqual(words(model(invited(), details: details).rows.first { $0.label == "Guests" }),
                       ["Accepted: Priya Raman", "Not answered: You"])
        XCTAssertEqual(words(model(invited(.accepted), details: details).rows.first { $0.label == "Guests" }),
                       ["Accepted: You, Priya Raman"], "the row is ahead of the details")
        XCTAssertEqual(words(model(invited(), details: details, answer: .live(.declined)).rows.first { $0.label == "Guests" }),
                       ["Accepted: Priya Raman", "Declined: You"], "an answer on its way")
        var read = details
        read.guests[0].response = .accepted
        XCTAssertEqual(words(model(invited(), details: read).rows.first { $0.label == "Guests" }),
                       ["Accepted: Priya Raman", "Not answered: You"], "a give-up put the row back: the row wins")
    }

    func testTheMailRowAndItsTrashAndTheSelectedConversation() throws {
        let invitation = CalendarInvitation(method: .request, uid: "uid-1", title: "Design critique", start: Support.at(19), end: Support.at(20),
                                            organizer: .init(name: "Rachel Kim", address: "rachel@example.test"))
        let related = RelatedInvitation(message: message("Design critique", roles: [.trash]), invitation: invitation)
        let card = model(invited(), related: related)
        XCTAssertEqual(card.mail?.subject, "Design critique")
        XCTAssertEqual(card.mail?.meta, "Rachel Kim · Thu 12 Nov · In the Trash")
        XCTAssertEqual(card.mail?.accessibilityLabel, "Show the mail: Design critique, from Rachel Kim, Thursday 12 November")
        XCTAssertNil(model(invited(), related: related, selected: related.message.conversationID).mail,
                     "the reader shows that conversation beside the column")
    }

    func testNotesAndTheirCutLine() {
        let notes = EventNotes(text: "Agenda…", links: [], isCut: true)
        XCTAssertEqual(model(invited(), details: CalendarEventDetails(notes: notes)).notes, notes)
        XCTAssertNil(model(invited(), details: CalendarEventDetails(notes: notes)).notesCutLine, "said once expanded")
        XCTAssertEqual(model(invited(), details: CalendarEventDetails(notes: notes), kind: .microsoft, notesExpanded: true).notesCutLine,
                       "The rest is in Outlook.")
    }
}
