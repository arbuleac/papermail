import Foundation
@testable import PaperCore

/// The mailbox the `PAPER_PERF=1` store benchmarks measure the budgets of docs/ARCHITECTURE.md on: the synthetic mailbox
/// at 300,000 messages since roadmap Q4.3, three accounts, the Microsoft one filing its archived mail in 200 folders.
/// `PAPER_PERF_MESSAGES` sets another size (100,000 for the runs recorded before Q4.3).
enum PerfMailbox {
    static let defaultMessageCount = 300_000
    static let graphFolderCount = 200
    static let batchSize = 200

    static var messageCount: Int {
        Int(ProcessInfo.processInfo.environment["PAPER_PERF_MESSAGES"] ?? "") ?? defaultMessageCount
    }

    static func make() -> SyntheticMailbox {
        SyntheticMailbox(seed: 7, accountCount: 3, messageCount: messageCount, graphFolderCount: graphFolderCount)
    }

    /// Keep mail on this Mac at 1 year, on the fixture's own clock: the fixture's mail spans the two years before
    /// `Options.now`, so about half of it lies outside the window.
    static func oneYearCutoff(_ mailbox: SyntheticMailbox) -> Date {
        MailRetention.oneYear.cutoff(now: mailbox.options.now) ?? mailbox.options.now
    }

    /// Loads the mailbox the way the sync engine does: metadata pages first, then the bodies in hydration batches.
    /// Returns the load's and the hydration's times and the slowest metadata page, in milliseconds.
    static func load(_ mailbox: SyntheticMailbox, into store: SQLiteMailStore,
                     bodies: Bool = true) throws -> (load: Double, slowestBatch: Double, hydrate: Double) {
        for account in mailbox.accounts { try store.upsertAccount(account) }
        let batches = mailbox.batches(of: batchSize)
        var slowest = 0.0
        let load = try milliseconds {
            for batch in batches {
                slowest = max(slowest, try milliseconds { try store.upsertMessages(batch) })
            }
        }
        guard bodies else { return (load, slowest, 0) }
        let hydrate = try milliseconds {
            for batch in batches {
                try store.saveBodies(batch.map { (id: $0.id, body: mailbox.body(for: $0)) })
            }
        }
        return (load, slowest, hydrate)
    }

    struct Sweep {
        var evicted = 0
        var batches = 0
        var total = 0.0
        /// How long each batch that wrote held the writer: from the rules asked again inside its write to its end.
        var writes: [Double] = []
        /// The longest batch, its read included.
        var slowestBatch = 0.0

        var slowestWrite: Double { writes.max() ?? 0 }
        var medianWrite: Double { PerfMailbox.percentile(writes, 0.5) }
        var p95Write: Double { PerfMailbox.percentile(writes, 0.95) }
    }

    /// A first sweep to `cutoff`, as `StorageSweeper` runs one: batches of `SyncTuning.evictionBatchSize`, each starting
    /// where the last one stopped, until nothing is left to look at.
    static func sweep(_ store: SQLiteMailStore, to cutoff: Date) throws -> Sweep {
        var result = Sweep()
        let batchSize = SyncTuning().evictionBatchSize
        var start: Date?
        let began = DispatchTime.now()
        while true {
            var asked: [DispatchTime] = []
            let batchStart = DispatchTime.now()
            let batch = try store.evictBodies(from: start, limit: batchSize) {
                asked.append(DispatchTime.now())
                return (cutoff, [])
            }
            let end = DispatchTime.now()
            result.batches += 1
            result.evicted += batch.evicted
            result.slowestBatch = max(result.slowestBatch, elapsed(from: batchStart, to: end))
            // Asked twice when the batch wrote: before its read, and again holding the writer.
            if asked.count > 1, let inWrite = asked.last {
                result.writes.append(elapsed(from: inWrite, to: end))
            }
            guard let next = batch.next, batch.evicted > 0 || next != start else { break }
            start = next
        }
        result.total = elapsed(from: began, to: DispatchTime.now())
        return result
    }

    /// Runs `work` on another thread and `action` on this one, every `interval` until `work` is done, as a user's keys
    /// meet the engine's background writes: how long each action took, in milliseconds.
    static func actions(every interval: TimeInterval = 0.002, during work: @escaping @Sendable () throws -> Void,
                        _ action: () throws -> Void) throws -> [Double] {
        let done = DispatchSemaphore(value: 0)
        let finished = ManagedFlag()
        DispatchQueue.global(qos: .utility).async {
            defer { finished.set(); done.signal() }
            do { try work() } catch { print("PAPER_PERF background work failed: \(error)") }
        }
        var timings: [Double] = []
        while !finished.isSet {
            timings.append(try milliseconds(action))
            Thread.sleep(forTimeInterval: interval)
        }
        done.wait()
        return timings
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    // MARK: Timing

    static func milliseconds(_ work: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now()
        try work()
        return elapsed(from: start, to: DispatchTime.now())
    }

    static func elapsed(from start: DispatchTime, to end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    /// The median of `runs` timings after one warm-up run, since no read the budgets cover is the first of its kind.
    static func median<T>(runs: Int, _ work: () throws -> T) throws -> (value: T, milliseconds: Double) {
        var last = try work()
        var timings: [Double] = []
        for _ in 0..<runs {
            timings.append(try milliseconds { last = try work() })
        }
        return (last, timings.sorted()[runs / 2])
    }

    static func report(_ label: String, _ milliseconds: Double) {
        print("PAPER_PERF \(label): \(String(format: "%.1f", milliseconds)) ms")
    }
}

/// A flag one thread sets and another reads.
final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}
