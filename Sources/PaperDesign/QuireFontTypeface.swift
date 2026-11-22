extension QuireFont {
    /// Settings › Appearance › Font (spec §4.4): the face every New York role is set in, app-wide. The raw values
    /// are what the app has always saved under the `readingFont` defaults key, so a saved choice carries over.
    public enum Typeface: String, CaseIterable, Sendable {
        /// New York, with the per-string script fallback to the sans twins.
        case newYork
        /// Every New York role in its SF Pro twin, whatever the text.
        case sfPro
    }
}
