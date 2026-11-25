import Foundation

/// An event's details as the store keeps them: what was read, at which of the event's versions, and when.
public struct StoredEventDetails: Hashable, Sendable {
    public var details: CalendarEventDetails
    /// The event's `version` when they were read: at another they are stale.
    public var version: String?
    public var readAt: Date

    public init(details: CalendarEventDetails, version: String?, readAt: Date) {
        self.details = details
        self.version = version
        self.readAt = readAt
    }
}
