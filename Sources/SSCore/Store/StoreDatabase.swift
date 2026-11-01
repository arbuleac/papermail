import Foundation
import GRDB

/// The slice of GRDB the store needs, so one `SQLiteMailStore` runs over a `DatabasePool` (WAL file) in the app
/// and over a `DatabaseQueue` (`:memory:`) in tests without the choice leaking into the public type.
protocol StoreDatabase: Sendable {
    func read<T>(_ work: (Database) throws -> T) throws -> T
    func write<T>(_ work: (Database) throws -> T) throws -> T
    /// - Parameter firstValueOnCallingThread: when started on the main thread, deliver the first value
    ///   before returning. False keeps the first fetch on a reader, for queries too slow for the main thread.
    func startObservation<Reducer: ValueReducer>(
        _ observation: ValueObservation<Reducer>,
        firstValueOnCallingThread: Bool,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable where Reducer.Value: Sendable
    func close() throws
}

extension StoreDatabase where Self: DatabaseWriter {
    func startObservation<Reducer: ValueReducer>(
        _ observation: ValueObservation<Reducer>,
        firstValueOnCallingThread: Bool,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable where Reducer.Value: Sendable {
        // `MailStoring` promises main-thread delivery with the current value first. GRDB's immediate scheduler
        // gives the synchronous first value a list binding expects, but it must be started on the main thread;
        // from anywhere else the first value hops to the main queue like every later one.
        if Thread.isMainThread, firstValueOnCallingThread {
            return observation.start(in: self, scheduling: .immediate, onError: onError, onChange: onChange)
        }
        return observation.start(in: self, scheduling: .async(onQueue: .main), onError: onError, onChange: onChange)
    }
}

extension DatabasePool: StoreDatabase {}
extension DatabaseQueue: StoreDatabase {}
