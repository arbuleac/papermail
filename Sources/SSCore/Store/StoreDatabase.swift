import Foundation
import GRDB

/// The slice of GRDB the store needs, so one `SQLiteMailStore` runs over a `DatabasePool` (WAL file) in the app
/// and over a `DatabaseQueue` (`:memory:`) in tests without the choice leaking into the public type.
protocol StoreDatabase: Sendable {
    func read<T>(_ work: (Database) throws -> T) throws -> T
    func write<T>(_ work: (Database) throws -> T) throws -> T
    func startObservation<Value: Sendable>(
        _ observation: ValueObservation<ValueReducers.Fetch<Value>>,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (Value) -> Void
    ) -> AnyDatabaseCancellable
    func close() throws
}

extension StoreDatabase where Self: DatabaseWriter {
    func startObservation<Value: Sendable>(
        _ observation: ValueObservation<ValueReducers.Fetch<Value>>,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (Value) -> Void
    ) -> AnyDatabaseCancellable {
        // `MailStoring` promises main-thread delivery with the current value first. GRDB's immediate scheduler
        // gives the synchronous first value a list binding expects, but it must be started on the main thread;
        // from anywhere else the first value hops to the main queue like every later one.
        if Thread.isMainThread {
            return observation.start(in: self, scheduling: .immediate, onError: onError, onChange: onChange)
        }
        return observation.start(in: self, scheduling: .async(onQueue: .main), onError: onError, onChange: onChange)
    }
}

extension DatabasePool: StoreDatabase {}
extension DatabaseQueue: StoreDatabase {}
