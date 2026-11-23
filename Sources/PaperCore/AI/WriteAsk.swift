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

    /// The card's instruction field; may be empty.
    public var instruction: String
    public var draft: Draft

    public init(instruction: String = "", draft: Draft = .empty) {
        self.instruction = instruction
        self.draft = draft
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
}
