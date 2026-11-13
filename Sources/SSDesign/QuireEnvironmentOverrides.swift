extension QuireEnvironment {
    /// Forced values that win over the system's, for tests and for snapshots rendered in a given mode
    /// (for example a Graphite specimen on a Mac set to Multicolor). nil follows the system.
    public struct Overrides: Equatable, Sendable {
        public var isGraphite: Bool?
        public var increaseContrast: Bool?
        public var reduceMotion: Bool?
        public var reduceTransparency: Bool?
        /// Wins over the app's Font setting, so the Design Gallery can show either face without saving it.
        public var typeface: QuireFont.Typeface?
        /// Wins over the app's Text size, for tests and snapshots at a given size.
        public var textSize: QuireFont.TextSize?

        public init(isGraphite: Bool? = nil, increaseContrast: Bool? = nil, reduceMotion: Bool? = nil, reduceTransparency: Bool? = nil,
                    typeface: QuireFont.Typeface? = nil, textSize: QuireFont.TextSize? = nil) {
            self.isGraphite = isGraphite
            self.increaseContrast = increaseContrast
            self.reduceMotion = reduceMotion
            self.reduceTransparency = reduceTransparency
            self.typeface = typeface
            self.textSize = textSize
        }
    }
}
