import XCTest
import PaperCore

/// The `CalendarStoring` contract (docs/DATA-MODEL.md, "Calendar events" and "Mail times"): what a read of an account's
/// calendar writes, time set aside on this Mac on its way to the provider and back, its removal and its undo, and the
/// times found in mail, which live and die with their message. Written as an extension so `SQLiteMailStoreContractTests`
/// inherits every case and both stores are held to the same semantics.
extension MailStoreContractTests {
    // MARK: Fixtures

    /// An event as a read of the account's calendar reports it.
    private func calendarRead(_ providerID: String, account: AccountID? = nil, title: String = "Standup", from start: TimeInterval,
                              to end: TimeInterval, response: CalendarEvent.Response = .accepted,
                              clientKey: String? = nil) -> CalendarEvent {
        let accountID = account ?? accountA
        return CalendarEvent(id: CalendarEvent.localID(accountID: accountID, providerID: providerID), accountID: accountID,
                             providerID: providerID, title: title, start: date(start), end: date(end), response: response,
                             clientKey: clientKey)
    }

    /// Time set aside for a mail on this Mac, as B makes it.
    private func calendarBlock(_ name: String, account: AccountID? = nil, from start: TimeInterval = 3_600,
                               to end: TimeInterval = 5_400) -> CalendarEvent {
        let accountID = account ?? accountA
        return CalendarEvent(id: "\(accountID.rawValue)|local-\(name)", accountID: accountID, providerID: nil, title: "Lunch?",
                             start: date(start), end: date(end), sourceMessage: MessageID(accountID: accountID, providerID: "m-\(name)"),
                             clientKey: "key-\(name)", sync: .creating)
    }

    /// The provider's copy of a block, as a create answers it.
    private func calendarCopy(of block: CalendarEvent, providerID: String) -> CalendarEvent {
        var copy = block
        copy.providerID = providerID
        copy.webURL = "https://calendar.google.com/event?eid=\(providerID)"
        copy.updatedAt = date(60)
        copy.sync = .synced
        return copy
    }

    private var calendarWeek: DateInterval { DateInterval(start: date(0), end: date(7 * 86_400)) }

    private func calendarRow(_ id: String) throws -> CalendarEvent? {
        try store.calendarEvents(in: DateInterval(start: date(-400 * 86_400), end: date(400 * 86_400)), accountIDs: nil)
            .first { $0.id == id }
    }

    /// Each event as `name:sync`, its name the provider id or the local id's tail.
    private static func calendarNames(_ events: [CalendarEvent]) -> [String] {
        events.map { "\($0.id.split(separator: "|").last.map(String.init) ?? $0.id):\($0.sync.rawValue)" }
    }

    // MARK: Reads

    func testCalendarEventsRoundTripEveryField() throws {
        let full = CalendarEvent(
            id: CalendarEvent.localID(accountID: accountA, providerID: "evt-full"), accountID: accountA, providerID: "evt-full",
            title: "Design review", location: "Room 4", start: date(3_600), end: date(7_200), isAllDay: false, response: .tentative,
            isFree: true, joinURL: "https://meet.google.com/abc-defg-hij", webURL: "https://calendar.google.com/event?eid=1",
            organizer: "Ben Carter", invitationUID: "uid-7@google.com", clientKey: "0123456789abcdef0123456789abcdef",
            updatedAt: date(30)
        )
        // Held floating: the start of its day as UTC, the end exclusive.
        let allDay = CalendarEvent(id: CalendarEvent.localID(accountID: accountA, providerID: "evt-day"), accountID: accountA,
                                   providerID: "evt-day", title: "Offsite", start: date(86_400), end: date(2 * 86_400),
                                   isAllDay: true, response: .organizer)
        var unaligned = calendarRead("evt-odd", from: 0, to: 60)
        unaligned.start = date(0).addingTimeInterval(0.000_4)
        try store.replaceCalendarEvents([full, allDay, unaligned], accountID: accountA, window: calendarWeek)
        let block = calendarBlock("lunch")
        try store.addCalendarEvent(block)

        XCTAssertEqual(try calendarRow(full.id), full, "every field as read")
        XCTAssertEqual(try calendarRow(allDay.id), allDay)
        XCTAssertEqual(try calendarRow(unaligned.id)?.start, date(0), "times are kept to the millisecond")
        XCTAssertEqual(try calendarRow(block.id), block, "time set aside, with its mail and its key")
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA), [block])
    }

    func testCalendarEventsAreThoseOverlappingTheIntervalInOrder() throws {
        let events = [
            calendarRead("before", from: 0, to: 1_000), calendarRead("acrossStart", from: 500, to: 1_500),
            calendarRead("inside", from: 1_200, to: 1_300), calendarRead("sameStartLonger", from: 1_200, to: 1_400),
            calendarRead("tieB", from: 1_500, to: 1_600), calendarRead("tieA", from: 1_500, to: 1_600),
            calendarRead("acrossEnd", from: 1_900, to: 2_500), calendarRead("after", from: 2_000, to: 2_100),
            calendarRead("pointAtStart", from: 1_000, to: 1_000), calendarRead("pointInside", from: 1_700, to: 1_700),
            calendarRead("pointAtEnd", from: 2_000, to: 2_000), calendarRead("covering", from: 0, to: 3_000),
            calendarRead("declined", from: 1_800, to: 1_850, response: .declined),
        ]
        try store.replaceCalendarEvents(events, accountID: accountA, window: calendarWeek)
        try store.replaceCalendarEvents([calendarRead("other", account: accountB, from: 1_100, to: 1_200)], accountID: accountB,
                                        window: calendarWeek)
        let interval = DateInterval(start: date(1_000), end: date(2_000))
        let mine = ["covering", "acrossStart", "pointAtStart", "inside", "sameStartLonger", "tieA", "tieB", "pointInside",
                    "declined", "acrossEnd"]

        XCTAssertEqual(Self.calendarNames(try store.calendarEvents(in: interval, accountIDs: nil)).map { $0.replacingOccurrences(of: ":synced", with: "") },
                       ["covering", "acrossStart", "pointAtStart", "other", "inside", "sameStartLonger", "tieA", "tieB", "pointInside",
                        "declined", "acrossEnd"],
                       "start, end, id; an event of no length at the interval's start counts, one at its end does not")
        XCTAssertEqual(try store.calendarEvents(in: interval, accountIDs: [accountA]).compactMap(\.providerID), mine)
        XCTAssertEqual(try store.calendarEvents(in: interval, accountIDs: [accountB]).compactMap(\.providerID), ["other"])
        XCTAssertEqual(try store.calendarEvents(in: interval, accountIDs: [accountA, accountB, accountA]).count, mine.count + 1)
        XCTAssertEqual(try store.calendarEvents(in: interval, accountIDs: []), [], "no account asked for, none answered")
        XCTAssertEqual(try store.calendarEvents(in: interval, accountIDs: nil).first { $0.providerID == "declined" }?.isShown, false,
                       "a declined event is listed for the caller to leave out")
    }

    // MARK: Reading a calendar

    func testAReadReplacesTheAccountsEventsInItsWindowOnly() throws {
        let day = DateInterval(start: date(0), end: date(86_400))
        try store.replaceCalendarEvents([
            calendarRead("kept", from: 100, to: 200), calendarRead("gone", from: 300, to: 400),
            calendarRead("straddles", from: -100, to: 100), calendarRead("outside", from: 90_000, to: 91_000),
            calendarRead("before", from: -7_200, to: -3_600),
        ], accountID: accountA, window: calendarWeek)
        try store.replaceCalendarEvents([calendarRead("theirs", account: accountB, from: 100, to: 200)], accountID: accountB, window: day)

        try store.replaceCalendarEvents([calendarRead("kept", title: "Standup moved", from: 150, to: 250), calendarRead("new", from: 500, to: 600)],
                                        accountID: accountA, window: day)
        let all = DateInterval(start: date(-86_400), end: date(7 * 86_400))
        XCTAssertEqual(try store.calendarEvents(in: all, accountIDs: [accountA]).compactMap(\.providerID),
                       ["before", "kept", "new", "outside"],
                       "what the read lists is written; what it no longer lists in its window goes; the rest is left alone")
        XCTAssertEqual(try calendarRow(CalendarEvent.localID(accountID: accountA, providerID: "kept"))?.title, "Standup moved")
        XCTAssertEqual(try store.calendarEvents(in: all, accountIDs: [accountB]).compactMap(\.providerID), ["theirs"], "another account's")

        try store.replaceCalendarEvents([], accountID: accountA, window: day)
        XCTAssertEqual(try store.calendarEvents(in: all, accountIDs: [accountA]).compactMap(\.providerID), ["before", "outside"],
                       "an empty day is an empty day")
    }

    func testAReadKeepsTimeSetAsideThatIsStillOnItsWay() throws {
        let block = calendarBlock("lunch")
        try store.addCalendarEvent(block)
        let meeting = calendarRead("meeting", from: 600, to: 1_200)
        try store.replaceCalendarEvents([meeting], accountID: accountA, window: calendarWeek)
        try store.removeCalendarEvent(id: meeting.id)

        try store.replaceCalendarEvents([calendarRead("meeting", title: "Meeting (moved)", from: 900, to: 1_500)], accountID: accountA,
                                        window: calendarWeek)
        XCTAssertEqual(try calendarRow(block.id), block, "not listed, still creating")
        let deleting = try XCTUnwrap(calendarRow(meeting.id))
        XCTAssertEqual(deleting.sync, .deleting, "an event read with the id of one being deleted keeps deleting")
        XCTAssertEqual(deleting.title, "Meeting (moved)", "and takes what the read says of it")
        XCTAssertEqual(Self.calendarNames(try store.pendingCalendarEvents(accountID: accountA)), ["local-lunch:creating", "meeting:deleting"])

        try store.replaceCalendarEvents([], accountID: accountA, window: calendarWeek)
        XCTAssertNil(try calendarRow(meeting.id), "a deleting event the read no longer lists is gone")
        XCTAssertEqual(try calendarRow(block.id), block)
    }

    func testAReadFindsTheCopyOfABlockWhoseCreateReplyWasLost() throws {
        let block = calendarBlock("lost")
        try store.addCalendarEvent(block)
        let copy = calendarRead("evt-9", title: "Lunch?", from: 3_600, to: 5_400, response: .organizer, clientKey: block.clientKey)
        try store.replaceCalendarEvents([copy], accountID: accountA, window: calendarWeek)

        let row = try XCTUnwrap(calendarRow(block.id), "the block keeps its local id")
        XCTAssertEqual(row.providerID, "evt-9")
        XCTAssertEqual(row.sync, .synced)
        XCTAssertEqual(row.sourceMessage, block.sourceMessage, "and its mail")
        XCTAssertEqual(row.clientKey, block.clientKey)
        XCTAssertNil(try calendarRow(copy.id), "never a second row for the same event")
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA), [], "nothing left to create")

        // The engine's create, retried, answers the same copy: the row already holds it.
        XCTAssertTrue(try store.settleCalendarEvent(id: block.id, created: calendarCopy(of: block, providerID: "evt-9")))
        XCTAssertEqual(try calendarRow(block.id), row)
        XCTAssertFalse(try store.settleCalendarEvent(id: block.id, created: calendarCopy(of: block, providerID: "evt-other")),
                       "another copy is not this row's")

        try store.replaceCalendarEvents([copy], accountID: accountA, window: calendarWeek)
        XCTAssertEqual(try calendarRow(block.id), row, "a refresh changes nothing")
    }

    func testABlockBeingDeletedWhoseCopyIsListedStaysDeleting() throws {
        let block = calendarBlock("drop")
        try store.addCalendarEvent(block)
        XCTAssertTrue(try store.settleCalendarEvent(id: block.id, created: calendarCopy(of: block, providerID: "evt-1")))
        try store.removeCalendarEvent(id: block.id)

        try store.replaceCalendarEvents([calendarRead("evt-1", title: "Lunch?", from: 3_600, to: 5_400, clientKey: block.clientKey)],
                                        accountID: accountA, window: calendarWeek)
        let row = try XCTUnwrap(calendarRow(block.id))
        XCTAssertEqual(row.sync, .deleting)
        XCTAssertEqual(row.providerID, "evt-1", "with the provider's id, for the engine to delete")
        XCTAssertEqual(row.sourceMessage, block.sourceMessage)
        XCTAssertNil(try calendarRow(CalendarEvent.localID(accountID: accountA, providerID: "evt-1")))
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA).map(\.id), [block.id])
        XCTAssertTrue(try store.settleCalendarEvent(id: block.id, created: nil))
        XCTAssertNil(try calendarRow(block.id))
    }

    /// A client key claims one row per read: the occurrences of a block someone made repeating elsewhere all carry its
    /// key (Google copies the series' private properties to each), and each stays an event of its own.
    func testAClientKeyClaimsOneRowPerRead() throws {
        let block = calendarBlock("weekly")
        try store.addCalendarEvent(block)
        XCTAssertTrue(try store.settleCalendarEvent(id: block.id, created: calendarCopy(of: block, providerID: "evt-w1")))
        let reads = [
            calendarRead("evt-w1", title: "Lunch?", from: 3_600, to: 5_400, clientKey: block.clientKey),
            calendarRead("evt-w2", title: "Lunch?", from: 3_600 + 86_400, to: 5_400 + 86_400, clientKey: block.clientKey),
            calendarRead("evt-w3", title: "Lunch?", from: 3_600 + 2 * 86_400, to: 5_400 + 2 * 86_400, clientKey: block.clientKey),
        ]
        try store.replaceCalendarEvents(reads, accountID: accountA, window: calendarWeek)

        let rows = try store.calendarEvents(in: calendarWeek, accountIDs: [accountA])
        XCTAssertEqual(rows.compactMap(\.providerID), ["evt-w1", "evt-w2", "evt-w3"], "every occurrence, each its own row")
        let first = try XCTUnwrap(calendarRow(block.id))
        XCTAssertEqual(first.providerID, "evt-w1", "the block keeps its local id, its mail and its key on the first")
        XCTAssertEqual(first.sourceMessage, block.sourceMessage)
        XCTAssertEqual(first.clientKey, block.clientKey)
        let others = rows.filter { $0.id != block.id }
        XCTAssertEqual(others.map(\.id), ["evt-w2", "evt-w3"].map { CalendarEvent.localID(accountID: accountA, providerID: $0) })
        XCTAssertTrue(others.allSatisfy { $0.clientKey == nil && $0.sourceMessage == nil && $0.sync == .synced })

        try store.replaceCalendarEvents(reads, accountID: accountA, window: calendarWeek)
        XCTAssertEqual(try store.calendarEvents(in: calendarWeek, accountIDs: [accountA]), rows, "the same read again changes nothing")
    }

    /// The history behind the window goes at each read: `synced` events that ended more than 30 days before the window
    /// kept around now, or before the read's own window when that starts earlier. Rows waiting for the provider, or
    /// marked failed, and other accounts' stay.
    func testAReadDeletesTheAccountsHistoryLongBehindTheWindow() throws {
        let kept = CalendarWindow.around(Date())
        let day: TimeInterval = 86_400
        let at = { (days: Double) in MailboxClock.aligned(kept.start.addingTimeInterval(days * day)) }
        func read(_ id: String, account: AccountID? = nil, endingAt end: Date) -> CalendarEvent {
            let accountID = account ?? accountA
            return CalendarEvent(id: CalendarEvent.localID(accountID: accountID, providerID: id), accountID: accountID,
                                 providerID: id, title: id, start: end.addingTimeInterval(-3_600), end: end)
        }
        // Around today, wherever the test runs: the line is measured from the window kept around now.
        let row = { (id: String) in
            try self.store.calendarEvents(in: DateInterval(start: at(-400), end: at(400)), accountIDs: nil).first { $0.id == id }
        }
        let past = DateInterval(start: at(-60), end: at(-1))
        try store.replaceCalendarEvents([read("old", endingAt: at(-31)), read("recent", endingAt: at(-29)),
                                         read("doomed", endingAt: at(-40))], accountID: accountA, window: past)
        try store.replaceCalendarEvents([read("theirs", account: accountB, endingAt: at(-31))], accountID: accountB, window: past)
        XCTAssertNotNil(try row(CalendarEvent.localID(accountID: accountA, providerID: "old")),
                        "a read of days behind the window keeps what it read")
        try store.removeCalendarEvent(id: CalendarEvent.localID(accountID: accountA, providerID: "doomed"))
        var waiting = calendarBlock("waiting")
        waiting.start = at(-40)
        waiting.end = at(-40).addingTimeInterval(1_800)
        try store.addCalendarEvent(waiting)

        try store.replaceCalendarEvents([read("today", endingAt: at(14.5))], accountID: accountA, window: kept)
        let names = try store.calendarEvents(in: DateInterval(start: at(-90), end: kept.end), accountIDs: nil).map(\.title)
        XCTAssertEqual(Set(names), ["recent", "doomed", "Lunch?", "theirs", "today"],
                       "only the account's synced history more than 30 days behind goes")
        XCTAssertEqual(try row(waiting.id)?.sync, .creating)
        XCTAssertEqual(try row(CalendarEvent.localID(accountID: accountA, providerID: "doomed"))?.sync, .deleting)

        // A read of days after the window never takes the window's own events.
        let later = DateInterval(start: kept.end.addingTimeInterval(30 * day), duration: 7 * day)
        try store.replaceCalendarEvents([], accountID: accountA, window: later)
        XCTAssertNotNil(try row(CalendarEvent.localID(accountID: accountA, providerID: "recent")))
        XCTAssertNotNil(try row(CalendarEvent.localID(accountID: accountA, providerID: "today")))
    }

    func testAReadForARemovedAccountWritesNothing() throws {
        try store.deleteAccount(accountA)
        try store.replaceCalendarEvents([calendarRead("late", from: 0, to: 60)], accountID: accountA, window: calendarWeek)
        XCTAssertEqual(try store.calendarEvents(in: calendarWeek, accountIDs: nil), [])
    }

    // MARK: Time set aside

    func testAddingRefusesATakenIdAndAnUnknownAccount() throws {
        var block = calendarBlock("once")
        block.providerID = "not-yet"
        block.sync = .synced
        block.clientKey = nil
        try store.addCalendarEvent(block)
        let row = try XCTUnwrap(calendarRow(block.id))
        XCTAssertEqual(row.sync, .creating, "set aside here: the provider has yet to create it")
        XCTAssertNil(row.providerID)
        let key = try XCTUnwrap(row.clientKey, "a key, so the create is idempotent")
        XCTAssertEqual(key.count, 32)

        XCTAssertThrowsError(try store.addCalendarEvent(calendarBlock("once"))) { error in
            guard case StoreError.conflict = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try store.addCalendarEvent(calendarBlock("stray", account: AccountID("acct-gone")))) { error in
            guard case StoreError.notFound = error else { return XCTFail("\(error)") }
        }
    }

    func testRemovingABlockWhileItIsCreatedLeavesAHiddenTombstoneUnderItsKey() throws {
        let block = calendarBlock("quick")
        try store.addCalendarEvent(block)
        XCTAssertEqual(try store.removeCalendarEvent(id: block.id), block, "the event as it was, for the undo")
        let tombstone = try XCTUnwrap(calendarRow(block.id), "its create may have reached the provider: only its key finds it")
        XCTAssertEqual(tombstone.sync, .deleting)
        XCTAssertFalse(tombstone.isShown, "gone from the calendar at once")
        XCTAssertNil(tombstone.providerID)
        XCTAssertEqual(tombstone.clientKey, block.clientKey)
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA), [tombstone])
        XCTAssertEqual(try store.removeCalendarEvent(id: block.id), tombstone, "removing it again changes nothing")

        // The create that was on its way settles its copy into the tombstone, for the engine to delete.
        XCTAssertTrue(try store.settleCalendarEvent(id: block.id, created: calendarCopy(of: block, providerID: "evt-late")))
        let settled = try XCTUnwrap(calendarRow(block.id))
        XCTAssertEqual(settled.sync, .deleting)
        XCTAssertEqual(settled.providerID, "evt-late")
        XCTAssertFalse(settled.isShown)
        XCTAssertEqual(settled.sourceMessage, block.sourceMessage)
        XCTAssertFalse(try store.settleCalendarEvent(id: block.id, created: calendarCopy(of: block, providerID: "evt-other")),
                       "its copy is known now")
        XCTAssertTrue(try store.settleCalendarEvent(id: block.id, created: nil), "the copy deleted")
        XCTAssertNil(try calendarRow(block.id), "and nothing comes back")
        XCTAssertNil(try store.removeCalendarEvent(id: block.id))
    }

    func testAReadFindsTheCopyOfARemovedBlockByItsKeyOrSweepsItsTombstone() throws {
        let found = calendarBlock("found"), never = calendarBlock("never", from: 7_200, to: 9_000)
        try store.addCalendarEvent(found)
        try store.addCalendarEvent(never)
        try store.removeCalendarEvent(id: found.id)
        try store.removeCalendarEvent(id: never.id)

        try store.replaceCalendarEvents([calendarRead("evt-8", title: "Lunch?", from: 3_600, to: 5_400, clientKey: found.clientKey)],
                                        accountID: accountA, window: calendarWeek)
        let adopted = try XCTUnwrap(calendarRow(found.id), "the copy a lost reply made is the tombstone's")
        XCTAssertEqual(adopted.sync, .deleting)
        XCTAssertEqual(adopted.providerID, "evt-8", "its id filled in, for the engine to delete")
        XCTAssertFalse(adopted.isShown)
        XCTAssertNil(try calendarRow(CalendarEvent.localID(accountID: accountA, providerID: "evt-8")), "never an event of its own")
        XCTAssertNil(try calendarRow(never.id), "no copy listed: the provider never made it")
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA).map(\.id), [found.id])
    }

    func testRemovingAnEventTheProviderHasWaitsForTheEngine() throws {
        let meeting = calendarRead("evt-2", from: 600, to: 1_200)
        try store.replaceCalendarEvents([meeting], accountID: accountA, window: calendarWeek)
        XCTAssertFalse(try store.settleCalendarEvent(id: meeting.id, created: nil), "not being deleted")

        XCTAssertEqual(try store.removeCalendarEvent(id: meeting.id), meeting)
        let row = try XCTUnwrap(calendarRow(meeting.id))
        XCTAssertEqual(row.sync, .deleting)
        XCTAssertFalse(row.isShown)
        XCTAssertEqual(try store.removeCalendarEvent(id: meeting.id), row, "removing it again changes nothing")
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA), [row])
        XCTAssertFalse(try store.settleCalendarEvent(id: meeting.id, created: calendarCopy(of: meeting, providerID: "evt-2")),
                       "a delete is not settled by a create")

        XCTAssertTrue(try store.settleCalendarEvent(id: meeting.id, created: nil))
        XCTAssertNil(try calendarRow(meeting.id))
        XCTAssertFalse(try store.settleCalendarEvent(id: meeting.id, created: nil), "the row has gone")
    }

    func testSettlingACreatedBlockKeepsItsLocalIdentity() throws {
        let block = calendarBlock("lunch")
        try store.addCalendarEvent(block)
        var copy = calendarCopy(of: block, providerID: "evt-3")
        copy.id = CalendarEvent.localID(accountID: accountA, providerID: "evt-3")
        copy.sourceMessage = nil
        XCTAssertTrue(try store.settleCalendarEvent(id: block.id, created: copy))

        let row = try XCTUnwrap(calendarRow(block.id))
        XCTAssertEqual(row.providerID, "evt-3")
        XCTAssertEqual(row.webURL, copy.webURL)
        XCTAssertEqual(row.updatedAt, copy.updatedAt)
        XCTAssertEqual(row.sync, .synced)
        XCTAssertEqual(row.sourceMessage, block.sourceMessage, "the mail it was set aside for stays")
        XCTAssertEqual(row.clientKey, block.clientKey)
        XCTAssertNil(try calendarRow(copy.id))
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA), [])
    }

    func testAFailedCreateIsMarkedUntilTheUserRemovesIt() throws {
        let block = calendarBlock("refused")
        try store.addCalendarEvent(block)
        try store.failCalendarEvent(id: block.id)
        XCTAssertEqual(try calendarRow(block.id)?.sync, .failed)
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA), [], "never replayed")

        let meeting = calendarRead("evt-4", from: 600, to: 1_200)
        try store.replaceCalendarEvents([meeting], accountID: accountA, window: calendarWeek)
        XCTAssertEqual(try calendarRow(block.id)?.sync, .failed, "the provider never had it: a read leaves its mark")
        try store.failCalendarEvent(id: meeting.id)
        XCTAssertEqual(try calendarRow(meeting.id)?.sync, .synced, "only a create fails")
        try store.failCalendarEvent(id: "acct-a|nothing")

        let again = calendarBlock("refused-again")
        try store.addCalendarEvent(again)
        try store.failCalendarEvent(id: again.id)
        XCTAssertEqual(try store.removeCalendarEvent(id: again.id)?.sync, .failed)
        XCTAssertNil(try calendarRow(again.id), "removed at once")

        let lucky = calendarBlock("lucky")
        try store.addCalendarEvent(lucky)
        try store.failCalendarEvent(id: lucky.id)
        try store.replaceCalendarEvents([meeting, calendarRead("evt-5", title: "Lunch?", from: 3_600, to: 5_400, clientKey: lucky.clientKey)],
                                        accountID: accountA, window: calendarWeek)
        XCTAssertEqual(try calendarRow(lucky.id)?.sync, .synced, "a read that finds it made after all settles it")
        XCTAssertEqual(try calendarRow(lucky.id)?.providerID, "evt-5")
    }

    func testPendingEventsAreOldestFirst() throws {
        try store.addCalendarEvent(calendarBlock("z-first"))
        Thread.sleep(forTimeInterval: 0.005)
        try store.addCalendarEvent(calendarBlock("a-second"))
        Thread.sleep(forTimeInterval: 0.005)
        let meeting = calendarRead("m-third", from: 600, to: 1_200)
        try store.replaceCalendarEvents([meeting], accountID: accountA, window: calendarWeek)
        try store.removeCalendarEvent(id: meeting.id)
        try store.addCalendarEvent(calendarBlock("theirs", account: accountB))

        XCTAssertEqual(Self.calendarNames(try store.pendingCalendarEvents(accountID: accountA)),
                       ["local-z-first:creating", "local-a-second:creating", "m-third:deleting"])
        XCTAssertEqual(Self.calendarNames(try store.pendingCalendarEvents(accountID: accountB)), ["local-theirs:creating"])
    }

    // MARK: Undo

    func testUndoingARemovalWhileTheEngineHasNotDeletedItPutsTheRowBack() throws {
        let block = calendarBlock("undo")
        try store.addCalendarEvent(block)
        XCTAssertTrue(try store.settleCalendarEvent(id: block.id, created: calendarCopy(of: block, providerID: "evt-6")))
        let settled = try XCTUnwrap(calendarRow(block.id))
        let removed = try XCTUnwrap(try store.removeCalendarEvent(id: block.id))

        XCTAssertEqual(try store.restoreCalendarEvent(removed), settled, "synced again, as it was")
        XCTAssertEqual(try calendarRow(block.id), settled)
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA), [])
        XCTAssertEqual(try store.restoreCalendarEvent(removed), settled, "a second undo changes nothing")
    }

    func testUndoingARemovalTheProviderHasDeletedMakesItAgainAsNew() throws {
        let block = calendarBlock("again")
        try store.addCalendarEvent(block)
        XCTAssertTrue(try store.settleCalendarEvent(id: block.id, created: calendarCopy(of: block, providerID: "evt-7")))
        let removed = try XCTUnwrap(try store.removeCalendarEvent(id: block.id))
        XCTAssertTrue(try store.settleCalendarEvent(id: block.id, created: nil))

        let restored = try store.restoreCalendarEvent(removed)
        XCTAssertNotEqual(restored.id, block.id, "Google keeps the old id reserved")
        XCTAssertTrue(restored.id.hasPrefix("acct-a|local-"))
        XCTAssertNotEqual(restored.clientKey, block.clientKey)
        XCTAssertEqual(restored.clientKey?.count, 32)
        XCTAssertNil(restored.providerID)
        XCTAssertNil(restored.webURL)
        XCTAssertNil(restored.updatedAt)
        XCTAssertEqual(restored.sync, .creating)
        XCTAssertEqual(restored.sourceMessage, block.sourceMessage)
        XCTAssertEqual([restored.title, "\(restored.start)", "\(restored.end)"], [block.title, "\(block.start)", "\(block.end)"])
        XCTAssertEqual(try calendarRow(restored.id), restored, "the row as it now stands")
        XCTAssertNil(try calendarRow(block.id))
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA), [restored])
    }

    func testUndoingTheRemovalOfABlockStillBeingCreatedKeepsItsIdAndKey() throws {
        let block = calendarBlock("early")
        try store.addCalendarEvent(block)
        let removed = try XCTUnwrap(try store.removeCalendarEvent(id: block.id))
        let restored = try store.restoreCalendarEvent(removed)
        XCTAssertEqual(restored, block, "its own id and key: a create sent again finds any copy the first one made")
        XCTAssertEqual(try calendarRow(block.id), block)
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA), [block])
        XCTAssertEqual(try store.restoreCalendarEvent(removed), block, "a second undo changes nothing")

        // Once a read swept its tombstone (or the engine deleted its copy, whose id Google keeps reserved), it comes back
        // under a new key.
        try store.removeCalendarEvent(id: block.id)
        try store.replaceCalendarEvents([], accountID: accountA, window: calendarWeek)
        XCTAssertNil(try calendarRow(block.id))
        let anew = try store.restoreCalendarEvent(removed)
        XCTAssertEqual(anew.id, block.id, "the provider never had it")
        XCTAssertNotEqual(anew.clientKey, block.clientKey)
        XCTAssertEqual(anew.clientKey?.count, 32)
        var expected = block
        expected.clientKey = anew.clientKey
        XCTAssertEqual(anew, expected)

        try store.deleteAccount(accountA)
        XCTAssertThrowsError(try store.restoreCalendarEvent(removed), "its account is gone") { error in
            guard case StoreError.notFound = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(try calendarRow(block.id))
    }

    func testUndoingTheRemovalOfABlockWhoseCopyARemovedCreateMadeKeepsThatCopy() throws {
        let block = calendarBlock("late")
        try store.addCalendarEvent(block)
        let removed = try XCTUnwrap(try store.removeCalendarEvent(id: block.id))
        XCTAssertTrue(try store.settleCalendarEvent(id: block.id, created: calendarCopy(of: block, providerID: "evt-9")))

        let restored = try store.restoreCalendarEvent(removed)
        XCTAssertEqual(restored.id, block.id)
        XCTAssertEqual(restored.sync, .synced, "the provider has it: it is simply back")
        XCTAssertEqual(restored.providerID, "evt-9")
        XCTAssertEqual(restored.sourceMessage, block.sourceMessage)
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA), [])
    }

    // MARK: Answers

    func testAnAnswerOnThisMacShowsOnTheInvitationsEventsAtOnce() throws {
        func invited(_ id: String, uid: String?, account: AccountID? = nil, start: TimeInterval,
                     response: CalendarEvent.Response = .needsAction) -> CalendarEvent {
            var event = calendarRead(id, account: account, from: start, to: start + 1_800, response: response)
            event.invitationUID = uid
            return event
        }
        // Exchange gives each occurrence its own UID, the series' with its date written in.
        let series = "040000008200E00074C5B7101A82E00800000000A0B1C2D3000000000000000010000000AABBCCDD"
        let occurrence = { (date: String) in
            String(series.prefix(32)) + date + String(series.dropFirst(40))
        }
        try store.replaceCalendarEvents([
            invited("once", uid: "uid-1@google.com", start: 3_600),
            invited("mine", uid: "uid-1@google.com", start: 3_600, response: .organizer),
            invited("other", uid: "uid-2@google.com", start: 7_200),
            invited("plain", uid: nil, start: 9_000),
            invited("w1", uid: occurrence("07EA0105"), start: 86_400),
            invited("w2", uid: occurrence("07EA0106"), start: 2 * 86_400),
            invited("w3", uid: occurrence("07EA0107"), start: 3 * 86_400),
        ], accountID: accountA, window: calendarWeek)
        try store.replaceCalendarEvents([invited("theirs", uid: "uid-1@google.com", account: accountB, start: 3_600)],
                                        accountID: accountB, window: calendarWeek)
        let response = { (id: String, account: AccountID) in
            try self.calendarRow(CalendarEvent.localID(accountID: account, providerID: id))?.response
        }

        try store.answerCalendarEvents(.declined, invitationUID: "uid-1@google.com", accountID: accountA, near: nil)
        XCTAssertEqual(try response("once", accountA), .declined)
        XCTAssertEqual(try response("mine", accountA), .organizer, "the user's own event is not an invitation to them")
        XCTAssertEqual(try response("other", accountA), .needsAction)
        XCTAssertEqual(try response("theirs", accountB), .needsAction, "another account's copy is its own")

        // A series answered: every occurrence. One occurrence answered: the one nearest its start.
        try store.answerCalendarEvents(.accepted, invitationUID: series, accountID: accountA, near: nil)
        XCTAssertEqual(try ["w1", "w2", "w3"].map { try response($0, accountA) }, [.accepted, .accepted, .accepted])
        try store.answerCalendarEvents(.tentative, invitationUID: series, accountID: accountA, near: date(2 * 86_400 + 600))
        XCTAssertEqual(try ["w1", "w2", "w3"].map { try response($0, accountA) }, [.accepted, .tentative, .accepted])

        // A row being deleted is left as it is.
        try store.removeCalendarEvent(id: CalendarEvent.localID(accountID: accountA, providerID: "other"))
        try store.answerCalendarEvents(.accepted, invitationUID: "uid-2@google.com", accountID: accountA, near: nil)
        XCTAssertEqual(try response("other", accountA), .needsAction)
    }

    // MARK: Accounts and mail

    func testRemovingTheAccountRemovesItsCalendarAndMailTimes() throws {
        try store.upsertMessages([message("m1", in: "c1"), message("b1", in: "cb", account: accountB, from: bea)])
        let m1 = MessageID(accountID: accountA, providerID: "m1"), b1 = MessageID(accountID: accountB, providerID: "b1")
        try store.saveMailTimes([MailTime(messageID: m1, start: date(3_600), phrase: "at 1am")], for: m1)
        try store.saveMailTimes([MailTime(messageID: b1, start: date(7_200), phrase: "at 2am")], for: b1)
        try store.replaceCalendarEvents([calendarRead("mine", from: 0, to: 60)], accountID: accountA, window: calendarWeek)
        try store.addCalendarEvent(calendarBlock("mine"))
        try store.replaceCalendarEvents([calendarRead("theirs", account: accountB, from: 0, to: 60)], accountID: accountB,
                                        window: calendarWeek)

        try store.deleteAccount(accountA)
        XCTAssertEqual(try store.calendarEvents(in: calendarWeek, accountIDs: nil).compactMap(\.providerID), ["theirs"])
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA), [])
        XCTAssertEqual(try store.mailTimes(in: ConversationID(accountID: accountA, providerID: "c1")), [])
        XCTAssertEqual(try store.mailTimes(in: ConversationID(accountID: accountB, providerID: "cb")).map(\.phrase), ["at 2am"])
    }

    func testWipingMailKeepsTheCalendarAndDropsMailTimes() throws {
        try store.upsertMessages([message("m1", in: "c1")])
        let m1 = MessageID(accountID: accountA, providerID: "m1")
        try store.saveMailTimes([MailTime(messageID: m1, start: date(3_600), phrase: "at 1am")], for: m1)
        let meeting = calendarRead("meeting", from: 0, to: 60)
        try store.replaceCalendarEvents([meeting], accountID: accountA, window: calendarWeek)
        let block = calendarBlock("kept")
        try store.addCalendarEvent(block)

        try store.wipeMailData(for: accountA)
        XCTAssertEqual(try store.calendarEvents(in: calendarWeek, accountIDs: nil), [meeting, block], "the calendar is not mail")
        XCTAssertEqual(try store.pendingCalendarEvents(accountID: accountA), [block])
        try store.upsertMessages([message("m1", in: "c1")])
        XCTAssertEqual(try store.mailTimes(in: ConversationID(accountID: accountA, providerID: "c1")), [],
                       "the times went with the mail, and do not come back with it")
    }

    func testMailTimesGoWithTheirMessage() throws {
        try store.upsertMessages([message("m1", in: "c1"), message("m2", in: "c1", date: date(10))])
        let m1 = MessageID(accountID: accountA, providerID: "m1"), m2 = MessageID(accountID: accountA, providerID: "m2")
        let c1 = ConversationID(accountID: accountA, providerID: "c1")
        try store.saveBody(body("Friday at 3pm?"), for: m1)
        try store.saveMailTimes([MailTime(messageID: m1, start: date(3_600), duration: 1_800, phrase: "Friday at 3pm")], for: m1)
        try store.saveMailTimes([MailTime(messageID: m2, start: date(7_200), phrase: "at 5")], for: m2)

        try store.evictBodies(from: nil, limit: 10) { (cutoff: self.date(1_000), excluding: []) }
        XCTAssertNil(try store.body(for: m1), "evicted")
        XCTAssertEqual(try store.mailTimes(in: c1).map(\.phrase), ["Friday at 3pm", "at 5"], "an eviction keeps them")

        try store.upsertMessages([message("m2", in: "c2", date: date(10))])
        XCTAssertEqual(try store.mailTimes(in: c1).map(\.phrase), ["Friday at 3pm"])
        XCTAssertEqual(try store.mailTimes(in: ConversationID(accountID: accountA, providerID: "c2")).map(\.phrase), ["at 5"],
                       "a message reported in another conversation takes its times there")

        try store.deleteMessages([m1])
        XCTAssertEqual(try store.mailTimes(in: c1), [], "deleted with the message")
        try store.upsertMessages([message("m1", in: "c1")])
        XCTAssertEqual(try store.mailTimes(in: c1), [], "and not back with it")

        let gone = MessageID(accountID: accountA, providerID: "never-stored")
        try store.saveMailTimes([MailTime(messageID: gone, start: date(3_600), phrase: "at 1am")], for: gone)
        try store.upsertMessages([message("never-stored", in: "c3")])
        XCTAssertEqual(try store.mailTimes(in: ConversationID(accountID: accountA, providerID: "c3")), [],
                       "times of a message the store does not hold are dropped, as its body would be")
    }

    func testMailTimesOfAConversationInOrder() throws {
        try store.upsertMessages([message("m1", in: "c1"), message("m2", in: "c1", date: date(10)), message("m3", in: "other")])
        let m1 = MessageID(accountID: accountA, providerID: "m1"), m2 = MessageID(accountID: accountA, providerID: "m2")
        let m3 = MessageID(accountID: accountA, providerID: "m3")
        let c1 = ConversationID(accountID: accountA, providerID: "c1")
        try store.saveMailTimes([
            MailTime(messageID: m2, start: date(7_200), phrase: "second, at 2"),
            MailTime(messageID: m2, start: date(3_600), duration: 3_600.4, phrase: "from 1 to 2"),
            MailTime(messageID: m2, start: date(3_600), phrase: "at 1 too"),
        ], for: m2)
        // Saved under the message it is given for.
        try store.saveMailTimes([MailTime(messageID: m3, start: date(3_600).addingTimeInterval(0.000_4), phrase: "at 1")], for: m1)
        try store.saveMailTimes([MailTime(messageID: m3, start: date(60), phrase: "elsewhere")], for: m3)

        let times = try store.mailTimes(in: c1)
        XCTAssertEqual(times.map(\.phrase), ["at 1", "from 1 to 2", "at 1 too", "second, at 2"],
                       "by start, then message, then the order found")
        XCTAssertEqual(times.first, MailTime(messageID: m1, start: date(3_600), phrase: "at 1"), "to the millisecond")
        XCTAssertEqual(times[1].duration, 3_600, "to the second")
        XCTAssertNil(times[2].duration)

        try store.saveMailTimes([MailTime(messageID: m2, start: date(100), phrase: "at noon")], for: m2)
        XCTAssertEqual(try store.mailTimes(in: c1).map(\.phrase), ["at noon", "at 1"], "a save replaces the message's times")
        try store.saveMailTimes([], for: m2)
        XCTAssertEqual(try store.mailTimes(in: c1).map(\.phrase), ["at 1"], "an empty list clears them")
    }

    // MARK: Observation

    func testObservingCalendarEventsDeliversEachChangeAndNoMail() throws {
        let box = ObservedValues()
        let observation = store.observeCalendarEvents(in: calendarWeek) { events in
            XCTAssertTrue(Thread.isMainThread)
            box.append(Self.calendarNames(events))
        }
        defer { observation.cancel() }
        func expectNext(_ value: [String], _ step: String) {
            let deadline = Date().addingTimeInterval(3)
            while box.values.last != value, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertEqual(box.values.last, value, step)
        }
        func expectNothingMore(_ step: String) {
            let count = box.values.count
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            XCTAssertEqual(box.values.count, count, step)
        }
        expectNext([], "the first value")
        try store.addCalendarEvent(calendarBlock("x"))
        expectNext(["local-x:creating"], "time set aside")
        let meeting = calendarRead("p", from: 600, to: 1_200)
        try store.replaceCalendarEvents([meeting], accountID: accountA, window: calendarWeek)
        expectNext(["p:synced", "local-x:creating"], "a read")
        try store.removeCalendarEvent(id: meeting.id)
        expectNext(["p:deleting", "local-x:creating"], "a removal")

        try store.addCalendarEvent(calendarBlock("later", from: 30 * 86_400, to: 30 * 86_400 + 1_800))
        expectNothingMore("an event outside the interval")
        try store.upsertMessages([message("m1", in: "c1")])
        let m1 = MessageID(accountID: accountA, providerID: "m1")
        try store.saveBody(body("Friday at 3pm"), for: m1)
        try store.saveMailTimes([MailTime(messageID: m1, start: date(3_600), phrase: "Friday at 3pm")], for: m1)
        try store.wipeMailData(for: accountA)
        expectNothingMore("mail arriving, a body, a time found in it and a wipe of the mail change nothing the calendar shows")

        try store.deleteAccount(accountA)
        expectNext([], "the account removed")
        XCTAssertEqual(box.values.count, 5, "each change once")
    }
}
