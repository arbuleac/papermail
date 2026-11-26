import Foundation
import PaperCore
import os

/// One signposter for the calendar so Instruments groups every "calendar.*" interval under one category, for its
/// budgets (docs/ARCHITECTURE.md: D or W to the calendar on screen in 50 ms, following J and K inside 16 ms).
enum CalendarSignposts {
    static let signposter = OSSignposter(subsystem: AppIdentity.bundleIdentifier, category: "calendar")
    /// What the calendar views log: kinds and failures, never an event's words.
    static let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "calendar")
}
