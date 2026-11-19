import Foundation
import os

/// One signposter for the calendar so Instruments groups every "calendar.*" interval under one category, for its
/// budgets (docs/ARCHITECTURE.md: D or W to the calendar on screen in 50 ms, following J and K inside 16 ms).
enum CalendarSignposts {
    static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "SuperSparrow", category: "calendar")
}
