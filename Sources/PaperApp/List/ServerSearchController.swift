import Foundation
import PaperCore

/// The list's search of the server (spec §5.10, “The end of a search”): runs `MailClient.searchServer` for the words
/// and scope the list shows and keeps what the row needs: the state, the conversations the server found (which the
/// list's query adds to the local results) and what the list showed before it ran (to count what it added).
///
/// The search runs off the main thread in the engine; nothing here waits for it. A new search (other words, another
/// scope) starts fresh: `reset()` cancels a search still running and forgets what it found, and a late answer for an
/// old search is dropped.
@MainActor
final class ServerSearchController {
    typealias Search = @Sendable (String, [AccountID]?) async throws -> ServerSearchResult

    enum State: Equatable {
        /// Not asked yet, for these words.
        case idle
        case searching
        /// The search answered for every account in scope.
        case finished
        /// Some account (or all) could not be searched: `failedAccounts` says which.
        case failed
    }

    /// The engine's `searchServer`, set by the window. Without it the list never offers the search.
    var search: Search?
    /// Called after every change of the state or of `found`, except by `reset`.
    var onChange: (() -> Void)?

    private(set) var state = State.idle
    /// The words and scope the current state belongs to; nil while idle.
    private(set) var words: String?
    private(set) var scope: [AccountID]?
    /// Every conversation the searches for these words found, including those a failed account's sibling found.
    private(set) var found: Set<ConversationID> = []
    /// The conversations the list showed when the first search for these words started: the local results.
    private(set) var before: Set<ConversationID> = []
    private(set) var failedAccounts: [AccountID] = []
    private var task: Task<Void, Never>?
    /// Bumped on every reset and run, so an answer meant for an earlier one is ignored.
    private var generation = 0
    /// When the current run asked the server, for analytics' timing of it.
    private var startedAt: ContinuousClock.Instant?

    var isRunning: Bool { state == .searching }

    /// Forgets everything: the words or the scope changed. A search still running is cancelled; what it already
    /// stored stays, as any mail does. Nothing is reported: the list's new query re-reads its rows anyway, and
    /// redrawing the old rows under it first would stop the field's spinner and offer the server for words not shown.
    func reset() {
        task?.cancel()
        task = nil
        generation += 1
        state = .idle
        words = nil
        scope = nil
        found = []
        before = []
        failedAccounts = []
    }

    /// Searches the server for `words` in `scope`. `listed` is what the list shows now, remembered on the first run
    /// for these words so a later count of what was added leaves the local results out. A run while one is running
    /// does nothing.
    func run(words: String, scope: [AccountID]?, listed: Set<ConversationID>) {
        guard let search, state != .searching else { return }
        if self.words != words || self.scope != scope {
            reset()
            before = listed
        }
        self.words = words
        self.scope = scope
        state = .searching
        failedAccounts = []
        startedAt = .now
        generation += 1
        let generation = generation
        onChange?()
        task = Task { [weak self] in
            let outcome: Result<ServerSearchResult, Error>
            do {
                outcome = .success(try await search(words, scope))
            } catch {
                outcome = .failure(error)
            }
            guard let self, self.generation == generation else { return }
            self.finish(outcome, scope: scope)
        }
    }

    private func finish(_ outcome: Result<ServerSearchResult, Error>, scope: [AccountID]?) {
        task = nil
        switch outcome {
        case .success(let result):
            found.formUnion(result.conversations)
            failedAccounts = result.failedAccounts
            state = result.failedAccounts.isEmpty ? .finished : .failed
            report()
        case .failure(let error) where error is CancellationError:
            // Only `reset` cancels, and it has already moved on.
            return
        case .failure:
            // The engine could not even start (its store unreadable): every account in scope counts as failed.
            failedAccounts = scope ?? []
            state = .failed
            report()
        }
        onChange?()
    }

    /// How the search went, for analytics: what it added to the local results, how many operators it used, and how long
    /// it took. The words are counted, never sent.
    private func report() {
        let added = found.subtracting(before).count
        let outcome: AnalyticsSignal.ServerSearchOutcome = state == .failed ? .failed : (added > 0 ? .found : .nothing)
        let operators = AnalyticsSignal.operators(in: words.flatMap { SearchQuery(parsing: $0) })
        let seconds = startedAt.map { Analytics.seconds(since: $0) } ?? 0
        startedAt = nil
        Analytics.send(.serverSearch(outcome, operators: operators, found: added, seconds: seconds))
    }

    #if DEBUG
    /// `--snapshot-state=server-…` (debug builds): shows a state without asking the server.
    func force(_ state: State, words: String, scope: [AccountID]?, found: Set<ConversationID> = [],
               before: Set<ConversationID> = [], failedAccounts: [AccountID] = []) {
        task?.cancel()
        task = nil
        generation += 1
        self.state = state
        self.words = words
        self.scope = scope
        self.found = found
        self.before = before
        self.failedAccounts = failedAccounts
        onChange?()
    }
    #endif
}
