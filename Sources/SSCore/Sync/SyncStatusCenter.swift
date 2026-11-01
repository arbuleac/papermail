import Foundation

/// Keeps the latest `AccountSyncStatus` per account and fans every change out to observers on the main thread.
///
/// Statuses are listed in registration order, which the engine keeps equal to the store's account order, so
/// the UI can zip them with its account strip.
final class SyncStatusCenter: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [AccountID] = []
    private var statuses: [AccountID: AccountSyncStatus] = [:]
    private var observers: [UUID: @Sendable ([AccountSyncStatus]) -> Void] = [:]

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
        let callbacks = changed ? Array(observers.values) : []
        lock.unlock()
        guard changed, !callbacks.isEmpty else { return }
        deliver { for callback in callbacks { callback(snapshot) } }
    }

    func remove(_ accountID: AccountID) {
        lock.lock()
        guard statuses.removeValue(forKey: accountID) != nil else { lock.unlock(); return }
        order.removeAll { $0 == accountID }
        let snapshot = snapshotLocked()
        let callbacks = Array(observers.values)
        lock.unlock()
        deliver { for callback in callbacks { callback(snapshot) } }
    }

    func observe(onChange: @escaping @Sendable ([AccountSyncStatus]) -> Void) -> StoreObservation {
        lock.lock()
        let token = UUID()
        observers[token] = onChange
        let current = snapshotLocked()
        lock.unlock()
        deliver { onChange(current) }
        return StoreObservation { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.observers[token] = nil
        }
    }

    private func snapshotLocked() -> [AccountSyncStatus] {
        order.compactMap { statuses[$0] }
    }

    private func deliver(_ block: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
