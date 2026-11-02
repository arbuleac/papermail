import SSDesign

/// Pins `QuireEnvironment` for tests that resolve colours or plan motion: the Mac running the tests may have
/// Graphite or Reduce Motion on, and the assertions are about the tokens, not that Mac.
enum QuireTestEnvironment {
    static func forceDefaults() {
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false))
    }

    static func reset() {
        QuireEnvironment.shared.setOverrides(.init())
    }
}
