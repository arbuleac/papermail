import Foundation

/// The exponential delay schedule every retry path in the engine shares.
enum Backoff {
    /// Delay before the given 1-based attempt: `base`, then doubling, never above `cap`.
    static func delay(attempt: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        // The exponent is clamped so a long-lived counter cannot overflow the power into infinity.
        let exponent = Double(max(0, min(attempt - 1, 30)))
        return max(0, min(cap, base * pow(2, exponent)))
    }
}
