import Foundation

/// Turns the bytes of a download into the fractions an attachment chip draws: rising only, never above 0.99 until
/// the caller says the file is complete, then 1. The length is the response's Content-Length when it states the
/// bytes that arrive (no Content-Encoding: URLSession hands over decoded bytes, so a compressed length would run
/// out early), otherwise the caller's estimate; with neither, the meter says nothing and the chip sweeps.
///
/// One meter spans every attempt of a download, so a request sent again after a refused token starts from where
/// the chip already is instead of jumping back.
public final class DownloadProgressMeter: @unchecked Sendable {
    /// What the bytes reach before the file is complete: decoding or moving it into place is still to come.
    public static let ceilingBeforeFinish = 0.99

    private let estimatedLength: Int64?
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var reported: Double?

    /// `estimatedLength` is how many bytes the response body should hold (nil or 0 when unknown). `report` hears
    /// each fraction on the caller's thread.
    public init(estimatedLength: Int64?, report: @escaping @Sendable (Double) -> Void) {
        self.estimatedLength = estimatedLength.flatMap { $0 > 0 ? $0 : nil }
        self.report = report
    }

    /// Reports 0 when the length is already known, so the chip shows a determinate contrail from the start rather
    /// than sweeping while the request is on its way.
    public func start() {
        guard estimatedLength != nil else { return }
        advance(to: 0)
    }

    /// `written` bytes of `response`'s body have arrived.
    public func received(_ written: Int64, of response: HTTPURLResponse) {
        guard let length = Self.length(of: response) ?? estimatedLength else { return }
        advance(to: min(Self.ceilingBeforeFinish, Double(written) / Double(length)))
    }

    /// The file is complete. Reports 1 when the download reported anything before; a download of unknown size
    /// stays indeterminate to the end.
    public func finish() {
        let determinate = lock.withLock { reported != nil }
        guard determinate else { return }
        advance(to: 1)
    }

    /// Reports under the lock, so two threads can never deliver their fractions out of order; `report` only hands
    /// the value on.
    private func advance(to fraction: Double) {
        lock.withLock {
            if let reported, fraction <= reported { return }
            reported = fraction
            report(fraction)
        }
    }

    /// The body's length as it arrives, when the response states it.
    static func length(of response: HTTPURLResponse) -> Int64? {
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespaces),
           !encoding.isEmpty, encoding.lowercased() != "identity" {
            return nil
        }
        let length = response.expectedContentLength
        return length > 0 ? length : nil
    }
}
