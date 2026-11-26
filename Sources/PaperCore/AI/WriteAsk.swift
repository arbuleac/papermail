import Foundation

/// What the user asked of Help Me Write: their instruction from the card, and the text in the field it works on.
/// The user's own words, so they are sent as written (only invisible characters go); mail is what gets redacted.
public struct WriteAsk: Sendable, Hashable {
    /// The field's text the write starts from (spec §1.4).
    public enum Draft: Sendable, Hashable {
        /// The field is empty: the reply is written from the conversation alone.
        case empty
        /// The user's typed text (the quick reply's whole text; a composer's body above the signature and quote): sent
        /// as “my notes so far”, and replaced by the reply.
        case notes(String)
        /// The selected text, rewritten per the instruction; the result replaces only the selection.
        case selection(String)
    }

    /// The user's own text around a selection to rewrite, read in the field as the user asked (`WriteSession.run`) and
    /// never before: what the rewrite reads so the part fits where it stands, and the few words beside it that it may
    /// change to join it (spec §5.56). Raw, as the field holds it: `WriteRewriteFrame` cleans, cuts and, for a body a
    /// mail link or a Service filled in, redacts it off the main thread. Only text the field calls the user's own is
    /// ever put here (`WriteField.textAroundSelectionIsOwn`, `WriteField.ownTextRange`).
    public struct Around: Sendable, Hashable {
        /// The field's own text from its start to the selection's trimmed core.
        public var before: String
        /// The field's own text from the core's end to the own text's end (above a composer's signature).
        public var after: String
        /// UTF-16 lengths measured outward from the core's edges (`WriteSeamWindows`): the blanks right before the core,
        /// then the few words before those that may change; the after side mirrors it. A window of 0 is none.
        public var beforeGap: Int
        public var beforeWindow: Int
        public var afterGap: Int
        public var afterWindow: Int

        public init(before: String, after: String, beforeGap: Int = 0, beforeWindow: Int = 0, afterGap: Int = 0,
                    afterWindow: Int = 0) {
            self.before = before
            self.after = after
            self.beforeGap = beforeGap
            self.beforeWindow = beforeWindow
            self.afterGap = afterGap
            self.afterWindow = afterWindow
        }
    }

    /// The card's instruction field; may be empty.
    public var instruction: String
    public var draft: Draft
    /// For a selection's rewrite where the text around it is the user's own: that text (the DRAFT form of the request).
    /// Nil for every other write, and for a rewrite that sends the selection alone.
    public var around: Around?

    public init(instruction: String = "", draft: Draft = .empty, around: Around? = nil) {
        self.instruction = instruction
        self.draft = draft
        self.around = around
    }

    /// The card says “Rewrite selection” and the button **Rewrite**.
    public var isRewrite: Bool {
        if case .selection = draft { return true }
        return false
    }

    /// Whether the ask itself says what to write: notes, a selection, or an instruction. What a new message is written
    /// from, having no conversation behind it (`WriteKind.hasNothingToWriteFrom`, which cleans the ask first).
    var hasBrief: Bool {
        if case .empty = draft { return !instruction.isEmpty }
        return true
    }

    /// The character a picture in a composer's body is: the text system's attachment character, U+FFFC.
    public static let pictureCharacter = "\u{FFFC}"

    /// The ask with every picture taken out of its notes or its selection: a picture holds no words, so it is nothing
    /// to write from and nothing to send. A new message's and a forward's ask is read so; a reply's is sent as it
    /// always was.
    ///
    /// Each attachment character goes, also one a mark joins (a variation selector after it), which a search that reads
    /// characters as the user sees them would not find on its own: the composer reads the body scalar by scalar
    /// (`WriteSession.holdsWords`), and the two must agree.
    var withoutPictures: WriteAsk {
        var ask = self
        switch draft {
        case .empty:
            break
        case .notes(let notes):
            ask.draft = .notes(notes.replacingOccurrences(of: Self.pictureCharacter, with: "", options: .literal))
        case .selection(let selection):
            ask.draft = .selection(selection.replacingOccurrences(of: Self.pictureCharacter, with: "", options: .literal))
        }
        return ask
    }
}
