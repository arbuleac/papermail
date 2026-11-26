import Foundation

/// One read of an event's details: what was read, at which of the event's versions, and the requests it made (which
/// the engine charges to the account).
public struct CalendarDetailsRead: Sendable {
    public var details: CalendarEventDetails
    public var version: String?
    public var requestCount: Int

    public init(details: CalendarEventDetails, version: String?, requestCount: Int) {
        self.details = details
        self.version = version
        self.requestCount = requestCount
    }
}
