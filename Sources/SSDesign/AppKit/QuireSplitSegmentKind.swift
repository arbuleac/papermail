extension QuireSplitSegment {
    /// Which half of a split button a segment is (spec §5.23).
    public enum Kind: Sendable {
        /// The command: a glyph, the label and its keycap, on the leading side of the face.
        case action
        /// The drop-down: the chevron, behind the divider on the trailing side. It acts on mouse-down, as a pull-down's
        /// menu opens, and VoiceOver hears a menu button.
        case menu
    }
}
