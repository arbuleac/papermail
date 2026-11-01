import Foundation

/// Fetches the bodies the store is missing for one account, sanitizes each once and stores it render-ready.
///
/// Hydration runs after every bootstrap page and every poll in batches with a bounded number of fetches in
/// flight. `ensureBody` serves the UI's on-demand path through the same in-flight table, so a body being
/// hydrated and a body being opened never fetch twice.
actor Hydrator {
    struct Outcome: Sendable {
        var fetched = 0
        var failed = 0
        /// An error that stops hydration for the whole account (auth, throttling); the syncer decides what to do.
        var blocking: ProviderError?
    }

    private let accountID: AccountID
    private let store: MailStoring
    private let provider: MailProvider
    private let sanitizer: BodySanitizing
    private let tuning: SyncTuning
    private var inFlight: [MessageID: Task<StoredBody, Error>] = [:]
    /// Bodies whose fetch failed for a reason a retry will not fix soon (decoding, not found, server errors)
    /// wait here so they do not occupy the whole batch on every poll.
    private var retryAfter: [MessageID: Date] = [:]

    init(accountID: AccountID, store: MailStoring, provider: MailProvider, sanitizer: BodySanitizing, tuning: SyncTuning) {
        self.accountID = accountID
        self.store = store
        self.provider = provider
        self.sanitizer = sanitizer
        self.tuning = tuning
    }

    /// Fetches one batch of missing bodies, newest inbox messages first, with bounded concurrency.
    func hydrateBatch() async -> Outcome {
        let now = Date()
        retryAfter = retryAfter.filter { $0.value > now }
        let candidates: [MessageID]
        do {
            // Ask for a little more than one batch so deferred failures do not crowd out fetchable bodies.
            let limit = tuning.hydrationBatchSize + min(retryAfter.count, tuning.hydrationBatchSize * 9)
            candidates = try store.messageIDsMissingBodies(accountID: accountID, limit: limit)
        } catch {
            SyncLog.logger.error("hydration: store read failed: \(String(describing: error), privacy: .private)")
            return Outcome()
        }
        let ids = Array(candidates.filter { retryAfter[$0] == nil && inFlight[$0] == nil }.prefix(tuning.hydrationBatchSize))
        guard !ids.isEmpty else { return Outcome() }

        var outcome = Outcome()
        await withTaskGroup(of: (MessageID, Error?).self) { group in
            var iterator = ids.makeIterator()
            var stopLaunching = false
            for _ in 0..<max(1, tuning.hydrationConcurrency) {
                guard let id = iterator.next() else { break }
                addFetch(of: id, to: &group)
            }
            for await (id, error) in group {
                if let error {
                    outcome.failed += 1
                    if let blocking = Self.blockingError(error) {
                        if outcome.blocking == nil { outcome.blocking = blocking }
                        stopLaunching = true
                    } else if Self.deservesDeferral(error) {
                        retryAfter[id] = Date().addingTimeInterval(tuning.hydrationRetryDelay)
                    }
                } else {
                    outcome.fetched += 1
                }
                if !stopLaunching, !Task.isCancelled, let next = iterator.next() {
                    addFetch(of: next, to: &group)
                }
            }
        }
        let fetched = outcome.fetched
        let failed = outcome.failed
        SyncLog.logger.debug("hydration: fetched \(fetched, privacy: .public), failed \(failed, privacy: .public)")
        return outcome
    }

    /// The stored body, fetched and sanitized first when missing. Concurrent callers share one fetch.
    func ensureBody(for id: MessageID) async throws -> StoredBody {
        if let stored = try store.body(for: id) { return stored }
        return try await fetchTask(for: id).value
    }

    func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
    }

    private func addFetch(of id: MessageID, to group: inout TaskGroup<(MessageID, Error?)>) {
        let task = fetchTask(for: id)
        group.addTask {
            do {
                _ = try await task.value
                return (id, nil)
            } catch {
                return (id, error)
            }
        }
    }

    private func fetchTask(for id: MessageID) -> Task<StoredBody, Error> {
        if let existing = inFlight[id] { return existing }
        let provider = provider
        let sanitizer = sanitizer
        let store = store
        // Detached so sanitizing (HTML parsing) runs off this actor and fetches overlap freely.
        let task = Task.detached(priority: .utility) { () throws -> StoredBody in
            let body = try await provider.body(for: id.providerID)
            try Task.checkCancellation()
            let sanitized = sanitizer.sanitize(body, messageID: id)
            let stored = StoredBody(body: body, renderedHTML: sanitized.html, plainText: sanitized.plainText)
            try store.saveBody(stored, for: id)
            return stored
        }
        inFlight[id] = task
        Task { [weak self] in
            _ = try? await task.value
            await self?.finish(id, task: task)
        }
        return task
    }

    private func finish(_ id: MessageID, task: Task<StoredBody, Error>) {
        if inFlight[id] == task { inFlight[id] = nil }
    }

    private static func blockingError(_ error: Error) -> ProviderError? {
        guard let providerError = error as? ProviderError else { return nil }
        switch providerError {
        case .unauthorized, .throttled: return providerError
        default: return nil
        }
    }

    /// Transient failures are retried on the next poll; everything else waits out `hydrationRetryDelay`.
    private static func deservesDeferral(_ error: Error) -> Bool {
        guard let providerError = error as? ProviderError else { return !(error is CancellationError) }
        switch providerError {
        case .network, .cancelled: return false
        default: return true
        }
    }
}
