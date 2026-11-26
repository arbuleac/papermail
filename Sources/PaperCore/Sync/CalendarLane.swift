import Foundation

/// The calendar lane of one account whose provider has a calendar (`CalendarProvider`), beside its live and backfill
/// lanes (docs/ARCHITECTURE.md, "Calendar"). A turn first sends what the user did on this Mac that the provider does not
/// know yet, oldest first: time set aside (a `creating` row) is created and settled, time removed (a `deleting` row) is
/// deleted. It then reads the account's main calendar for `CalendarWindow` around now into the store, which the day column
/// and the week draw from, and any days outside that window the app asked for, and says where the calendar stands as
/// `AccountSyncStatus.calendar`.
///
/// It keeps no timer. The live lane tells it whenever a full cycle has caught up, and it takes a turn when its last read
/// is two minutes old while the app is frontmost (ten minutes otherwise), at once when asked (`MailClient.refreshCalendars`,
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

    /// What a failure held back.
    private enum Part {
        case writes, window, covering, details
    }

    /// A write that failed for a reason of its own (a reply that did not read, a 5xx for that one event, the store
    /// refusing to settle it): the turn goes on past it, and it is tried again once its own backoff has passed.
    private struct RowFailure {
        var tries: Int
        var retryAt: TimeInterval
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
    /// `.check`: a live cycle caught up (or days outside the window were asked for), so look whether a turn is due;
    /// `.poll`: a read was asked for; `.operations`: a write waits.
    private let waker = SyncWaker()

    /// On the continuous clock: when the last read of the window began, and until when a failure holds the next turn back.
    private var lastTurn: TimeInterval?
    private var heldUntil: TimeInterval?
    private var consecutiveFailures = 0
    /// Reasons for the next turn not to wait for the interval: a read asked for, a write queued (or held back by a
    /// failure every request would meet), a read that failed and is tried again after the backoff.
    private var readAsked = false
    private var writesQueued = false
    private var readFailed = false
    /// Days outside the window the app turned to (`MailClient.refreshCalendars(accountID:covering:)`), each read once at
    /// the next turn.
    private var coveringAsked: [DateInterval] = []
    /// Events whose details a card asked for (`MailClient.readCalendarEventDetails`), oldest first, each read once.
    private var detailsAsked: [String] = []
    /// Writes that failed for a reason of their own, by row id, with their tries: one that fails
    /// `SyncTuning.failingPageTries` times is given up as the provider refusing it.
    private var rowFailures: [String: RowFailure] = [:]
    /// The last read that went through in this run, for `CalendarSyncState.failing(lastRead:)`.
    private var lastRead: Date?
    /// Copies the provider made of blocks whose row went altogether while their create was on its way, whose delete has
    /// not gone through yet. A block removed during its create keeps a tombstone in the store, which holds the copy's
    /// id instead; this is for a row that left nothing (its account removed meanwhile).
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

    /// Has the next turn read `interval` too, once, besides the window it keeps (`MailClient.refreshCalendars(accountID:
    /// covering:)`): a day or a week the app turned to outside `CalendarWindow`.
    nonisolated func read(covering interval: DateInterval) {
        Task { await self.ask(covering: interval) }
    }

    /// Has the next turn read the event's details, after the writes and before the window (a card is open on it).
    nonisolated func readDetails(_ eventID: String) {
        Task { await self.ask(details: eventID) }
    }

    /// Whether a card's ask waits to be read (for tests).
    var hasDetailsAsked: Bool { !detailsAsked.isEmpty }

    /// Internal so a test can ask without the hop through a task.
    func ask(details eventID: String) {
        guard !detailsAsked.contains(eventID) else { return }
        detailsAsked.append(eventID)
        waker.signal(.check)
    }

    private func ask(covering interval: DateInterval) {
        guard interval.duration > 0, !coveringAsked.contains(where: { Self.interval($0, holds: interval) }) else { return }
        coveringAsked.append(interval)
        // Not a read of the window: a fresh one serves the days inside it, and the turn reads only the asked days.
        waker.signal(.check)
    }

    func run() async {
        let id = accountID.rawValue
        SyncLog.logger.info("calendar lane started for \(id, privacy: .public)")
        while !Task.isCancelled {
            let reasons = await waker.wait(timeout: nil)
            if Task.isCancelled { break }
            if reasons.contains(.poll) { readAsked = true }
            if reasons.contains(.operations) { writesQueued = true }
            // Parked, the account sends nothing; the live lane's next cycle that catches up wakes this lane again.
            guard !link.isParked, isDue else { continue }
            await turn()
        }
        SyncLog.logger.info("calendar lane stopped for \(id, privacy: .public)")
    }

    /// Whether a turn is due now: never inside a failure's backoff; at once when asked, when a write is queued, a read
    /// failed or days outside the window wait to be read; when a write that failed on its own may be tried again;
    /// otherwise once the window's last read is the interval old (or at the first look).
    private var isDue: Bool {
        let now = clock.uptime()
        if let heldUntil, now < heldUntil { return false }
        if readAsked || writesQueued || readFailed || !coveringAsked.isEmpty || !detailsAsked.isEmpty { return true }
        return rowRetryIsDue(now) || windowIsStale(now)
    }

    private func windowIsStale(_ now: TimeInterval) -> Bool {
        guard let lastTurn else { return true }
        return now - lastTurn >= (isAppActive() ? tuning.calendarActiveInterval : tuning.calendarBackgroundInterval)
    }

    private func rowRetryIsDue(_ now: TimeInterval) -> Bool {
        rowFailures.values.contains { $0.retryAt <= now }
    }

    /// One turn: the permission (no request), the writes waiting, then the read of the window, then the days asked for
    /// outside it. Internal so a test can take one without the loop.
    func turn() async {
        let now = clock.uptime()
        // The window is read at every turn but one woken only for days outside it while its last read is fresh.
        // A turn woken only for an event's details while the window is fresh reads only those.
        let readsWindow = readAsked || writesQueued || readFailed || windowIsStale(now) || rowRetryIsDue(now)
            || (coveringAsked.isEmpty && detailsAsked.isEmpty)
        if readsWindow { lastTurn = now }
        readAsked = false
        writesQueued = false
        readFailed = false
        guard await provider.hasCalendarPermission() else {
            // Time set aside meanwhile waits as it is, and goes out once Connect has the scope, every write with its tries
            // afresh (a write held for its own backoff would otherwise have a turn taken for it on every live cycle).
            // Days asked for are asked again when they are shown again.
            coveringAsked = []
            detailsAsked = []
            rowFailures = [:]
            publish(.notConnected)
            return
        }
        if Task.isCancelled { return }
        // Each row is sent once a turn, whatever became of it: a refusal the store could not record leaves it pending.
        var sent: Set<String> = []
        if let (failure, error) = await sendWrites(once: &sent) {
            await record(failure, holding: .writes, error: error)
            return
        }
        // A card is open on these: they go before the window's read, which may take a while.
        if let (failure, error) = await readAskedDetails() {
            await record(failure, holding: .details, error: error)
            return
        }
        let window = CalendarWindow.around(clock.now())
        if readsWindow {
            // The window's read is background work: a body the reader is waiting for goes first, for
            // `backgroundYieldLimit` at most. Writes and days the user turned to are the user's and do not wait.
            let hold = budget.foreground
            if hold.isActive { await hold.waitUntilIdle(limit: tuning.backgroundYieldLimit) }
            if Task.isCancelled { return }
            guard await read(window) else { return }
            // The read may have found, by its key, the copy a lost create reply made of a block removed since: its
            // tombstone now holds the copy's id, which is deleted now rather than a turn later. Time set aside during
            // the read goes too.
            if let (failure, error) = await sendWrites(once: &sent) {
                await record(failure, holding: .writes, error: error)
                return
            }
            if isAppActive(), let (failure, error) = await prefetchDetails() {
                await record(failure, holding: .details, error: error)
                return
            }
        }
        await readCovering(besides: window)
    }

    // MARK: Details

    /// Reads the details asked for, oldest first. Details are extras, so failures are quiet: one every request would
    /// meet stops the turn with the asks kept; any other drops that one ask. An event the provider no longer has writes
    /// nothing (the next read sweeps its row and its details).
    private func readAskedDetails() async -> (Failure, Error)? {
        while let id = detailsAsked.first {
            if Task.isCancelled { return (.cancelled, CancellationError()) }
            guard let event = try? store.calendarEvent(id: id), event.accountID == accountID, event.sync == .synced,
                  let providerID = event.providerID, !event.isSetAside else {
                detailsAsked.removeFirst()
                continue
            }
            do {
                try await readDetails(of: event, providerID: providerID)
                detailsAsked.removeFirst()
            } catch {
                if Self.failsEveryRequest(error) { return (Self.failure(of: error), error) }
                detailsAsked.removeFirst()
                SyncLog.logger.notice("calendar: details not read for \(self.accountID.rawValue, privacy: .public): \(SyncErrorDescription.describe(error), privacy: .private)")
            }
        }
        return nil
    }

    /// Reads ahead the details of the next day's events that changed since theirs were read, at most
    /// `calendarDetailsPrefetch`, so a card opened on one shows everything at once.
    private func prefetchDetails() async -> (Failure, Error)? {
        let now = clock.now()
        let events: [CalendarEvent]
        do {
            events = try store.eventsNeedingDetails(accountID: accountID, in: DateInterval(start: now, duration: 86_400),
                                                    limit: tuning.calendarDetailsPrefetch)
        } catch {
            return nil
        }
        var read = 0
        for event in events {
            if Task.isCancelled { return (.cancelled, CancellationError()) }
            guard let providerID = event.providerID else { continue }
            do {
                try await readDetails(of: event, providerID: providerID)
                read += 1
            } catch {
                if Self.failsEveryRequest(error) { return (Self.failure(of: error), error) }
            }
        }
        if read > 0 { SyncLog.logger.debug("calendar: read ahead the details of \(read, privacy: .public) events for \(self.accountID.rawValue, privacy: .public)") }
        return nil
    }

    private func readDetails(of event: CalendarEvent, providerID: String) async throws {
        let now = clock.now()
        let known = try event.seriesID.flatMap { series in
            try store.seriesRepeats(accountID: accountID, seriesID: series, since: now.addingTimeInterval(-86_400))
        }
        let email = (try? store.accounts().first { $0.id == accountID })??.email ?? ""
        let read = try await provider.calendarEventDetails(providerID: providerID, seriesID: event.seriesID, knownRepeats: known,
                                                           account: CalendarAccountFacts(email: email))
        guard let read else { return }
        await charge(requests: read.requestCount)
        try store.saveCalendarEventDetails(read.details, eventID: event.id, version: read.version ?? event.version, readAt: now)
    }

    // MARK: Writes

    /// Sends the account's waiting writes in the order they were made, each read from the store as its turn comes, so a
    /// block removed meanwhile is never sent and one set aside anew goes out in this turn. A write the provider refuses
    /// for good is marked so; one that fails for a reason of its own waits for its own backoff while the rest, and the
    /// read, go on. Only a failure every request would meet (the network, a throttle, the token, the scope) stops the
    /// turn, leaving every write waiting and the read not taken.
    private func sendWrites(once sent: inout Set<String>) async -> (Failure, Error)? {
        do {
            try await deleteStrays()
        } catch {
            return (Self.failure(of: error), error)
        }
        let now = clock.uptime()
        var seen: Set<String> = []
        while true {
            if Task.isCancelled { return (.cancelled, CancellationError()) }
            let next: CalendarEvent?
            do {
                next = try store.pendingCalendarEvents(accountID: accountID).first { !seen.contains($0.id) }
            } catch {
                return (.transient(retryAfter: nil, throttled: false), error)
            }
            guard let event = next else { break }
            seen.insert(event.id)
            if sent.contains(event.id) { continue }
            if let held = rowFailures[event.id], now < held.retryAt { continue }
            // The row as last known, for what a failure makes of it: a block removed during its create is deleted next.
            var current = event
            do {
                switch event.sync {
                case .creating:
                    sent.insert(event.id)
                    if let tombstone = try await create(event) {
                        current = tombstone
                        try await delete(tombstone)
                    }
                case .deleting where event.providerID?.isEmpty ?? true:
                    // The tombstone of a block removed while it was being created, whose copy (if any) this Mac has not
                    // heard of: the read finds it by its key and fills in its id, or sweeps the tombstone.
                    continue
                case .deleting:
                    sent.insert(event.id)
                    try await delete(event)
                case .synced, .failed:
                    continue
                }
                rowFailures[event.id] = nil
            } catch {
                let failure = Self.failure(of: error)
                if case .refused = failure {
                    rowFailures[event.id] = nil
                    refuse(current, error)
                    continue
                }
                if Self.failsEveryRequest(error) { return (failure, error) }
                note(current, failedWith: error)
            }
        }
        // A row settled, removed or given up meanwhile holds nothing back.
        rowFailures = rowFailures.filter { seen.contains($0.key) }
        return nil
    }

    /// Creates the block under its client key, so a create sent again after a lost reply returns the copy already made,
    /// and settles the row with the copy. Returns the row's tombstone when the block was removed while the create was on
    /// its way: the copy's id is in it now, and the caller deletes it.
    private func create(_ event: CalendarEvent) async throws -> CalendarEvent? {
        var sent = event
        sent.sourceThreadID = threadID(of: event.sourceMessage)
        let created = try await provider.createCalendarEvent(sent)
        await charge(requests: 1)
        guard try store.settleCalendarEvent(id: event.id, created: created) else {
            // The row left nothing behind (its account removed meanwhile): only this lane knows the copy now.
            guard let providerID = created.providerID, !providerID.isEmpty else { return nil }
            strays.append(providerID)
            try await deleteStrays()
            return nil
        }
        guard let row = try store.pendingCalendarEvents(accountID: accountID).first(where: { $0.id == event.id }),
              row.sync == .deleting, !(row.providerID?.isEmpty ?? true) else { return nil }
        return row
    }

    /// The provider's id of the conversation the block was set aside for, which Gmail's link back to the mail names; nil
    /// when the store no longer has the message.
    private func threadID(of message: MessageID?) -> String? {
        guard let message, message.accountID == accountID else { return nil }
        return (try? store.message(message))?.conversationID.providerID
    }

    /// Deletes the copies made of blocks whose row went altogether. One the provider refuses for good is left on the
    /// calendar, where the user can delete it; one that fails for a reason of its own is tried again first next turn;
    /// a failure every request would meet throws.
    private func deleteStrays() async throws {
        while let stray = strays.first {
            do {
                try await provider.deleteCalendarEvent(providerID: stray)
                await charge(requests: 1)
            } catch {
                if Self.failsEveryRequest(error) { throw error }
                guard case .refused = Self.failure(of: error) else {
                    SyncLog.logger.notice("calendar: the delete of a copy failed for \(self.accountID.rawValue, privacy: .public), tried again next turn: \(SyncErrorDescription.describe(error), privacy: .private)")
                    return
                }
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

    /// A write failed for a reason of its own: it waits for its own backoff, and after `failingPageTries` tries it is
    /// given up as refused, so one event the provider keeps failing never stops the account's calendar. A create given
    /// up shows the failed mark, and a read that finds its copy after all (by its key) settles it.
    private func note(_ event: CalendarEvent, failedWith error: Error) {
        let tries = (rowFailures[event.id]?.tries ?? 0) + 1
        guard tries < tuning.failingPageTries else {
            rowFailures[event.id] = nil
            refuse(event, error)
            return
        }
        let delay = Backoff.delay(attempt: tries, base: tuning.backoffBase, cap: retryCap)
        rowFailures[event.id] = RowFailure(tries: tries, retryAt: clock.uptime() + delay)
        SyncLog.logger.notice("calendar write failed for \(self.accountID.rawValue, privacy: .public) (try \(tries, privacy: .public)), retrying in \(delay, privacy: .public) s: \(SyncErrorDescription.describe(error), privacy: .private)")
    }

    // MARK: Read

    /// Reads the window into the store. False when it failed, which ends the turn.
    private func read(_ window: DateInterval) async -> Bool {
        let now = clock.now()
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
            return true
        } catch {
            await record(Self.failure(of: error), holding: .window, error: error)
            return false
        }
    }

    /// Reads each interval asked for outside `window`, once, written as any read is (`replaceCalendarEvents` over it).
    /// One the window holds is served by the window's read.
    private func readCovering(besides window: DateInterval) async {
        while let interval = coveringAsked.first {
            coveringAsked.removeFirst()
            if Self.interval(window, holds: interval) { continue }
            do {
                let listing = try await provider.calendarEvents(in: interval)
                await charge(requests: listing.requestCount)
                try store.replaceCalendarEvents(listing.events, accountID: accountID, window: interval)
                consecutiveFailures = 0
            } catch {
                let failure = Self.failure(of: error)
                switch failure {
                case .transient:
                    // Read once the backoff has passed, first.
                    coveringAsked.insert(interval, at: 0)
                case .refused:
                    log(refused: "a read of days outside the window", error)
                case .cancelled, .notConnected, .apiDisabled:
                    break
                }
                await record(failure, holding: .covering, error: error)
                return
            }
        }
    }

    private static func interval(_ outer: DateInterval, holds inner: DateInterval) -> Bool {
        outer.start <= inner.start && inner.end <= outer.end
    }

    // MARK: Outcomes

    /// Never longer than the active interval: a read that late is as stale as one that never came.
    private var retryCap: TimeInterval {
        min(tuning.backoffCap, tuning.calendarActiveInterval)
    }

    private func record(_ failure: Failure, holding part: Part, error: Error) async {
        // An error that surfaces while the lane is being stopped is the stop itself.
        guard !Task.isCancelled else { return }
        let id = accountID.rawValue
        switch failure {
        case .cancelled:
            return
        case .notConnected:
            coveringAsked = []
            publish(.notConnected)
        case .apiDisabled:
            coveringAsked = []
            publish(.apiDisabled)
        case .refused where part == .covering || part == .details:
            // That interval is dropped; nothing else waits on it.
            return
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
            let delay = throttled
                ? Backoff.throttleDelay(retryAfter: retryAfter, attempt: consecutiveFailures, base: tuning.backoffBase, cap: retryCap)
                : Backoff.delay(attempt: consecutiveFailures, base: tuning.backoffBase, cap: retryCap)
            heldUntil = clock.uptime() + delay
            switch part {
            case .writes: writesQueued = true
            case .window: readFailed = true
            case .covering, .details: break
            }
            // The days outside the window and the details are the app's extras: their read failing says nothing of the
            // calendar's state.
            if part != .covering, part != .details { publish(.failing(lastRead: lastRead)) }
            let description = SyncErrorDescription.describe(error)
            SyncLog.logger.notice("calendar \(Self.name(of: part), privacy: .public) failed for \(id, privacy: .public), retrying in \(delay, privacy: .public) s: \(description, privacy: .private)")
        }
    }

    private static func name(of part: Part) -> String {
        switch part {
        case .writes: return "write"
        case .window: return "read"
        case .covering: return "read outside the window"
        case .details: return "read of details"
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

    /// Whether a failed write says something of the account rather than of that one write: every request, the read
    /// included, would meet it now (the engine stopping, the scope, the API turned off, a throttle, the network, the
    /// token, the keychain). Anything else (a reply that did not read, a 5xx or a timeout for that event, the store
    /// refusing to record it) is that write's alone.
    private static func failsEveryRequest(_ error: Error) -> Bool {
        if error is CancellationError || error is CalendarProviderError || error is AuthError || error is URLError {
            return true
        }
        switch error as? ProviderError {
        case .cancelled?, .throttled?, .network?, .unauthorized?:
            return true
        default:
            return false
        }
    }

    private func charge(requests: Int) async {
        guard let cost = budget.quota.calendarRequestCost, requests > 0 else { return }
        await budget.recordLive(cost * Double(requests))
    }

    /// Publishes where the calendar stands only when that changes kind, or when a read is newer by more than
    /// `SyncTuning.calendarStatusRefresh` than the one published: every observer of the statuses (the day column, the
    /// week, their foot) would otherwise lay out again after every read for a date nothing shows.
    private func publish(_ state: CalendarSyncState) {
        let refresh = tuning.calendarStatusRefresh
        statusCenter.update(accountID) { status in
            guard Self.isNews(state, after: status.calendar, refresh: refresh) else { return }
            status.calendar = state
        }
    }

    private static func isNews(_ state: CalendarSyncState, after published: CalendarSyncState, refresh: TimeInterval) -> Bool {
        switch (published, state) {
        case (.current(let then), .current(let now)):
            return abs(now.timeIntervalSince(then)) > refresh
        case (.unknown, .unknown), (.notConnected, .notConnected), (.apiDisabled, .apiDisabled), (.failing, .failing):
            return false
        default:
            return true
        }
    }

    private func log(refused what: String, _ error: Error) {
        SyncLog.logger.error("calendar: the provider refused \(what, privacy: .public) for \(self.accountID.rawValue, privacy: .public): \(SyncErrorDescription.describe(error), privacy: .private)")
    }
}
