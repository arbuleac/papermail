import Foundation
import XCTest
@testable import SSCore

/// The transfer under both providers' attachment downloads. Each provider's stub `URLProtocol` drives the streaming
/// itself; this covers the hand-over between the caller and URLSession's delegate queue.
final class HTTPDownloadTests: XCTestCase {
    /// A task cancelled before it is resumed (the caller cancelled between `run`'s first check and `begin`) still
    /// completes, on URLSession's queue and whenever it gets to it, which can be before the caller hands over its
    /// continuation. The caller must hear that completion rather than wait for ever.
    func testACompletionBeforeTheCallerWaitsStillResumesIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HTTPDownloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // Never resumed, so nothing goes out.
        let task = session.dataTask(with: URL(string: "https://example.invalid/attachment")!)
        let receiver = HTTPDownload.Receiver(destination: folder.appendingPathComponent("file"), onBytes: { _, _ in })
        receiver.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))

        let heard = Heard()
        let resumed = expectation(description: "the caller is resumed")
        Task {
            do {
                _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPDownload.Outcome, Error>) in
                    heard.started = receiver.begin(continuation)
                }
            } catch {
                heard.error = error
            }
            resumed.fulfill()
        }
        await fulfillment(of: [resumed], timeout: 5)

        XCTAssertEqual((heard.error as? URLError)?.code, .cancelled)
        XCTAssertEqual(heard.started, false, "a task that has completed is not started")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("file").path))
    }
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedError: Error?
    private var recordedStarted: Bool?

    var error: Error? {
        get { lock.withLock { recordedError } }
        set { lock.withLock { recordedError = newValue } }
    }

    var started: Bool? {
        get { lock.withLock { recordedStarted } }
        set { lock.withLock { recordedStarted = newValue } }
    }
}
