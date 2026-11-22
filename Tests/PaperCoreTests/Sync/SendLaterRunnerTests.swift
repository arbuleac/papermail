import Foundation
import XCTest
@testable import PaperCore

/// Send Later in the engine (spec §5.23): a message waits in the outbox for the wall-clock time the user chose and goes
/// then while the engine runs; a time that passed while it was stopped is never sent at start, but waits as `missed`
/// until the user says to send it. Time moves by hand (`HandClock`); nothing sleeps for real.
final class SendLaterRunnerTests: XCTestCase {
    private let fallback: TimeInterval = 30
    private let draft = UUID()

    private func harness(_ clock: HandClock, engineStore: MailStoring? = nil, start: Bool = true,
                         tune: (inout SyncTuning) -> Void = { _ in }) throws -> EngineHarness {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...1, next: nil, cursor: "c0"))]]
        try engineStore?.upsertAccount(Fixtures.account(id: provider.accountID))
        let harness = try EngineHarness(provider: provider, engineStore: engineStore) {
            $0.pollInterval = self.fallback
            $0.sendClock = clock.sendClock
            tune(&$0)
        }
        if start { harness.engine.start() }
        return harness
    }

    private func sleep(_ index: Int, of clock: HandClock, file: StaticString = #filePath, line: UInt = #line) async throws -> TimeInterval {
        try await waitUntil("wait \(index + 1) of the send runner", file: file, line: line) { clock.sleeps.count > index }
        return clock.sleeps[index]
    }

    func testAScheduledMessageWaitsForItsTimeAndGoesThen() async throws {
        let clock = HandClock()
        let harness = try harness(clock)
        _ = try await sleep(0, of: clock)
        let id = try harness.engine.scheduleSend(Fixtures.outgoing(), at: clock.now.addingTimeInterval(45), draftID: draft)
        let stored = try XCTUnwrap(try harness.store.pendingSends().first { $0.id == id })
        XCTAssertEqual(stored.status, .later)
        XCTAssertEqual(stored.draftID, draft)
        // Further away than the background poll: the runner looks at the poll interval, then at the time itself.
        let first = try await sleep(1, of: clock)
        XCTAssertEqual(first, fallback, accuracy: 0.001)
        XCTAssertEqual(clock.advance(fallback), 1)
        let second = try await sleep(2, of: clock)
        XCTAssertEqual(second, 15, accuracy: 0.001)
        XCTAssertTrue(harness.provider.sendCalls.isEmpty)
        XCTAssertEqual(clock.advance(15), 1)
        try await waitUntil("sent at its time") { harness.provider.sendCalls.count == 1 }
        await harness.shutdown()
    }

    /// Unlike an undo-send a previous run left, a Send Later message is not held to the retry cap: an hour away is an hour.
    func testAScheduledTimeHoursAwayIsNotCutShort() async throws {
        let clock = HandClock()
        let harness = try harness(clock)
        _ = try await sleep(0, of: clock)
        _ = try harness.engine.scheduleSend(Fixtures.outgoing(), at: clock.now.addingTimeInterval(3_600), draftID: draft)
        _ = try await sleep(1, of: clock)
        // 119 looks at the background interval take it to 3,570 s, where the retry cap would long since have sent it.
        for index in 2..<121 {
            XCTAssertEqual(clock.advance(fallback), 1)
            _ = try await sleep(index, of: clock)
            XCTAssertTrue(harness.provider.sendCalls.isEmpty, "held at \(Double(index - 1) * fallback) s")
        }
        XCTAssertEqual(clock.advance(fallback), 1)
        try await waitUntil("sent at its time") { harness.provider.sendCalls.count == 1 }
        await harness.shutdown()
    }

    /// The time is the one on the wall: setting the clock past it sends the message as soon as the runner is woken
    /// (the engine wakes it on `NSSystemClockDidChange`; `checkForMail` stands in for it here).
    func testSettingTheClockPastTheTimeSendsIt() async throws {
        let clock = HandClock()
        let harness = try harness(clock)
        _ = try await sleep(0, of: clock)
        _ = try harness.engine.scheduleSend(Fixtures.outgoing(), at: clock.now.addingTimeInterval(600), draftID: draft)
        _ = try await sleep(1, of: clock)
        clock.setWallClock(by: 900)
        harness.engine.checkForMail()
        try await waitUntil("sent once the runner looked") { harness.provider.sendCalls.count == 1 }
        await harness.shutdown()
    }

    /// The Mac slept through the time with Paper running: it goes at wake, as a snooze comes back then.
    func testATimePassedWhileTheMacSleptGoesAtWake() async throws {
        let clock = HandClock()
        let harness = try harness(clock)
        _ = try await sleep(0, of: clock)
        _ = try harness.engine.scheduleSend(Fixtures.outgoing(), at: clock.now.addingTimeInterval(20), draftID: draft)
        _ = try await sleep(1, of: clock)
        clock.sleepThrough(3_600)
        harness.engine.checkForMail()
        try await waitUntil("sent on waking") { harness.provider.sendCalls.count == 1 }
        await harness.shutdown()
    }

    /// The roadmap's rule: a time missed while the app was closed is not sent at launch. It waits, `missed`, for the user.
    func testATimeMissedWhileClosedIsHeldUntilTheUserSaysSend() async throws {
        let clock = HandClock()
        let harness = try harness(clock, start: false)
        let missed = PendingSend(message: Fixtures.outgoing(), createdAt: clock.now.addingTimeInterval(-7_200),
                                 sendAfter: clock.now.addingTimeInterval(-60), status: .later, draftID: draft)
        let ahead = PendingSend(message: Fixtures.outgoing(), createdAt: clock.now.addingTimeInterval(-7_200),
                                sendAfter: clock.now.addingTimeInterval(600), status: .later, draftID: UUID())
        try harness.store.enqueueSend(missed)
        try harness.store.enqueueSend(ahead)
        harness.engine.start()
        try await waitUntil("marked missed") { try harness.store.pendingSends().first { $0.id == missed.id }?.status == .missed }
        XCTAssertEqual(try harness.store.pendingSends().first { $0.id == ahead.id }?.status, .later, "still ahead: waits as before")
        // Minutes go by with the runner looking: the missed one is never claimed.
        _ = try await sleep(0, of: clock)
        for index in 1...4 {
            XCTAssertEqual(clock.advance(fallback), 1)
            _ = try await sleep(index, of: clock)
        }
        XCTAssertTrue(harness.provider.sendCalls.isEmpty)
        XCTAssertEqual(try harness.store.pendingSends().first { $0.id == missed.id }?.status, .missed)
        XCTAssertEqual(try harness.engine.sendNow([missed.id, "gone"]), [missed.id])
        try await waitUntil("sent once asked") { harness.provider.sendCalls.count == 1 }
        await harness.shutdown()
    }

    /// A send the previous run was handing over when it quit may have gone: the next launch marks it failed, never sends it
    /// again, and its reason reads as one that may have gone, which is what the app keeps its draft with (§5.53).
    func testASendInterruptedByAQuitIsFailedAtLaunchAsOneThatMayHaveGone() async throws {
        let clock = HandClock()
        let harness = try harness(clock, start: false)
        let interrupted = PendingSend(message: Fixtures.outgoing(), createdAt: clock.now.addingTimeInterval(-60),
                                      sendAfter: clock.now.addingTimeInterval(-55), status: .sending, attempts: 1)
        try harness.store.enqueueSend(interrupted)
        harness.engine.start()
        try await waitUntil("marked failed") { try harness.store.pendingSends().first { $0.id == interrupted.id }?.status == .failed }
        let failed = try XCTUnwrap(try harness.store.pendingSendSummaries().first { $0.id == interrupted.id })
        XCTAssertTrue(SendFailureWording.isInterrupted(lastError: failed.lastError), failed.lastError ?? "no reason")
        XCTAssertEqual(SendFailureWording.notice(subject: failed.subject, lastError: failed.lastError),
                       "\u{201c}\(failed.subject)\u{201d} may have gone. Check Sent.")
        XCTAssertEqual(FailedSend.settledByTheApp([failed], owned: { _ in false }, accounts: [failed.accountID]).map(\.id), [interrupted.id],
                       "nobody at launch answers for it: the app keeps its draft")
        _ = try await sleep(0, of: clock)
        XCTAssertEqual(clock.advance(fallback), 1)
        _ = try await sleep(1, of: clock)
        XCTAssertTrue(harness.provider.sendCalls.isEmpty, "never sent a second time")
        await harness.shutdown()
    }

    /// Keep in Drafts: a missed message is taken back like any held one.
    func testAMissedOrWaitingMessageCanBeCancelledButNotOnceItIsGoing() async throws {
        let clock = HandClock()
        let harness = try harness(clock, start: false)
        let missed = PendingSend(message: Fixtures.outgoing(), sendAfter: clock.now.addingTimeInterval(-1), status: .missed, draftID: draft)
        try harness.store.enqueueSend(missed)
        XCTAssertTrue(try harness.engine.cancelSend(id: missed.id))
        let waiting = try harness.engine.scheduleSend(Fixtures.outgoing(), at: clock.now.addingTimeInterval(600), draftID: draft)
        XCTAssertTrue(try harness.engine.cancelSend(id: waiting))
        var going = PendingSend(message: Fixtures.outgoing(), sendAfter: clock.now, status: .sending, draftID: draft)
        try harness.store.enqueueSend(going)
        XCTAssertFalse(try harness.engine.cancelSend(id: going.id))
        going.status = .sent
        try harness.store.updateSend(going)
        XCTAssertFalse(try harness.engine.cancelSend(id: going.id))
        XCTAssertEqual(try harness.store.pendingSends().map(\.id), [going.id])
        await harness.shutdown()
    }

    /// The app removes the draft a Send Later message was written in once it has gone, so the row stays, `sent`, until
    /// then; an undo-send's row goes at once, as before.
    func testADeliveredScheduledMessageStaysAsSentForTheAppToClearAway() async throws {
        let clock = HandClock()
        let harness = try harness(clock)
        _ = try await sleep(0, of: clock)
        let id = try harness.engine.scheduleSend(Fixtures.outgoing(), at: clock.now, draftID: draft)
        try await waitUntil("sent") { harness.provider.sendCalls.count == 1 }
        try await waitUntil("kept as sent") { try harness.store.pendingSends().first { $0.id == id }?.status == .sent }
        let plain = try harness.engine.scheduleSend(Fixtures.outgoing(), at: clock.now, draftID: nil)
        try await waitUntil("sent too") { harness.provider.sendCalls.count == 2 }
        try await waitUntil("gone") { try !harness.store.pendingSends().contains { $0.id == plain } }
        await harness.shutdown()
    }

    /// Quitting while another send uploads: a Send Later message claimed in the same read goes back to waiting for its
    /// time, so the next launch asks about it rather than sending it at once as an undo-send would go.
    func testStoppingMidDeliveryPutsAScheduledMessageBackToWaiting() async throws {
        // The outbox lists by creation: an undo-send is created on the real clock, a Send Later message on this one, which
        // starts a day ahead, so the undo-send is the one in flight when the quit lands.
        let clock = HandClock(wallStart: Date().addingTimeInterval(86_400))
        let harness = try harness(clock)
        _ = try await sleep(0, of: clock)
        _ = try harness.engine.send(Fixtures.outgoing(), undoWindow: 5)
        _ = try await sleep(1, of: clock)
        let later = try harness.engine.scheduleSend(Fixtures.outgoing(), at: clock.now.addingTimeInterval(5), draftID: draft)
        _ = try await sleep(2, of: clock)
        harness.provider.holdSends = true
        clock.advance(5)
        try await waitUntil("the first send in flight") { harness.provider.sendCalls.count == 1 }
        await harness.engine.stopAndWait()
        let sends = try harness.store.pendingSends()
        XCTAssertEqual(harness.provider.sendCalls.count, 1, "the Send Later message never reached the provider")
        let left = try XCTUnwrap(sends.first { $0.id == later })
        XCTAssertEqual(left.status, .later)
        XCTAssertEqual(left.attempts, 0)
        XCTAssertEqual(left.draftID, draft)
        await harness.shutdown()
    }

    /// The demo's sample (spec §5.43): one message waiting for Monday 09:00 with no kept draft, so Drafts lists it.
    func testTheDemoSampleWaitsForMondayMorning() async throws {
        let clock = HandClock()
        let harness = try harness(clock, start: false)
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        let thursday = try XCTUnwrap(london.date(from: DateComponents(year: 2025, month: 3, day: 6, hour: 15)))
        let id = try XCTUnwrap(try DemoSeeder.seedSendLater(harness.engine, accounts: [Fixtures.account(id: Fixtures.accountID)],
                                                            now: thursday, calendar: london))
        let send = try XCTUnwrap(try harness.store.pendingSends().first { $0.id == id })
        XCTAssertEqual(send.status, .later)
        XCTAssertNil(send.draftID)
        XCTAssertEqual(send.sendAfter, london.date(from: DateComponents(year: 2025, month: 3, day: 10, hour: 9)))
        XCTAssertEqual(SendLaterConversation.listed([PendingSendSummary(send)]).count, 1, "listed in Drafts")
        XCTAssertNil(try DemoSeeder.seedSendLater(harness.engine, accounts: [], now: thursday, calendar: london))
        await harness.shutdown()
    }

    /// The draft id survives the SQLite store, and a throttle keeps it with the row while the message waits to retry.
    func testTheDraftIDRoundTripsThroughTheSQLiteStoreAndAThrottle() async throws {
        let clock = HandClock()
        let store = try SQLiteMailStore.inMemory()
        let harness = try harness(clock, engineStore: store)
        harness.provider.sendResults = [.failure(ProviderError.throttled(retryAfter: 7))]
        _ = try await sleep(0, of: clock)
        let id = try harness.engine.scheduleSend(Fixtures.outgoing(), at: clock.now, draftID: draft)
        try await waitUntil("throttled") { harness.provider.sendCalls.count == 1 }
        try await waitUntil("back in the outbox") { try store.pendingSends().first { $0.id == id }?.status == .scheduled }
        let row = try XCTUnwrap(try store.pendingSends().first { $0.id == id })
        XCTAssertEqual(row.draftID, draft)
        XCTAssertEqual(SendLaterState(PendingSendSummary(row)), .sending, "still listed in Drafts while it waits to retry")
        await harness.shutdown()
    }

    /// A throttle at its time puts it back to retry (`scheduled`, with its draft id); a quit before the retry, and a launch
    /// after it, must not send it then as an undo-send left behind would go: it was a Send Later message whose time came
    /// while the app was open, but it has not gone, and the user is asked as for any time missed while the app was closed.
    func testAThrottledMessageLeftByAQuitIsAskedAboutAtTheNextLaunch() async throws {
        let store = try SQLiteMailStore.inMemory()
        let clock = HandClock()
        let first = try harness(clock, engineStore: store)
        first.provider.sendResults = [.failure(ProviderError.throttled(retryAfter: 30))]
        _ = try await sleep(0, of: clock)
        let id = try first.engine.scheduleSend(Fixtures.outgoing(), at: clock.now, draftID: draft)
        try await waitUntil("throttled") { first.provider.sendCalls.count == 1 }
        try await waitUntil("back in the outbox to retry") { try store.pendingSendSummaries().first { $0.id == id }?.status == .scheduled }
        await first.engine.stopAndWait()
        await first.shutdown()

        // The next morning.
        let next = HandClock(wallStart: clock.now.addingTimeInterval(86_400))
        let second = try harness(next, engineStore: store)
        try await waitUntil("marked missed") { try store.pendingSendSummaries().first { $0.id == id }?.status == .missed }
        _ = try await sleep(0, of: next)
        for index in 1...3 {
            XCTAssertEqual(next.advance(fallback), 1)
            _ = try await sleep(index, of: next)
        }
        XCTAssertTrue(second.provider.sendCalls.isEmpty, "not sent at launch")
        XCTAssertEqual(try store.pendingSendSummaries().first { $0.id == id }?.draftID, draft)
        XCTAssertEqual(try second.engine.sendNow([id]), [id])
        try await waitUntil("sent once asked") { second.provider.sendCalls.count == 1 }
        XCTAssertEqual(second.provider.sendCalls.first?.subject, Fixtures.outgoing().subject, "the whole message, read for the provider")
        await second.shutdown()
    }

    /// The token could not be fetched at the time (an expired token after a night idle, the token endpoint answering
    /// 503; a keychain read that failed): the HTTP clients fetch it outside their error mapping, so the `AuthError`
    /// reached the runner as itself and the send was marked failed, its draft back with a banner, though no request was
    /// made. It waits in the outbox with its draft id and goes at the next try, as a send with no connection does.
    func testASendWhoseTokenCouldNotBeFetchedWaitsAndGoesAgain() async throws {
        let clock = HandClock()
        let store = try SQLiteMailStore.inMemory()
        let harness = try harness(clock, engineStore: store)
        harness.provider.sendResults = [.failure(AuthError.refreshFailed("503")), .failure(AuthError.keychain(status: -128))]
        _ = try await sleep(0, of: clock)
        let id = try harness.engine.scheduleSend(Fixtures.outgoing(), at: clock.now, draftID: draft)
        try await waitUntil("the token refresh failed") { harness.provider.sendCalls.count == 1 }
        try await waitUntil("back in the outbox to retry") { try store.pendingSendSummaries().first { $0.id == id }?.status == .scheduled }
        var row = try XCTUnwrap(try store.pendingSendSummaries().first { $0.id == id })
        XCTAssertEqual(row.draftID, draft, "still the Send Later message, listed in Drafts as Sending…")
        XCTAssertNotNil(row.lastError)

        // A refused keychain waits too, at the cap, rather than asking for the password again at once.
        clock.advance(1)
        try await waitUntil("the keychain refused") { harness.provider.sendCalls.count == 2 }
        try await waitUntil("back in the outbox again") { try store.pendingSendSummaries().first { $0.id == id }?.status == .scheduled }
        row = try XCTUnwrap(try store.pendingSendSummaries().first { $0.id == id })
        XCTAssertEqual(row.draftID, draft)

        clock.advance(60)
        try await waitUntil("sent at the next try") { harness.provider.sendCalls.count == 3 }
        try await waitUntil("delivered") { try store.pendingSendSummaries().first { $0.id == id }?.status == .sent }
        await harness.shutdown()
    }

    /// A send that met no connection waits out a backoff that grows to a minute. When the network comes back (the
    /// engine's `checkForMail`, which a wake and the app coming forward also run) it goes then, not at the end of that
    /// wait, as the runner's comment said it did.
    func testASendThatMetNoConnectionGoesWhenTheNetworkReturns() async throws {
        let clock = HandClock()
        let harness = try harness(clock) {
            $0.backoffBase = 40
            $0.backoffCap = 300
        }
        harness.provider.sendResults = [.failure(ProviderError.transport(URLError(.notConnectedToInternet), bytesSent: 0))]
        _ = try await sleep(0, of: clock)
        let id = try harness.engine.scheduleSend(Fixtures.outgoing(), at: clock.now, draftID: draft)
        try await waitUntil("no connection") { harness.provider.sendCalls.count == 1 }
        try await waitUntil("held to retry") { try harness.store.pendingSendSummaries().first { $0.id == id }?.status == .scheduled }
        harness.engine.checkForMail()
        try await waitUntil("sent when the network returns") { harness.provider.sendCalls.count == 2 }
        XCTAssertEqual(try harness.store.pendingSendSummaries().first { $0.id == id }?.status, .sent)

        // A throttle is not hurried by a wake: the provider said when.
        harness.provider.sendResults = [.failure(ProviderError.throttled(retryAfter: 40))]
        let throttled = try harness.engine.scheduleSend(Fixtures.outgoing(), at: clock.now, draftID: UUID())
        try await waitUntil("throttled") { harness.provider.sendCalls.count == 3 }
        try await waitUntil("held to retry") {
            try harness.store.pendingSendSummaries().first { $0.id == throttled }?.status == .scheduled
        }
        harness.engine.checkForMail()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.provider.sendCalls.count, 3, "the throttle's time stands")
        await harness.shutdown()
    }

    /// An undo-send left by a quit is unchanged: it carries no draft, so it goes within the retry cap of launch as before.
    func testAnUndoSendLeftByAQuitStillGoesAtLaunch() async throws {
        let clock = HandClock()
        let harness = try harness(clock, start: false)
        try harness.store.enqueueSend(PendingSend(message: Fixtures.outgoing(), sendAfter: clock.now.addingTimeInterval(-60)))
        harness.engine.start()
        try await waitUntil("sent") { harness.provider.sendCalls.count == 1 }
        await harness.shutdown()
    }
}
