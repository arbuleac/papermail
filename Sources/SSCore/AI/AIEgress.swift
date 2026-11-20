import Foundation
import os

/// Where every contact Help Me Write makes beyond this Mac is recorded, as it is made: each HTTP request to a provider
/// and each launch of a CLI, with the user action that allowed it (spec §3b). The SSAI adapters call `record` right
/// before `URLSession` sends and before a process starts; since both need an `AIUserAction`, no contact goes unrecorded
/// or unasked.
///
/// The record goes to the debug log (names and paths only, never content) and to an observer the tests install to prove
/// that launch, Settings, typing and switching conversations make no contact, and each allowed action exactly the
/// expected one.
public enum AIEgress {
    public enum Contact: Sendable, Hashable, CustomStringConvertible {
        /// An HTTP request: its method, host and path, never its body, headers or query.
        case request(method: String, host: String, path: String)
        /// A CLI started: its file name and first argument (`--version`, `auth`, `login`, `features`, `-p`, `exec`).
        case launch(tool: String, command: String)

        public var description: String {
            switch self {
            case .request(let method, let host, let path): return "\(method) \(host)\(path)"
            case .launch(let tool, let command): return "\(tool) \(command)"
            }
        }
    }

    public typealias Observer = @Sendable (Contact, AIUserAction) -> Void

    private static let logger = Logger(subsystem: "io.supersparrow.mac", category: "ai")
    private static let observer = OSAllocatedUnfairLock<Observer?>(initialState: nil)

    /// Installs (or with nil removes) the one observer of every contact; tests only.
    public static func observe(_ new: Observer?) {
        observer.withLock { $0 = new }
    }

    /// Records a contact about to be made for `action`.
    public static func record(_ contact: Contact, by action: AIUserAction) {
        logger.debug("AI contact for \(action.kind.rawValue, privacy: .public): \(contact.description, privacy: .public)")
        observer.withLock { $0 }?(contact, action)
    }

    /// The request's method, host and path.
    public static func contact(for request: URLRequest) -> Contact {
        .request(method: request.httpMethod ?? "GET", host: request.url?.host ?? "", path: request.url?.path ?? "")
    }
}
