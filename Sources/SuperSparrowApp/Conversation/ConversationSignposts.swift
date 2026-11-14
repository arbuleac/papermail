import Foundation
import os

/// Signpost and log handles for the reader. Intervals are the "open conversation" budgets in
/// docs/ARCHITECTURE.md; log lines never carry subjects, bodies or addresses.
enum ConversationSignposts {
    static let subsystem = "io.supersparrow.mac"
    static let signposter = OSSignposter(subsystem: subsystem, category: "conversation")
    static let log = Logger(subsystem: subsystem, category: "conversation")

    static let show: StaticString = "conversation.show"
    static let render: StaticString = "conversation.render"
    static let prerender: StaticString = "conversation.prerender"
    /// A new reader Text size (Settings or ⌘+ / ⌘−) until every ready shell has measured its bodies at it.
    static let textSize: StaticString = "conversation.textSize"

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
