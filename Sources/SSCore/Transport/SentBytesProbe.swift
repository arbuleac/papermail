import Foundation

/// A task delegate that hears how many bytes of a request left this Mac, so a "no network" failure URLSession reports
/// for a request already on its way (the interface went down after the body was sent) is told apart from one that never
/// left (`ProviderError.transport(_:bytesSent:)`). Passed to `URLSession.data(for:delegate:)`, which delivers a failed
/// task's metrics before the call throws. A probe that heard nothing says nil, which counts as "may have left": a send
/// is then marked failed rather than risk going out twice.
public final class SentBytesProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: Int64?

    /// The request's header and body bytes every transaction of the task sent; nil until the metrics arrive.
    public var bytesSent: Int64? {
        lock.withLock { sent }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let bytes = metrics.transactionMetrics.reduce(Int64(0)) {
            $0 + $1.countOfRequestHeaderBytesSent + $1.countOfRequestBodyBytesSent
        }
        lock.withLock { sent = bytes }
    }
}
