import Foundation

/// FNV-1a over UTF-8 bytes.
///
/// `Hasher` is seeded per process, so two equal values hash differently across launches and, more importantly,
/// the row cache cannot rely on it to look up an entry by a value rebuilt later. This hasher is deterministic
/// for the life of the data, which is what a cache key derived from row content needs.
public struct StableHasher: Sendable {
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    private var state = StableHasher.offsetBasis

    public init() {}

    public mutating func combine(_ string: String) {
        for byte in string.utf8 { combineByte(byte) }
        // A terminator so ("ab", "c") and ("a", "bc") do not collide.
        combineByte(0xFF)
    }

    public mutating func combine(_ value: Int) {
        combine(UInt64(bitPattern: Int64(value)))
    }

    public mutating func combine(_ value: UInt64) {
        var remaining = value
        for _ in 0..<8 {
            combineByte(UInt8(truncatingIfNeeded: remaining))
            remaining >>= 8
        }
    }

    public mutating func combine(_ value: Bool) {
        combineByte(value ? 1 : 0)
    }

    /// Millisecond precision matches what the store persists, so a round trip through SQLite keeps the key.
    public mutating func combine(_ date: Date) {
        let milliseconds = (date.timeIntervalSinceReferenceDate * 1000).rounded()
        // Clamp so `.distantFuture` style sentinels cannot trap the integer conversion.
        let clamped = min(max(milliseconds, -9.0e18), 9.0e18)
        combine(UInt64(bitPattern: Int64(clamped)))
    }

    public var finalized: UInt64 { state }

    public static func hash(_ string: String) -> UInt64 {
        var hasher = StableHasher()
        hasher.combine(string)
        return hasher.finalized
    }

    private mutating func combineByte(_ byte: UInt8) {
        state ^= UInt64(byte)
        state = state &* StableHasher.prime
    }
}
