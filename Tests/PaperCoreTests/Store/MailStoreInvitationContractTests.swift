import XCTest
import PaperCore

/// The `MailStoring` contract for calendar invitations (roadmap Q3.2, docs/DATA-MODEL.md `bodies.invitation_json`,
/// `messages.invitation_reply`): the facts travel with the body, and the user's answer is local state that the
/// operation that records it writes, no provider report undoes, and a give-up puts back. Written as an extension so
/// `SQLiteMailStoreContractTests` inherits every case and both stores are held to the same semantics.
extension MailStoreContractTests {
    private var invitationMessage: MessageID { MessageID(accountID: accountA, providerID: "invite") }

    private func storedInvitation() -> CalendarInvitation {
        CalendarInvitation(
            method: .request, uid: "uid-7@google.com", sequence: 2, recurrenceID: date(3_600),
            title: "Design review", start: date(86_400), end: date(90_000), timeZoneID: "Europe/Berlin",
            location: "Room 4, Level 2", conferenceURL: "https://meet.google.com/abc-defg-hij",
            organizer: CalendarInvitation.Person(name: "Ben Carter", address: "ben@contoso.test"),
            attendees: [CalendarInvitation.Person(name: nil, address: "a@example.com", response: .needsAction),
                        CalendarInvitation.Person(name: "Ada", address: "ada@contoso.test", response: .tentative)],
            repeats: "Every week on Tuesday", userAddress: "a@example.com", userResponse: .needsAction,
            graphEventID: "AAMkEvent=", calendarText: "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n"
        )
    }

    private func answer(_ response: InvitationResponse, previous: InvitationResponse? = nil) -> InvitationAnswer {
        InvitationAnswer(response: response, previous: previous, uid: "uid-7@google.com", title: "Design review",
                         start: date(86_400), end: date(90_000), organizer: EmailAddress(address: "ben@contoso.test"),
                         attendee: EmailAddress(address: "a@example.com"))
    }

    private func seedInvitation(receivedAt: Date? = nil) throws {
        try store.upsertMessages([message("invite", in: "c-invite", subject: "Invitation: Design review", date: receivedAt ?? date(0))])
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>Invitation</p>", text: nil), renderedHTML: "<p>Invitation</p>",
                                      plainText: "Invitation", invitation: storedInvitation()), for: invitationMessage)
    }

    func testAnInvitationTravelsWithItsBody() throws {
        try seedInvitation()
        XCTAssertEqual(try store.body(for: invitationMessage)?.invitation, storedInvitation())
        try store.upsertMessages([message("plain", in: "c-plain")])
        let plain = MessageID(accountID: accountA, providerID: "plain")
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>Hi</p>", text: nil), renderedHTML: "<p>Hi</p>", plainText: "Hi"), for: plain)
        XCTAssertNil(try store.body(for: plain)?.invitation, "a body without one has none")
        XCTAssertNil(try store.message(invitationMessage)?.invitationReply, "nobody has answered yet")
    }

    /// The calendar reads only the invitation, on every selection: the same one the body carries, none for a body
    /// without one, a missing body or an evicted one.
    func testTheInvitationReadsAloneAsTheBodyCarriesIt() throws {
        XCTAssertNil(try store.invitation(for: invitationMessage), "no message, no body")
        try seedInvitation()
        XCTAssertEqual(try store.invitation(for: invitationMessage), storedInvitation())
        try store.upsertMessages([message("plain", in: "c-plain")])
        let plain = MessageID(accountID: accountA, providerID: "plain")
        XCTAssertNil(try store.invitation(for: plain), "no body yet")
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>Hi</p>", text: nil), renderedHTML: "<p>Hi</p>", plainText: "Hi"), for: plain)
        XCTAssertNil(try store.invitation(for: plain), "a body without one")
        XCTAssertEqual(try store.evictBodies(receivedBefore: date(86_400 * 365), excluding: [], limit: 10), 2)
        XCTAssertNil(try store.invitation(for: invitationMessage), "an evicted body keeps no calendar text, as body(for:) says")
    }

    func testTheAnswerIsRecordedByItsOperationAndSurvivesProviderReports() throws {
        try seedInvitation()
        let operation = Operation(accountID: accountA, change: .answerInvitation(answer(.accepted)), targets: [invitationMessage])
        try store.enqueue(operation)
        XCTAssertEqual(try store.message(invitationMessage)?.invitationReply, .accepted, "recorded in the enqueue's transaction")
        XCTAssertEqual(try store.messages(in: ConversationID(accountID: accountA, providerID: "c-invite")).first?.invitationReply, .accepted)

        // Providers never report it: their copy of the message comes without, while the operation is live and after.
        try store.upsertMessages([message("invite", in: "c-invite", subject: "Invitation: Design review", isRead: false)])
        XCTAssertEqual(try store.message(invitationMessage)?.invitationReply, .accepted)
        try store.confirmOperation(id: operation.id)
        try store.upsertMessages([message("invite", in: "c-invite", subject: "Invitation: Design review")])
        try store.writeBackfillMessages([message("invite", in: "c-invite", subject: "Invitation: Design review")], refreshExisting: true)
        XCTAssertEqual(try store.message(invitationMessage)?.invitationReply, .accepted)

        // A body fetched again (after an eviction, say) states the invitation as it came; the answer stays on the message.
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>Again</p>", text: nil), renderedHTML: "<p>Again</p>",
                                      plainText: "Again", invitation: storedInvitation()), for: invitationMessage)
        XCTAssertEqual(try store.message(invitationMessage)?.invitationReply, .accepted)
    }

    func testAGivenUpAnswerPutsBackTheAnswerItReplaced() throws {
        try seedInvitation()
        let first = Operation(accountID: accountA, change: .answerInvitation(answer(.accepted)), targets: [invitationMessage],
                              createdAt: date(10))
        try store.enqueue(first)
        try store.confirmOperation(id: first.id)
        var second = Operation(accountID: accountA, change: .answerInvitation(answer(.declined, previous: .accepted)),
                               targets: [invitationMessage], createdAt: date(20))
        try store.enqueue(second)
        XCTAssertEqual(try store.message(invitationMessage)?.invitationReply, .declined)

        second.status = .failed
        second.attempts = 5
        try store.updateOperation(second)
        XCTAssertEqual(try store.message(invitationMessage)?.invitationReply, .accepted, "the answer that went out is shown again")
        let summary = try XCTUnwrap(try store.conversations(ConversationQuery(view: .all)).first { $0.id.providerID == "c-invite" })
        XCTAssertEqual(summary.failedOperation, .answerInvitation)
    }

    func testAGiveUpReplaysANewerAnswerOnTop() throws {
        try seedInvitation()
        var accept = Operation(accountID: accountA, change: .answerInvitation(answer(.accepted)), targets: [invitationMessage],
                               createdAt: date(10))
        try store.enqueue(accept)
        let tentative = Operation(accountID: accountA, change: .answerInvitation(answer(.tentative, previous: .accepted)),
                                  targets: [invitationMessage], createdAt: date(20))
        try store.enqueue(tentative)
        accept.status = .failed
        try store.updateOperation(accept)
        XCTAssertEqual(try store.message(invitationMessage)?.invitationReply, .tentative, "the newer live answer still wins")
    }

    /// The newer answer was queued while the first was still on its way, so it names the first as the one it replaced.
    /// The first is given up: it never went out. When the newer one is given up too, the card goes back to the answer
    /// before both, never to the first.
    func testAGiveUpNeverPutsBackAnAnswerThatWasItselfGivenUp() throws {
        try seedInvitation()
        var accept = Operation(accountID: accountA, change: .answerInvitation(answer(.accepted)), targets: [invitationMessage],
                               createdAt: date(10))
        try store.enqueue(accept)
        accept.status = .uncertain
        accept.attempts = 1
        try store.updateOperation(accept)
        var decline = Operation(accountID: accountA, change: .answerInvitation(answer(.declined, previous: .accepted)),
                                targets: [invitationMessage], createdAt: date(20))
        try store.enqueue(decline)

        accept.status = .failed
        try store.updateOperation(accept)
        XCTAssertEqual(try store.message(invitationMessage)?.invitationReply, .declined, "the newer live answer still wins")
        let live = try XCTUnwrap(try store.pendingOperations(accountID: accountA, limit: 10).first { $0.id == decline.id })
        guard case .answerInvitation(let carried) = live.change else { return XCTFail("\(live.change)") }
        XCTAssertNil(carried.previous, "it now replaces what the given-up answer replaced")

        decline = live
        decline.status = .failed
        try store.updateOperation(decline)
        XCTAssertNil(try store.message(invitationMessage)?.invitationReply, "no answer went out, so none is shown")
    }

    func testEvictionTakesTheCalendarTextAndKeepsTheAnswer() throws {
        try seedInvitation(receivedAt: date(-540 * 86_400))
        let operation = Operation(accountID: accountA, change: .answerInvitation(answer(.accepted)), targets: [invitationMessage])
        try store.enqueue(operation)
        try store.confirmOperation(id: operation.id)

        XCTAssertEqual(try store.evictBodies(receivedBefore: date(-90 * 86_400), excluding: [], limit: 10), 1)
        XCTAssertNil(try store.body(for: invitationMessage), "an evicted body is fetched again when opened")
        XCTAssertEqual(try store.message(invitationMessage)?.invitationReply, .accepted)
        // Fetched again, the invitation is back with it.
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>Again</p>", text: nil), renderedHTML: "<p>Again</p>",
                                      plainText: "Again", invitation: storedInvitation()), for: invitationMessage)
        XCTAssertEqual(try store.body(for: invitationMessage)?.invitation?.uid, "uid-7@google.com")
    }

    func testAnswerChangesReachTheConversationsObservers() throws {
        try seedInvitation()
        let delivered = expectation(description: "the answer is observed")
        delivered.assertForOverFulfill = false
        let observation = store.observeConversation(ConversationID(accountID: accountA, providerID: "c-invite")) { messages in
            if messages.first?.invitationReply == .tentative { delivered.fulfill() }
        }
        defer { observation.cancel() }
        try store.enqueue(Operation(accountID: accountA, change: .answerInvitation(answer(.tentative)), targets: [invitationMessage]))
        wait(for: [delivered], timeout: 5)
    }
}
