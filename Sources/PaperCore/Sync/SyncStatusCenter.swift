import Foundation

/// Keeps the latest `AccountSyncStatus` per account and fans every change out to observers on the main thread.
///
/// Statuses are listed in registration order, which the engine keeps equal to the store's account order, so
/// the UI can zip them with its account strip.
///
/// An account's two lanes publish from different threads, and each snapshot is handed to the main queue after
/// the lock is let go, so two can arrive in the opposite order to the one they were taken in. Each carries a
/// number taken under the lock, and an observer never gets one older than the last it got: the last to arrive
/// would otherwise stay on screen, older state over newer.
final class SyncStatusCenter: @unchecked Sendable {
    /// Main-thread state per observer; `lastDelivered` is only read and written on the main thread.
    private final class Observer: @unchecked Sendable {
        let onChange: @Sendable ([AccountSyncStatus]) -> Void
        var lastDelivered: UInt64 = 0

        init(_ onChange: @escaping @Sendable ([AccountSyncStatus]) -> Void) {
            self.onChange = onChange
        }
    }

    private let lock = NSLock()
    private var order: [AccountID] = []
    private var statuses: [AccountID: AccountSyncStatus] = [:]
    private var observers: [UUID: Observer] = [:]
    private var sequence: UInt64 = 0

    func register(_ accountID: AccountID) {
        update(accountID) { _ in }
    }

    func status(for accountID: AccountID) -> AccountSyncStatus? {
        lock.lock(); defer { lock.unlock() }
        return statuses[accountID]
    }

    func snapshot() -> [AccountSyncStatus] {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked()
    }

    /// Applies `mutate` to the account's status (creating an idle one first) and notifies observers when
    /// something actually changed, so phase flips that land on the same value do not churn the UI.
    func update(_ accountID: AccountID, _ mutate: (inout AccountSyncStatus) -> Void) {
        lock.lock()
        let isNew = statuses[accountID] == nil
        var status = statuses[accountID] ?? AccountSyncStatus(accountID: accountID, phase: .idle)
        let before = status
        mutate(&status)
        if isNew { order.append(accountID) }
        statuses[accountID] = status
        let changed = isNew || before != status
        let snapshot = changed ? snapshotLocked() : []
        let number = changed ? nextNumberLocked() : 0
        let targets = changed ? Array(observers.values) : []
        lock.unlock()
        guard changed, !targets.isEmpty else { return }
        deliver(snapshot, numbered: number, to: targets)
    }

    func remove(_ accountID: AccountID) {
        lock.lock()
        guard statuses.removeValue(forKey: accountID) != nil else { lock.unlock(); return }
        order.removeAll { $0 == accountID }
        let snapshot = snapshotLocked()
        let number = nextNumberLocked()
        let targets = Array(observers.values)
        lock.unlock()
        deliver(snapshot, numbered: number, to: targets)
    }

    func observe(onChange: @escaping @Sendable ([AccountSyncStatus]) -> Void) -> StoreObservation {
        lock.lock()
        let token = UUID()
        let observer = Observer(onChange)
        observers[token] = observer
        let current = snapshotLocked()
        let number = nextNumberLocked()
        lock.unlock()
        deliver(current, numbered: number, to: [observer])
        return StoreObservation { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.observers[token] = nil
        }
    }

    private func snapshotLocked() -> [AccountSyncStatus] {
        order.compactMap { statuses[$0] }
    }

    private func nextNumberLocked() -> UInt64 {
        sequence += 1
        return sequence
    }

    private func deliver(_ snapshot: [AccountSyncStatus], numbered number: UInt64, to targets: [Observer]) {
        let block: @Sendable () -> Void = {
            for observer in targets where number > observer.lastDelivered {
                observer.lastDelivered = number
                observer.onChange(snapshot)
            }
        }
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
