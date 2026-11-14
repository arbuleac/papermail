import Foundation

/// Records the waits a provider asked for instead of sleeping them.
final class WaitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var waits: [TimeInterval] {
        lock.withLock { recorded }
    }

    func record(_ wait: TimeInterval) {
        lock.withLock { recorded.append(wait) }
    }

    func reset() {
        lock.withLock { recorded = [] }
    }
}
