import Foundation

/// Replays the outbox of one account against its provider.
///
/// Operations go out strictly in creation order. Consecutive operations with the same change share one
/// `apply` call, so archiving twenty conversations costs one request. An operation waiting on a backoff holds
/// back every later operation that touches one of its messages, so the provider never sees a later intent
/// before an earlier one on the same message.
struct OperationRunner: Sendable {
    struct Outcome: Sendable {
        var applied = 0
        /// The provider rejected the token; the syncer must stop and wait for the user.
        var needsReauth = false
        /// When the earliest deferred operation becomes due, so the loop can wake early for it.
        var nextAttemptAt: Date?
    }

    private enum GroupResult {
        case applied
        case deferred(Date)
        case uncertain(Date?)
        case needsReauth
    }

    let accountID: AccountID
    let store: MailStoring
    let provider: MailProvider
    let tuning: SyncTuning

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
        for operation in operations {
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

        for group in Self.groups(of: eligible, maxTargets: tuning.maxApplyTargets) {
            if Task.isCancelled { break }
            switch await apply(group) {
            case .applied:
                outcome.applied += group.count
            case .deferred(let until):
                // The provider is unhappy; later operations would fail the same way and must keep their order.
                outcome.nextAttemptAt = Self.earlier(outcome.nextAttemptAt, until)
                return outcome
            case .uncertain(let until):
                if let until { outcome.nextAttemptAt = Self.earlier(outcome.nextAttemptAt, until) }
                return outcome
            case .needsReauth:
                outcome.needsReauth = true
                return outcome
            }
        }
        return outcome
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
        case .throttled, .network:
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

    private static func earlier(_ a: Date?, _ b: Date) -> Date {
        guard let a else { return b }
        return min(a, b)
    }
}
