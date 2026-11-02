extension QuireEnvironment {
    /// What Quire currently draws for.
    public struct Snapshot: Equatable, Sendable {
        public var isGraphite: Bool
        public var increaseContrast: Bool
        public var reduceMotion: Bool
        public var reduceTransparency: Bool

        public init(isGraphite: Bool, increaseContrast: Bool, reduceMotion: Bool, reduceTransparency: Bool) {
            self.isGraphite = isGraphite
            self.increaseContrast = increaseContrast
            self.reduceMotion = reduceMotion
            self.reduceTransparency = reduceTransparency
        }
    }
}
