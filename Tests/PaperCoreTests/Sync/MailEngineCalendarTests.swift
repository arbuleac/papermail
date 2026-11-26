import Foundation
import OSLog
import XCTest
@testable import PaperCore

/// The calendar lane through the engine (docs/ARCHITECTURE.md, "Calendar"): when it reads (after a live cycle that caught
/// up, every two minutes in front and every ten behind, at once when asked, when a write waits or once an answer has gone
/// out, and days outside the window once when asked), the time set aside and removed on this Mac sent oldest first and
/// settled, a write that keeps failing never holding the rest back, every refusal kept away from the mail, and Connect.
///
/// The calendar's clock is a `HandClock` that moves only when a test moves it, so a read that happens without it moving
/// was asked for, and one that does not happen is not due.
final class MailEngineCalendarTests: XCTestCase {
    private let account = Fixtures.accountID
    private let source = MessageID(accountID: Fixtures.accountID, providerID: "2")

    private func started(
        _ provider: ScriptedCalendarProvider, clock: HandClock, tune: (inout SyncTuning) -> Void = { _ in }
    ) async throws -> EngineHarness {
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider) { tuning in
            tuning.calendarClock = clock.sendClock
            tune(&tuning)
        }
        harness.engine.start()
        try await waitUntil("head page stored") { try harness.store.syncCursor(for: Fixtures.accountID) == "c0" }
        return harness
    }

    private func block(at start: Date, title: String = "Q3 budget") -> CalendarEvent {
        CalendarEvent(id: CalendarEvent.newLocalID(accountID: account), accountID: account, providerID: nil, title: title,
                      start: start, end: start.addingTimeInterval(1_800), sourceMessage: source, sync: .creating)
    }

    private func stored(_ harness: EngineHarness, _ clock: HandClock) throws -> [CalendarEvent] {
        try harness.store.calendarEvents(in: CalendarWindow.around(clock.now), accountIDs: [account])
    }

    private func row(_ id: String, _ harness: EngineHarness, _ clock: HandClock) throws -> CalendarEvent? {
        try stored(harness, clock).first { $0.id == id }
    }

    private func calendarState(_ recorder: PhaseRecorder) -> CalendarSyncState? {
        recorder.latest.first { $0.accountID == account }?.calendar
    }

    /// Waits for `count` more live polls, so a read that was due would have had its chance.
    private func waitForPolls(_ count: Int, of provider: ScriptedProvider) async throws {
        let target = provider.changesCalls.count + count
        try await waitUntil("\(count) more polls") { provider.changesCalls.count >= target }
    }

    // MARK: When it reads

    func testTheFirstReadRidesTheFirstLiveCycleAndTheNextWaitsTwoMinutes() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let standup = provider.seedEvent("Standup", start: clock.now.addingTimeInterval(3_600))
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }

        try await waitUntil("the first read") { provider.readWindows.count == 1 }
        XCTAssertEqual(provider.readWindows.first, CalendarWindow.around(clock.now))
        try await waitUntil("its events stored") { try self.stored(harness, clock).map(\.providerID) == [standup] }
        try await waitUntil("the calendar is current") { self.calendarState(recorder) == .current(clock.now) }

        // The polls go on every 0.15 s; the calendar is not read with each of them.
        try await waitForPolls(5, of: provider)
        XCTAssertEqual(provider.readWindows.count, 1)
        clock.advance(119)
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.readWindows.count, 1, "not before two minutes")
        clock.advance(1)
        try await waitUntil("read again after two minutes") { provider.readWindows.count == 2 }
        await harness.shutdown()
    }

    /// Where the calendar stands is published when it changes, not with every read: the views that observe the statuses
    /// lay out again on each, for a date nothing shows. A read five minutes newer than the one published says so.
    func testTheStatusIsPublishedWhenItChangesNotWithEveryRead() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        let first = clock.now
        try await waitUntil("current") { self.calendarState(recorder) == .current(first) }
        for read in 2...3 {
            clock.advance(120)
            try await waitUntil("read \(read)") { provider.readWindows.count == read }
        }
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(calendarState(recorder), .current(first), "four minutes on, the same state: nothing published")
        XCTAssertTrue(recorder.calendarsSeen.isSubset(of: [.unknown, .current(first)]), "no read dated anew: \(recorder.calendarsSeen)")

        // A failure is a change; so is the read that ends it.
        provider.readResults = [ProviderError.network("offline")]
        harness.engine.refreshCalendars(accountID: account)
        try await waitUntil("failing") { self.calendarState(recorder) == .failing(lastRead: clock.now) }
        clock.advance(1)
        try await waitUntil("current again") { self.calendarState(recorder) == .current(clock.now) }
        let recovered = clock.now

        // Five minutes newer than the one published, a read is published.
        clock.advance(120)
        try await waitUntil("read 6") { provider.readWindows.count == 6 }
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(calendarState(recorder), .current(recovered))
        clock.advance(181)
        try await waitUntil("published again") { self.calendarState(recorder) == .current(clock.now) }
        await harness.shutdown()
    }

    func testInTheBackgroundTheCalendarIsReadEveryTenMinutes() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.readWindows.count == 1 }
        harness.engine.setAppActive(false)

        clock.advance(120)
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.readWindows.count, 1, "two minutes is the frontmost interval")
        clock.advance(479)
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.readWindows.count, 1)
        clock.advance(1)
        try await waitUntil("read after ten minutes") { provider.readWindows.count == 2 }

        // Back in front, two minutes again.
        harness.engine.setAppActive(true)
        clock.advance(120)
        try await waitUntil("read after two minutes in front") { provider.readWindows.count == 3 }
        await harness.shutdown()
    }

    func testARefreshReadsAtOnce() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.readWindows.count == 1 }

        harness.engine.refreshCalendars(accountID: account)
        try await waitUntil("read for the asking") { provider.readWindows.count == 2 }
        harness.engine.refreshCalendars(accountID: nil)
        try await waitUntil("read for every account") { provider.readWindows.count == 3 }
        harness.engine.refreshCalendars(accountID: AccountID("nobody"))
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.readWindows.count, 3)
        await harness.shutdown()
    }

    /// A slow calendar is nobody's poll: the live lane goes on polling while a read waits for its answer, as it does for
    /// a slow unsubscribe (`MailEngineUnsubscribeTests.testASlowSenderNeverHoldsBackThePoll`).
    func testASlowCalendarNeverHoldsBackTheMailPoll() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.holdReads = true
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the read under way") { provider.readWindows.count == 1 }
        let pollsBefore = provider.changesCalls.count
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertGreaterThanOrEqual(provider.changesCalls.count - pollsBefore, 2, "the live lane kept polling meanwhile")
        XCTAssertEqual(provider.readWindows.count, 1, "and the read is not sent again meanwhile")

        let recorder = PhaseRecorder()
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        provider.releaseReads()
        try await waitUntil("the read answered") { self.calendarState(recorder) == .current(clock.now) }
        await harness.shutdown()
    }

    func testAProviderWithoutACalendarKeepsNoCalendarLane() async throws {
        let provider = ScriptedProvider(accountID: account)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider)
        let recorder = PhaseRecorder()
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        harness.engine.start()
        try await waitUntil("head page stored") { try harness.store.syncCursor(for: Fixtures.accountID) == "c0" }
        harness.engine.refreshCalendars(accountID: nil)
        try harness.engine.addCalendarEvent(block(at: Fixtures.baseDate))
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(calendarState(recorder), .unknown)
        await harness.shutdown()
    }

    // MARK: Status, never the mail's

    func testWithoutTheCalendarScopeTheAccountIsNotConnectedAndNothingIsSent() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.grantsCalendar = false
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)

        try await waitUntil("not connected") { self.calendarState(recorder) == .notConnected }
        try await waitUntil("the permission asked of the token, after the block was queued") {
            provider.calendarPermissionChecks >= 2
        }
        XCTAssertTrue(provider.readWindows.isEmpty, "no request")
        XCTAssertTrue(provider.createCalls.isEmpty)
        XCTAssertEqual(try row(event.id, harness, clock)?.sync, .creating, "the block waits as it is")
        let status = try XCTUnwrap(recorder.latest.first { $0.accountID == account })
        XCTAssertTrue(status.permissionsNeeded.isEmpty, "the mail's reconnect ask is the outbox's alone")
        XCTAssertNotEqual(status.phase, .needsReauth)

        // Once granted (Connect), the next look sends the block and reads.
        provider.grantsCalendar = true
        harness.engine.refreshCalendars(accountID: account)
        try await waitUntil("the block created") { try self.row(event.id, harness, clock)?.sync == .synced }
        try await waitUntil("read") { provider.readWindows.count == 1 }
        try await waitUntil("current") { self.calendarState(recorder) == .current(clock.now) }
        await harness.shutdown()
    }

    func testACalendarApiTurnedOffSaysSo() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.readResults = [CalendarProviderError.apiDisabled]
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("API disabled") { self.calendarState(recorder) == .apiDisabled }
        // Nothing this Mac does turns it on: the lane waits for the interval, or for a refresh.
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.readWindows.count, 1)
        harness.engine.refreshCalendars(accountID: account)
        try await waitUntil("current once turned on") { self.calendarState(recorder) == .current(clock.now) }
        await harness.shutdown()
    }

    /// Whatever the calendar meets (a refused token, its own throttle, the service, the scope, the API), the mail goes on:
    /// the phase never leaves its polls, no reconnect is asked for, the token is never thrown away, and Google Calendar's
    /// throttle never pauses the Gmail backfill.
    func testCalendarFailuresNeverReachTheMail() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.readResults = [
            ProviderError.unauthorized, ProviderError.throttled(retryAfter: 30), ProviderError.server(status: 500, message: "boom"),
            CalendarProviderError.permissionMissing, CalendarProviderError.apiDisabled, ProviderError.network("offline"),
        ]
        let budgets = Budgets()
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock) { tuning in
            tuning.quota = { _ in .standard(for: .gmail) }
            tuning.makeBudget = { quota in budgets.add(QuotaBudget(quota: quota)) }
        }
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }

        let steps: [(advance: TimeInterval, state: CalendarSyncState)] = [
            (0, .failing(lastRead: nil)), (1, .failing(lastRead: nil)), (1, .failing(lastRead: nil)),
            (1, .notConnected), (120, .apiDisabled), (120, .failing(lastRead: nil)), (1, .current(clock.now.addingTimeInterval(244))),
        ]
        for (index, step) in steps.enumerated() {
            clock.advance(step.advance)
            try await waitUntil("read \(index + 1)") { provider.readWindows.count == index + 1 }
            try await waitUntil("state after read \(index + 1)") { self.calendarState(recorder) == step.state }
            let status = try XCTUnwrap(recorder.latest.first { $0.accountID == account })
            XCTAssertTrue(status.permissionsNeeded.isEmpty, "read \(index + 1)")
            XCTAssertNil(status.message, "read \(index + 1): the sync line says nothing")
            XCTAssertNil(status.retryAt, "read \(index + 1)")
        }
        XCTAssertFalse(recorder.seen.contains(.error))
        XCTAssertFalse(recorder.seen.contains(.needsReauth))
        XCTAssertFalse(recorder.seen.contains(.paused), "never Rate limited")
        XCTAssertTrue(harness.tokenProvider.invalidations.isEmpty, "a calendar 401 never throws the token away")
        let paused = await budgets.first?.pausedUntil
        XCTAssertNil(paused, "Google Calendar's quota is not Gmail's")
        await harness.shutdown()
    }

    // MARK: Writes

    func testTimeSetAsideIsCreatedSettledAndReadBackAsOneEvent() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.readWindows.count == 1 }

        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        XCTAssertEqual(try row(event.id, harness, clock)?.sync, .creating, "drawn before any request")
        try await waitUntil("created") { provider.createCalls.count == 1 }
        let sent = try XCTUnwrap(provider.createCalls.first)
        XCTAssertEqual(sent.id, event.id)
        XCTAssertNotNil(sent.clientKey, "the store gives every block its key")
        XCTAssertEqual(sent.sourceMessage, source)
        XCTAssertEqual(sent.sourceThreadID, "t1", "the mail's conversation, for the link back, with no request of its own")
        try await waitUntil("settled") { try self.row(event.id, harness, clock)?.providerID == "evt-1" }
        XCTAssertNil(try row(event.id, harness, clock)?.sourceThreadID, "the store never keeps it")
        try await waitUntil("read after the write") { provider.readWindows.count == 2 }

        let rows = try stored(harness, clock)
        XCTAssertEqual(rows.count, 1, "the read finds the copy by its key: no second row")
        XCTAssertEqual(rows.first?.id, event.id)
        XCTAssertEqual(rows.first?.sync, .synced)
        XCTAssertEqual(rows.first?.sourceMessage, source, "it still knows its mail")
        XCTAssertEqual(provider.calendar.count, 1)
        await harness.shutdown()
    }

    func testABlockRemovedWhileItsCreateWasOnItsWayTakesTheCopyWithIt() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.readWindows.count == 1 }
        provider.holdCreates = true

        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("create under way") { provider.createCalls.count == 1 }
        let removed = try harness.engine.removeCalendarEvent(id: event.id)
        XCTAssertEqual(removed?.sync, .creating)
        XCTAssertEqual(try row(event.id, harness, clock)?.isShown, false, "gone from the calendar at once")
        provider.holdCreates = false

        try await waitUntil("the copy deleted") { provider.deleteCalls == ["evt-1"] }
        XCTAssertTrue(provider.calendar.isEmpty)
        try await waitUntil("read") { provider.readWindows.count == 2 }
        XCTAssertTrue(try stored(harness, clock).isEmpty)
        await harness.shutdown()
    }

    func testACreateSentAgainAfterALostReplyMakesNoSecondCopy() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.createScripts = [.loseReply(ProviderError.network("connection lost"))]
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.readWindows.count == 1 }

        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("the reply lost") { self.calendarState(recorder) == .failing(lastRead: clock.now) }
        XCTAssertEqual(provider.calendar.count, 1, "the provider made it")
        XCTAssertEqual(try row(event.id, harness, clock)?.sync, .creating, "this Mac never heard")
        XCTAssertEqual(provider.readWindows.count, 1, "a write held back holds the read back too")

        clock.advance(1)
        try await waitUntil("settled on the second try") { try self.row(event.id, harness, clock)?.sync == .synced }
        XCTAssertEqual(provider.createCalls.map(\.clientKey), [sent(provider, 0), sent(provider, 0)], "under one key")
        try await waitUntil("read") { provider.readWindows.count == 2 }
        XCTAssertEqual(provider.calendar.count, 1, "one copy")
        XCTAssertEqual(try stored(harness, clock).count, 1, "one row")
        await harness.shutdown()
    }

    /// The create's reply was lost, and the provider then refuses the second create as a duplicate rather than hand the
    /// copy back (Graph may): the block is marked failed, and the read that follows finds the copy by its client key and
    /// settles it, one row with its mail, not a failed block beside a second event.
    func testACopyMadeUnderALostReplyIsFoundByItsKeyOnTheNextRead() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.createScripts = [.loseReply(ProviderError.network("connection lost")),
                                  .fail(ProviderError.server(status: 409, message: "duplicate transaction"))]
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.readWindows.count == 1 }

        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("the reply lost") { provider.createCalls.count == 1 }
        try await waitForPolls(3, of: provider)
        clock.advance(1)
        try await waitUntil("the second create refused") { provider.createCalls.count == 2 }
        try await waitUntil("read") { provider.readWindows.count == 2 }

        let rows = try stored(harness, clock)
        XCTAssertEqual(rows.count, 1, "no duplicate")
        XCTAssertEqual(rows.first?.id, event.id)
        XCTAssertEqual(rows.first?.sync, .synced, "the failed mark gives way to the copy")
        XCTAssertEqual(rows.first?.providerID, "evt-1")
        XCTAssertEqual(rows.first?.sourceMessage, source)
        XCTAssertEqual(provider.calendar.count, 1)
        await harness.shutdown()
    }

    func testTimeRemovedIsDeletedOnTheProvider() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("settled") { try self.row(event.id, harness, clock)?.sync == .synced }
        let reads = provider.readWindows.count

        let removed = try harness.engine.removeCalendarEvent(id: event.id)
        XCTAssertEqual(removed?.sync, .synced)
        XCTAssertEqual(try row(event.id, harness, clock)?.sync, .deleting, "never drawn, kept until the provider deletes it")
        try await waitUntil("deleted there") { provider.deleteCalls == ["evt-1"] }
        try await waitUntil("and here") { try self.row(event.id, harness, clock) == nil }
        try await waitUntil("read") { provider.readWindows.count > reads }
        XCTAssertTrue(provider.calendar.isEmpty)
        XCTAssertTrue(try stored(harness, clock).isEmpty, "the read does not bring it back")
        await harness.shutdown()
    }

    /// The user undid the removal while its delete was on its way: the provider has deleted the event, so the time is set
    /// aside anew rather than swept by the next read, and the undo holds.
    func testAnUndoWhileTheDeleteWasOnItsWaySetsTheTimeAsideAgain() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("settled") { try self.row(event.id, harness, clock)?.providerID == "evt-1" }

        provider.holdDeletes = true
        let removed = try XCTUnwrap(try harness.engine.removeCalendarEvent(id: event.id))
        try await waitUntil("delete under way") { provider.deleteCalls == ["evt-1"] }
        let restored = try harness.engine.restoreCalendarEvent(removed)
        XCTAssertEqual(restored.sync, .synced)
        provider.holdDeletes = false

        try await waitUntil("set aside anew") { provider.calendar.map(\.providerID) == ["evt-2"] }
        try await waitUntil("settled anew") {
            try self.stored(harness, clock).map(\.providerID) == ["evt-2"]
        }
        let rows = try stored(harness, clock)
        XCTAssertEqual(rows.first?.sync, .synced)
        XCTAssertEqual(rows.first?.title, "Q3 budget")
        XCTAssertEqual(rows.first?.start, event.start)
        XCTAssertEqual(rows.first?.sourceMessage, source)
        XCTAssertNotEqual(provider.createCalls.last?.clientKey, provider.createCalls.first?.clientKey, "a new key")
        await harness.shutdown()
    }

    func testACreateTheProviderRefusesIsMarkedFailedAndTheReadGoesOn() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.createScripts = [.fail(ProviderError.server(status: 400, message: "bad request"))]
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.readWindows.count == 1 }

        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("failed") { try self.row(event.id, harness, clock)?.sync == .failed }
        try await waitUntil("read") { provider.readWindows.count == 2 }
        XCTAssertEqual(calendarState(recorder), .current(clock.now))
        XCTAssertTrue(provider.calendar.isEmpty)

        // Never sent again: it keeps its mark until the user removes it.
        harness.engine.refreshCalendars(accountID: account)
        try await waitUntil("read again") { provider.readWindows.count == 3 }
        XCTAssertEqual(provider.createCalls.count, 1)
        XCTAssertEqual(try row(event.id, harness, clock)?.sync, .failed)
        XCTAssertEqual(try harness.engine.removeCalendarEvent(id: event.id)?.sync, .failed)
        XCTAssertNil(try row(event.id, harness, clock))
        await harness.shutdown()
    }

    func testAThrottledCreateBacksOffAndKeepsItsBlock() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.createScripts = [.fail(ProviderError.throttled(retryAfter: 30))]
        let budgets = Budgets()
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock) { tuning in
            tuning.quota = { _ in .standard(for: .gmail) }
            tuning.makeBudget = { quota in budgets.add(QuotaBudget(quota: quota)) }
        }
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.readWindows.count == 1 }

        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("throttled") { self.calendarState(recorder) == .failing(lastRead: clock.now) }
        try await waitForPolls(5, of: provider)
        XCTAssertEqual(provider.createCalls.count, 1, "held back by its own backoff")
        XCTAssertEqual(try row(event.id, harness, clock)?.sync, .creating, "the block waits, drawn")
        XCTAssertFalse(recorder.seen.contains(.paused), "the mail is not rate limited")
        let paused = await budgets.first?.pausedUntil
        XCTAssertNil(paused, "Google Calendar's throttle never pauses the Gmail backfill")

        // The harness caps every backoff at a second.
        clock.advance(1)
        try await waitUntil("sent again and settled") { try self.row(event.id, harness, clock)?.sync == .synced }
        XCTAssertEqual(provider.createCalls.count, 2)
        await harness.shutdown()
    }

    /// The store refusing a calendar write loses nothing: a read's write is taken again after the backoff, and a create
    /// that landed but could not be settled (as if the app had died between the two) is found by the turn's read under
    /// its key, one row with its mail and no second copy.
    func testAStoreWriteThatFailsIsTakenAgainAndMakesNoSecondCopy() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.seedEvent("Standup", start: clock.now.addingTimeInterval(3_600))
        let store = InMemoryMailStore()
        let faulty = FaultyStore(base: store)
        faulty.fail(.replaceCalendarEvents)
        let recorder = PhaseRecorder()
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(store: store, provider: provider, engineStore: faulty) { tuning in
            tuning.calendarClock = clock.sendClock
        }
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        harness.engine.start()

        try await waitUntil("the read's write refused") { self.calendarState(recorder) == .failing(lastRead: nil) }
        XCTAssertTrue(try stored(harness, clock).isEmpty)
        clock.advance(1)
        try await waitUntil("written on the next turn") { try self.stored(harness, clock).count == 1 }
        try await waitUntil("current") { self.calendarState(recorder) == .current(clock.now) }

        faulty.fail(.settleCalendarEvent)
        let event = block(at: clock.now.addingTimeInterval(7_200))
        let reads = provider.readWindows.count
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("the settle refused") { faulty.fired.contains(.settleCalendarEvent) }
        try await waitUntil("the turn's read") { provider.readWindows.count > reads }
        try await waitUntil("settled by the read") { try self.row(event.id, harness, clock)?.sync == .synced }
        XCTAssertEqual(try row(event.id, harness, clock)?.sourceMessage, source)
        XCTAssertEqual(provider.createCalls.count, 1)
        XCTAssertEqual(provider.calendar.count, 2, "the standup and one copy of the block")
        XCTAssertEqual(calendarState(recorder), .current(clock.now), "that one write's trouble is no failing calendar")
        XCTAssertEqual(try stored(harness, clock).count, 2)
        await harness.shutdown()
    }

    // MARK: A block removed while its create was out

    /// B, the create reaches the provider but its reply is lost, and the user removes the block: the hidden tombstone
    /// keeps its key, the next read finds the copy by it, and the copy is deleted in that same turn, never brought back
    /// as an event of its own.
    func testRemovingABlockWhoseCreateReplyWasLostDeletesTheCopy() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.createScripts = [.loseReply(ProviderError.network("connection lost"))]
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.readWindows.count == 1 }

        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("the reply lost") { self.calendarState(recorder) == .failing(lastRead: clock.now) }
        XCTAssertEqual(provider.calendar.count, 1, "the provider made it")
        XCTAssertEqual(try harness.engine.removeCalendarEvent(id: event.id)?.sync, .creating)
        XCTAssertTrue(try stored(harness, clock).filter(\.isShown).isEmpty, "gone from the calendar at once")

        clock.advance(1)
        try await waitUntil("the copy deleted") { provider.deleteCalls == ["evt-1"] }
        try await waitUntil("and nothing left here") { try self.stored(harness, clock).isEmpty }
        XCTAssertTrue(provider.calendar.isEmpty)
        XCTAssertEqual(provider.readWindows.count, 2, "one read found it and the same turn deleted it")
        XCTAssertEqual(provider.createCalls.count, 1, "never created again")
        await harness.shutdown()
    }

    /// B, then Z on its toast while the create is on its way, and that create's reply is lost.
    func testUndoingABlockWhileItsCreateIsOutAndTheReplyIsLostDeletesTheCopy() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.readWindows.count == 1 }
        provider.createScripts = [.loseReply(ProviderError.network("timed out"))]
        provider.holdCreates = true

        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("create under way") { provider.createCalls.count == 1 }
        XCTAssertNotNil(try harness.engine.removeCalendarEvent(id: event.id), "Z on B's toast")
        provider.holdCreates = false
        try await waitUntil("the provider made it") { provider.calendar.count == 1 }

        clock.advance(1)
        try await waitUntil("the copy deleted") { provider.calendar.isEmpty }
        try await waitUntil("and nothing left here") { try self.stored(harness, clock).isEmpty }
        XCTAssertEqual(provider.deleteCalls, ["evt-1"])
        XCTAssertTrue(try harness.store.pendingCalendarEvents(accountID: account).isEmpty)
        await harness.shutdown()
    }

    /// A lost reply, Remove, then the undo of the Remove: the block comes back under its own id and key, so the create
    /// sent again finds the copy the first one made. One copy on the calendar, one row with its mail.
    func testRemovingThenRestoringABlockWhoseCreateReplyWasLostKeepsOneCopy() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.createScripts = [.loseReply(ProviderError.network("connection lost"))]
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.readWindows.count == 1 }

        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("the reply lost") { self.calendarState(recorder) == .failing(lastRead: clock.now) }
        let asWas = try XCTUnwrap(try harness.engine.removeCalendarEvent(id: event.id))
        let restored = try harness.engine.restoreCalendarEvent(asWas)
        XCTAssertEqual(restored.id, event.id)
        XCTAssertEqual(restored.clientKey, asWas.clientKey, "the same key: the create sent again finds the copy")
        XCTAssertEqual(restored.sync, .creating)

        clock.advance(1)
        try await waitUntil("settled") { try self.row(event.id, harness, clock)?.sync == .synced }
        try await waitUntil("read") { provider.readWindows.count == 2 }
        XCTAssertEqual(provider.calendar.count, 1, "one copy")
        let rows = try stored(harness, clock)
        XCTAssertEqual(rows.map(\.id), [event.id], "drawn once")
        XCTAssertEqual(rows.first?.sourceMessage, source)
        XCTAssertEqual(rows.first?.providerID, "evt-1")
        XCTAssertTrue(provider.deleteCalls.isEmpty)
        await harness.shutdown()
    }

    /// A create that never reached the provider, then Remove: the read lists no copy, so it sweeps the tombstone.
    func testRemovingABlockThatWasNeverMadeLeavesNothing() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.createScripts = [.fail(ProviderError.network("offline"))]
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.readWindows.count == 1 }
        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("create failed") { provider.createCalls.count == 1 }
        try await waitUntil("the turn ended") { try self.row(event.id, harness, clock)?.sync == .creating && provider.createCalls.count == 1 }
        _ = try harness.engine.removeCalendarEvent(id: event.id)

        clock.advance(1)
        try await waitUntil("read") { provider.readWindows.count == 2 }
        try await waitUntil("the tombstone swept") { try self.stored(harness, clock).isEmpty }
        XCTAssertTrue(try harness.store.pendingCalendarEvents(accountID: account).isEmpty)
        XCTAssertTrue(provider.deleteCalls.isEmpty)
        XCTAssertEqual(provider.createCalls.count, 1)
        await harness.shutdown()
    }

    /// Removed while its create was out, the block's copy is deleted at once; when that delete fails, the copy's id waits
    /// in the store, not in memory, so a quit loses nothing and the next turn deletes it.
    func testTheCopyOfABlockRemovedDuringItsCreateWaitsInTheStoreForItsDelete() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.readWindows.count == 1 }
        provider.holdCreates = true
        provider.deleteResults = [ProviderError.network("offline")]

        let event = block(at: clock.now.addingTimeInterval(7_200))
        try harness.engine.addCalendarEvent(event)
        try await waitUntil("create under way") { provider.createCalls.count == 1 }
        _ = try harness.engine.removeCalendarEvent(id: event.id)
        provider.holdCreates = false
        try await waitUntil("its delete tried") { provider.deleteCalls == ["evt-1"] }
        try await waitUntil("the copy's id kept") {
            try harness.store.pendingCalendarEvents(accountID: self.account).map(\.providerID) == ["evt-1"]
        }
        XCTAssertEqual(try row(event.id, harness, clock)?.sync, .deleting)
        XCTAssertEqual(try row(event.id, harness, clock)?.isShown, false)

        clock.advance(1)
        try await waitUntil("deleted on the next turn") { provider.calendar.isEmpty }
        try await waitUntil("and here") { try self.stored(harness, clock).isEmpty }
        XCTAssertEqual(provider.deleteCalls, ["evt-1", "evt-1"])
        await harness.shutdown()
    }

    // MARK: A write that keeps failing

    /// One block whose create keeps failing for a reason of its own (a reply that never reads, a 5xx for that one
    /// event) holds nothing back: the read goes on, so a meeting added elsewhere shows, the next block is sent, and the
    /// stuck one is tried again after its own backoff and given up after `failingPageTries` tries, with the failed mark.
    func testOneWriteThatKeepsFailingNeverHoldsBackTheReadsOrTheOtherWrites() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.readWindows.count == 1 }

        let stuck = block(at: clock.now.addingTimeInterval(7_200))
        provider.stuckCreates = [stuck.id: ProviderError.decoding("unexpected reply")]
        try harness.engine.addCalendarEvent(stuck)
        try await waitUntil("its create failed") { provider.createCalls.count == 1 }
        try await waitUntil("and the read went on") { provider.readWindows.count == 2 }

        // A meeting is added on the phone, and the user sets time aside for another mail.
        provider.seedEvent("Board meeting", start: clock.now.addingTimeInterval(3_600))
        let later = block(at: clock.now.addingTimeInterval(10_800), title: "Later")
        try harness.engine.addCalendarEvent(later)
        try await waitUntil("the next block sent and settled") { try self.row(later.id, harness, clock)?.sync == .synced }
        try await waitUntil("the meeting read") { try self.stored(harness, clock).contains { $0.title == "Board meeting" } }
        XCTAssertEqual(provider.createCalls.filter { $0.id == stuck.id }.count, 1, "not tried again inside its backoff")
        XCTAssertEqual(try row(stuck.id, harness, clock)?.sync, .creating)
        XCTAssertEqual(calendarState(recorder), .current(clock.now), "that one write's trouble is no failing calendar")

        // Tried again after its own backoff (the harness caps it at a second), and given up after five tries.
        for tries in 2...5 {
            clock.advance(1)
            try await waitUntil("try \(tries)") { provider.createCalls.filter { $0.id == stuck.id }.count == tries }
        }
        try await waitUntil("given up") { try self.row(stuck.id, harness, clock)?.sync == .failed }
        clock.advance(1)
        harness.engine.refreshCalendars(accountID: account)
        let reads = provider.readWindows.count
        try await waitUntil("read again") { provider.readWindows.count > reads }
        XCTAssertEqual(provider.createCalls.filter { $0.id == stuck.id }.count, 5, "never sent again")
        await harness.shutdown()
    }

    // MARK: Days outside the window

    /// Days the column or the week turned to outside the window are read once, at once, as the read of their own
    /// interval, without reading the window again; days inside it are served by the window's read.
    func testDaysOutsideTheWindowAreReadOnceWhenAsked() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.seedEvent("Standup", start: clock.now.addingTimeInterval(3_600))
        let offsite = clock.now.addingTimeInterval(90 * 86_400)
        provider.seedEvent("Offsite", start: offsite)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.readWindows.count == 1 }
        let window = CalendarWindow.around(clock.now)
        XCTAssertFalse(window.contains(offsite))

        let week = DateInterval(start: offsite.addingTimeInterval(-2 * 86_400), duration: 7 * 86_400)
        harness.engine.refreshCalendars(accountID: nil, covering: week)
        try await waitUntil("that week read") { provider.readWindows.count == 2 }
        XCTAssertEqual(provider.readWindows, [window, week], "the week alone: the window is fresh")
        try await waitUntil("its events stored") {
            try harness.store.calendarEvents(in: week, accountIDs: [self.account]).map(\.title) == ["Offsite"]
        }

        // A day inside the window costs nothing; one asked again is read again.
        harness.engine.refreshCalendars(accountID: account, covering: DateInterval(start: clock.now, duration: 86_400))
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.readWindows.count, 2)

        // A read that fails is tried again after the backoff.
        provider.readResults = [ProviderError.network("offline")]
        harness.engine.refreshCalendars(accountID: account, covering: week)
        try await waitUntil("tried") { provider.readWindows.count == 3 }
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.readWindows.count, 3, "inside its backoff")
        clock.advance(1)
        try await waitUntil("tried again") { provider.readWindows.count == 4 }
        XCTAssertEqual(provider.readWindows.last, week)
        await harness.shutdown()
    }

    // MARK: Answers

    /// Google and Exchange put an invitation on the calendar themselves. Answered on this Mac, its event shows the
    /// answer at once (a decline leaves the day column), and the calendar is read once the answer has gone out, not
    /// before, when the provider would still say the old one.
    func testAnAnswerShowsOnTheCalendarAtOnceAndIsReadOnceItHasGoneOut() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let start = clock.now.addingTimeInterval(86_400)
        let review = provider.seedEvent("Design review", start: start, minutes: 60, invitationUID: "uid-1@google.com",
                                        response: .needsAction)
        let offsite = provider.seedEvent("Offsite", start: start.addingTimeInterval(7_200), invitationUID: "uid-2@google.com",
                                         response: .needsAction)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the invitations read") { try self.stored(harness, clock).count == 2 }
        let invitation = CalendarInvitation(
            method: .request, uid: "uid-1@google.com", sequence: 1, title: "Design review", start: start,
            end: start.addingTimeInterval(3_600), organizer: CalendarInvitation.Person(name: "Ben", address: "ben@example.com"),
            attendees: [CalendarInvitation.Person(address: "me@example.com", response: .needsAction)],
            userAddress: "me@example.com", userResponse: .needsAction
        )
        try harness.store.saveBody(StoredBody(body: MessageBody(html: "<p>Invite</p>", text: nil), renderedHTML: "<p>Invite</p>",
                                              plainText: "Invite", invitation: invitation), for: source)
        let response = { (providerID: String) in
            try self.stored(harness, clock).first { $0.providerID == providerID }?.response
        }

        provider.holdApplies = true
        try harness.engine.answerInvitation(.declined, to: source)
        XCTAssertEqual(try response(review), .declined, "on the calendar before any request")
        XCTAssertEqual(try stored(harness, clock).first { $0.providerID == review }?.isShown, false, "a decline is not drawn")
        XCTAssertEqual(try response(offsite), .needsAction, "another invitation keeps its own")
        try await waitUntil("the answer on its way") { harness.provider.applyCalls.contains { $0.change.kind == .answerInvitation } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(provider.readWindows.count, 1, "not read while the answer is out")

        provider.answer(review, .declined)
        provider.releaseHeldApplies()
        try await waitUntil("read once it went out") { provider.readWindows.count == 2 }
        XCTAssertEqual(try response(review), .declined)
        await harness.shutdown()
    }

    // MARK: Connect and accounts

    func testConnectAsksForTheCalendarAndReadsOnceGranted() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        provider.grantsCalendar = false
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("not connected") { self.calendarState(recorder) == .notConnected }

        // The sign-in grants the scope.
        provider.grantsCalendar = true
        let connected = try await harness.engine.connectCalendar(Fixtures.account())
        XCTAssertEqual(connected.id, account)
        XCTAssertEqual(harness.authenticator.permissions.last, [.calendar], "the calendar on top of mail, with nothing queued")
        XCTAssertEqual(harness.tokenProvider.replacements, [account])
        try await waitUntil("read without waiting for the interval") { provider.readWindows.count == 1 }
        try await waitUntil("current") { self.calendarState(recorder) == .current(clock.now) }

        // A plain reconnect still asks only for what the account holds or its queued work waits for.
        _ = try await harness.engine.reconnect(Fixtures.account())
        XCTAssertEqual(harness.authenticator.permissions.last, [])
        _ = try await harness.engine.reconnect(Fixtures.account(), adding: [.calendar])
        XCTAssertEqual(harness.authenticator.permissions.last, [.calendar])
        await harness.shutdown()
    }

    func testRemovingTheAccountStopsItsCalendar() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let recorder = PhaseRecorder()
        let harness = try await started(provider, clock: clock)
        let observation = harness.engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        try await waitUntil("the first read") { provider.readWindows.count == 1 }

        try await harness.engine.removeAccount(account)
        try await waitUntil("its status gone") { !recorder.latest.contains { $0.accountID == self.account } }
        harness.engine.refreshCalendars(accountID: nil)
        clock.advance(600)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(provider.readWindows.count, 1, "nothing read for an account that has gone")
        XCTAssertFalse(recorder.latest.contains { $0.accountID == account }, "and no status written back")
        await harness.shutdown()
    }

    // MARK: Details

    /// A card asks for its event's details: read once and stored; asked again while they are fresh, nothing is read, and
    /// an ask repeated within the minute is not passed on.
    func testAnAskedEventIsReadOnceAndAFreshOneIsNotAskedAgain() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let weekly = provider.seedEvent("Weekly", start: clock.now.addingTimeInterval(3 * 86_400), version: "v1")
        let harness = try await started(provider, clock: clock) { $0.calendarDetailsAskInterval = 0 }
        harness.engine.setAppActive(false)
        let id = CalendarEvent.localID(accountID: account, providerID: weekly)
        try await waitUntil("stored") { try harness.store.calendarEvent(id: id) != nil }

        harness.engine.readCalendarEventDetails(eventID: id)
        try await waitUntil("read and stored") { try harness.store.calendarEventDetails(id: id) != nil }
        XCTAssertEqual(provider.detailsCalls.count, 1)
        harness.engine.readCalendarEventDetails(eventID: id)
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.detailsCalls.count, 1, "fresh at the event's version")

        harness.engine.readCalendarEventDetails(eventID: "acct|none")
        try await waitForPolls(2, of: provider)
        XCTAssertEqual(provider.detailsCalls.count, 1, "an event the store does not have")
        await harness.shutdown()
    }

    private func sent(_ provider: ScriptedCalendarProvider, _ index: Int) -> String? {
        provider.createCalls[index].clientKey
    }
}

/// The lane alone, for what the engine's harness cannot measure: which quota a calendar request is charged to, and which
/// budget a throttle on it pauses.
final class CalendarLaneQuotaTests: XCTestCase {
    private let account = Fixtures.accountID

    private func lane(_ provider: ScriptedCalendarProvider, quota: ProviderQuota, start: Date)
        throws -> (CalendarLane, QuotaBudget, InMemoryMailStore) {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        // The budget's clock stands still, so nothing refills between two readings.
        let budget = QuotaBudget(quota: quota, now: { start })
        let lane = CalendarLane(accountID: account, store: store, provider: provider, statusCenter: SyncStatusCenter(),
                                tuning: SyncTuning(), budget: budget, link: LaneLink(), isAppActive: { true })
        return (lane, budget, store)
    }

    private func block(at start: Date) -> CalendarEvent {
        CalendarEvent(id: CalendarEvent.newLocalID(accountID: account), accountID: account, providerID: nil, title: "Q3 budget",
                      start: start, end: start.addingTimeInterval(1_800),
                      sourceMessage: MessageID(accountID: account, providerID: "2"), sync: .creating)
    }

    func testAGraphCalendarSpendsTheMailboxQuota() async throws {
        let start = Date()
        let provider = ScriptedCalendarProvider(accountID: account, kind: .microsoft)
        provider.requestsPerRead = 3
        let (lane, budget, store) = try lane(provider, quota: .standard(for: .microsoft), start: start)
        var before = await budget.liveHeadroom
        await lane.turn()
        var after = await budget.liveHeadroom
        XCTAssertEqual(before - after, 3, accuracy: 1e-9, "a read's pages")

        try store.addCalendarEvent(block(at: start.addingTimeInterval(7_200)))
        before = after
        await lane.turn()
        after = await budget.liveHeadroom
        XCTAssertEqual(before - after, 4, accuracy: 1e-9, "the create, then the read")

        provider.readResults = [ProviderError.throttled(retryAfter: 30)]
        await lane.turn()
        let paused = await budget.pausedUntil
        XCTAssertEqual(paused, start.addingTimeInterval(30), "the same mailbox: the backfill pauses too")
    }

    func testAGoogleCalendarIsChargedToNothing() async throws {
        let start = Date()
        let provider = ScriptedCalendarProvider(accountID: account, kind: .gmail)
        provider.requestsPerRead = 3
        let (lane, budget, store) = try lane(provider, quota: .standard(for: .gmail), start: start)
        let before = await budget.liveHeadroom
        try store.addCalendarEvent(block(at: start.addingTimeInterval(7_200)))
        await lane.turn()
        let after = await budget.liveHeadroom
        XCTAssertEqual(before, after)
        XCTAssertEqual(provider.createCalls.count, 1)

        provider.readResults = [ProviderError.throttled(retryAfter: 30)]
        await lane.turn()
        let paused = await budget.pausedUntil
        XCTAssertNil(paused, "the Calendar API's quota is its own")
    }

    func testTheStandardQuotasSayWhatACalendarRequestCosts() {
        XCTAssertEqual(ProviderQuota.standard(for: .microsoft).calendarRequestCost, 1)
        XCTAssertNil(ProviderQuota.standard(for: .gmail).calendarRequestCost)
        XCTAssertNil(ProviderQuota.unlimited.calendarRequestCost)
    }
}

/// An event's details (docs/ARCHITECTURE.md, "Calendar" › A turn): read when a card asks, after the writes and before
/// the window; read ahead for the next day's changed events after a window read while the app is in front; quiet when
/// they fail; charged like any calendar request.
final class CalendarLaneDetailsTests: XCTestCase {
    private let account = Fixtures.accountID

    private func lane(_ provider: ScriptedCalendarProvider, quota: ProviderQuota = .unlimited, active: Bool = true,
                      statusCenter: SyncStatusCenter = SyncStatusCenter(),
                      tune: (inout SyncTuning) -> Void = { _ in }) throws -> (CalendarLane, QuotaBudget, InMemoryMailStore) {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        // The budget's clock stands still, so nothing refills between two readings.
        let start = Date()
        let budget = QuotaBudget(quota: quota, now: { start })
        var tuning = SyncTuning()
        tune(&tuning)
        let lane = CalendarLane(accountID: account, store: store, provider: provider, statusCenter: statusCenter,
                                tuning: tuning, budget: budget, link: LaneLink(), isAppActive: { active })
        return (lane, budget, store)
    }

    private func id(_ providerID: String) -> String {
        CalendarEvent.localID(accountID: account, providerID: providerID)
    }

    func testAnAskedEventIsReadAfterTheWritesAndBeforeTheWindowAndStored() async throws {
        let provider = ScriptedCalendarProvider(accountID: account)
        let later = provider.seedEvent("Weekly", start: Date().addingTimeInterval(3 * 86_400), seriesID: "S", version: "v1")
        // Every turn reads the window, so the order of the three is seen.
        let (lane, _, store) = try lane(provider, active: false) { $0.calendarBackgroundInterval = 0 }
        await lane.turn()
        try store.addCalendarEvent(CalendarEvent(id: CalendarEvent.newLocalID(accountID: account), accountID: account, providerID: nil,
                                                 title: "Q3", start: Date().addingTimeInterval(7_200), end: Date().addingTimeInterval(9_000),
                                                 sourceMessage: MessageID(accountID: account, providerID: "2"), sync: .creating))
        await lane.ask(details: id(later))
        await lane.turn()

        XCTAssertEqual(Array(provider.calendarCalls.suffix(3)), ["create", "details \(later)", "read"], "writes, details, then the window")
        let stored = try XCTUnwrap(try store.calendarEventDetails(id: id(later)))
        XCTAssertEqual(stored.version, "v1")
        XCTAssertEqual(stored.details.repeats, "Every week")
        XCTAssertEqual(stored.details.organizer?.address, "erin@example.com")

        // A second ask reads it once more, handed the series' words already known: the series request is spared.
        await lane.ask(details: id(later))
        await lane.turn()
        XCTAssertEqual(provider.detailsCalls.last?.knownRepeats, "Every week")
    }

    func testTheNextDaysChangedEventsAreReadAheadInFrontOnly() async throws {
        let provider = ScriptedCalendarProvider(accountID: account)
        let soon = (0..<10).map { provider.seedEvent("Soon \($0)", start: Date().addingTimeInterval(3_600 + Double($0) * 600), version: "v1") }
        let farOff = provider.seedEvent("Next week", start: Date().addingTimeInterval(5 * 86_400), version: "v1")
        let (lane, _, store) = try lane(provider)
        await lane.turn()
        XCTAssertEqual(provider.detailsCalls.map(\.providerID), Array(soon.prefix(8)), "at most eight, the next 24 hours, by start")
        XCTAssertFalse(provider.detailsCalls.contains { $0.providerID == farOff })

        // Read already at this version: nothing more until one changes.
        await lane.turn()
        XCTAssertEqual(provider.detailsCalls.count, 10, "the two left over, then nothing")
        provider.edit(soon[0], version: "v2")
        await lane.turn()
        XCTAssertEqual(provider.detailsCalls.last?.providerID, soon[0])
        XCTAssertEqual(try store.calendarEventDetails(id: id(soon[0]))?.version, "v2")

        let behindProvider = ScriptedCalendarProvider(accountID: account)
        behindProvider.seedEvent("Soon", start: Date().addingTimeInterval(3_600), version: "v1")
        let (behind, _, _) = try self.lane(behindProvider, active: false)
        await behind.turn()
        XCTAssertTrue(behindProvider.detailsCalls.isEmpty, "never in the background")
    }

    func testADetailsFailureIsQuiet() async throws {
        let provider = ScriptedCalendarProvider(accountID: account)
        let event = provider.seedEvent("Weekly", start: Date().addingTimeInterval(3_600), version: "v1")
        let center = SyncStatusCenter()
        let (lane, _, store) = try lane(provider, active: false, statusCenter: center)
        await lane.turn()
        provider.detailsResults = [ProviderError.server(status: 500, message: "boom")]
        await lane.ask(details: id(event))
        await lane.turn()
        XCTAssertNil(try store.calendarEventDetails(id: id(event)))
        let asked = await lane.hasDetailsAsked
        XCTAssertFalse(asked, "a failure of its own drops the ask")
        guard case .current = center.status(for: account)?.calendar else {
            return XCTFail("the calendar's state is not the details'")
        }

        // One every request would meet stops the turn with the ask kept.
        provider.detailsResults = [ProviderError.network("offline")]
        await lane.ask(details: id(event))
        let reads = provider.readWindows.count
        await lane.turn()
        let kept = await lane.hasDetailsAsked
        XCTAssertTrue(kept)
        XCTAssertEqual(provider.readWindows.count, reads, "the turn stopped there")
        guard case .current = center.status(for: account)?.calendar else {
            return XCTFail("still not the calendar's state")
        }
    }

    /// The lane says what it did in ids and counts: no title, organizer, address or answer of an event reaches the log at
    /// info or above, whether a read, a details read or a failed one.
    func testNothingOfAnEventReachesTheLogAboveDebug() async throws {
        let start = Date()
        let provider = ScriptedCalendarProvider(accountID: account)
        let title = "Zebra Quorum Ninefold"
        let event = provider.seedEvent(title, start: Date().addingTimeInterval(3_600), invitationUID: "uid-zebra@larkspur.test",
                                       response: .needsAction, seriesID: "S", version: "v1")
        let (lane, _, store) = try lane(provider, active: false)
        await lane.turn()
        XCTAssertEqual(try store.calendarEvent(id: id(event))?.title, title)
        await lane.ask(details: id(event))
        await lane.turn()
        XCTAssertEqual(try store.calendarEventDetails(id: id(event))?.details.organizer?.address, "erin@example.com")
        provider.edit(event, version: "v2")
        provider.detailsResults = [ProviderError.server(status: 500, message: "boom")]
        await lane.ask(details: id(event))
        await lane.turn()
        // A line the capture must find, so an empty capture never passes for a clean one.
        let sentinel = "lane log check \(UUID().uuidString)"
        SyncLog.logger.notice("\(sentinel, privacy: .public)")
        try await Task.sleep(for: .milliseconds(300))

        let logs = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try logs.getEntries(at: logs.position(date: start.addingTimeInterval(-1)),
                                          matching: NSPredicate(format: "subsystem == %@", AppIdentity.bundleIdentifier))
        let loud = entries.compactMap { $0 as? OSLogEntryLog }.filter { $0.level != .debug && $0.level != .undefined }
        XCTAssertTrue(loud.contains { $0.composedMessage == sentinel }, "the capture sees this process's lines")
        XCTAssertTrue(loud.contains { $0.composedMessage.hasPrefix("calendar: details not read for") }, "the failure was said")
        let leaks = loud.map(\.composedMessage).filter { line in
            [title, "Zebra", "larkspur", "erin@example.com", "Erin", "Every week"].contains { line.contains($0) }
        }
        XCTAssertEqual(leaks, [], "ids and counts only")
    }

    func testAGraphDetailsReadIsLiveSpend() async throws {
        let provider = ScriptedCalendarProvider(accountID: account, kind: .microsoft)
        provider.requestsPerDetails = 2
        let event = provider.seedEvent("Weekly", start: Date().addingTimeInterval(3 * 86_400), seriesID: "S", version: "v1")
        let (lane, budget, _) = try lane(provider, quota: .standard(for: .microsoft), active: false)
        await lane.turn()
        let before = await budget.liveHeadroom
        await lane.ask(details: id(event))
        await lane.turn()
        let after = await budget.liveHeadroom
        XCTAssertEqual(before - after, 2, accuracy: 1e-9, "the event and its series")
    }
}

/// The budgets an engine made, in order, from any thread.
final class Budgets: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [QuotaBudget] = []

    var first: QuotaBudget? {
        lock.lock(); defer { lock.unlock() }
        return made.first
    }

    func add(_ budget: QuotaBudget) -> QuotaBudget {
        lock.lock(); defer { lock.unlock() }
        made.append(budget)
        return budget
    }
}
