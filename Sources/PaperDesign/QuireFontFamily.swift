extension QuireFont {
    /// The four system families Quire sets type in (spec §4.4). No bundled or web fonts.
    public enum Family: String, Sendable {
        /// SF Pro: `NSFont.systemFont`.
        case sf
        /// New York: the system font's serif design.
        case serif
        /// SF Pro Rounded: the system font's rounded design.
        case rounded
        /// SF Mono: `NSFont.monospacedSystemFont`.
        case mono
    }
}
