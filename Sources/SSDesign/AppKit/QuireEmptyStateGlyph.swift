extension QuireEmptyStateView {
    /// The only glyphs an empty state carries (spec §5.9), above the sentence.
    public enum Glyph: Sendable {
        /// The brand mark, `ss.paperPlane`, at 40 pt in the system's secondary label grey, 8 pt above: inbox zero only.
        case brandMark
        /// `wifi.slash` at 20 pt in `ink3`, 8 pt above: offline with nothing cached.
        case offline
    }
}
