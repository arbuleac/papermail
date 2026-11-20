import os

/// The "list.search" interval: from the moment the list takes a search query to the moment it has applied that
/// query's first page, which is what someone typing in the search field waits for. The store's "store.search"
/// intervals inside it are the full-text reads alone.
///
/// At most one is open. A query replaced before its first page arrives (more typing, a cleared field, another
/// view) ends its interval marked "superseded", as does the list going away, so intervals never leak or overlap.
/// A query whose store read fails ends marked "failed" at once, so a broken search never reads as a slow one.
/// Nothing here reads the query: a signpost must never carry what the user typed.
final class ListSearchSignpost {
    enum Event: Equatable {
        case began, finished, superseded, failed
    }

    /// For tests: every begin and end, in order. Nil in the app, so the hot path pays one nil check.
    var onEvent: ((Event) -> Void)?

    private static let name: StaticString = "list.search"
    private let signposter = ListSignposts.signposter
    private var open: OSSignpostIntervalState?
    private var openedAt: ContinuousClock.Instant?

    /// A new search query; one still waiting for its rows was superseded by it.
    func begin() {
        supersede()
        open = signposter.beginInterval(Self.name, id: signposter.makeSignpostID())
        openedAt = .now
        onEvent?(.began)
    }

    /// The query's first page is in the list: how long it took, for analytics' sampled timing. Later refreshes of the same
    /// query find nothing open, and return nil.
    @discardableResult
    func finish() -> Double? {
        guard let state = open else { return nil }
        open = nil
        signposter.endInterval(Self.name, state)
        onEvent?(.finished)
        defer { openedAt = nil }
        return openedAt.map { Analytics.seconds(since: $0) }
    }

    /// The query was replaced before its first page arrived.
    func supersede() {
        guard let state = open else { return }
        open = nil
        signposter.endInterval(Self.name, state, "superseded")
        onEvent?(.superseded)
    }

    /// The store's read failed, so no first page will come.
    func fail() {
        guard let state = open else { return }
        open = nil
        signposter.endInterval(Self.name, state, "failed")
        onEvent?(.failed)
    }

    deinit {
        supersede()
    }
}
