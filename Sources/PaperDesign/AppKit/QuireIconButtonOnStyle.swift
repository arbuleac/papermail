extension QuireIconButton {
    /// How an icon button shows that it is on.
    public enum OnStyle: Sendable {
        /// The on symbol in `star`, no fill: the star action (`star.fill`, §5.12).
        case star
        /// A quiet toggle: the symbol in `accent` on `accentWash` (hover `accentWashHover`, pressed
        /// `accentWashPressed`): Format, the format toggles, Original colors (§5.14, §5.20).
        case quiet
        /// The on symbol in `accent`, no fill: a copy button's Copied mark (§5.54).
        case accent
    }
}
