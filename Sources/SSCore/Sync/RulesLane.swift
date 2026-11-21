import Foundation

/// The rules lane of one account whose provider keeps server rules (`RuleProvider`), beside its live, backfill and calendar
/// lanes (docs/ARCHITECTURE.md, "Rules"). The server is the single source of truth for sender rules: Gmail's filters and
/// Outlook's inbox rules act on mail as it arrives, whether or not this Mac is on, and the store keeps only their mirror
/// and the user's changes on their way there.
///
/// A turn first deletes the rules nobody wants (made for a row removed while their create was on its way), then reads the
/// server's rules into the store (`replaceServerSenderRules`), which also serves as the read before a create, then sends
/// what the user changed on this Mac, oldest first: a rule set (`creating`) or changed (`replacing`) is
/// made to be the one rule the server holds for its sender (an identical rule there is adopted rather than made twice,
/// a new one created and recorded at once, then the old and any conflicting rules for the address deleted), and a rule
/// removed (`deleting`) is deleted. It then says where the rules stand as `AccountSyncStatus.rules`. Only the sender's
/// address and the action reach the provider.
///
/// It keeps no timer. The live lane tells it whenever a full cycle has caught up, and it takes a turn when its last read
/// is half an hour old while the app is frontmost (two hours otherwise), at once when asked (`MailClient.refreshServerRules`,
/// a reconnect for the scope) or when a write waits, and after a failure once its own backoff has passed. As a child of
/// the account's task group it stops with the other lanes, and a slow rules request never holds back a mail poll. It sends
/// nothing while the account is parked (`LaneLink.isParked`).
///
/// Nothing it meets reaches the mail: it never sets the live lane's phase, message or retry time, never touches
/// `permissionsNeeded` (the outbox's), and never parks the account. A token without the rules scope is `.notConnected`
/// and costs no request; the writes wait, and the engine's reconnect asks for the scope while they do. Both providers'
/// rules spend the mail's quota (`ProviderQuota.ruleReadCost` and the rest), so a throttle there pauses the backfill as any
/// live throttle does.
actor RulesLane {
    /// What a failed request means for the turn.
    private enum Failure {
        /// The engine is stopping: nothing failed.
        case cancelled
        /// The token lacks the rules scope: the writes wait for a reconnect that asks for it.
        case notConnected
        /// The server refuses this request for good: a create is given up, a delete or a replacement put back as the
        /// server has it, a read tried again after the backoff.
        case refused(RulesSyncFailure)
        /// Worth trying again after the backoff: the network, the service, a throttle, the token.
        case transient(retryAfter: TimeInterval?, throttled: Bool)
    }

    let accountID: AccountID
    private let store: MailStoring
    private let provider: RuleProvider
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
    /// Reasons for the next turn not to wait for the interval.
    private var readAsked = false
    private var writesQueued = false
    private var failedTurn = false
    /// The token lacked the scope at the last turn: every wake looks again, which costs no request, so a reconnect that
    /// granted it (from whichever path) sends the waiting writes at the next live cycle.
    private var waitingForPermission = false
    /// The other rules the last read in this run counted, for `RulesSyncState.failed`.
    private var lastOtherCount: Int?
    /// Why the last write the server refused for good was given up, said in the status until a later write goes through.
    private var givenUp: RulesSyncFailure?
    /// Tries of writes that failed for a reason of their own, by address: one that fails `SyncTuning.failingPageTries`
    /// times is given up as refused, so one rule the provider keeps failing never holds the others back.
    private var writeTries: [String: Int] = [:]
    /// Rules made or adopted for a row that went while the request was on its way (removed before it reached the server,
    /// or its account removed), or found by a read for a row removed after its create's reply was lost, whose delete has
    /// not gone through yet. A read never writes them into the store.
    private var strays: [String] = []
    /// Creates that failed in a way that may have reached the server (the network or the service failing with the
    /// request sent), by address: the server may hold the rule though the store never heard. If the user removes the row
    /// before the next read, the rule that read finds for the address with that action is nobody's: a stray, deleted,
    /// rather than shown as the server's rule (which would undo the removal).
    private var unansweredCreates: [String: SenderRule.Action] = [:]

    init(
        accountID: AccountID,
        store: MailStoring,
        provider: RuleProvider,
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
        self.clock = tuning.rulesClock
    }

    // MARK: Loop

    nonisolated func wake(_ reason: WakeReason) {
        waker.signal(reason)
    }

    func run() async {
        let id = accountID.rawValue
        SyncLog.logger.info("rules lane started for \(id, privacy: .public)")
        while !Task.isCancelled {
            let reasons = await waker.wait(timeout: nil)
            if Task.isCancelled { break }
            if reasons.contains(.poll) { readAsked = true }
            if reasons.contains(.operations) { writesQueued = true }
            // Parked, the account sends nothing; the live lane's next cycle that catches up wakes this lane again.
            guard !link.isParked, isDue else { continue }
            await turn()
        }
        SyncLog.logger.info("rules lane stopped for \(id, privacy: .public)")
    }

    /// Whether a turn is due now: never inside a failure's backoff; at once when asked, when a write is queued, when a
    /// failed turn waits to be tried again, or while the scope is missing (the look costs nothing); otherwise once the
    /// last read is the interval old (or at the first look).
    private var isDue: Bool {
        let now = clock.uptime()
        if let heldUntil, now < heldUntil { return false }
        if readAsked || writesQueued || failedTurn || waitingForPermission { return true }
        guard let lastTurn else { return true }
        return now - lastTurn >= (isAppActive() ? tuning.rulesActiveInterval : tuning.rulesBackgroundInterval)
    }

    /// One turn: the permission (no request), the read, then the writes waiting. Internal so a test can take one without
    /// the loop.
    func turn() async {
        let asked = readAsked || writesQueued
        lastTurn = clock.uptime()
        readAsked = false
        writesQueued = false
        failedTurn = false
        guard await provider.hasRulesPermission() else {
            // The writes wait as they are, and go out once a reconnect has the scope, each with its tries afresh.
            waitingForPermission = true
            writeTries = [:]
            publish(.notConnected)
            return
        }
        waitingForPermission = false
        if Task.isCancelled { return }
        if !asked {
            // A read nobody asked for is background work: a body the reader is waiting for goes first, for
            // `backgroundYieldLimit` at most. The user's writes and Settings' read do not wait.
            let hold = budget.foreground
            if hold.isActive { await hold.waitUntilIdle(limit: tuning.backgroundYieldLimit) }
            if Task.isCancelled { return }
        }
        // Before the read, which would otherwise find them and could give them to a row (one set again since).
        if let (failure, error) = await deleteStrays() {
            await record(failure, error: error, what: "the delete of a rule nobody wants")
            return
        }
        guard let (listing, readAt) = await read() else { return }
        var server = listing.senderRules
        // Those the read found for rows removed after a lost reply.
        if let (failure, error) = await deleteStrays() {
            await record(failure, error: error, what: "the delete of a rule nobody wants")
            return
        }
        var reported: RulesSyncFailure?
        var wrote = false
        var seen: Set<String> = []
        while true {
            if Task.isCancelled { return }
            let next: SenderRule?
            do {
                next = try store.pendingSenderRules(accountID: accountID).first { !seen.contains($0.address) }
            } catch {
                await record(.transient(retryAfter: nil, throttled: false), error: error, what: "a write")
                return
            }
            guard let row = next else { break }
            seen.insert(row.address)
            do {
                switch row.sync {
                case .creating, .replacing: try await write(row, server: &server)
                case .deleting: try await delete(row, server: &server)
                case .saved: continue
                }
                writeTries[row.address] = nil
                wrote = true
            } catch {
                let failure = Self.failure(of: error)
                switch failure {
                case .cancelled:
                    return
                case .notConnected:
                    await record(failure, error: error, what: "a write")
                    return
                case .refused(let kind):
                    writeTries[row.address] = nil
                    giveUp(row, server: server, error)
                    reported = kind
                case .transient:
                    let tries = (writeTries[row.address] ?? 0) + 1
                    if !Self.failsEveryRequest(error), tries >= tuning.failingPageTries {
                        writeTries[row.address] = nil
                        giveUp(row, server: server, error)
                        reported = .refused
                        continue
                    }
                    // A failure every request would meet is the account's, not the rule's: its tries are not counted.
                    if !Self.failsEveryRequest(error) { writeTries[row.address] = tries }
                    await record(failure, error: error, what: "a write")
                    return
                }
            }
        }
        // A row settled, removed or given up meanwhile holds nothing back.
        writeTries = writeTries.filter { seen.contains($0.key) }
        consecutiveFailures = 0
        heldUntil = nil
        // A rule given up stays said through the reads that follow (Settings opening asks for one, which must not wipe
        // out why the rule it would list is gone), until a later turn sends a write of its own.
        if let reported {
            givenUp = reported
        } else if wrote {
            givenUp = nil
        }
        publish(givenUp.map { .failed($0, otherCount: listing.otherCount) }
            ?? .upToDate(otherCount: listing.otherCount, readAt: readAt))
    }

    // MARK: Read

    /// Reads the server's rules into the store, leaving out the strays (`strays`), which nobody wants: the rules a create
    /// whose reply was lost may have made for a row the user removed since are strays from here. Nil when it failed, which
    /// ends the turn.
    private func read() async -> (ServerRuleListing, Date)? {
        let readAt = clock.now()
        let signposter = SyncLog.signposter
        let interval = signposter.beginInterval("sync.rules", id: signposter.makeSignpostID())
        defer { signposter.endInterval("sync.rules", interval) }
        do {
            var listing = try await provider.serverRules()
            await charge(budget.quota.ruleReadCost * Double(listing.requestCount))
            if !unansweredCreates.isEmpty {
                let rows = Set(try store.senderRules().filter { $0.accountID == accountID }.map(\.address))
                let unwanted = listing.senderRules.filter { rule in
                    !rows.contains(rule.address) && unansweredCreates[rule.address] == rule.action
                }
                strays += unwanted.map(\.serverID).filter { !strays.contains($0) }
            }
            listing.senderRules.removeAll { strays.contains($0.serverID) }
            try store.replaceServerSenderRules(accountID: accountID, with: listing.senderRules, readAt: readAt)
            // Every create unanswered before this read is settled by it: adopted by its row, or a stray.
            unansweredCreates = [:]
            lastOtherCount = listing.otherCount
            SyncLog.logger.debug("rules read for \(self.accountID.rawValue, privacy: .public): \(listing.senderRules.count, privacy: .public) sender rules, \(listing.otherCount, privacy: .public) others, \(listing.requestCount, privacy: .public) requests")
            return (listing, readAt)
        } catch {
            await record(Self.failure(of: error), error: error, what: "the read")
            return nil
        }
    }

    // MARK: Writes

    /// Makes the server hold exactly the row's action for its sender: an identical rule the read found is adopted, or a
    /// new one created and recorded at once (so a removal meanwhile, or a failure deleting the old rules, never leaves it
    /// on the server unknown to the store); then the row's old rules, and any other rule the server holds for the address
    /// with the other action, are deleted, and the row settled.
    private func write(_ row: SenderRule, server: inout [ServerSenderRule]) async throws {
        let entries = server.filter { $0.address == row.address }
        var ids = entries.filter { $0.action == row.action }.map(\.serverID)
        let others = SenderRuleMirror.unique(row.serverIDs + entries.filter { $0.action != row.action }.map(\.serverID))
            .filter { !ids.contains($0) }
        if ids.isEmpty {
            let id: String
            do {
                id = try await provider.createSenderRule(address: row.address, action: row.action)
            } catch {
                if Self.mayHaveCreated(error) { unansweredCreates[row.address] = row.action }
                throw error
            }
            await charge(budget.quota.ruleCreateCost)
            ids = [id]
            server.append(ServerSenderRule(serverID: id, address: row.address, action: row.action))
            let written = SenderRuleOutcome.written(action: row.action, serverIDs: ids, deleted: [])
            guard try store.settleSenderRule(for: row.address, accountID: accountID, written) else {
                try await strand(ids, server: &server)
                return
            }
            if others.isEmpty { return }
        }
        for id in others {
            try await provider.deleteRule(serverID: id)
            await charge(budget.quota.ruleDeleteCost)
            server.removeAll { $0.serverID == id }
        }
        let outcome = SenderRuleOutcome.written(action: row.action, serverIDs: ids, deleted: others)
        guard try store.settleSenderRule(for: row.address, accountID: accountID, outcome) else {
            try await strand(ids, server: &server)
            return
        }
    }

    /// Deletes every rule the server holds for the removed sender: the row's, and any the read found for the address since.
    private func delete(_ row: SenderRule, server: inout [ServerSenderRule]) async throws {
        let ids = SenderRuleMirror.unique(row.serverIDs + server.filter { $0.address == row.address }.map(\.serverID))
        for id in ids {
            try await provider.deleteRule(serverID: id)
            await charge(budget.quota.ruleDeleteCost)
            server.removeAll { $0.serverID == id }
        }
        try store.settleSenderRule(for: row.address, accountID: accountID, .deleted(serverIDs: ids))
    }

    /// Rules written for a row that has gone: deleted now, or at the next turn if that fails.
    private func strand(_ ids: [String], server: inout [ServerSenderRule]) async throws {
        strays += ids
        server.removeAll { ids.contains($0.serverID) }
        if let (_, error) = await deleteStrays() { throw error }
    }

    /// Deletes the rules nobody wants any more. One the provider refuses for good is left on the server, where the next
    /// read shows it as the server's rule; one that fails for a reason of its own is tried again first next turn; a
    /// failure every request would meet is returned.
    private func deleteStrays() async -> (Failure, Error)? {
        while let stray = strays.first {
            do {
                try await provider.deleteRule(serverID: stray)
                await charge(budget.quota.ruleDeleteCost)
            } catch {
                if Self.failsEveryRequest(error) { return (Self.failure(of: error), error) }
                guard case .refused = Self.failure(of: error) else {
                    SyncLog.logger.notice("rules: the delete of a rule nobody wants failed for \(self.accountID.rawValue, privacy: .public), tried again next turn: \(SyncErrorDescription.describe(error), privacy: .private)")
                    return nil
                }
                log(refused: "the delete of a rule nobody wants", error)
            }
            strays.removeFirst()
        }
        return nil
    }

    /// The server will never take this write: a create is given up (the row goes), a delete or a replacement is put back
    /// as the server has it now, folded as a read folds it: the rules this turn's read found for the address, less those
    /// deleted and plus those created since (a replacement's new rule made before the old one's delete was refused), not
    /// only those under the row's ids when the turn began.
    private func giveUp(_ row: SenderRule, server: [ServerSenderRule], _ error: Error) {
        let serverHas = SenderRuleMirror.fold(server.filter { $0.address == row.address })[row.address]?.action
        do {
            try store.settleSenderRule(for: row.address, accountID: accountID, .refused(attempted: row.sync, serverHas: serverHas))
        } catch {
            SyncLog.logger.error("rules: could not record a refusal for \(self.accountID.rawValue, privacy: .public): \(SyncErrorDescription.describe(error), privacy: .private)")
        }
        log(refused: row.sync == .deleting ? "a delete" : "a create", error)
    }

    // MARK: Outcomes

    /// Never longer than the frontmost interval: a read that late is as stale as one that never came.
    private var retryCap: TimeInterval {
        min(tuning.backoffCap, tuning.rulesActiveInterval)
    }

    private func record(_ failure: Failure, error: Error, what: String) async {
        // An error that surfaces while the lane is being stopped is the stop itself.
        guard !Task.isCancelled else { return }
        switch failure {
        case .cancelled:
            return
        case .notConnected:
            waitingForPermission = true
            writeTries = [:]
            publish(.notConnected)
        case .refused, .transient:
            var retryAfter: TimeInterval?
            var throttled = false
            var words = RulesSyncFailure.unreachable
            switch failure {
            case .transient(let after, let wasThrottled):
                retryAfter = after
                throttled = wasThrottled
            case .refused(let kind):
                words = kind
            case .cancelled, .notConnected:
                break
            }
            consecutiveFailures += 1
            // The rules spend the mail's quota, which the backfill spends too.
            if throttled { await budget.liveThrottled(retryAfter: retryAfter) }
            let delay = throttled
                ? Backoff.throttleDelay(retryAfter: retryAfter, attempt: consecutiveFailures, base: tuning.backoffBase, cap: retryCap)
                : Backoff.delay(attempt: consecutiveFailures, base: tuning.backoffBase, cap: retryCap)
            heldUntil = clock.uptime() + delay
            failedTurn = true
            publish(.failed(words, otherCount: lastOtherCount))
            SyncLog.logger.notice("rules: \(what, privacy: .public) failed for \(self.accountID.rawValue, privacy: .public), retrying in \(delay, privacy: .public) s: \(SyncErrorDescription.describe(error), privacy: .private)")
        }
    }

    private static func failure(of error: Error) -> Failure {
        if error is CancellationError { return .cancelled }
        switch error as? RuleProviderError {
        case .permissionMissing?: return .notConnected
        case .limitReached?: return .refused(.limitReached)
        case .refused?: return .refused(.refused)
        case nil: break
        }
        switch error as? ProviderError {
        case .cancelled?:
            return .cancelled
        case .throttled(let retryAfter)?:
            return .transient(retryAfter: retryAfter, throttled: true)
        case .notFound?:
            return .refused(.refused)
        case .server(let status, _)? where (400..<500).contains(status) && status != 408:
            return .refused(.refused)
        default:
            // The network, the service, a reply that did not read (the next read finds a rule a create made), the token
            // (the live lane parks the account if it is refused for mail too), the keychain, the store.
            return .transient(retryAfter: nil, throttled: false)
        }
    }

    /// Whether a create that failed may have made its rule all the same: its request may have reached the server and the
    /// answer been lost (the network, the service, a reply that did not read, the engine stopping meanwhile). Not when the
    /// server answered no (a refusal, a throttle, the token) or nothing was sent (the keychain).
    private static func mayHaveCreated(_ error: Error) -> Bool {
        if error is RuleProviderError || error is AuthError { return false }
        switch error as? ProviderError {
        case .throttled?, .unauthorized?, .notFound?:
            return false
        case .server(let status, _)? where (400..<500).contains(status) && status != 408:
            return false
        default:
            return true
        }
    }

    /// Whether a failed write says something of the account rather than of that one write: every request would meet it
    /// now (the engine stopping, the scope, a throttle, the network, the token, the keychain).
    private static func failsEveryRequest(_ error: Error) -> Bool {
        if error is CancellationError || error is AuthError || error is URLError { return true }
        if case .permissionMissing? = error as? RuleProviderError { return true }
        switch error as? ProviderError {
        case .cancelled?, .throttled?, .network?, .unauthorized?:
            return true
        default:
            return false
        }
    }

    private func charge(_ cost: Double) async {
        guard cost > 0 else { return }
        await budget.recordLive(cost)
    }

    private func publish(_ state: RulesSyncState) {
        statusCenter.update(accountID) { $0.rules = state }
    }

    private func log(refused what: String, _ error: Error) {
        SyncLog.logger.error("rules: the provider refused \(what, privacy: .public) for \(self.accountID.rawValue, privacy: .public): \(SyncErrorDescription.describe(error), privacy: .private)")
    }
}
