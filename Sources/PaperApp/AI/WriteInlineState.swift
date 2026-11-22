import AppKit

/// Whether Help me write can write in a field now, as far as this Mac knows (`HelpMeWrite.availability`, spec §3b: no
/// network, no process).
enum WriteAvailability: Equatable {
    /// No provider chosen: nothing of Help me write shows in the text; ⌘J says so.
    case off
    /// A provider is chosen but cannot write: ⌘J shows the reason under the caret's line, with Settings….
    case unavailable(reason: String)
    /// Ready: the writer's name for the words (“Claude”), and its source line for the tooltips.
    case ready(writer: String, source: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Who writes, in the words the text shows (“Written by Claude”); Claude while nothing names another.
    var writer: String {
        if case .ready(let writer, _) = self { return writer }
        return "Claude"
    }
}

/// What a session is doing in its field (§5.56).
enum WritePhase: Equatable {
    case idle
    /// A reply streams in, in pencil, the pencil mark after it.
    case writing
    /// A reply just landed; the afterline under it stays until the user types, sends, presses Esc or moves away.
    case written
    /// The write could not start or failed: the reason under the caret's line, with Try again and, when the fix is
    /// there, Settings….
    case failed(reason: String, offersSettings: Bool)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The words Help me write uses in the text, in one place so the surfaces, the context menu, VoiceOver and the tests
/// agree.
enum WriteWords {
    /// The prompt line's preset chips and the afterline's Shorter.
    static let presets = ["Shorter", "Friendlier", "Say no politely"]
    static let tryAgain = "Try again"
    static let sayHow = "Say how"
    static let undo = "Undo"
    static let settings = "Settings\u{2026}"
    static let rewrite = "Rewrite"

    /// The ghost after the caret on an empty reply.
    static let ghostReply = "to write a reply"
    /// The ghost after the quick reply's placeholder (“Reply to Sam…”), which already says what the field is for.
    static let ghostAfterPlaceholder = "to write it"
    /// The ghost after the caret at the end of the user's notes.
    static let ghostNotes = "to write from your notes"

    /// The prompt line's placeholder for `writer` (“Claude”); the demo, whose writer is no one, asks plainly.
    static func promptPlaceholder(writer: String, rewrites: Bool) -> String {
        guard writer != "the demo" else {
            return rewrites ? "Say how to rewrite it\u{2026}" : "Say what to write\u{2026}"
        }
        return rewrites ? "Tell \(writer) how to rewrite it\u{2026}" : "Tell \(writer) what to write\u{2026}"
    }

    static func written(by writer: String, rewrite: Bool) -> String {
        (rewrite ? "Rewritten by " : "Written by ") + writer
    }
}
