extension QuireEmptyStateView {
    /// One piece of an empty state's hint line: words, or keycaps set inline with them
    /// (`[.keys(["J", "K"]), .text("to move ·"), .keys(["↩"]), .text("to open")]`).
    public enum HintPart: Equatable, Sendable {
        case text(String)
        case keys([String])
    }
}
