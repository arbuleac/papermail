import Foundation

/// Replays the outbox of one account against its provider.
///
/// Operations go out strictly in creation order. Consecutive operations with the same change share one
/// `apply` call, so archiving twenty conversations costs one request. An operation waiting on a backoff holds
/// back every later operation that touches one of its messages, so the provider never sees a later intent
/// before an earlier one on the same message.
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
        /// When the earliest deferred operation becomes due, so the loop can wake early for it.
        var nextAttemptAt: Date?
        /// Set when the provider throttled an apply. The operations already wait for it; the live lane pauses the
        /// backfill with it, since the outbox spends the same quota.
        var throttle: Throttle?
        /// Permissions the account has not granted that due operations wait for: they stay pending, untried, and the
        /// account asks to reconnect with them. Complete for the operations read, whatever the drain met after.
        var permissionsNeeded: Set<AccountPermission> = []
    }

    private enum GroupResult {
        case applied
        case deferred(Date)
        case throttled(Date, retryAfter: TimeInterval?)
        case uncertain(Date?)
        case needsReauth
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

    private func applyGroups(of eligible: [Operation], into outcome: inout Outcome) async {
        for group in Self.groups(of: eligible, maxTargets: tuning.maxApplyTargets) {
            if Task.isCancelled { break }
            switch await apply(group) {
            case .applied:
                outcome.applied += group.count
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
    private func droppingReplacedAnswers(from operations: [Operation]) -> [Operation] {
        var newest: [MessageID: Int] = [:]
        for (index, operation) in operations.enumerated() where operation.change.kind == .answerInvitation {
            guard operation.targets.count == 1 else { continue }
            newest[operation.targets[0]] = index
        }
        // By the index of the answer that replaces them: the answer the first replaced one replaced, and whether none
        // of them was ever tried.
        var takenOver: [Int: (previous: InvitationResponse?, untried: Bool)] = [:]
        var replaced: [Int: [Operation]] = [:]
        for (index, operation) in operations.enumerated() {
            guard case .answerInvitation(let answer) = operation.change, operation.targets.count == 1,
                  let latest = newest[operation.targets[0]], latest > index else { continue }
            let untried = operation.attempts == 0
            if let carried = takenOver[latest] {
                takenOver[latest] = (carried.previous, carried.untried && untried)
            } else {
                takenOver[latest] = (answer.previous, untried)
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

    private func apply(_ group: [Operation]) async -> GroupResult {
        guard let change = group.first?.change else { return .applied }
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
        var failure: Error?
        var start = 0
        while start < providerIDs.count {
            let end = min(start + tuning.maxApplyTargets, providerIDs.count)
            let slice = Array(providerIDs[start..<end])
            start = end
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
        guard let failure else {
            confirm(marked)
            let count = providerIDs.count
            SyncLog.logger.debug("outbox: applied \(String(describing: change), privacy: .public) to \(count, privacy: .public) messages")
            return .applied
        }
        // What went through is done: an operation keeps only the targets still owed, so a retry sends those alone and a
        // give-up puts back only those. One with none left is confirmed.
        let owed = Set(unapplied)
        var settled: [Operation] = []
        var narrowed: [Operation] = []
        for operation in marked {
            let left = operation.targets.filter { owed.contains($0.providerID) }
            if left.isEmpty {
                settled.append(operation)
            } else {
                var remaining = operation
                remaining.targets = left
                narrowed.append(remaining)
            }
        }
        confirm(settled)
        guard !narrowed.isEmpty else { return .applied }
        return record(failure, for: narrowed)
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
        // Each operation keeps its own history: a fresh one that shared the request with an old one must not
        // inherit the old one's backoff, nor be given up after its first try.
        for var operation in operations {
            switch error as? ProviderError {
            case .throttled(let retryAfter):
                operation.status = .pending
                operation.nextAttemptAt = now.addingTimeInterval(Backoff.throttleDelay(
                    retryAfter: retryAfter, attempt: operation.attempts, base: tuning.backoffBase, cap: tuning.userRetryAfterCap
                ))
            case .network:
                operation.status = .pending
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
            do {
                try store.updateOperation(operation)
            } catch {
                SyncLog.logger.error("outbox: could not record failure: \(String(describing: error), privacy: .private)")
            }
        }
        let count = operations.count
        SyncLog.logger.error("outbox: apply failed for \(count, privacy: .public) operations, \(givenUp, privacy: .public) given up: \(description, privacy: .private)")
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

    private func backoff(for operation: Operation) -> TimeInterval {
        Backoff.delay(attempt: operation.attempts, base: tuning.backoffBase, cap: tuning.backoffCap)
    }

    fileprivate static func earlier(_ a: Date?, _ b: Date) -> Date {
        guard let a else { return b }
        return min(a, b)
    }
}
