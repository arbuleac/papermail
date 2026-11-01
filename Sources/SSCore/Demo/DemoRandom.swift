import Foundation

/// SplitMix64: tiny, fast and identical on every run, so the demo mailbox is the same mailbox every time.
struct DemoRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    mutating func int(_ range: Range<Int>) -> Int {
        precondition(!range.isEmpty)
        return range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        int(range.lowerBound..<(range.upperBound + 1))
    }

    mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[int(0..<items.count)]
    }
}
