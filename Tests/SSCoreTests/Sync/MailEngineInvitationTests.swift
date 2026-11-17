import Foundation
import XCTest
@testable import SSCore

/// Answering invitations through the engine (docs/ARCHITECTURE.md, "Calendar invitations"): the answer is recorded
/// locally at once and queued; a missing calendar permission holds it, untried, while the account asks to reconnect
/// with the added scope; once granted it goes out; a give-up puts the previous answer back; and the invitation is
/// read when the body is stored, never when it is opened.
final class MailEngineInvitationTests: XCTestCase {
    private let target = MessageID(accountID: Fixtures.accountID, providerID: "2")

    private func invitation(method: CalendarInvitation.Method = .request, userIsOrganizer: Bool = false) -> CalendarInvitation {
        CalendarInvitation(
            method: method, uid: "uid-1@google.com", sequence: 3, title: "Design review",
            start: Fixtures.baseDate.addingTimeInterval(86_400), end: Fixtures.baseDate.addingTimeInterval(90_000),
            organizer: CalendarInvitation.Person(name: "Ben Carter", address: "ben@example.com"),
            attendees: [CalendarInvitation.Person(name: "Me Myself", address: "me@example.com", response: .needsAction)],
            userAddress: "me@example.com", userResponse: .needsAction, userIsOrganizer: userIsOrganizer
        )
    }

    private func harness(permission: AccountPermission? = nil, applyResults: [Result<Void, Error>] = [],
                         invitation: CalendarInvitation? = nil, tune: (inout SyncTuning) -> Void = { _ in }) async throws -> EngineHarness {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        provider.applyResults = applyResults
        provider.permissionNeeded = permission
        let harness = try EngineHarness(provider: provider, tune: tune)
        harness.engine.start()
        try await waitUntil("bootstrap complete") { try harness.store.syncCursor(for: Fixtures.accountID) == "c0" }
        try harness.store.saveBody(StoredBody(body: MessageBody(html: "<p>Invite</p>", text: nil), renderedHTML: "<p>Invite</p>",
                                              plainText: "Invite", invitation: invitation ?? self.invitation()), for: target)
        return harness
    }

    private func answers(_ provider: ScriptedProvider) -> [InvitationAnswer] {
        provider.applyCalls.compactMap { call in
            if case .answerInvitation(let answer) = call.change { return answer }
            return nil
        }
    }

    func testAnAnswerIsRecordedAtOnceAndReplayedOnce() async throws {
        let harness = try await harness()
        try harness.engine.answerInvitation(.accepted, to: target)
        XCTAssertEqual(try harness.store.message(target)?.invitationReply, .accepted, "the card shows the answer before any request")

        try await waitUntil("answer applied") { self.answers(harness.provider).count == 1 }
        let answer = try XCTUnwrap(answers(harness.provider).first)
        XCTAssertEqual(answer.response, .accepted)
        XCTAssertNil(answer.previous)
        XCTAssertEqual(answer.uid, "uid-1@google.com")
        XCTAssertEqual(answer.sequence, 3)
        XCTAssertEqual(answer.organizer, EmailAddress(name: "Ben Carter", address: "ben@example.com"))
        XCTAssertEqual(answer.attendee, EmailAddress(name: "Me Myself", address: "me@example.com"))
        XCTAssertEqual(harness.provider.applyCalls.last?.ids, ["2"])
        try await waitUntil("operation confirmed") { try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty }
        XCTAssertEqual(try harness.store.message(target)?.invitationReply, .accepted, "the answer stays once confirmed")

        // The same answer again changes nothing and sends nothing; another answer replaces it, naming the first.
        try harness.engine.answerInvitation(.accepted, to: target)
        try harness.engine.answerInvitation(.declined, to: target)
        try await waitUntil("second answer applied") { self.answers(harness.provider).count == 2 }
        XCTAssertEqual(answers(harness.provider).last?.response, .declined)
        XCTAssertEqual(answers(harness.provider).last?.previous, .accepted)
        await harness.shutdown()
    }

    func testAProviderReportDoesNotUndoTheAnswer() async throws {
        let harness = try await harness()
        try harness.engine.answerInvitation(.tentative, to: target)
        try await waitUntil("operation confirmed") {
            try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty && !self.answers(harness.provider).isEmpty
        }
        // A poll brings the message again, as providers know it: without a local answer.
        try harness.store.upsertMessages([Fixtures.message(2, isRead: true)])
        XCTAssertEqual(try harness.store.message(target)?.invitationReply, .tentative)
        await harness.shutdown()
    }

    func testAnAnswerWithoutPermissionWaitsUntriedAndTheAccountAsksToReconnect() async throws {
        let harness = try await harness(permission: .calendar)
        let recorder = PhaseRecorder()
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }

        try harness.engine.answerInvitation(.accepted, to: target)
        XCTAssertEqual(try harness.store.message(target)?.invitationReply, .accepted, "the card shows it chosen meanwhile")
        try await waitUntil("account asks for the permission") {
            recorder.latest.first { $0.accountID == Fixtures.accountID }?.permissionsNeeded == [.calendar]
        }
        // Other work goes on: an archive of another message is not held behind the waiting answer.
        let other = MessageID(accountID: Fixtures.accountID, providerID: "3")
        try harness.engine.perform(.archive, on: [other])
        try await waitUntil("archive applied") { harness.provider.applyCalls.contains { $0.change == .archive } }
        XCTAssertTrue(answers(harness.provider).isEmpty, "nothing goes out without the permission")
        let waiting = try XCTUnwrap(try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).first)
        XCTAssertEqual(waiting.attempts, 0, "a waiting answer spends no attempt, so it is never given up")
        XCTAssertEqual(waiting.status, .pending)

        // The user reconnects; the reconnect asks for the calendar on top of mail.
        _ = try await harness.engine.reconnect(Fixtures.account())
        XCTAssertEqual(harness.authenticator.permissions.last, [.calendar])
        // Once the token carries the scope, the answer goes out and the ask goes away.
        harness.provider.permissionNeeded = nil
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("answer applied after the grant") { self.answers(harness.provider).count == 1 }
        try await waitUntil("ask withdrawn") {
            recorder.latest.first { $0.accountID == Fixtures.accountID }?.permissionsNeeded.isEmpty == true
        }
        await harness.shutdown()
    }

    func testAReconnectKeepsAPermissionTheAccountGrantedBefore() async throws {
        let harness = try await harness()
        try harness.tokenStore.save(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3_600),
                                                scope: OAuthEndpoints.googleScope + " " + OAuthEndpoints.googleCalendarScope),
                                    for: Fixtures.accountID)
        _ = try await harness.engine.reconnect(Fixtures.account())
        XCTAssertEqual(harness.authenticator.permissions.last, [.calendar], "signing in again never takes a permission away")
        await harness.shutdown()
    }

    /// The token provider of a healthy account still holds the old token, valid for up to an hour and without the scope
    /// the reconnect added: it is told, so the waiting answer goes out on the next drain rather than an hour later.
    func testAReconnectTellsTheTokenProviderItsTokensWereReplaced() async throws {
        let harness = try await harness()
        XCTAssertTrue(harness.tokenProvider.replacements.isEmpty)
        _ = try await harness.engine.reconnect(Fixtures.account())
        XCTAssertEqual(harness.tokenProvider.replacements, [Fixtures.accountID])
        XCTAssertNotNil(try harness.tokenStore.tokens(for: Fixtures.accountID), "after the new tokens are stored")
        await harness.shutdown()
    }

    func testAGivenUpAnswerPutsThePreviousAnswerBack() async throws {
        let failure = Result<Void, Error>.failure(ProviderError.server(status: 500, message: "boom"))
        let harness = try await harness(applyResults: [.success(()), failure]) { $0.maxOperationAttempts = 1 }
        try harness.engine.answerInvitation(.accepted, to: target)
        try await waitUntil("first answer confirmed") {
            try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty && self.answers(harness.provider).count == 1
        }
        try harness.engine.answerInvitation(.declined, to: target)
        XCTAssertEqual(try harness.store.message(target)?.invitationReply, .declined)
        let conversation = ConversationID(accountID: Fixtures.accountID, providerID: "t1")
        try await waitUntil("failure marked") {
            try harness.store.conversations(ConversationQuery(view: .all)).first { $0.id == conversation }?.failedOperation == .answerInvitation
        }
        XCTAssertEqual(try harness.store.message(target)?.invitationReply, .accepted, "the card goes back to the answer that went out")
        await harness.shutdown()
    }

    /// The organizer updated the invitation since: a later message in the conversation carries it with a higher
    /// SEQUENCE and new times. The earlier one is not answered (its card offers no answer), so an answer always carries
    /// the latest revision's UID, SEQUENCE, RECURRENCE-ID and times.
    func testOnlyTheLatestRevisionOfAnInvitationIsAnswered() async throws {
        let harness = try await harness()
        let newer = MessageID(accountID: Fixtures.accountID, providerID: "3")
        var updated = invitation()
        updated.sequence = 4
        updated.start = updated.start.addingTimeInterval(3_600)
        updated.end = updated.end.addingTimeInterval(3_600)
        try harness.store.saveBody(StoredBody(body: MessageBody(html: "<p>Updated</p>", text: nil), renderedHTML: "<p>Updated</p>",
                                              plainText: "Updated", invitation: updated), for: newer)

        XCTAssertThrowsError(try harness.engine.answerInvitation(.accepted, to: target)) { error in
            guard case StoreError.conflict? = error as? StoreError else { return XCTFail("\(error)") }
        }
        XCTAssertNil(try harness.store.message(target)?.invitationReply)
        XCTAssertTrue(try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty, "nothing queued")

        try harness.engine.answerInvitation(.accepted, to: newer)
        try await waitUntil("answer applied") { self.answers(harness.provider).count == 1 }
        let answer = try XCTUnwrap(answers(harness.provider).first)
        XCTAssertEqual(answer.sequence, 4)
        XCTAssertEqual(answer.start, updated.start)
        XCTAssertEqual(harness.provider.applyCalls.last?.ids, ["3"])
        await harness.shutdown()
    }

    func testOnlyAnAnswerableInvitationCanBeAnswered() async throws {
        let harness = try await harness(invitation: invitation(method: .cancel))
        XCTAssertThrowsError(try harness.engine.answerInvitation(.accepted, to: target)) { error in
            guard case StoreError.conflict? = error as? StoreError else { return XCTFail("\(error)") }
        }
        try harness.store.saveBody(StoredBody(body: MessageBody(html: nil, text: "x"), renderedHTML: "x", plainText: "x",
                                              invitation: invitation(userIsOrganizer: true)), for: target)
        XCTAssertThrowsError(try harness.engine.answerInvitation(.accepted, to: target), "the user's own event")
        let plain = MessageID(accountID: Fixtures.accountID, providerID: "1")
        XCTAssertThrowsError(try harness.engine.answerInvitation(.accepted, to: plain)) { error in
            guard case StoreError.notFound? = error as? StoreError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try harness.engine.answerInvitation(.needsAction, to: target), "no answer is not an answer")
        XCTAssertNil(try harness.store.message(target)?.invitationReply)
        XCTAssertTrue(try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty)
        await harness.shutdown()
    }

    func testTheInvitationIsReadWhenTheBodyIsStored() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...2, next: nil, cursor: "c0"))]]
        let ics = CalendarFixtures.googleRequest.replacingOccurrences(of: "alex@contoso.test", with: "me@example.com")
        provider.bodies = [
            "1": .success(MessageBody(html: "<p>Lunch?</p>", text: nil)),
            "2": .success(MessageBody(html: "<p>Invitation</p>", text: nil, calendar: ics)),
        ]
        let harness = try EngineHarness(provider: provider)
        harness.engine.start()
        try await waitUntil("bodies stored") {
            try harness.store.body(for: self.target) != nil
                && harness.store.body(for: MessageID(accountID: Fixtures.accountID, providerID: "1")) != nil
        }
        let stored = try XCTUnwrap(try harness.store.body(for: target)?.invitation)
        XCTAssertEqual(stored.title, "Design review")
        XCTAssertEqual(stored.userAddress, "me@example.com", "the account's address is the user")
        XCTAssertEqual(stored.calendarText, ics)
        XCTAssertNil(try harness.store.body(for: MessageID(accountID: Fixtures.accountID, providerID: "1"))?.invitation,
                     "a message without one is unchanged")
        await harness.shutdown()
    }

    /// Only the account's address is the user's. The Gmail account (me@example.com) is not on the Exchange invitation,
    /// and no recipient is taken for it: not a colleague beside it, not a list the invitation went to alone, not the
    /// colleague a forward kept as its only recipient, not whoever the user forwarded it to from Sent. None is shown as
    /// "You", none is answered for, and the account, which the invitation never names, offers no answer of its own.
    func testNoRecipientIsTakenForTheUser() throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        func read(_ calendar: String, from: String = "rachel.kim@northwind.test", to recipients: [String], cc: [String] = [],
                  roles: Set<MailboxRole> = [.inbox]) throws -> CalendarInvitation {
            var message = Fixtures.message(2, roles: roles)
            message.from = EmailAddress(address: from)
            message.to = recipients.map { EmailAddress(address: $0) }
            message.cc = cc.map { EmailAddress(address: $0) }
            try store.upsertMessages([message])
            let body = MessageBody(html: "<p>Roadmap review</p>", text: nil, calendar: calendar)
            return try XCTUnwrap(Hydrator.invitation(in: body, for: target, store: store))
        }
        let toList = CalendarFixtures.exchangeRequest.replacingOccurrences(
            of: "CN=Alex Morgan:mailto:alex@northwind.test", with: "CN=Partners:mailto:partners@northwind.test")

        let cases: [(name: String, invitation: CalendarInvitation)] = [
            ("colleague beside it", try read(CalendarFixtures.exchangeRequest, to: ["marcus.bell@northwind.test", "alex@northwind.test"])),
            ("colleague in Cc", try read(CalendarFixtures.exchangeRequest, to: ["alex@northwind.test"], cc: ["marcus.bell@northwind.test"])),
            ("a list alone", try read(toList, to: ["partners@northwind.test"])),
            ("a forward keeping its recipient", try read(CalendarFixtures.exchangeRequest, to: ["Alex@Northwind.test"])),
            ("the user's forward in Sent", try read(CalendarFixtures.exchangeRequest, from: "me@example.com",
                                                    to: ["marcus.bell@northwind.test"], roles: [.sent])),
        ]
        for (name, invitation) in cases {
            XCTAssertNil(invitation.userAddress, name)
            XCTAssertNil(invitation.userResponse, name)
            XCTAssertFalse(invitation.userIsOrganizer, name)
            XCTAssertEqual(invitation.answersAsAccount, false, name)
            XCTAssertFalse(invitation.isAnswerable, name)
            XCTAssertNil(InvitationAnswer(.declined, to: invitation, accountEmail: "me@example.com", accountName: "Me", previous: nil), name)
        }
    }

    /// A Microsoft event message's own calendar part, read when Graph would not hand over its event (an account that
    /// granted mail alone): Microsoft answers the event in the user's own calendar, so it is answered as the account,
    /// named or not, as Graph's own reading of the event is.
    func testAMicrosoftEventMessagesCalendarIsAnsweredAsTheAccount() throws {
        func read(accountEmail: String) throws -> CalendarInvitation {
            let store = InMemoryMailStore()
            var account = Fixtures.account()
            account.kind = .microsoft
            account.email = accountEmail
            try store.upsertAccount(account)
            try store.upsertMessages([Fixtures.message(2)])
            let body = MessageBody(html: "<p>Roadmap review</p>", text: nil, calendar: CalendarFixtures.exchangeRequest)
            return try XCTUnwrap(Hydrator.invitation(in: body, for: target, store: store))
        }
        let named = try read(accountEmail: "alex@northwind.test")
        XCTAssertEqual(named.userAddress, "alex@northwind.test", "the account named is still \"You\"")
        XCTAssertEqual(named.answersAsAccount, true)
        XCTAssertTrue(named.isAnswerable)

        let alias = try read(accountEmail: "a.morgan@northwind.test")
        XCTAssertNil(alias.userAddress, "an address the account is not is never taken for it")
        XCTAssertEqual(alias.answersAsAccount, true)
        XCTAssertTrue(alias.isAnswerable, "the answer goes to the event Exchange put on this account's calendar")
    }

    /// An invitation forwarded from the user's other account names that account, not this one: the card shows "You"
    /// for neither (the answer would speak for this account) and offers no answer, which the engine refuses too.
    func testAnInvitationToTheUsersOtherAccountIsNotAnsweredFromThisOne() async throws {
        let ics = CalendarFixtures.googleRequest.replacingOccurrences(of: "alex@contoso.test", with: "me.personal@gmail.test")
        let unlisted = try XCTUnwrap(CalendarInvitationReader.invitation(fromICS: ics, userAddresses: ["me@example.com"]))
        let harness = try await harness(invitation: unlisted)
        XCTAssertThrowsError(try harness.engine.answerInvitation(.accepted, to: target)) { error in
            guard case StoreError.conflict? = error as? StoreError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty)

        let other = Account(id: AccountID("acct-personal"), kind: .gmail, email: "me.personal@gmail.test", displayName: "Me",
                            addedAt: Fixtures.baseDate)
        let accounts = [Fixtures.accountID: Fixtures.account(), other.id: other]
        let message = try XCTUnwrap(try harness.store.message(target))
        let body = try XCTUnwrap(try harness.store.body(for: target))
        let payload = RenderPayloadBuilder().build(messages: [message], bodies: [target: body], accounts: accounts)
        let card = try XCTUnwrap(payload.messages.first?.invitation)
        XCTAssertFalse(card.canAnswer)
        XCTAssertFalse(card.guests?.contains("You") ?? false, "the other account's address is not this account's user")
        await harness.shutdown()
    }

    /// A poll settles an old uncertain change once it reports the change's message, because the report shows whether
    /// it landed. It shows nothing of an answer (a mail and a calendar call), so an uncertain answer stays queued
    /// through the poll, and stays chosen, while an uncertain read change beside it is settled as before.
    func testAPollNeverSettlesAnUncertainAnswer() async throws {
        // Long backoffs, so both rows were last tried 700 s ago and their retries are still ahead.
        let harness = try await harness { $0.backoffBase = 3000; $0.backoffCap = 3600 }
        let triedAt = Date().addingTimeInterval(-700)
        let accepted = try XCTUnwrap(InvitationAnswer(.accepted, to: invitation(), accountEmail: "me@example.com",
                                                      accountName: nil, previous: nil))
        let answer = Operation(accountID: Fixtures.accountID, change: .answerInvitation(accepted), targets: [target],
                               createdAt: triedAt, status: .uncertain, attempts: 8, nextAttemptAt: triedAt.addingTimeInterval(3600))
        let read = Operation(accountID: Fixtures.accountID, change: .setRead(true), targets: [target],
                             createdAt: triedAt, status: .uncertain, attempts: 1, nextAttemptAt: triedAt.addingTimeInterval(3000))
        try harness.store.updateOperation(answer)
        try harness.store.updateOperation(read)

        // The phone read the message: the poll lists it.
        harness.provider.enqueueChanges(.success(Fixtures.changes(upserts: [Fixtures.message(2)], cursor: "c1")))
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("poll applied") { try harness.store.syncCursor(for: Fixtures.accountID) == "c1" }
        let pending = try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10)
        XCTAssertEqual(pending.map(\.id), [answer.id], "the read change is settled, the answer is not")
        XCTAssertEqual(pending.first?.status, .uncertain)
        XCTAssertEqual(try harness.store.message(target)?.invitationReply, .accepted)
        XCTAssertTrue(answers(harness.provider).isEmpty)
        await harness.shutdown()
    }

    /// While an answer waits for the permission, perhaps for good, the message's other work still reaches the server:
    /// an archive of several conversations that includes it, a trash, and a read change behind them.
    func testAnAnswerWaitingForPermissionHoldsBackNoOtherChangeToItsMessage() async throws {
        let harness = try await harness(permission: .calendar)
        let recorder = PhaseRecorder()
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }

        try harness.engine.answerInvitation(.accepted, to: target)
        try await waitUntil("account asks for the permission") {
            recorder.latest.first { $0.accountID == Fixtures.accountID }?.permissionsNeeded == [.calendar]
        }
        let ids = (1...3).map { MessageID(accountID: Fixtures.accountID, providerID: "\($0)") }
        try harness.engine.perform(.archive, on: ids)
        try harness.engine.perform(.setRead(true), on: [ids[2]])
        try harness.engine.perform(.trash, on: [target])
        try await waitUntil("the other changes applied") {
            let calls = harness.provider.applyCalls
            return calls.contains { $0.change == .archive && Set($0.ids) == ["1", "2", "3"] }
                && calls.contains { $0.change == .setRead(true) && $0.ids == ["3"] }
                && calls.contains { $0.change == .trash && $0.ids == ["2"] }
        }
        XCTAssertTrue(answers(harness.provider).isEmpty)
        let pending = try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10)
        XCTAssertEqual(pending.map { OperationKind($0.change) }, [.answerInvitation], "only the answer still waits")
        XCTAssertEqual(pending.first?.attempts, 0)
        await harness.shutdown()
    }

    /// The user changes their answer while the first waits for the permission: after the reconnect only the last one
    /// goes out, so the organizer gets one reply (one patch, one mail; one Graph call), never each answer on the way.
    func testOnlyTheLatestAnswerGoesOutAfterTheReconnect() async throws {
        let harness = try await harness(permission: .calendar)
        let recorder = PhaseRecorder()
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }

        try harness.engine.answerInvitation(.accepted, to: target)
        try await waitUntil("account asks for the permission") {
            recorder.latest.first { $0.accountID == Fixtures.accountID }?.permissionsNeeded == [.calendar]
        }
        try harness.engine.answerInvitation(.declined, to: target)
        try harness.engine.answerInvitation(.tentative, to: target)
        XCTAssertEqual(try harness.store.message(target)?.invitationReply, .tentative)
        try await waitUntil("the replaced answers dropped") {
            try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).count == 1
        }
        let waiting = try XCTUnwrap(try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).first)
        guard case .answerInvitation(let kept) = waiting.change else { return XCTFail("\(waiting.change)") }
        XCTAssertEqual(kept.response, .tentative)
        XCTAssertNil(kept.previous, "a give-up puts back what was recorded before the first of them")

        _ = try await harness.engine.reconnect(Fixtures.account())
        harness.provider.permissionNeeded = nil
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("answer applied after the grant") { !self.answers(harness.provider).isEmpty }
        try await waitUntil("outbox empty") { try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty }
        XCTAssertEqual(answers(harness.provider).map(\.response), [.tentative])
        XCTAssertNil(answers(harness.provider).first?.previous)
        XCTAssertEqual(try harness.store.message(target)?.invitationReply, .tentative)
        await harness.shutdown()
    }

    /// The same when the grant lands between the two checks of one drain: the replaced answer is dropped before
    /// anything is asked or sent.
    func testAReplacedAnswerIsDroppedEvenWhenTheGrantLandsMidDrain() async throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages([Fixtures.message(2)])
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.permissionNeeded = .calendar
        provider.permissionGrantedAfterChecks = 1
        let accepted = try XCTUnwrap(InvitationAnswer(.accepted, to: invitation(), accountEmail: "me@example.com",
                                                      accountName: nil, previous: nil))
        let declined = try XCTUnwrap(InvitationAnswer(.declined, to: invitation(), accountEmail: "me@example.com",
                                                      accountName: nil, previous: .accepted))
        try store.enqueue(Operation(accountID: Fixtures.accountID, change: .answerInvitation(accepted), targets: [target],
                                    createdAt: Fixtures.baseDate))
        try store.enqueue(Operation(accountID: Fixtures.accountID, change: .answerInvitation(declined), targets: [target],
                                    createdAt: Fixtures.baseDate.addingTimeInterval(1)))
        let runner = OperationRunner(accountID: Fixtures.accountID, store: store, provider: provider, tuning: SyncTuning())

        let first = await runner.drain()
        XCTAssertEqual(first.permissionsNeeded, [.calendar])
        XCTAssertTrue(answers(provider).isEmpty)
        let second = await runner.drain()
        XCTAssertTrue(second.permissionsNeeded.isEmpty)
        XCTAssertEqual(answers(provider).map(\.response), [.declined])
        XCTAssertNil(answers(provider).first?.previous)
    }

    /// An answer that failed in a way that may have sent nothing waits in its backoff; the user changes it twice. The
    /// retry of the first and the middle one never go out: only the last does.
    func testAnAnswerWaitingInItsBackoffIsReplacedByTheLatest() async throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages([Fixtures.message(2)])
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.applyResults = [.failure(ProviderError.network("connection lost"))]
        var tuning = SyncTuning()
        tuning.backoffBase = 3_600
        let runner = OperationRunner(accountID: Fixtures.accountID, store: store, provider: provider, tuning: tuning)
        func answer(_ response: InvitationResponse, previous: InvitationResponse?, at offset: TimeInterval) throws {
            let built = try XCTUnwrap(InvitationAnswer(response, to: invitation(), accountEmail: "me@example.com", accountName: nil,
                                                       previous: previous))
            try store.enqueue(Operation(accountID: Fixtures.accountID, change: .answerInvitation(built), targets: [target],
                                        createdAt: Fixtures.baseDate.addingTimeInterval(offset)))
        }
        try answer(.accepted, previous: nil, at: 0)
        _ = await runner.drain()
        XCTAssertEqual(try store.pendingOperations(accountID: Fixtures.accountID, limit: 10).first?.attempts, 1)
        try answer(.declined, previous: .accepted, at: 1)
        try answer(.tentative, previous: .declined, at: 2)

        _ = await runner.drain()
        XCTAssertEqual(answers(provider).map(\.response), [.accepted, .tentative], "the failed first try, then only the latest")
        XCTAssertNil(answers(provider).last?.previous)
        XCTAssertTrue(try store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty)
        XCTAssertEqual(try store.message(target)?.invitationReply, .tentative)
    }

    /// Changed and changed back before anything went out, the answer says what the organizer already has: nothing is
    /// sent at all.
    func testAnAnswerChangedBackBeforeAnythingWentOutSendsNothing() async throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        // Accepted before, and that answer went out (its operation is long confirmed).
        try store.upsertMessages([Fixtures.message(2)])
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.permissionNeeded = .calendar
        let declined = try XCTUnwrap(InvitationAnswer(.declined, to: invitation(), accountEmail: "me@example.com",
                                                      accountName: nil, previous: .accepted))
        let acceptedAgain = try XCTUnwrap(InvitationAnswer(.accepted, to: invitation(), accountEmail: "me@example.com",
                                                           accountName: nil, previous: .declined))
        try store.enqueue(Operation(accountID: Fixtures.accountID, change: .answerInvitation(declined), targets: [target],
                                    createdAt: Fixtures.baseDate))
        try store.enqueue(Operation(accountID: Fixtures.accountID, change: .answerInvitation(acceptedAgain), targets: [target],
                                    createdAt: Fixtures.baseDate.addingTimeInterval(1)))
        let runner = OperationRunner(accountID: Fixtures.accountID, store: store, provider: provider, tuning: SyncTuning())

        let outcome = await runner.drain()
        XCTAssertTrue(outcome.permissionsNeeded.isEmpty, "nothing left waits for the permission")
        XCTAssertTrue(try store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty)
        XCTAssertTrue(answers(provider).isEmpty)
        XCTAssertEqual(try store.message(target)?.invitationReply, .accepted)
    }

    /// The answer that replaced others is given up: the card goes back to the answer recorded before all of them, not
    /// to a replaced one that never went out.
    func testGivingUpTheLatestAnswerPutsBackTheOneBeforeAllOfThem() async throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        // Accepted before, and that answer went out (its operation is long confirmed).
        try store.upsertMessages([Fixtures.message(2)])
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.applyResults = [.failure(ProviderError.server(status: 500, message: "boom"))]
        var tuning = SyncTuning()
        tuning.maxOperationAttempts = 1
        let declined = try XCTUnwrap(InvitationAnswer(.declined, to: invitation(), accountEmail: "me@example.com",
                                                      accountName: nil, previous: .accepted))
        let tentative = try XCTUnwrap(InvitationAnswer(.tentative, to: invitation(), accountEmail: "me@example.com",
                                                       accountName: nil, previous: .declined))
        try store.enqueue(Operation(accountID: Fixtures.accountID, change: .answerInvitation(declined), targets: [target],
                                    createdAt: Fixtures.baseDate))
        try store.enqueue(Operation(accountID: Fixtures.accountID, change: .answerInvitation(tentative), targets: [target],
                                    createdAt: Fixtures.baseDate.addingTimeInterval(1)))
        XCTAssertEqual(try store.message(target)?.invitationReply, .tentative)
        let runner = OperationRunner(accountID: Fixtures.accountID, store: store, provider: provider, tuning: tuning)

        _ = await runner.drain()
        XCTAssertEqual(answers(provider).map(\.response), [.tentative])
        XCTAssertEqual(answers(provider).first?.previous, .accepted)
        XCTAssertEqual(try store.message(target)?.invitationReply, .accepted)
    }

    /// The event, or the message naming it, is gone (Graph answers 404): the answer is given up at once, the card puts
    /// the previous answer back and the conversation shows the failure, rather than claiming an answer nothing sent.
    func testAnAnswerToAnEventThatIsGoneIsGivenUpAtOnce() async throws {
        let harness = try await harness(applyResults: [.failure(ProviderError.notFound)])
        try harness.engine.answerInvitation(.accepted, to: target)
        let conversation = ConversationID(accountID: Fixtures.accountID, providerID: "t1")
        try await waitUntil("failure marked") {
            try harness.store.conversations(ConversationQuery(view: .all)).first { $0.id == conversation }?.failedOperation == .answerInvitation
        }
        XCTAssertNil(try harness.store.message(target)?.invitationReply, "the card goes back to no answer")
        XCTAssertEqual(answers(harness.provider).count, 1, "tried once, never again")
        XCTAssertTrue(try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty)
        await harness.shutdown()
    }
}
