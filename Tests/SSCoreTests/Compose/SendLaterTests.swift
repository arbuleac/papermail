import XCTest
@testable import SSCore

/// Send Later's pure halves (spec §5.19, §5.23): the drop-down's presets on fixed clocks, the Drafts row a scheduled
/// message gets and its time slot's words, and the reader's draft sheet line with its Cancel.
final class SendLaterTests: XCTestCase {
    private let british = Locale(identifier: "en_GB")
    private let account = AccountID("acct")

    private var london: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        calendar.locale = british
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        london.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private var formatter: DateFormatting {
        DateFormatting(locale: british, calendar: london, timeZone: london.timeZone)
    }

    /// As the outbox's readers see it (`MailStoring.pendingSendSummaries`).
    private func send(status: PendingSendStatus = .later, at time: Date, draft: UUID? = UUID(),
                      attachments: [OutgoingAttachment] = []) -> PendingSendSummary {
        PendingSendSummary(PendingSend(
            id: "s1",
            message: OutgoingMessage(accountID: account, to: [EmailAddress(name: "Ben Carter", address: "ben@contoso.test")],
                                     subject: "Re: Contoso rollout", html: "<p>Thanks Ben</p>",
                                     text: "Thanks Ben, forwarding to IT now.\n\nAlex", attachments: attachments),
            createdAt: date(2025, 3, 6, 9, 20), sendAfter: time, status: status, draftID: draft
        ))
    }

    // MARK: Presets

    /// Thursday 6 March 2025: Tomorrow is Friday 09:00, Monday the next Monday.
    func testAWeekdayOffersTomorrowAndMonday() {
        let offered = SendLaterPreset.offered(at: date(2025, 3, 6, 9, 20), calendar: london)
        XCTAssertEqual(offered.map(\.preset), [.tomorrow, .monday])
        XCTAssertEqual(offered.map(\.date), [date(2025, 3, 7, 9), date(2025, 3, 10, 9)])
        XCTAssertEqual(SendLaterPreset.allCases.map(\.title), ["Tomorrow", "Monday"])
    }

    /// On a Sunday Monday's time is Tomorrow's, so it is offered once; on a Monday, Monday is a week on.
    func testSundayOffersTomorrowAloneAndMondayOffersAWeekOn() {
        let sunday = SendLaterPreset.offered(at: date(2025, 3, 9, 22), calendar: london)
        XCTAssertEqual(sunday.map(\.preset), [.tomorrow])
        XCTAssertEqual(sunday.first?.date, date(2025, 3, 10, 9))
        let monday = SendLaterPreset.offered(at: date(2025, 3, 10, 8), calendar: london)
        XCTAssertEqual(monday.map(\.date), [date(2025, 3, 11, 9), date(2025, 3, 17, 9)])
    }

    /// The clocks go forward in London on 30 March 2025: Monday 09:00 is still 09:00 on the wall.
    func testDaylightSavingKeepsTheWallClockTime() {
        let offered = SendLaterPreset.offered(at: date(2025, 3, 28, 17), calendar: london)
        XCTAssertEqual(offered.last?.date, date(2025, 3, 31, 9))
        XCTAssertEqual(london.component(.hour, from: offered.last?.date ?? Date()), 9)
        XCTAssertEqual(SendLaterPreset.pickerStart(after: date(2025, 3, 28, 17), calendar: london), date(2025, 3, 29, 9))
    }

    // MARK: State

    func testOnlySendLaterMessagesHaveAState() {
        let time = date(2025, 3, 10, 9)
        XCTAssertEqual(SendLaterState(send(at: time)), .waiting(until: time))
        XCTAssertEqual(SendLaterState(send(status: .missed, at: time)), .missed(time))
        XCTAssertEqual(SendLaterState(send(status: .sending, at: time)), .sending)
        XCTAssertEqual(SendLaterState(send(status: .scheduled, at: time)), .sending, "a throttle's retry keeps its draft")
        XCTAssertNil(SendLaterState(send(status: .scheduled, at: time, draft: nil)), "an undo-send")
        XCTAssertNil(SendLaterState(send(status: .sent, at: time)), "gone: the app clears it away")
        XCTAssertNil(SendLaterState(send(status: .failed, at: time)), "kept as a draft with its reason instead")
        XCTAssertTrue(SendLaterState.waiting(until: time).isHeld)
        XCTAssertTrue(SendLaterState.missed(time).isHeld)
        XCTAssertFalse(SendLaterState.sending.isHeld)
    }

    // MARK: The Drafts row

    func testTheRowStandsForTheMessageAsItWillBeSent() throws {
        let time = date(2025, 3, 10, 9)
        let pending = send(at: time, attachments: [OutgoingAttachment(filename: "plan.pdf", mimeType: "application/pdf", data: Data([1]))])
        let summary = try XCTUnwrap(SendLaterConversation.summary(for: pending))
        XCTAssertEqual(summary.id, SendLaterConversation.conversationID(sendID: "s1", account: account))
        XCTAssertEqual(SendLaterConversation.sendID(of: summary.id), "s1")
        XCTAssertEqual(SendLaterConversation.sendID(of: summary.latestMessageID), "s1")
        XCTAssertTrue(LocalDraftConversation.isLocal(summary.id), "kept away from the store as a kept draft is")
        XCTAssertNil(LocalDraftConversation.draftID(of: summary.id), "but it names no kept draft")
        XCTAssertNil(SendLaterConversation.sendID(of: LocalDraftConversation.conversationID(draftID: UUID(), account: account)))
        XCTAssertEqual(summary.subject, "Re: Contoso rollout")
        XCTAssertEqual(summary.snippet, "Thanks Ben, forwarding to IT now. Alex")
        XCTAssertEqual(summary.sendLater, .waiting(until: time))
        XCTAssertTrue(summary.hasAttachments)
        let inline = OutgoingAttachment(filename: "logo.png", mimeType: "image/png", data: Data([1]), contentID: "logo")
        XCTAssertEqual(SendLaterConversation.summary(for: send(at: time, attachments: [inline]))?.hasAttachments, false,
                       "an inline image is no attachment to list")
        XCTAssertEqual(summary.unreadCount, 0)
        XCTAssertEqual(summary.latestDate, pending.createdAt)
        XCTAssertNil(SendLaterConversation.summary(for: send(status: .scheduled, at: time, draft: nil)))
        XCTAssertEqual(SendLaterConversation.listed([pending, send(status: .sent, at: time)]).count, 1)

        let message = SendLaterConversation.message(for: pending, sender: EmailAddress(name: "Alex", address: "alex@contoso.test"))
        XCTAssertEqual(message.roles, [.drafts])
        XCTAssertEqual(message.to.map(\.address), ["ben@contoso.test"])
        XCTAssertEqual(message.conversationID, summary.id)
        let body = SendLaterConversation.body(for: pending)
        XCTAssertEqual(body.plainText, pending.text)
    }

    /// “Sends Mon 09:00” in the time slot, “Not sent” once missed, “Sending…” on its way; VoiceOver hears the condition too.
    func testTheTimeSlotSaysWhenItSends() throws {
        let now = date(2025, 3, 6, 9, 20)
        let reference = formatter.reference(now: now)
        let context = ConversationRowText.Context(kind: .draft, recipients: [EmailAddress(name: "Ben Carter", address: "ben@contoso.test")])
        func row(_ status: PendingSendStatus, _ time: Date) throws -> ConversationRowText {
            ConversationRowText(summary: try XCTUnwrap(SendLaterConversation.summary(for: send(status: status, at: time))),
                                reference: reference, formatter: formatter, context: context)
        }
        let monday = try row(.later, date(2025, 3, 10, 9))
        XCTAssertEqual(monday.timeText, "Sends Mon 09:00")
        XCTAssertEqual(monday.senderLine, "Draft to Ben Carter")
        XCTAssertTrue(monday.accessibilityLabel.contains("Sends Mon 09:00, while SuperSparrow is open."), monday.accessibilityLabel)
        XCTAssertEqual(monday.timeToolTip, "Sends Mon 09:00 while SuperSparrow is open", "and the time's tooltip says it")
        XCTAssertEqual(try row(.later, date(2025, 3, 6, 15)).timeText, "Sends 15:00", "today: the time alone")
        XCTAssertEqual(try row(.later, date(2025, 4, 2, 9)).timeText, "Sends 2 Apr 09:00", "beyond the week: the date")
        let missed = try row(.missed, date(2025, 3, 6, 9))
        XCTAssertEqual(missed.timeText, "Not sent")
        XCTAssertNil(missed.timeToolTip, "nothing waits on the app any more: the launch alert asked")
        XCTAssertTrue(missed.accessibilityLabel.contains("Not sent, was due 09:00."), missed.accessibilityLabel)
        XCTAssertEqual(try row(.sending, date(2025, 3, 6, 9)).timeText, "Sending\u{2026}")
        XCTAssertNotEqual(ConversationRowText.cacheKey(for: try XCTUnwrap(SendLaterConversation.summary(for: send(at: date(2025, 3, 10, 9)))), dayStamp: 1),
                          ConversationRowText.cacheKey(for: try XCTUnwrap(SendLaterConversation.summary(for: send(at: date(2025, 3, 11, 9)))), dayStamp: 1),
                          "a new time draws the row again")
        XCTAssertNotEqual(ConversationRowText.cacheKey(for: try XCTUnwrap(SendLaterConversation.summary(for: send(at: date(2025, 3, 10, 9)))), dayStamp: 1),
                          ConversationRowText.cacheKey(for: try XCTUnwrap(SendLaterConversation.summary(for: send(status: .sending, at: date(2025, 3, 10, 9)))), dayStamp: 1),
                          "so does a new state")
    }

    // MARK: The draft sheet

    func testTheDraftSheetSaysWhenItSendsAndOffersCancelWhileItWaits() throws {
        let now = date(2025, 3, 6, 9, 20)
        let builder = RenderPayloadBuilder(calendar: london, locale: british, timeZone: london.timeZone)
        let sender = EmailAddress(name: "Alex", address: "alex@contoso.test")
        func card(_ state: SendLaterState?) throws -> RenderPayload.Message {
            let pending = send(at: date(2025, 3, 10, 9))
            let message = SendLaterConversation.message(for: pending, sender: sender)
            let payload = builder.build(messages: [message], bodies: [message.id: SendLaterConversation.body(for: pending)], accounts: [:],
                                        sendLater: state.map { [message.id: $0] } ?? [:], now: now)
            return try XCTUnwrap(payload.messages.first)
        }
        let waiting = try card(.waiting(until: date(2025, 3, 10, 9)))
        XCTAssertTrue(waiting.isDraft)
        XCTAssertEqual(waiting.dateDisplay, "Sends Mon 09:00")
        XCTAssertTrue(waiting.cancelsSendLater)
        let missed = try card(.missed(date(2025, 3, 6, 9)))
        XCTAssertEqual(missed.dateDisplay, "Not sent")
        XCTAssertFalse(missed.cancelsSendLater, "the launch alert asks about it instead")
        XCTAssertFalse(try card(.sending).cancelsSendLater)
        let plain = try card(nil)
        XCTAssertTrue(plain.dateDisplay.hasPrefix("Edited "), "an ordinary draft as before")
        XCTAssertFalse(plain.cancelsSendLater)

        let message = SendLaterConversation.message(for: send(at: date(2025, 3, 10, 9)), sender: sender)
        let before = RenderInputs(messages: [message], sendLater: [message.id: .waiting(until: date(2025, 3, 10, 9))]) { _ in true }
        let after = RenderInputs(messages: [message], sendLater: [message.id: .sending]) { _ in true }
        XCTAssertNotEqual(before, after, "a change of state draws the sheet again")
        XCTAssertNil(before.flagPatches(to: after), "with a payload, not a flag patch")
    }
}
