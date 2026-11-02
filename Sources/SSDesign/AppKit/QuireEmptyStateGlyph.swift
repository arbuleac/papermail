extension QuireEmptyStateView {
    /// The only glyphs an empty state carries (spec §5.9), in `ink3`, above the sentence.
    public enum Glyph: Sendable {
        /// `ss.sparrow` at 30 pt, 8 pt above: inbox zero only.
        case sparrow
        /// `wifi.slash` at 20 pt, 8 pt above: offline with nothing cached.
        case offline
    }
}
