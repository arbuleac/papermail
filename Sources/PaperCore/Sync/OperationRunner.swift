import Foundation

/// Replays the outbox of one account against its provider.
///
/// Operations go out strictly in creation order. Consecutive operations with the same change share one
/// `apply` call, so archiving twenty conversations costs one request. An operation waiting on a backoff holds
/// back every later operation that touches one of its messages, so the provider never sees a later intent
/// before an earlier one on the same message. One drain makes at most `SyncTuning.maxApplyCallsPerDrain` calls: an
/// operation with thousands of targets is narrowed to what is left and goes on next cycle, after the account's poll,
/// so it never keeps new mail waiting.
///
/// Unsubscribe requests (`MetadataChange.unsubscribe`) are no change to the provider's mail: they go after the rest,
/// each on its own (`Unsubscriber`), and neither wait behind nor hold back anything. One the sender refuses, or one
/// that keeps failing, is dropped quietly: the conversation's archive beside it has already gone its own way, and the
/// request is not something the row can show as failed.
struct OperationRunner: Sendable {
    struct Outcome: Sendable {
        /// A throttled apply, and the retry time the provider named, if any.
        struct Throttle: Sendable, Equatable {
            var retryAfter: TimeInterval?
        }

        var applied = 0
        /// The provider rejected the token; the syncer must stop and wait for the user.
        var needsReauth = false
        /// The keychain refused the token (with `needsReauth`): the syncer parks with the keychain's message, before
        /// anything else asks the keychain again.
        var keychainDenial: AuthError?
        /// When the earliest deferred operation becomes due, so the loop can wake early for it.
        var nextAttemptAt: Date?
        /// Set when the provider throttled an apply. The operations already wait for it; the live lane pauses the
        /// backfill with it, since the outbox spends the same quota.
        var throttle: Throttle?
        /// Permissions the account has not granted that due operations wait for: they stay pending, untried, and the
        /// account asks to reconnect with them. Complete for the operations read, whatever the drain met after.
        var permissionsNeeded: Set<AccountPermission> = []
        /// An answer to an invitation went out: the calendar's copy of it says so from now on.
        var answeredInvitation = false
    }

    private enum GroupResult {
        case applied
        /// The drain's calls ran out part-way: what went out is settled, and the operations keep the rest, due at once.
        case paused
        case deferred(Date)
        case throttled(Date, retryAfter: TimeInterval?)
        case uncertain(Date?)
        case needsReauth
        case keychainDenied(AuthError)
    }

    let accountID: AccountID
    let store: MailStoring
    let provider: MailProvider
    let tuning: SyncTuning
    var unsubscriber = Unsubscriber()

    /// Applies every due operation in order and stops at the first failure, leaving the rest for later.
    func drain() async -> Outcome {
        var outcome = Outcome()
        // Expired failures go first: pruning is what clears a conversation's failed mark after a day, and the
        // outbox is drained on every cycle, so the mark never outlives its expiry by more than a poll.
        do {
            try store.pruneFailedOperations(accountID: accountID, now: Date())
        } catch {
            SyncLog.logger.error("outbox: could not prune failed operations: \(String(describing: error), privacy: .private)")
        }
        let fetched: [Operation]
        do {
            fetched = try store.pendingOperations(accountID: accountID, limit: tuning.pendingOperationsFetchLimit)
        } catch {
            SyncLog.logger.error("outbox: could not read pending operations: \(String(describing: error), privacy: .private)")
            return outcome
        }
        let operations = droppingReplacedAnswers(from: fetched)
        guard !operations.isEmpty else { return outcome }

        let now = Date()
        var blocked: Set<MessageID> = []
        // The messages of operations waiting for the user's permission, by kind. Such a wait lasts until the user
        // reconnects, perhaps never, so it holds back only later operations of its own kind on those messages (a
        // second answer is never heard before the first, even if the grant lands mid-drain). An archive, a trash or a
        // read change goes on: an answer never moves the message (Gmail answers by UID, Graph by the event).
        var waitingForPermission: [OperationKind: Set<MessageID>] = [:]
        var eligible: [Operation] = []
        var requests: [Operation] = []
        for operation in operations {
            if case .unsubscribe = operation.change {
                if let nextAttemptAt = operation.nextAttemptAt, nextAttemptAt > now {
                    outcome.nextAttemptAt = Self.earlier(outcome.nextAttemptAt, nextAttemptAt)
                } else {
                    requests.append(operation)
                }
                continue
            }
            if let nextAttemptAt = operation.nextAttemptAt, nextAttemptAt > now {
                blocked.formUnion(operation.targets)
                outcome.nextAttemptAt = Self.earlier(outcome.nextAttemptAt, nextAttemptAt)
                continue
            }
            if operation.targets.contains(where: blocked.contains) {
                blocked.formUnion(operation.targets)
                continue
            }
            let kind = OperationKind(operation.change)
            if let waiting = waitingForPermission[kind], operation.targets.contains(where: waiting.contains) {
                waitingForPermission[kind, default: []].formUnion(operation.targets)
                continue
            }
            // Asked without a request: an operation waiting for the user's permission is never tried, so it spends no
            // attempt and is never given up.
            if let permission = await provider.missingPermission(for: operation.change) {
                outcome.permissionsNeeded.insert(permission)
                waitingForPermission[kind, default: []].formUnion(operation.targets)
                continue
            }
            eligible.append(operation)
        }

        await applyGroups(of: eligible, into: &outcome)
        // After the provider's operations, so a slow sender's server never holds back the archive queued beside it.
        for operation in requests {
            if Task.isCancelled || outcome.needsReauth { break }
            await send(operation, into: &outcome)
        }
        return outcome
    }

    /// The targets one provider call carries: the provider's own limit, within the tuning's.
    private var callTargets: Int {
        max(1, min(tuning.maxApplyTargets, provider.maxApplyTargets))
    }

    private func applyGroups(of eligible: [Operation], into outcome: inout Outcome) async {
        // Calls left in this drain (`SyncTuning.maxApplyCallsPerDrain`). Once they are spent the operations after wait for
        // the next cycle, which comes at once, after the poll when one is due: strict order holds across cycles too.
        var calls = max(1, tuning.maxApplyCallsPerDrain)
        for group in Self.groups(of: eligible, maxTargets: callTargets) {
            if Task.isCancelled { break }
            guard calls > 0 else {
                outcome.nextAttemptAt = Self.earlier(outcome.nextAttemptAt, Date())
                return
            }
            switch await apply(group, calls: &calls) {
            case .applied:
                outcome.applied += group.count
                if group.contains(where: { $0.change.kind == .answerInvitation }) { outcome.answeredInvitation = true }
            case .paused:
                outcome.nextAttemptAt = Self.earlier(outcome.nextAttemptAt, Date())
                return
            case .deferred(let until):
                // The provider is unhappy; later operations would fail the same way and must keep their order.
                outcome.nextAttemptAt = Self.earlier(outcome.nextAttemptAt, until)
                return
            case .throttled(let until, let retryAfter):
                outcome.nextAttemptAt = Self.earlier(outcome.nextAttemptAt, until)
                outcome.throttle = Outcome.Throttle(retryAfter: retryAfter)
                return
            case .uncertain(let until):
                if let until { outcome.nextAttemptAt = Self.earlier(outcome.nextAttemptAt, until) }
                return
            case .needsReauth:
                outcome.needsReauth = true
                return
            case .keychainDenied(let denial):
                outcome.needsReauth = true
                outcome.keychainDenial = denial
                return
            }
        }
    }

    // MARK: Unsubscribe requests

    /// Sends one unsubscribe request. Written ahead as "retry after the backoff", like `apply`'s operations, so a crash
    /// mid-request leaves a row the next launch sends again: an unsubscribe asked twice is harmless. The one-click POST
    /// goes to a server nobody vouches for, so it runs off this cycle (`Unsubscriber.detach`) and a slow one never
    /// holds back the poll; its row is written ahead past the request's whole timeout, so no later drain sends it
    /// twice. The mailto request is the provider's own send, waited for like any other provider call.
    private func send(_ operation: Operation, into outcome: inout Outcome) async {
        guard case .unsubscribe(let method) = operation.change else { return }
        var operation = operation
        operation.status = .pending
        operation.attempts += 1
        operation.nextAttemptAt = Date().addingTimeInterval(backoff(for: operation))
        switch method {
        case .oneClick(let url):
            // The demo's senders are made up and have no server: nothing leaves this Mac for them.
            if provider is DemoMailProvider {
                Self.record(.sent, for: operation, store: store, tuning: tuning).apply(to: &outcome)
                return
            }
            operation.nextAttemptAt = operation.nextAttemptAt?.addingTimeInterval(Unsubscriber.resourceTimeout)
            Self.save(operation, store: store)
            let (store, tuning, unsubscriber) = (store, tuning, unsubscriber)
            let written = operation
            unsubscriber.detach(operation.id) {
                let result = await unsubscriber.postOneClick(to: url)
                _ = Self.record(result, for: written, store: store, tuning: tuning)
            }
            if let next = operation.nextAttemptAt { outcome.nextAttemptAt = Self.earlier(outcome.nextAttemptAt, next) }
        case .mailto:
            Self.save(operation, store: store)
            let result = await unsubscriber.sendMail(method, from: accountID, via: provider)
            Self.record(result, for: operation, store: store, tuning: tuning).apply(to: &outcome)
        case .browser:
            // The app opens a page itself and never queues one; a row that says otherwise has nothing to send.
            Self.record(.refused("a page, not a request"), for: operation, store: store, tuning: tuning).apply(to: &outcome)
        }
    }

    /// What a request's result asks of the cycle that sent it: a detached POST's is dropped, since its cycle has moved on.
    private struct RequestEffect {
        var applied = 0
        var needsReauth = false
        var throttle: Outcome.Throttle?
        var nextAttemptAt: Date?

        func apply(to outcome: inout Outcome) {
            outcome.applied += applied
            if needsReauth { outcome.needsReauth = true }
            if let throttle { outcome.throttle = throttle }
            if let nextAttemptAt { outcome.nextAttemptAt = OperationRunner.earlier(outcome.nextAttemptAt, nextAttemptAt) }
        }
    }

    /// Writes what became of a request: confirmed when it went; deleted, quietly, when the sender or the provider
    /// refused it or a failing server used up its attempts; otherwise kept for another try. Never written as failed:
    /// that would mark the conversation with a failure the user can do nothing about, and give back nothing, since the
    /// request changed nothing locally.
    private static func record(_ result: Unsubscriber.Outcome, for operation: Operation, store: MailStoring,
                               tuning: SyncTuning) -> RequestEffect {
        guard case .unsubscribe(let method) = operation.change else { return RequestEffect() }
        SyncLog.logger.debug("unsubscribe: \(String(describing: result), privacy: .public) for \(method.url.absoluteString, privacy: .private)")
        var operation = operation
        var effect = RequestEffect()
        switch result {
        case .sent:
            settle(operation, dropped: false, store: store)
            effect.applied = 1
        case .refused(let reason):
            // Asking again would get the same answer.
            SyncLog.logger.notice("unsubscribe: request refused (\(reason, privacy: .public)), dropped")
            settle(operation, dropped: true, store: store)
        case .needsReauth:
            operation.nextAttemptAt = nil
            operation.lastError = SyncErrorDescription.describe(ProviderError.unauthorized)
            save(operation, store: store)
            effect.needsReauth = true
        case .retry(let counted, let retryAfter):
            if counted, operation.attempts >= tuning.maxOperationAttempts {
                SyncLog.logger.notice("unsubscribe: request failed \(operation.attempts, privacy: .public) times, dropped")
                settle(operation, dropped: true, store: store)
                return effect
            }
            operation.nextAttemptAt = Date().addingTimeInterval(retryAfter.map {
                Backoff.throttleDelay(retryAfter: $0, attempt: operation.attempts, base: tuning.backoffBase, cap: tuning.userRetryAfterCap)
            } ?? Backoff.delay(attempt: operation.attempts, base: tuning.backoffBase, cap: tuning.backoffCap))
            // A throttle on the mailto send spends the same quota as the backfill, which pauses for it.
            if let retryAfter, case .mailto = method { effect.throttle = Outcome.Throttle(retryAfter: retryAfter) }
            operation.lastError = counted ? "unsubscribe request failed" : "unsubscribe request waiting"
            save(operation, store: store)
            effect.nextAttemptAt = operation.nextAttemptAt
        }
        return effect
    }

    private static func settle(_ operation: Operation, dropped: Bool, store: MailStoring) {
        do {
            if dropped {
                try store.deleteOperation(id: operation.id)
            } else {
                try store.confirmOperation(id: operation.id)
            }
        } catch {
            SyncLog.logger.error("unsubscribe: could not settle the request: \(String(describing: error), privacy: .private)")
        }
    }

    private static func save(_ operation: Operation, store: MailStoring) {
        do {
            try store.updateOperation(operation)
        } catch {
            SyncLog.logger.error("unsubscribe: could not record the attempt: \(String(describing: error), privacy: .private)")
        }
    }

    /// The organizer hears only the user's latest answer to an invitation, never each one they changed their mind
    /// through while an earlier one waited (for the permission, a backoff, the network). So an answer that a newer
    /// answer to the same message replaces is dropped before anything is sent: deleted, which keeps the local answer
    /// (the newer one's). Dropping it is right whether or not it went out, since the newer answer is what must reach
    /// the organizer last either way. The newest takes over the answer the first dropped one replaced
    /// (`InvitationAnswer.previous`), so a give-up still puts back the last one recorded before this run of changes.
    /// When nothing dropped was ever tried and the newest repeats that answer, the organizer already has it, so the
    /// newest goes too. An answer names one message (`MailEngine.answerInvitation`).
    ///
    /// The newest is saved first and the dropped ones deleted after it: an interruption in between leaves an outbox
    /// the next drain prunes the same way, never a lone stale answer. A write that fails keeps that operation queued.
    /// What an answer answers, for `droppingReplacedAnswers`: its one message, or with none (given from the calendar)
    /// the provider's event. Nil for an answer neither names, which is never dropped.
    static func answerKey(of operation: Operation) -> String? {
        guard case .answerInvitation(let answer) = operation.change else { return nil }
        if operation.targets.count == 1 {
            let target = operation.targets[0]
            return "mail|" + target.accountID.rawValue + "|" + target.providerID
        }
        if operation.targets.isEmpty, let event = answer.calendar?.providerEventID {
            return "calendar|" + event
        }
        return nil
    }

    private func droppingReplacedAnswers(from operations: [Operation]) -> [Operation] {
        var newest: [String: Int] = [:]
        for (index, operation) in operations.enumerated() {
            guard let key = Self.answerKey(of: operation) else { continue }
            newest[key] = index
        }
        // By the index of the answer that replaces them: the answer the first replaced one replaced, what each calendar
        // row said before the first answer that recorded it, and whether none of them was ever tried.
        var takenOver: [Int: (previous: InvitationResponse?, rows: [String: CalendarEvent.Response], untried: Bool)] = [:]
        var replaced: [Int: [Operation]] = [:]
        for (index, operation) in operations.enumerated() {
            guard case .answerInvitation(let answer) = operation.change, let key = Self.answerKey(of: operation),
                  let latest = newest[key], latest > index else { continue }
            let untried = operation.attempts == 0
            if var carried = takenOver[latest] {
                for (row, said) in answer.calendar?.previous ?? [:] where carried.rows[row] == nil { carried.rows[row] = said }
                carried.untried = carried.untried && untried
                takenOver[latest] = carried
            } else {
                takenOver[latest] = (answer.previous, answer.calendar?.previous ?? [:], untried)
            }
            replaced[latest, default: []].append(operation)
        }
        guard !replaced.isEmpty else { return operations }

        var removed: Set<String> = []
        var rewritten: [String: Operation] = [:]
        for (latest, carried) in takenOver.sorted(by: { $0.key < $1.key }) {
            guard case .answerInvitation(var answer) = operations[latest].change else { continue }
            var survivor = operations[latest]
            answer.previous = carried.previous
            if var copies = answer.calendar {
                // A give-up puts back what each row said before this run of changes, not what a dropped answer wrote.
                for (row, said) in carried.rows { copies.previous[row] = said }
                answer.calendar = copies
            }
            survivor.change = .answerInvitation(answer)
            do {
                try store.updateOperation(survivor)
            } catch {
                // Without the answer it replaced on the newest, a give-up would restore one that never went out.
                SyncLog.logger.error("outbox: could not take over a replaced answer: \(String(describing: error), privacy: .private)")
                continue
            }
            rewritten[survivor.id] = survivor
            var deletedAll = true
            for old in replaced[latest] ?? [] {
                do {
                    try store.deleteOperation(id: old.id)
                    removed.insert(old.id)
                } catch {
                    deletedAll = false
                    SyncLog.logger.error("outbox: could not drop a replaced answer: \(String(describing: error), privacy: .private)")
                }
            }
            guard deletedAll, carried.untried, survivor.attempts == 0, answer.response == carried.previous else { continue }
            do {
                try store.deleteOperation(id: survivor.id)
                removed.insert(survivor.id)
            } catch {
                SyncLog.logger.error("outbox: could not drop a repeated answer: \(String(describing: error), privacy: .private)")
            }
        }
        let count = removed.count
        SyncLog.logger.debug("outbox: dropped \(count, privacy: .public) replaced answers")
        return operations.compactMap { removed.contains($0.id) ? nil : (rewritten[$0.id] ?? $0) }
    }

    /// Adjacent operations with the same change are merged while their distinct targets fit one apply call.
    /// An operation larger than the limit forms its own group and is chunked when applied.
    static func groups(of operations: [Operation], maxTargets: Int) -> [[Operation]] {
        var groups: [[Operation]] = []
        var currentTargets: Set<String> = []
        for operation in operations {
            let targets = Set(operation.targets.map(\.providerID))
            if let first = groups.last?.first, first.change == operation.change,
               currentTargets.union(targets).count <= maxTargets {
                groups[groups.count - 1].append(operation)
                currentTargets.formUnion(targets)
            } else {
                groups.append([operation])
                currentTargets = targets
            }
        }
        return groups
    }

    private func apply(_ group: [Operation], calls: inout Int) async -> GroupResult {
        guard let change = group.first?.change else { return .applied }
        // An answer given from the calendar names no message: it is sent once, on the provider's event, as an
        // unsubscribe is sent with no target. Any other operation with no target (one queued before 1.22) is done.
        if group.allSatisfy({ $0.targets.isEmpty }) {
            guard case .answerInvitation(let answer) = change, answer.calendar?.providerEventID != nil else {
                confirm(group)
                return .applied
            }
            return await applyCalendarAnswer(group, change: change, calls: &calls)
        }
        var providerIDs: [String] = []
        var seen: Set<String> = []
        for operation in group {
            for target in operation.targets where seen.insert(target.providerID).inserted {
                providerIDs.append(target.providerID)
            }
        }
        var marked: [Operation] = []
        for var operation in group {
            // Written ahead of the request as "may have landed, retry after the backoff": a crash during the
            // request then leaves a row the next launch replays (apply is idempotent) and a poll can settle,
            // rather than one parked in `inFlight`, which `pendingOperations` never returns.
            operation.status = .uncertain
            operation.attempts += 1
            operation.nextAttemptAt = Date().addingTimeInterval(backoff(for: operation))
            do {
                try store.updateOperation(operation)
            } catch {
                SyncLog.logger.error("outbox: could not mark operation in flight: \(String(describing: error), privacy: .private)")
            }
            marked.append(operation)
        }
        // Slice by slice, and past a slice the provider refused in part or whole: one message it will not change must not
        // keep the others from going out, on this attempt or on every retry. Only a failure every request would meet
        // (a throttle, a refused token, the network, a cancellation) leaves the slices after it unsent.
        var unapplied: [String] = []
        // Targets never sent because the drain's calls ran out.
        var unsent: [String] = []
        var failure: Error?
        var start = 0
        while start < providerIDs.count {
            guard calls > 0 else {
                unsent = Array(providerIDs[start...])
                break
            }
            let end = min(start + callTargets, providerIDs.count)
            let slice = Array(providerIDs[start..<end])
            start = end
            calls -= 1
            let error: Error
            do {
                try await provider.apply(change, to: slice)
                continue
            } catch let partial as PartialApplyError {
                unapplied += partial.unapplied
                error = partial.error
            } catch let whole {
                unapplied += slice
                error = whole
            }
            guard Self.failsEveryRequest(error) else {
                failure = failure ?? error
                continue
            }
            failure = error
            unapplied += providerIDs[start...]
            break
        }
        guard failure != nil || !unsent.isEmpty else {
            confirm(marked)
            let count = providerIDs.count
            SyncLog.logger.debug("outbox: applied \(String(describing: change), privacy: .public) to \(count, privacy: .public) messages")
            return .applied
        }
        // What went through is done: an operation keeps only the targets still owed, so a retry sends those alone and a
        // give-up puts back only those. One with none left is confirmed.
        let owed = Set(unapplied + unsent)
        let refused = Set(unapplied)
        var settled: [Operation] = []
        var narrowed: [Operation] = []
        for operation in marked {
            let left = operation.targets.filter { owed.contains($0.providerID) }
            if left.isEmpty {
                settled.append(operation)
            } else {
                var remaining = operation
                // Those never sent go first and those refused last, so each attempt reaches targets the one before did
                // not, and a target the provider keeps refusing never holds back the rest from going out.
                remaining.targets = unsent.isEmpty ? left
                    : left.filter { !refused.contains($0.providerID) } + left.filter { refused.contains($0.providerID) }
                narrowed.append(remaining)
            }
        }
        confirm(settled)
        guard !narrowed.isEmpty else { return .applied }
        // A refusal counts as the attempt it was, the rest waiting out its backoff with it.
        if let failure { return record(failure, for: narrowed) }
        // The drain's share of calls is spent, not an attempt: the rest goes on the next cycle, at once.
        let sent = providerIDs.count - unsent.count
        SyncLog.logger.debug("outbox: sent \(sent, privacy: .public) of \(providerIDs.count, privacy: .public) targets, the rest next cycle")
        let writtenAhead = narrowed.compactMap(\.nextAttemptAt).min()
        var persisted = true
        for var operation in narrowed {
            operation.status = .pending
            operation.attempts = max(0, operation.attempts - 1)
            operation.nextAttemptAt = nil
            if !save(recorded: operation) { persisted = false }
        }
        // Unwritten, the rows still list what went out and the next drain would send those first calls again, never the
        // rest: a store that cannot write waits out the write-ahead's backoff instead of being drained again at once.
        guard persisted else { return .deferred(writtenAhead ?? Date()) }
        return .paused
    }

    /// Sends an answer with no message: one provider call, written ahead as every apply is, its failure recorded as an
    /// apply's (a gone event is given up at once and its rows put back; a throttle or the network waits).
    private func applyCalendarAnswer(_ group: [Operation], change: MetadataChange, calls: inout Int) async -> GroupResult {
        guard calls > 0 else { return .paused }
        var marked: [Operation] = []
        for var operation in group {
            operation.status = .uncertain
            operation.attempts += 1
            operation.nextAttemptAt = Date().addingTimeInterval(backoff(for: operation))
            do {
                try store.updateOperation(operation)
            } catch {
                SyncLog.logger.error("outbox: could not mark an answer in flight: \(String(describing: error), privacy: .private)")
            }
            marked.append(operation)
        }
        calls -= 1
        do {
            try await provider.apply(change, to: [])
        } catch {
            return record(error, for: marked)
        }
        confirm(marked)
        SyncLog.logger.debug("outbox: answered an event with no message")
        return .applied
    }

    private func confirm(_ operations: [Operation]) {
        for operation in operations {
            do {
                try store.confirmOperation(id: operation.id)
            } catch {
                // The provider has the change; an uncertain row lets the next poll settle the local copy.
                var settled = operation
                settled.status = .uncertain
                settled.lastError = String(describing: error)
                try? store.updateOperation(settled)
            }
        }
    }

    /// A failure the next request would meet too, after which the rest of an apply is not sent.
    static func failsEveryRequest(_ error: Error) -> Bool {
        if error is CancellationError || error is AuthError { return true }
        switch error as? ProviderError {
        case .throttled?, .unauthorized?, .network?, .cancelled?: return true
        default: return false
        }
    }

    private func record(_ error: Error, for operations: [Operation]) -> GroupResult {
        let description = SyncErrorDescription.describe(error)
        let now = Date()
        var earliest: Date?
        var givenUp = 0
        let authError = error as? AuthError
        // Each operation keeps its own history: a fresh one that shared the request with an old one must not
        // inherit the old one's backoff, nor be given up after its first try.
        for var operation in operations {
            if let authError {
                // The token could not be had (the keychain refused, the token endpoint failed): no request left this
                // Mac, so the change cannot have landed and the attempt does not count. A refused keychain waits for
                // the user, as a refused token does; anything else is retried on the backoff, never given up.
                operation.status = .pending
                if authError.isKeychainDenial {
                    operation.attempts = max(0, operation.attempts - 1)
                    operation.nextAttemptAt = nil
                } else {
                    operation.attempts = min(operation.attempts, attemptsAtBackoffCap)
                    operation.nextAttemptAt = now.addingTimeInterval(backoff(for: operation))
                }
                operation.lastError = description
                if let next = operation.nextAttemptAt { earliest = Self.earlier(earliest, next) }
                save(recorded: operation)
                continue
            }
            switch error as? ProviderError {
            case .throttled(let retryAfter):
                // Waiting out the provider says nothing about the change: the count stops where the backoff reaches
                // its cap, so the give-up's attempts are left for failures that reached it.
                operation.status = .pending
                operation.attempts = min(operation.attempts, attemptsAtBackoffCap)
                operation.nextAttemptAt = now.addingTimeInterval(Backoff.throttleDelay(
                    retryAfter: retryAfter, attempt: operation.attempts, base: tuning.backoffBase, cap: tuning.userRetryAfterCap
                ))
            case .network:
                // Offline for an hour and a half, a count that kept growing would give the change up at the first
                // server error once the network was back. The backoff still grows to its cap.
                operation.status = .pending
                operation.attempts = min(operation.attempts, attemptsAtBackoffCap)
                operation.nextAttemptAt = now.addingTimeInterval(backoff(for: operation))
            case .unauthorized:
                operation.status = .pending
                operation.nextAttemptAt = nil
            case .notFound where operation.change.kind == .answerInvitation:
                // The event, or the message naming it, is gone and the provider said nothing went out (a provider that
                // calls a vanished target done returns normally instead). No retry can answer it, so it is given up
                // now: the card puts the previous answer back and the conversation shows the failure.
                operation.status = .failed
                operation.nextAttemptAt = now.addingTimeInterval(tuning.failedOperationRetention)
                givenUp += 1
            default:
                // Timeouts, server errors, decoding failures, cancellation: the provider may or may not have
                // applied the change. The row stays so local state keeps winning until a poll settles it, and
                // is retried later because `apply` is idempotent; after too many attempts it is given up.
                if operation.attempts >= tuning.maxOperationAttempts {
                    // A failed row is never tried again; its next_attempt_at is when it is pruned instead.
                    // Writing it failed also puts its targets back the way they were (`updateOperation`).
                    operation.status = .failed
                    operation.nextAttemptAt = now.addingTimeInterval(tuning.failedOperationRetention)
                    givenUp += 1
                } else {
                    operation.status = .uncertain
                    operation.nextAttemptAt = now.addingTimeInterval(backoff(for: operation))
                }
            }
            operation.lastError = description
            if operation.status != .failed, let next = operation.nextAttemptAt { earliest = Self.earlier(earliest, next) }
            save(recorded: operation)
        }
        let count = operations.count
        SyncLog.logger.error("outbox: apply failed for \(count, privacy: .public) operations, \(givenUp, privacy: .public) given up: \(description, privacy: .private)")
        if let authError {
            return authError.isKeychainDenial ? .keychainDenied(authError) : .deferred(earliest ?? now)
        }
        switch error as? ProviderError {
        case .throttled(let retryAfter):
            return .throttled(earliest ?? now, retryAfter: retryAfter)
        case .network:
            return .deferred(earliest ?? now)
        case .unauthorized:
            return .needsReauth
        default:
            return .uncertain(earliest)
        }
    }

    /// Whether the store took the write.
    @discardableResult
    private func save(recorded operation: Operation) -> Bool {
        do {
            try store.updateOperation(operation)
            return true
        } catch {
            SyncLog.logger.error("outbox: could not record the attempt: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    private func backoff(for operation: Operation) -> TimeInterval {
        Backoff.delay(attempt: operation.attempts, base: tuning.backoffBase, cap: tuning.backoffCap)
    }

    /// The attempt at which the backoff reaches its cap: where the count stops on failures that did not reach the
    /// provider (the network, a throttle, a token that could not be had), so they keep the longest wait without using
    /// up the attempts a give-up counts.
    private var attemptsAtBackoffCap: Int {
        var attempt = 1
        while attempt < 31, Backoff.delay(attempt: attempt, base: tuning.backoffBase, cap: tuning.backoffCap) < tuning.backoffCap {
            attempt += 1
        }
        return attempt
    }

    fileprivate static func earlier(_ a: Date?, _ b: Date) -> Date {
        guard let a else { return b }
        return min(a, b)
    }
}
