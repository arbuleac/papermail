import Foundation

/// The exponential delay schedule every retry path in the engine shares.
enum Backoff {
    /// Delay before the given 1-based attempt: `base`, then doubling, never above `cap`.
    static func delay(attempt: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        // The exponent is clamped so a long-lived counter cannot overflow the power into infinity.
        let exponent = Double(max(0, min(attempt - 1, 30)))
        return max(0, min(cap, base * pow(2, exponent)))
    }

    /// The wait after a throttled response: the provider's `Retry-After` when it sent one, but never under
    /// `base`, so "retry after 0" cannot turn the retry into a hot loop, nor over `cap`, since a retry time is
    /// measured against this Mac's clock and a skewed one stretches it; the regular schedule otherwise.
    static func throttleDelay(retryAfter: TimeInterval?, attempt: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        guard let retryAfter else { return delay(attempt: attempt, base: base, cap: cap) }
        return min(max(retryAfter, base), max(cap, base))
    }
}
