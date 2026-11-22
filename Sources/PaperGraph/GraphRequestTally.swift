import Foundation

/// Counts the requests Graph charges against the mailbox's limit while one provider call runs, so `changes` can
/// report what it really sent: a delta GET per folder it visits, the folder lookups of a refresh, and one per part
/// of each `$batch` (Graph counts the parts, not the envelope). The transport adds to whichever tally the calling
/// task has bound, so helpers several calls deep are counted without passing anything along.
final class GraphRequestTally: @unchecked Sendable {
    @TaskLocal static var current: GraphRequestTally?

    private let lock = NSLock()
    private var total = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    func add(_ requests: Int) {
        lock.lock()
        defer { lock.unlock() }
        total += requests
    }

    /// Runs `body` with a fresh tally bound and returns what it sent alongside its result.
    static func counting<T>(_ body: () async throws -> T) async rethrows -> (T, Int) {
        let tally = GraphRequestTally()
        let result = try await $current.withValue(tally) { try await body() }
        return (result, tally.count)
    }
}
