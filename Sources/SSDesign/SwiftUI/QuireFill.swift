import SwiftUI

/// A control face as Quire describes it: an optional opaque base with an optional wash composited over it
/// (`raised + hover`, `sheet + pressed`). A face with no base is transparent: the surface beneath shows, and a
/// wash alone (`fill` on the toggle's off track) composites over whatever that surface is (spec §4.1).
public struct QuireFill: Equatable, Sendable {
    public var base: QuireColorToken?
    public var wash: QuireColorToken?

    public init(_ base: QuireColorToken? = nil, wash: QuireColorToken? = nil) {
        self.base = base
        self.wash = wash
    }

    /// Nothing drawn.
    public static let clear = QuireFill()

    public var isClear: Bool { base == nil && wash == nil }

    /// The tokens in drawing order, as `contrastPairs` writes a stack in tokens.json.
    public var stack: [QuireColorToken] { [base, wash].compactMap { $0 } }
}
