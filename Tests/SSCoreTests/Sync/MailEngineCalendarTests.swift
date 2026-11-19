import Foundation
import XCTest
@testable import SSCore

/// The calendar lane through the engine (docs/ARCHITECTURE.md, "Calendar"): when it reads (after a live cycle that caught
/// up, once a minute in front and every five minutes behind, at once when asked or when a write waits), the time set
/// aside and removed on this Mac sent oldest first and settled, every refusal kept away from the mail, and Connect.
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

    func testTheFirstReadRidesTheFirstLiveCycleAndTheNextWaitsAMinute() async throws {
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
        clock.advance(59)
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.readWindows.count, 1, "not before a minute")
        clock.advance(1)
        try await waitUntil("read again after a minute") { provider.readWindows.count == 2 }
        try await waitUntil("dated by the new read") { self.calendarState(recorder) == .current(clock.now) }
        await harness.shutdown()
    }

    func testInTheBackgroundTheCalendarIsReadEveryFiveMinutes() async throws {
        let clock = HandClock()
        let provider = ScriptedCalendarProvider(accountID: account)
        let harness = try await started(provider, clock: clock)
        try await waitUntil("the first read") { provider.readWindows.count == 1 }
        harness.engine.setAppActive(false)

        clock.advance(60)
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.readWindows.count, 1, "a minute is the frontmost interval")
        clock.advance(239)
        try await waitForPolls(3, of: provider)
        XCTAssertEqual(provider.readWindows.count, 1)
        clock.advance(1)
        try await waitUntil("read after five minutes") { provider.readWindows.count == 2 }

        // Back in front, a minute again.
        harness.engine.setAppActive(true)
        clock.advance(60)
        try await waitUntil("read after a minute in front") { provider.readWindows.count == 3 }
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
            (1, .notConnected), (60, .apiDisabled), (60, .failing(lastRead: nil)), (1, .current(clock.now.addingTimeInterval(124))),
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
        try await waitUntil("settled") { try self.row(event.id, harness, clock)?.providerID == "evt-1" }
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
        XCTAssertNil(try row(event.id, harness, clock), "gone at once")
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
