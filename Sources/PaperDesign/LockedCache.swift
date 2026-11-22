import Foundation

/// A small thread-safe memo table. Fonts, paragraph styles and glyph images are built lazily from whatever
/// thread first asks (row strings are built off the main thread), so the caches cannot be main-actor state.
final class LockedCache<Key: Hashable, Value>: @unchecked Sendable {
    private var storage: [Key: Value] = [:]
    private let lock = NSLock()

    func value(for key: Key, make: () -> Value) -> Value {
        lock.lock()
        if let v = storage[key] {
            lock.unlock()
            return v
        }
        lock.unlock()
        // Built outside the lock: font and image construction can re-enter AppKit, which may itself lock.
        let v = make()
        lock.lock()
        defer { lock.unlock() }
        if let existing = storage[key] { return existing }
        storage[key] = v
        return v
    }

    func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}
