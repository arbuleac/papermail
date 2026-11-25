import AppKit
import PaperCore

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
    /// Nothing failed, but ⌘J cannot write here as things stand (a forward still loading its forwarded message, a body
    /// where only a selection can be rewritten): the words, quietly, under the caret's line, with no action. ⌘J under
    /// them asks again.
    case notice(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// A line under the text that goes as the user types, presses Esc or moves away: a draft's afterline, a failure's,
    /// a notice.
    var showsLine: Bool {
        switch self {
        case .written, .failed, .notice: return true
        case .idle, .writing: return false
        }
    }
}

/// The words Help me write uses in the text, in one place so the surfaces, the context menu, VoiceOver and the tests
/// agree. “Reply” is what a reply's field writes; “message” what a new message and a forward write. “Notes” is always
/// what the user typed.
enum WriteWords {
    /// The afterline's Shorter, and the first chip of every set.
    static let shorter = "Shorter"
    /// The prompt line's preset chips where a reply is written.
    static let presets = [shorter, "Friendlier", "Say no politely"]
    /// The chips where a new message or a forward's message is written: there is nothing there to say no to.
    static let messagePresets = [shorter, "Friendlier", "More formal"]
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
    /// The ghost on an empty forward whose forwarded message is there to write from.
    static let ghostMessage = "to write a message"
    /// The ghost where there is nothing to write from yet (an empty new message, a forward without its original): ⌘J
    /// opens the prompt line there.
    static let ghostSayWhat = "to say what to write"

    /// What ⌘J says in a forward whose forwarded message has not arrived yet.
    static let forwardLoading = "The forwarded message is still loading"
    /// What ⌘J says, with nothing selected, in a body the composer cannot tell the user's words from quoted mail in.
    static let selectionOnly = "Select the text to rewrite"

    /// The chips for a field that writes `kind`.
    static func presets(for kind: WriteKind) -> [String] {
        kind == .reply ? presets : messagePresets
    }

    /// The ghost on an empty field that writes `kind`. One that begins “to write” writes at once; “to say” opens the
    /// prompt line, because there is nothing to write from yet.
    static func emptyGhost(for kind: WriteKind) -> String {
        if kind.hasNothingToWriteFrom(WriteAsk()) { return ghostSayWhat }
        return kind == .reply ? ghostReply : ghostMessage
    }

    /// What a draft of `kind` is called in the menus and by VoiceOver.
    static func noun(for kind: WriteKind) -> String {
        kind == .reply ? "Reply" : "Message"
    }

    /// What VoiceOver says as a draft lands: a selection rewritten, or what was written, and that the Subject was set
    /// with it when it was (the one effect of a write that is not at the caret).
    static func landed(_ kind: WriteKind, by writer: String, rewrite: Bool, withSubject: Bool, joined: Bool = false) -> String {
        if rewrite { return "Selection rewritten by \(writer)" + (joined ? ", with the words next to it adjusted" : "") }
        return noun(for: kind) + (withSubject ? " and subject" : "") + " written by \(writer)"
    }

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
