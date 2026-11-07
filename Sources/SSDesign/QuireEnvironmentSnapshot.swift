extension QuireEnvironment {
    /// What Quire currently draws for.
    public struct Snapshot: Equatable, Sendable {
        public var isGraphite: Bool
        public var increaseContrast: Bool
        public var reduceMotion: Bool
        public var reduceTransparency: Bool
        /// The Font setting (spec §4.4). Not a system setting: the app sets it (`setTypeface(_:)`).
        public var typeface: QuireFont.Typeface

        public init(isGraphite: Bool, increaseContrast: Bool, reduceMotion: Bool, reduceTransparency: Bool,
                    typeface: QuireFont.Typeface = .newYork) {
            self.isGraphite = isGraphite
            self.increaseContrast = increaseContrast
            self.reduceMotion = reduceMotion
            self.reduceTransparency = reduceTransparency
            self.typeface = typeface
        }
    }
}
