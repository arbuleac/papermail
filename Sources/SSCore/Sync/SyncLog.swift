import Foundation
import os

/// The one logger for the sync module. Message content (bodies, subjects, addresses) never reaches it above
/// debug level; account ids are UUIDs the engine minted and are safe to log publicly.
enum SyncLog {
    static let logger = Logger(subsystem: "io.supersparrow.mac", category: "sync")
}
