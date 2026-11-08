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
        let operations: [Operation]
        do {
            operations = try store.pendingOperations(accountID: accountID, limit: tuning.pendingOperationsFetchLimit)
        } catch {
            SyncLog.logger.error("outbox: could not read pending operations: \(String(describing: error), privacy: .private)")
            return outcome
        }
        guard !operations.isEmpty else { return outcome }

        let now = Date()
        var blocked: Set<MessageID> = []
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
        do {
            var start = 0
            while start < providerIDs.count {
                let end = min(start + tuning.maxApplyTargets, providerIDs.count)
                try await provider.apply(change, to: Array(providerIDs[start..<end]))
                start = end
            }
            for operation in marked {
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
            let count = providerIDs.count
            SyncLog.logger.debug("outbox: applied \(String(describing: change), privacy: .public) to \(count, privacy: .public) messages")
            return .applied
        } catch {
            return record(error, for: marked)
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
