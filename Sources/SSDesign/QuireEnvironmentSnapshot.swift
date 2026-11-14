extension QuireEnvironment {
    /// What Quire currently draws for.
    public struct Snapshot: Equatable, Sendable {
        public var isGraphite: Bool
        public var increaseContrast: Bool
        public var reduceMotion: Bool
        public var reduceTransparency: Bool
        /// The Font setting (spec §4.4). Not a system setting: the app sets it (`setTypeface(_:)`).
        public var typeface: QuireFont.Typeface
        /// Text size (spec §4.15). Not a system setting either: the app sets it (`setTextSize(_:)`).
        public var textSize: QuireFont.TextSize

        public init(isGraphite: Bool, increaseContrast: Bool, reduceMotion: Bool, reduceTransparency: Bool,
                    typeface: QuireFont.Typeface = .newYork, textSize: QuireFont.TextSize = .default) {
            self.isGraphite = isGraphite
            self.increaseContrast = increaseContrast
            self.reduceMotion = reduceMotion
            self.reduceTransparency = reduceTransparency
            self.typeface = typeface
            self.textSize = textSize
        }
    }
}
