import Foundation

/// The API providers' one retry. A reply that has started to appear in the user's field is never asked for again
/// (the text would repeat, and a second answer may differ from the first), so only a failure before any text is
/// retried, once, after what the server asked for or a second. A server that asks for more than ten seconds is
/// answered with the error instead: the card then says when to try again, rather than spinning for a minute of the
/// write's two.
enum HTTPRetryPolicy {
    /// One try and one retry.
    static let attempts = 2
    /// The wait when the server named none.
    static let defaultDelay: TimeInterval = 1
    /// The longest wait worth spending inside one write.
    static let longestDelay: TimeInterval = 10

    typealias Pause = @Sendable (TimeInterval) async throws -> Void

    /// The real wait; tests pass one that records the delay and returns at once.
    static let sleep: Pause = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// How long to wait before the retry, or nil when the server asked for longer than `longestDelay`.
    static func delay(after retryAfter: TimeInterval?) -> TimeInterval? {
        let delay = max(0, retryAfter ?? defaultDelay)
        return delay <= longestDelay ? delay : nil
    }

    /// The server's wait in seconds: OpenAI's `retry-after-ms` first, then `retry-after` as seconds (Anthropic,
    /// OpenAI) or an HTTP date (RFC 9110 allows both).
    static func retryAfter(in response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        if let milliseconds = response.value(forHTTPHeaderField: "retry-after-ms").flatMap(seconds(in:)) {
            return milliseconds / 1000
        }
        guard let value = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return nil }
        if let seconds = seconds(in: value) { return seconds }
        guard let date = httpDate(value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    private static func seconds(in value: String) -> TimeInterval? {
        guard let number = Double(value.trimmingCharacters(in: .whitespaces)), number.isFinite, number >= 0 else { return nil }
        return number
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
