import Foundation

/// The live account contexts, shared by the engine and the send runner. A plain locked map rather than an
/// actor because the facade's synchronous commands (`perform`, `send`) look accounts up without awaiting.
final class AccountRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [AccountID: AccountContext] = [:]
    private var order: [AccountID] = []

    func context(for id: AccountID) -> AccountContext? {
        lock.lock(); defer { lock.unlock() }
        return contexts[id]
    }

    func all() -> [AccountContext] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { contexts[$0] }
    }

    /// Keeps the first context registered for an account when two callers build one at the same time.
    func insertIfAbsent(_ context: AccountContext) -> AccountContext {
        lock.lock(); defer { lock.unlock() }
        if let existing = contexts[context.account.id] { return existing }
        contexts[context.account.id] = context
        order.append(context.account.id)
        return context
    }

    @discardableResult
    func remove(_ id: AccountID) -> AccountContext? {
        lock.lock(); defer { lock.unlock() }
        order.removeAll { $0 == id }
        return contexts.removeValue(forKey: id)
    }
}
