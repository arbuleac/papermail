import Foundation

/// One HTTP request whose successful body goes to a file as it arrives instead of into memory, reporting the bytes
/// written, so an attachment of any size downloads in constant memory and can say how far it has got. The
/// providers' transports wrap it in their own token retry and status mapping, as they do their buffered requests.
///
/// It runs a data task with a task delegate rather than `URLSession.data(for:)`, which hands back the body only
/// once it is complete; a test session's stub `URLProtocol` drives it like any other task.
public enum HTTPDownload {
    /// What came back. A reply outside 200…299 leaves the file alone and carries its body here instead, for the
    /// transport's error mapping (an error document, so it is kept in memory, up to `maxErrorBody` bytes).
    public struct Outcome: Sendable {
        public var response: HTTPURLResponse
        public var errorBody: Data?

        public init(response: HTTPURLResponse, errorBody: Data?) {
            self.response = response
            self.errorBody = errorBody
        }
    }

    /// Error documents are a few hundred bytes; anything longer is not one, and only its start is worth keeping.
    public static let maxErrorBody = 256 * 1024

    /// Sends `request` and writes a 2xx body to `destination` (created or truncated) as it arrives. `onBytes` hears
    /// the bytes written so far after every chunk, with the response they belong to, on the session's delegate
    /// queue. Throws what the transfer throws (`URLError`, `CancellationError`) or a file error (`CocoaError`), and
    /// leaves no partial file behind when it does. Cancelling the calling task cancels the transfer.
    public static func run(
        _ request: URLRequest,
        session: URLSession,
        to destination: URL,
        onBytes: @escaping @Sendable (_ written: Int64, _ response: HTTPURLResponse) -> Void
    ) async throws -> Outcome {
        try Task.checkCancellation()
        let receiver = Receiver(destination: destination, onBytes: onBytes)
        let task = session.dataTask(with: request)
        task.delegate = receiver
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, Error>) in
                if receiver.begin(continuation) { task.resume() }
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The task's delegate: opens the file when a 2xx response arrives, appends each chunk, and resumes the caller
    /// once the task completes. URLSession calls it on one serial queue; the lock covers the continuation, which
    /// `begin` sets from the caller's thread, and a completion that beat it. Internal, not private, so a test can
    /// complete it before `begin`, an order no real transfer produces on demand.
    final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let destination: URL
        private let onBytes: @Sendable (Int64, HTTPURLResponse) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Error>?
        /// The result of a task that completed before `begin`: one cancelled before it was resumed (the caller
        /// cancelled between `run`'s first check and `begin`) still completes, on the delegate queue, whenever
        /// URLSession gets to it, and with no continuation yet to take it the caller would wait for ever.
        private var completed: Result<Outcome, Error>?
        private var response: HTTPURLResponse?
        private var file: FileHandle?
        private var wroteFile = false
        private var written: Int64 = 0
        private var errorBody: Data?
        private var fileError: Error?

        init(destination: URL, onBytes: @escaping @Sendable (Int64, HTTPURLResponse) -> Void) {
            self.destination = destination
            self.onBytes = onBytes
        }

        /// Hands over the caller's continuation; false when the task has already completed, which resumes it at
        /// once and leaves nothing to start.
        func begin(_ continuation: CheckedContinuation<Outcome, Error>) -> Bool {
            let completed: Result<Outcome, Error>? = lock.withLock {
                if let completed = self.completed { return completed }
                self.continuation = continuation
                return nil
            }
            guard let completed else { return true }
            continuation.resume(with: completed)
            return false
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.allow)
                return
            }
            lock.withLock {
                // A redirect's own response never reaches here; a second call would be a new body, so start over.
                closeFile()
                self.response = http
                written = 0
                errorBody = nil
                if (200..<300).contains(http.statusCode) {
                    do {
                        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination])
                        }
                        wroteFile = true
                        file = try FileHandle(forWritingTo: destination)
                    } catch {
                        fileError = error
                    }
                } else {
                    errorBody = Data()
                }
            }
            if lock.withLock({ fileError != nil }) {
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let report: (Int64, HTTPURLResponse)? = lock.withLock {
                guard let response else { return nil }
                if errorBody != nil {
                    let room = HTTPDownload.maxErrorBody - (errorBody?.count ?? 0)
                    if room > 0 { errorBody?.append(data.prefix(room)) }
                    return nil
                }
                guard let file, fileError == nil else { return nil }
                do {
                    try file.write(contentsOf: data)
                } catch {
                    fileError = error
                    return nil
                }
                written += Int64(data.count)
                return (written, response)
            }
            if let report {
                onBytes(report.0, report.1)
            } else if lock.withLock({ fileError != nil }) {
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, result, created): (CheckedContinuation<Outcome, Error>?, Result<Outcome, Error>, Bool) = lock.withLock {
                closeFile()
                let result: Result<Outcome, Error>
                if let fileError {
                    result = .failure(fileError)
                } else if let error {
                    result = .failure(error)
                } else if let response {
                    result = .success(Outcome(response: response, errorBody: errorBody))
                } else {
                    result = .failure(URLError(.badServerResponse))
                }
                let pending = self.continuation
                self.continuation = nil
                if pending == nil { completed = result }
                return (pending, result, wroteFile)
            }
            if case .failure = result, created {
                try? FileManager.default.removeItem(at: destination)
            }
            continuation?.resume(with: result)
        }

        /// Called with the lock held.
        private func closeFile() {
            try? file?.close()
            file = nil
        }
    }
}
