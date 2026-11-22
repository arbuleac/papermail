import PaperDesign

/// Pins `QuireEnvironment` for tests that resolve colours or plan motion: the Mac running the tests may have
/// Graphite or Reduce Motion on, and the assertions are about the tokens, not that Mac. The theme is pinned too, to
/// Study unless a test asks for another (spec §4.16).
enum QuireTestEnvironment {
    static func forceDefaults(theme: QuireTheme = .study) {
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false,
                                                   theme: theme))
    }

    static func reset() {
        QuireEnvironment.shared.setOverrides(.init())
    }
}
