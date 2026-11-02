extension QuireEnvironment {
    /// Forced values that win over the system's, for tests and for snapshots rendered in a given mode
    /// (for example a Graphite specimen on a Mac set to Multicolor). nil follows the system.
    public struct Overrides: Equatable, Sendable {
        public var isGraphite: Bool?
        public var increaseContrast: Bool?
        public var reduceMotion: Bool?
        public var reduceTransparency: Bool?

        public init(isGraphite: Bool? = nil, increaseContrast: Bool? = nil, reduceMotion: Bool? = nil, reduceTransparency: Bool? = nil) {
            self.isGraphite = isGraphite
            self.increaseContrast = increaseContrast
            self.reduceMotion = reduceMotion
            self.reduceTransparency = reduceTransparency
        }
    }
}
