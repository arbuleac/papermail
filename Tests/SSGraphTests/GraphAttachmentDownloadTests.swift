import Foundation
import SSCore
import XCTest
@testable import SSGraph

/// Attachments the user opens stream their raw bytes to disk and report them as they arrive (Q1.7b), with the
/// transport's token retry, request tally and throttle mapping kept on that path.
final class GraphAttachmentDownloadTests: GraphTestCase {
    private let valuePath = "/v1.0/me/messages/M-1/attachments/A-2/$value"
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("GraphAttachmentDownloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        try super.tearDownWithError()
    }

    func testADownloadStreamsTheRawBytesWithRisingProgressEndingAtOne() async throws {
        let bytes = Self.bytes(count: 40_000)
        route { [valuePath] request in
            request.path == valuePath ? Self.chunked(bytes, contentLength: true, pieces: 5) : nil
        }
        let destination = folder.appendingPathComponent("file")
        let recorder = ProgressRecorder()

        try await makeProvider().downloadAttachment(messageID: "M-1", attachmentID: "A-2", expectedSize: bytes.count,
                                                    to: destination, progress: recorder.record)

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let values = recorder.values
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(Set(values).count, values.count)
        XCTAssertGreaterThanOrEqual(values.count, 4, "several chunks moved the chip: \(values)")
        XCTAssertTrue(values.dropLast().allSatisfy { $0 <= DownloadProgressMeter.ceilingBeforeFinish })
        XCTAssertEqual(requests.map(\.path), [valuePath])
        XCTAssertEqual(requests.first?.header("Accept"), "*/*")
        XCTAssertEqual(requests.first?.header("Authorization"), "Bearer token-1")
    }

    /// Graph's listed size runs a little over the file; the stated length is what the bytes count against.
    func testTheContentLengthWinsOverTheListedSize() async throws {
        let bytes = Self.bytes(count: 20_000)
        route { [valuePath] request in
            request.path == valuePath ? Self.chunked(bytes, contentLength: true, pieces: 4) : nil
        }
        let recorder = ProgressRecorder()

        try await makeProvider().downloadAttachment(messageID: "M-1", attachmentID: "A-2", expectedSize: 26_000,
                                                    to: folder.appendingPathComponent("file"), progress: recorder.record)

        XCTAssertEqual(recorder.values.dropLast().last, DownloadProgressMeter.ceilingBeforeFinish, "every stated byte arrived")
        XCTAssertEqual(recorder.values.last, 1)
    }

    /// Without a stated length the listed size measures it; with neither, the chip keeps its sweep.
    func testTheListedSizeMeasuresAChunkedReplyAndNoSizeReportsNothing() async throws {
        let bytes = Self.bytes(count: 20_000)
        route { [valuePath] request in
            request.path == valuePath ? Self.chunked(bytes, contentLength: false, pieces: 4) : nil
        }
        let measured = ProgressRecorder()
        try await makeProvider().downloadAttachment(messageID: "M-1", attachmentID: "A-2", expectedSize: bytes.count,
                                                    to: folder.appendingPathComponent("measured"), progress: measured.record)
        XCTAssertGreaterThanOrEqual(measured.values.count, 4, "\(measured.values)")
        XCTAssertEqual(measured.values, measured.values.sorted())
        XCTAssertEqual(measured.values.last, 1)

        let unknown = ProgressRecorder()
        try await makeProvider().downloadAttachment(messageID: "M-1", attachmentID: "A-2", expectedSize: 0,
                                                    to: folder.appendingPathComponent("unknown"), progress: unknown.record)
        XCTAssertEqual(unknown.values, [])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("unknown")), bytes)
    }

    func testA401RefreshesTheTokenAndDownloadsAgain() async throws {
        tokens = StubTokenProvider(tokens: ["token-1", "token-2"])
        let bytes = Self.bytes(count: 12_000)
        route { [valuePath] request in
            guard request.path == valuePath else { return nil }
            if request.header("Authorization") == "Bearer token-1" {
                return .json(#"{"error":{"code":"InvalidAuthenticationToken","message":"expired"}}"#, status: 401)
            }
            return Self.chunked(bytes, contentLength: true, pieces: 4)
        }
        let destination = folder.appendingPathComponent("file")
        let recorder = ProgressRecorder()

        let (_, sent) = try await GraphRequestTally.counting {
            try await self.makeProvider().downloadAttachment(messageID: "M-1", attachmentID: "A-2", expectedSize: bytes.count,
                                                             to: destination, progress: recorder.record)
        }

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(tokens.invalidations, 1)
        XCTAssertEqual(requests.map { $0.header("Authorization") }, ["Bearer token-1", "Bearer token-2"])
        XCTAssertEqual(sent, 2, "the transport counts the refused attempt as it does for every request")
        XCTAssertEqual(recorder.values, recorder.values.sorted())
        XCTAssertEqual(recorder.values.last, 1)
    }

    func testTwo401sNeedSigningInAgain() async throws {
        route { [valuePath] request in
            request.path == valuePath ? .json(#"{"error":{"code":"InvalidAuthenticationToken","message":"expired"}}"#, status: 401) : nil
        }
        let destination = folder.appendingPathComponent("file")

        await expectProviderError({
            try await self.makeProvider().downloadAttachment(messageID: "M-1", attachmentID: "A-2", expectedSize: 10,
                                                             to: destination, progress: { _ in })
        }, matches: \.isUnauthorized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testA429IsThrottledWithItsRetryAfter() async throws {
        route { [valuePath] request in
            request.path == valuePath
                ? .json(#"{"error":{"code":"TooManyRequests","message":"slow down"}}"#, status: 429, headers: ["Retry-After": "7"])
                : nil
        }
        let destination = folder.appendingPathComponent("file")

        await expectProviderError({
            try await self.makeProvider().downloadAttachment(messageID: "M-1", attachmentID: "A-2", expectedSize: 10,
                                                             to: destination, progress: { _ in })
        }, matches: { $0.retryAfter == 7 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(requests.count, 1, "a throttle is not a missing $value: no fallback request")
    }

    func testA503WithRetryAfterIsThrottled() async throws {
        route { [valuePath] request in
            request.path == valuePath
                ? .json(#"{"error":{"code":"ServiceUnavailable","message":"busy"}}"#, status: 503, headers: ["Retry-After": "9"])
                : nil
        }

        await expectProviderError({
            try await self.makeProvider().downloadAttachment(messageID: "M-1", attachmentID: "A-2", expectedSize: 10,
                                                             to: self.folder.appendingPathComponent("file"), progress: { _ in })
        }, matches: { $0.retryAfter == 9 })
    }

    /// An item or reference attachment has no `$value`; its bytes come as base64 in JSON, as before.
    func testAnAttachmentWithoutRawBytesFallsBackToContentBytes() async throws {
        let bytes = Data([9, 8, 7, 6, 5])
        route { request in
            switch request.path {
            case "/v1.0/me/messages/M-1/attachments/A-2/$value": return .json(Fixtures.notFoundError, status: 404)
            case "/v1.0/me/messages/M-1/attachments/A-2": return .json(Fixtures.attachmentWithBytes(bytes))
            default: return nil
            }
        }
        let destination = folder.appendingPathComponent("file")
        let recorder = ProgressRecorder()

        try await makeProvider().downloadAttachment(messageID: "M-1", attachmentID: "A-2", expectedSize: bytes.count,
                                                    to: destination, progress: recorder.record)

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(recorder.values, [0, 1])
    }

    func testANetworkFailureIsANetworkErrorAndLeavesNoFile() async throws {
        route { [valuePath] request in request.path == valuePath ? .failure(.networkConnectionLost) : nil }
        let destination = folder.appendingPathComponent("file")

        await expectProviderError({
            try await self.makeProvider().downloadAttachment(messageID: "M-1", attachmentID: "A-2", expectedSize: 10,
                                                             to: destination, progress: { _ in })
        }, matches: \.isNetwork)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Cancelling the caller stops the transfer: no file, a cancellation, not a network error.
    func testCancellingStopsTheDownload() async throws {
        let bytes = Self.bytes(count: 40_000)
        route { [valuePath] request in
            request.path == valuePath ? Self.chunked(bytes, contentLength: true, pieces: 40) : nil
        }
        let destination = folder.appendingPathComponent("file")
        let started = expectation(description: "bytes arrived")
        started.assertForOverFulfill = false
        let provider = makeProvider()
        let task = Task {
            try await provider.downloadAttachment(messageID: "M-1", attachmentID: "A-2", expectedSize: bytes.count,
                                                  to: destination, progress: { fraction in if fraction > 0 { started.fulfill() } })
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()

        do {
            try await task.value
            XCTFail("expected the download to stop")
        } catch ProviderError.cancelled {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: Helpers

    static func bytes(count: Int) -> Data {
        var state: UInt32 = 88_172_645
        return Data((0..<count).map { _ -> UInt8 in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        })
    }

    static func chunked(_ bytes: Data, contentLength: Bool, pieces: Int) -> Reply {
        var headers = ["Content-Type": "application/octet-stream"]
        if contentLength { headers["Content-Length"] = String(bytes.count) }
        return .chunked(status: 200, headers: headers, body: bytes, pieces: pieces)
    }
}

/// Collects the fractions a download reports.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var values: [Double] { lock.withLock { recorded } }

    var record: @Sendable (Double) -> Void {
        { [self] fraction in lock.withLock { recorded.append(fraction) } }
    }
}
