import Foundation

/// The calendar lane of one account whose provider has a calendar (`CalendarProvider`), beside its live and backfill
/// lanes (docs/ARCHITECTURE.md, "Calendar"). A turn first sends what the user did on this Mac that the provider does not
/// know yet, oldest first: time set aside (a `creating` row) is created and settled, time removed (a `deleting` row) is
/// deleted. It then reads the account's main calendar for `CalendarWindow` around now into the store, which the day column
/// and the week draw from, and says where the calendar stands as `AccountSyncStatus.calendar`.
///
/// It keeps no timer. The live lane tells it whenever a full cycle has caught up, and it takes a turn when its last one
/// is a minute old while the app is frontmost (five minutes otherwise), at once when asked (`MailClient.refreshCalendars`,
/// Connect) or when a write waits, and after a failure once its own backoff has passed. As the third child of the
/// account's task group it stops with the other two, and a slow calendar never holds back a mail poll. It sends nothing
/// while the account is parked (`LaneLink.isParked`: waiting for sign-in, or at launch until the live lane's first cycle
/// has tried the token); what was asked meanwhile stays asked.
///
/// Nothing it meets reaches the mail: it never sets the live lane's phase, message or retry time, never touches
/// `permissionsNeeded` (the outbox's, rewritten on every drain), and never parks the account, since a refused token is
/// the live lane's to find. A token without the calendar scope is `.notConnected` and costs no request. Google Calendar's
/// quota is its own, so its requests are charged to nothing and its throttles back off this lane alone; Graph's calendar
/// spends the mailbox's quota (`ProviderQuota.calendarRequestCost`), so its requests are live spend and a throttle there
/// pauses the backfill as any live throttle does.
actor CalendarLane {
    /// What a failed request means for the turn.
    private enum Failure {
        /// The engine is stopping: nothing failed.
        case cancelled
        /// The token lacks the calendar scope: Connect asks for it.
        case notConnected
        /// Google's Calendar API is off for the OAuth client the user registered.
        case apiDisabled
        /// The provider refuses this request for good (a 4xx that is no throttle, scope or token): a create is marked
        /// failed and a delete given up; a read is tried again after the backoff.
        case refused
        /// Worth trying again after the backoff: the network, the service, a throttle, the token.
        case transient(retryAfter: TimeInterval?, throttled: Bool)
    }

    let accountID: AccountID
    private let store: MailStoring
    private let provider: CalendarProvider
    private let statusCenter: SyncStatusCenter
    private let tuning: SyncTuning
    private let budget: QuotaBudget
    private let link: LaneLink
    private let isAppActive: @Sendable () -> Bool
    private let clock: SendClock
    /// `.check`: a live cycle caught up, so look whether a turn is due; `.poll`: a read was asked for; `.operations`: a
    /// write waits.
    private let waker = SyncWaker()

    /// On the continuous clock: when the last turn began, and until when a failure holds the next one back.
    private var lastTurn: TimeInterval?
    private var heldUntil: TimeInterval?
    private var consecutiveFailures = 0
    /// Reasons for the next turn not to wait for the interval: a read asked for, a write waiting (queued, or held back
    /// by a failure), a read that failed and is tried again after the backoff.
    private var readAsked = false
    private var writesWaiting = false
    private var readFailed = false
    /// The last read that went through in this run, for `CalendarSyncState.failing(lastRead:)`.
    private var lastRead: Date?
    /// Copies the provider made of blocks removed while their create was on its way, whose delete has not gone through
    /// yet. Deleted before anything else, and before the next read could bring them back as events of their own.
    private var strays: [String] = []

    init(
        accountID: AccountID,
        store: MailStoring,
        provider: CalendarProvider,
        statusCenter: SyncStatusCenter,
        tuning: SyncTuning,
        budget: QuotaBudget,
        link: LaneLink,
        isAppActive: @escaping @Sendable () -> Bool
    ) {
        self.accountID = accountID
        self.store = store
        self.provider = provider
        self.statusCenter = statusCenter
        self.tuning = tuning
        self.budget = budget
        self.link = link
        self.isAppActive = isAppActive
        self.clock = tuning.calendarClock
    }

    // MARK: Loop

    nonisolated func wake(_ reason: WakeReason) {
        waker.signal(reason)
    }

    func run() async {
        let id = accountID.rawValue
        SyncLog.logger.info("calendar lane started for \(id, privacy: .public)")
        while !Task.isCancelled {
            let reasons = await waker.wait(timeout: nil)
            if Task.isCancelled { break }
            if reasons.contains(.poll) { readAsked = true }
            if reasons.contains(.operations) { writesWaiting = true }
            // Parked, the account sends nothing; the live lane's next cycle that catches up wakes this lane again.
            guard !link.isParked, isDue else { continue }
            await turn()
        }
        SyncLog.logger.info("calendar lane stopped for \(id, privacy: .public)")
    }

    /// Whether a turn is due now: never inside a failure's backoff; at once when asked, when a write waits or a read
    /// failed; otherwise once the interval has passed since the last turn (or at the first look).
    var isDue: Bool {
        let now = clock.uptime()
        if let heldUntil, now < heldUntil { return false }
        if readAsked || writesWaiting || readFailed { return true }
        guard let lastTurn else { return true }
        return now - lastTurn >= (isAppActive() ? tuning.calendarActiveInterval : tuning.calendarBackgroundInterval)
    }

    /// One turn: the permission (no request), the writes waiting, then the read.
    func turn() async {
        lastTurn = clock.uptime()
        readAsked = false
        writesWaiting = false
        readFailed = false
        guard await provider.hasCalendarPermission() else {
            // Time set aside meanwhile waits as it is, and goes out once Connect has the scope.
            publish(.notConnected)
            return
        }
        if Task.isCancelled { return }
        if let (failure, error) = await sendWrites() {
            await record(failure, writing: true, error: error)
            return
        }
        await read()
    }

    // MARK: Writes

    /// Sends the account's waiting writes in the order they were made, each read from the store as its turn comes, so a
    /// block removed meanwhile is never sent and one set aside anew goes out in this turn. Stops at the first failure
    /// that is not the provider refusing that one write for good, leaving it and the rest waiting.
    private func sendWrites() async -> (Failure, Error)? {
        do {
            try await deleteStrays()
        } catch {
            return (Self.failure(of: error), error)
        }
        // Each row once a turn, whatever became of it: a refusal the store could not record leaves it pending.
        var sent: Set<String> = []
        while true {
            if Task.isCancelled { return (.cancelled, CancellationError()) }
            let next: CalendarEvent?
            do {
                next = try store.pendingCalendarEvents(accountID: accountID).first { !sent.contains($0.id) }
            } catch {
                return (.transient(retryAfter: nil, throttled: false), error)
            }
            guard let event = next else { return nil }
            sent.insert(event.id)
            do {
                switch event.sync {
                case .creating: try await create(event)
                case .deleting: try await delete(event)
                case .synced, .failed: continue
                }
            } catch {
                let failure = Self.failure(of: error)
                guard case .refused = failure else { return (failure, error) }
                refuse(event, error)
            }
        }
    }

    /// Creates the block under its client key, so a create sent again after a lost reply returns the copy already made,
    /// and settles the row with the copy. A row gone meanwhile (removed while the create was on its way) takes the copy
    /// with it.
    private func create(_ event: CalendarEvent) async throws {
        let created = try await provider.createCalendarEvent(event)
        await charge(requests: 1)
        guard try !store.settleCalendarEvent(id: event.id, created: created) else { return }
        guard let providerID = created.providerID, !providerID.isEmpty else { return }
        strays.append(providerID)
        try await deleteStrays()
    }

    /// Deletes the copies made of blocks removed meanwhile. One the provider refuses for good is left on the calendar,
    /// where the user can delete it; anything else throws, and the copy is tried again first next turn.
    private func deleteStrays() async throws {
        while let stray = strays.first {
            do {
                try await provider.deleteCalendarEvent(providerID: stray)
                await charge(requests: 1)
            } catch {
                guard case .refused = Self.failure(of: error) else { throw error }
                log(refused: "the delete of a copy made for time removed meanwhile", error)
            }
            strays.removeFirst()
        }
    }

    private func delete(_ event: CalendarEvent) async throws {
        if let providerID = event.providerID, !providerID.isEmpty {
            try await provider.deleteCalendarEvent(providerID: providerID)
            await charge(requests: 1)
        }
        guard try !store.settleCalendarEvent(id: event.id, created: nil) else { return }
        try makeAgainIfUndone(event)
    }

    /// The settle of a delete was refused because the row is `synced` again: the user undid the removal while the
    /// delete was on its way, and the provider no longer has the event. Time set aside is set aside anew (a new row the
    /// next turn creates), so the undo holds; any other event the provider deleted is gone, and the next read says so.
    private func makeAgainIfUndone(_ event: CalendarEvent) throws {
        guard event.isSetAside else { return }
        let span = DateInterval(start: event.start, end: max(event.end, event.start.addingTimeInterval(1)))
        guard let current = try store.calendarEvents(in: span, accountIDs: [accountID]).first(where: { $0.id == event.id }),
              current.sync == .synced, current.providerID == event.providerID,
              let asWas = try store.removeCalendarEvent(id: current.id) else { return }
        // Removed (now `deleting`) and settled as the provider has it, then put back: with a provider id gone, that is a
        // new row under a new key, `creating`, which this turn sends after the rows queued before it.
        try store.settleCalendarEvent(id: current.id, created: nil)
        try store.restoreCalendarEvent(asWas)
    }

    /// The provider will never take this write: a create shows the failed mark until the user removes it; a delete is
    /// given up and the event is back on the calendar, as the provider still has it.
    private func refuse(_ event: CalendarEvent, _ error: Error) {
        do {
            if event.sync == .creating {
                try store.failCalendarEvent(id: event.id)
            } else {
                try store.restoreCalendarEvent(event)
            }
        } catch {
            SyncLog.logger.error("calendar: could not record a refusal for \(self.accountID.rawValue, privacy: .public): \(SyncErrorDescription.describe(error), privacy: .private)")
        }
        log(refused: event.sync == .creating ? "a create" : "a delete", error)
    }

    // MARK: Read

    private func read() async {
        let now = clock.now()
        let window = CalendarWindow.around(now)
        let signposter = SyncLog.signposter
        let interval = signposter.beginInterval("sync.calendar", id: signposter.makeSignpostID())
        defer { signposter.endInterval("sync.calendar", interval) }
        do {
            let listing = try await provider.calendarEvents(in: window)
            await charge(requests: listing.requestCount)
            try store.replaceCalendarEvents(listing.events, accountID: accountID, window: window)
            lastRead = now
            consecutiveFailures = 0
            heldUntil = nil
            publish(.current(now))
            SyncLog.logger.debug("calendar read for \(self.accountID.rawValue, privacy: .public): \(listing.events.count, privacy: .public) events in \(listing.requestCount, privacy: .public) requests")
        } catch {
            let failure = Self.failure(of: error)
            if case .refused = failure {
                await record(.transient(retryAfter: nil, throttled: false), writing: false, error: error)
            } else {
                await record(failure, writing: false, error: error)
            }
        }
    }

    // MARK: Outcomes

    private func record(_ failure: Failure, writing: Bool, error: Error) async {
        // An error that surfaces while the lane is being stopped is the stop itself.
        guard !Task.isCancelled else { return }
        let id = accountID.rawValue
        switch failure {
        case .cancelled:
            return
        case .notConnected:
            publish(.notConnected)
        case .apiDisabled:
            publish(.apiDisabled)
        case .refused, .transient:
            var retryAfter: TimeInterval?
            var throttled = false
            if case .transient(let after, let wasThrottled) = failure {
                retryAfter = after
                throttled = wasThrottled
            }
            consecutiveFailures += 1
            // Graph's calendar spends the mailbox's quota, which the backfill spends too; Google Calendar's is its own.
            if throttled, budget.quota.calendarRequestCost != nil { await budget.liveThrottled(retryAfter: retryAfter) }
            // Never longer than the active interval: a read a minute late is as stale as one that never came.
            let cap = min(tuning.backoffCap, tuning.calendarActiveInterval)
            let delay = throttled
                ? Backoff.throttleDelay(retryAfter: retryAfter, attempt: consecutiveFailures, base: tuning.backoffBase, cap: cap)
                : Backoff.delay(attempt: consecutiveFailures, base: tuning.backoffBase, cap: cap)
            heldUntil = clock.uptime() + delay
            if writing { writesWaiting = true } else { readFailed = true }
            publish(.failing(lastRead: lastRead))
            let description = SyncErrorDescription.describe(error)
            SyncLog.logger.notice("calendar \(writing ? "write" : "read", privacy: .public) failed for \(id, privacy: .public), retrying in \(delay, privacy: .public) s: \(description, privacy: .private)")
        }
    }

    private static func failure(of error: Error) -> Failure {
        if error is CancellationError { return .cancelled }
        switch error as? CalendarProviderError {
        case .permissionMissing?: return .notConnected
        case .apiDisabled?: return .apiDisabled
        case nil: break
        }
        switch error as? ProviderError {
        case .cancelled?:
            return .cancelled
        case .throttled(let retryAfter)?:
            return .transient(retryAfter: retryAfter, throttled: true)
        case .notFound?:
            return .refused
        case .server(let status, _)? where (400..<500).contains(status) && status != 408:
            return .refused
        default:
            // The network, the service, a reply that did not read (a create sent again finds its copy), the token (the
            // live lane parks the account if it is refused for mail too), the keychain, the store.
            return .transient(retryAfter: nil, throttled: false)
        }
    }

    private func charge(requests: Int) async {
        guard let cost = budget.quota.calendarRequestCost, requests > 0 else { return }
        await budget.recordLive(cost * Double(requests))
    }

    private func publish(_ state: CalendarSyncState) {
        statusCenter.update(accountID) { $0.calendar = state }
    }

    private func log(refused what: String, _ error: Error) {
        SyncLog.logger.error("calendar: the provider refused \(what, privacy: .public) for \(self.accountID.rawValue, privacy: .public): \(SyncErrorDescription.describe(error), privacy: .private)")
    }
}
