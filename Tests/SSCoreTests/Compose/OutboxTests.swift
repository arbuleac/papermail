import XCTest
@testable import SSCore

/// The Outbox's pure halves (spec §5.53): the state each send in the outbox shows, the order the rows go in, the row a
/// send gets and its time slot's words, the sheet's date line and what it offers, the reader's actions, the empty state
/// and the drops it refuses. Every row is built from `PendingSendSummary` values alone, as the outbox's observation
/// delivers them.
final class OutboxTests: XCTestCase {
    private let british = Locale(identifier: "en_GB")
    private let account = AccountID("acct")
    private let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")

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

    /// Thursday 6 March 2025, 09:20.
    private var now: Date { date(2025, 3, 6, 9, 20) }

    private func send(_ id: String = "s1", status: PendingSendStatus, created: Date? = nil, at time: Date? = nil,
                      lastError: String? = nil, draft: UUID? = nil, files: Bool = false) -> PendingSendSummary {
        PendingSendSummary(
            id: id, accountID: account, createdAt: created ?? now, sendAfter: time ?? now.addingTimeInterval(5), status: status,
            attempts: lastError == nil ? 0 : 1, lastError: lastError, draftID: draft, to: [ben], subject: "Re: Contoso rollout",
            text: "Thanks Ben, forwarding to IT now.\n\nAlex", hasFiles: files
        )
    }

    // MARK: State

    /// Every send the provider has not taken yet has a state, from the moment Send is pressed; one it took has none.
    func testEverySendNotYetTakenHasAState() {
        let monday = date(2025, 3, 10, 9)
        XCTAssertEqual(OutboxState(send(status: .scheduled)), .sending, "counting down its undo window")
        XCTAssertEqual(OutboxState(send(status: .sending)), .sending, "claimed by the runner")
        XCTAssertEqual(OutboxState(send(status: .later, at: monday, draft: UUID())), .waiting(until: monday))
        XCTAssertEqual(OutboxState(send(status: .missed, at: monday, draft: UUID())), .missed(monday))
        XCTAssertEqual(OutboxState(send(status: .scheduled, lastError: "throttled (retry after 30 s)")),
                       .retrying(lastError: "throttled (retry after 30 s)"), "put back by a throttle: the runner wrote why")
        XCTAssertEqual(OutboxState(send(status: .scheduled, lastError: "network", draft: UUID())), .retrying(lastError: "network"),
                       "a Send Later message waiting out a retry reads as one too")
        XCTAssertEqual(OutboxState(send(status: .failed, lastError: "HTTP 400")), .failed(lastError: "HTTP 400"))
        XCTAssertNil(OutboxState(send(status: .sent, draft: UUID())), "taken: it leaves the Outbox at once")

        XCTAssertTrue(OutboxState.waiting(until: monday).isHeld)
        XCTAssertTrue(OutboxState.missed(monday).isHeld)
        for state in [OutboxState.sending, .retrying(lastError: nil), .failed(lastError: nil)] {
            XCTAssertFalse(state.isHeld, "\(state): only a Send Later message is the user's to change from here")
        }
        XCTAssertEqual([OutboxState.sending, .waiting(until: monday), .retrying(lastError: nil), .missed(monday), .failed(lastError: nil)]
            .map(\.goesByItself), [true, true, true, false, false])
    }

    /// Those that go by themselves soonest first, then those waiting for the user, newest first; a sent one not at all.
    func testTheOutboxListsTheSendsInTheOrderTheyGo() {
        let sends = [
            send("failedOld", status: .failed, created: date(2025, 3, 5, 9), lastError: "HTTP 400"),
            send("monday", status: .later, created: date(2025, 3, 4, 9), at: date(2025, 3, 10, 9), draft: UUID()),
            send("counting", status: .scheduled, created: now, at: now.addingTimeInterval(5)),
            send("retrying", status: .scheduled, created: date(2025, 3, 6, 9), at: now.addingTimeInterval(30), lastError: "network"),
            send("missed", status: .missed, created: date(2025, 3, 5, 18), at: date(2025, 3, 6, 9), draft: UUID()),
            send("sending", status: .sending, created: date(2025, 3, 6, 9, 19), at: now.addingTimeInterval(-1)),
            send("tomorrow", status: .later, created: date(2025, 3, 6, 8), at: date(2025, 3, 7, 9), draft: UUID()),
            send("gone", status: .sent, created: now, draft: UUID()),
        ]
        XCTAssertEqual(SendLaterConversation.outboxListed(sends).map(\.id),
                       ["sending", "counting", "retrying", "tomorrow", "monday", "missed", "failedOld"])
        XCTAssertEqual(SendLaterConversation.listed(sends).map(\.id).sorted(), ["missed", "monday", "tomorrow"],
                       "Drafts lists its Send Later messages as before")
    }

    // MARK: The row

    func testTheRowStandsForTheMessageAsItWillGo() throws {
        let pending = send(status: .scheduled, files: true)
        let summary = try XCTUnwrap(SendLaterConversation.outboxSummary(for: pending))
        XCTAssertEqual(summary.id, SendLaterConversation.conversationID(sendID: "s1", account: account), "the Drafts row's id")
        XCTAssertEqual(summary.latestMessageID, SendLaterConversation.messageID(sendID: "s1", account: account))
        XCTAssertTrue(LocalDraftConversation.isLocal(summary.id), "kept away from the store as a kept draft is")
        XCTAssertEqual(summary.subject, "Re: Contoso rollout")
        XCTAssertEqual(summary.snippet, "Thanks Ben, forwarding to IT now. Alex")
        XCTAssertEqual(summary.latestDate, now, "dated when Send was pressed")
        XCTAssertTrue(summary.hasAttachments)
        XCTAssertEqual(summary.unreadCount, 0)
        XCTAssertEqual(summary.outbox, .sending)
        XCTAssertNil(summary.sendLater, "no Drafts state: nothing reads it as a Drafts row")
        XCTAssertNil(SendLaterConversation.outboxSummary(for: send(status: .sent, draft: UUID())))

        let later = send(status: .later, at: date(2025, 3, 10, 9), draft: UUID())
        XCTAssertEqual(SendLaterConversation.outboxSummary(for: later)?.id, SendLaterConversation.summary(for: later)?.id,
                       "a Send Later message is the same row in both views")
    }

    /// The time slot says where the send is: as Drafts says a Send Later message's, “Sending…” for one going, “Retrying
    /// shortly” for one put back, and “Couldn't send”, in `danger`, for one that failed; VoiceOver hears the same.
    func testTheTimeSlotSaysWhereTheSendIs() throws {
        let reference = formatter.reference(now: now)
        let context = ConversationRowText.Context(kind: .sent, recipients: [ben])
        func row(_ pending: PendingSendSummary) throws -> ConversationRowText {
            ConversationRowText(summary: try XCTUnwrap(SendLaterConversation.outboxSummary(for: pending)), reference: reference,
                                formatter: formatter, context: context)
        }
        let counting = try row(send(status: .scheduled))
        XCTAssertEqual(counting.timeText, "Sending\u{2026}")
        XCTAssertEqual(counting.senderLine, "To Ben Carter")
        XCTAssertFalse(counting.isTimeFailure)
        XCTAssertNil(counting.timeToolTip)
        XCTAssertTrue(counting.accessibilityLabel.contains("Sending."), counting.accessibilityLabel)
        XCTAssertEqual(try row(send(status: .sending)).timeText, "Sending\u{2026}")

        let monday = try row(send(status: .later, at: date(2025, 3, 10, 9), draft: UUID()))
        XCTAssertEqual(monday.timeText, "Sends Mon 09:00", "as its Drafts row says it")
        XCTAssertEqual(monday.timeToolTip, "Sends Mon 09:00 while SuperSparrow is open")
        XCTAssertTrue(monday.accessibilityLabel.contains("Sends Mon 09:00, while SuperSparrow is open."), monday.accessibilityLabel)
        XCTAssertEqual(try row(send(status: .later, at: date(2025, 3, 6, 15), draft: UUID())).timeText, "Sends 15:00")
        let missed = try row(send(status: .missed, at: date(2025, 3, 6, 9), draft: UUID()))
        XCTAssertEqual(missed.timeText, "Not sent")
        XCTAssertTrue(missed.accessibilityLabel.contains("Not sent, was due 09:00."), missed.accessibilityLabel)

        let retrying = try row(send(status: .scheduled, lastError: "network"))
        XCTAssertEqual(retrying.timeText, "Retrying shortly")
        XCTAssertFalse(retrying.isTimeFailure)
        XCTAssertTrue(retrying.accessibilityLabel.contains("Not sent yet, retrying shortly."), retrying.accessibilityLabel)

        let failed = try row(send(status: .failed, lastError: "HTTP 400"))
        XCTAssertEqual(failed.timeText, "Couldn't send")
        XCTAssertTrue(failed.isTimeFailure, "set in danger")
        XCTAssertNil(failed.timeToolTip)
        XCTAssertTrue(failed.accessibilityLabel.contains("Couldn't send."), failed.accessibilityLabel)
        XCTAssertFalse(failed.timeText.contains("\u{2014}"), "no long dash")

        func key(_ pending: PendingSendSummary) throws -> UInt64 {
            ConversationRowText.cacheKey(for: try XCTUnwrap(SendLaterConversation.outboxSummary(for: pending)), dayStamp: 1)
        }
        XCTAssertNotEqual(try key(send(status: .scheduled)), try key(send(status: .scheduled, lastError: "network")),
                          "a new state draws the row again")
        XCTAssertNotEqual(try key(send(status: .sending)), try key(send(status: .failed, lastError: "HTTP 400")))
        let later = send(status: .later, at: date(2025, 3, 10, 9), draft: UUID())
        XCTAssertNotEqual(ConversationRowText.cacheKey(for: try XCTUnwrap(SendLaterConversation.summary(for: later)), dayStamp: 1),
                          try key(later), "a Drafts row and an Outbox row never share a cached row")
    }

    // MARK: The sheet

    /// The sheet says where the send is, a failed one's reason in `danger`; a waiting Send Later message offers Cancel and,
    /// held, Continue editing, and nothing in the Outbox offers Discard draft.
    func testTheSheetSaysWhereItIsAndWhatItOffers() throws {
        let builder = RenderPayloadBuilder(calendar: london, locale: british, timeZone: london.timeZone)
        let sender = EmailAddress(name: "Alex", address: "alex@contoso.test")
        let alex = Account(id: account, kind: .gmail, email: "alex@contoso.test", displayName: "Alex", addedAt: now)
        func card(_ pending: PendingSendSummary) throws -> RenderPayload.Message {
            let message = SendLaterConversation.message(for: pending, sender: sender)
            let state = try XCTUnwrap(OutboxState(pending))
            let payload = builder.build(messages: [message], bodies: [message.id: SendLaterConversation.body(for: pending)],
                                        accounts: [account: alex], outbox: [message.id: state], now: now)
            return try XCTUnwrap(payload.messages.first)
        }
        let waiting = try card(send(status: .later, at: date(2025, 3, 10, 9), draft: UUID()))
        XCTAssertTrue(waiting.isDraft, "the draft sheet, as Drafts shows a Send Later message")
        XCTAssertEqual(waiting.dateDisplay, "Sends Mon 09:00")
        XCTAssertTrue(waiting.cancelsSendLater)
        XCTAssertEqual(waiting.outbox, RenderPayload.OutboxSheet(continues: true, failed: false))
        let missed = try card(send(status: .missed, at: date(2025, 3, 6, 9), draft: UUID()))
        XCTAssertEqual(missed.dateDisplay, "Not sent")
        XCTAssertFalse(missed.cancelsSendLater, "the launch alert asks about it, as in Drafts")
        XCTAssertEqual(missed.outbox?.continues, true)
        let sending = try card(send(status: .scheduled))
        XCTAssertEqual(sending.dateDisplay, "Sending\u{2026}")
        XCTAssertFalse(sending.cancelsSendLater)
        XCTAssertEqual(sending.outbox, RenderPayload.OutboxSheet(continues: false, failed: false), "it only shows")
        XCTAssertEqual(try card(send(status: .scheduled, lastError: "network")).dateDisplay, "Retrying shortly")
        let failed = try card(send(status: .failed, lastError: "HTTP 400"))
        XCTAssertEqual(failed.dateDisplay, "Couldn't send: Gmail didn't accept the message.", "the banner's reason")
        XCTAssertEqual(failed.outbox, RenderPayload.OutboxSheet(continues: false, failed: true))

        let pending = send(status: .scheduled)
        let message = SendLaterConversation.message(for: pending, sender: sender)
        let drafts = builder.build(messages: [message], bodies: [:], accounts: [:], now: now)
        XCTAssertNil(drafts.messages.first?.outbox, "absent everywhere but the Outbox")
        let json = String(decoding: try JSONEncoder().encode(drafts), as: UTF8.self)
        XCTAssertFalse(json.contains("\"outbox\""), "and from the payload's JSON")

        let before = RenderInputs(messages: [message], outbox: [message.id: .sending]) { _ in true }
        let after = RenderInputs(messages: [message], outbox: [message.id: .failed(lastError: "HTTP 400")]) { _ in true }
        XCTAssertNotEqual(before, after, "a change of state draws the sheet again")
        XCTAssertNil(before.flagPatches(to: after), "with a payload, not a flag patch")
    }

    // MARK: The view

    /// Nothing applies to a message on its way but Continue Editing on a held Send Later message, one or several.
    func testTheReaderOffersOnlyContinueEditingOnAHeldMessage() {
        XCTAssertEqual(ReaderActionSet.make(.outbox(continues: true)), ReaderActionSet(primary: [.continueEditing], replies: []))
        XCTAssertEqual(ReaderActionSet.make(.outbox(continues: false)), ReaderActionSet(primary: [], replies: []))
        XCTAssertTrue(ReaderActionSet.make(.several(count: 3, view: .outbox, allStarred: false)).all.isEmpty)
        XCTAssertTrue(ReaderActionSet.make(.one(view: .outbox, inTrash: false, emptied: false, starred: false, replyAllAvailable: true))
            .all.isEmpty)
    }

    /// The empty Outbox says so whatever the accounts' sync states, which say nothing of what this Mac is sending.
    func testTheEmptyOutboxSaysSoWhateverTheSync() {
        let query = ConversationQuery(view: .outbox)
        let expected = ListEmptyState(sentence: "Nothing waiting to send", hint: "Messages you send wait here until they have gone.")
        XCTAssertEqual(ListEmptyState.make(query: query), expected)
        XCTAssertEqual(ListEmptyState.make(query: query, isOfflineWithNothingCached: true, firstSyncFinishedAccount: "Contoso",
                                           olderMailDownloading: true), expected)
    }

    /// No rail folder takes rows dragged out of the Outbox, Trash included; a search typed there lists All Mail's rows.
    func testNoFolderTakesTheOutboxsRows() {
        let row = SendLaterConversation.outboxSummary(for: send(status: .scheduled))!
        for tile in MailboxView.allCases {
            XCTAssertFalse(RailDrop.accepts(tile, rows: [row], selectedView: .outbox, isSearching: false), "\(tile)")
        }
        XCTAssertNil(RailDrop.change(for: .outbox), "and the Outbox has no tile to drop on")
        XCTAssertEqual(ShellQuery.make(scope: nil, view: .outbox, searchText: "lisbon").view, .all)
        XCTAssertEqual(ShellQuery.make(scope: nil, view: .outbox, searchText: "").view, .outbox)
    }

    /// Appended last, so the views before it keep the `allCases` positions the menus use as tags.
    func testTheOutboxIsTheLastView() {
        XCTAssertEqual(MailboxView.allCases, [.inbox, .starred, .sent, .drafts, .trash, .all, .later, .outbox])
    }
}
