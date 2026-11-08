extension QuireEmptyStateView {
    /// One piece of an empty state's hint line: words, or keycaps set inline with them
    /// (`[.keys(["J", "K"]), .text("to move ·"), .keys(["↩"]), .text("to open")]`).
    public enum HintPart: Equatable, Sendable {
        case text(String)
        case keys([String])
        /// Words that act when clicked (`QuireEmptyStateView.onLink`): `accent`, underlined on hover, `ink2` while
        /// pressed, as link buttons are (§5.24). The empty search's “Search Gmail” and “Try again” (§5.9).
        case link(String)
    }
}
