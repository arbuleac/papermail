import Foundation
import PaperCore
import XCTest
@testable import PaperGmail

/// Attachments the user opens stream to disk and report their bytes as they arrive (Q1.7b), with the client's token
/// retry and throttle mapping kept on that path.
final class GmailAttachmentDownloadTests: XCTestCase {
    private let server = StubServer.shared
    private let resource = "/users/me/messages/m1/attachments/ATT_BIG"
    private var folder: URL!

    override func setUpWithError() throws {
        server.reset()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("GmailAttachmentDownloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server.reset()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Streaming

    /// The reply arrives in pieces; each moves the chip on, never past 99% while the bytes are still base64 on
    /// disk, and 1 comes only once the decoded file is in place.
    func testADownloadReportsRisingProgressAndOneOnlyOnceTheFileIsDecoded() async throws {
        let bytes = Self.bytes(count: 30_000)
        server.on("GET", resource, Self.reply(for: bytes).chunked(6))
        let destination = folder.appendingPathComponent("file")
        let recorder = ProgressRecorder(watching: destination)

        try await TestSupport.makeProvider().downloadAttachment(messageID: "m1", attachmentID: "ATT_BIG", expectedSize: bytes.count,
                                                                to: destination, progress: recorder.record)

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let values = recorder.values
        XCTAssertEqual(values.first, 0, "a known size shows a determinate contrail from the start")
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted(), "rising")
        XCTAssertEqual(Set(values).count, values.count, "never the same fraction twice")
        XCTAssertGreaterThanOrEqual(values.count, 4, "several chunks moved the chip: \(values)")
        XCTAssertTrue(values.dropLast().allSatisfy { $0 <= DownloadProgressMeter.ceilingBeforeFinish }, "\(values)")
        XCTAssertEqual(recorder.sizeOnDiskAtOne, bytes.count, "1 was reported with the decoded file written")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["file"], "nothing else left behind")
    }

    /// Google usually sends the reply chunked; when it states its length that is what the bytes count against.
    func testTheReplysContentLengthMeasuresTheDownloadWhenTheSizeIsUnknown() async throws {
        let bytes = Self.bytes(count: 9_000)
        var reply = Self.reply(for: bytes)
        reply.headers["Content-Length"] = String(reply.body.count)
        server.on("GET", resource, reply.chunked(4))
        let destination = folder.appendingPathComponent("file")
        let recorder = ProgressRecorder()

        try await TestSupport.makeProvider().downloadAttachment(messageID: "m1", attachmentID: "ATT_BIG", expectedSize: 0,
                                                                to: destination, progress: recorder.record)

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let values = recorder.values
        XCTAssertGreaterThanOrEqual(values.count, 3, "\(values)")
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values.dropLast().last, DownloadProgressMeter.ceilingBeforeFinish, "every byte in, not yet decoded")
    }

    /// No size listed and no length stated: nothing to measure against, so the chip keeps its sweep.
    func testAnUnknownSizeReportsNothing() async throws {
        let bytes = Self.bytes(count: 5_000)
        server.on("GET", resource, Self.reply(for: bytes).chunked(3))
        let destination = folder.appendingPathComponent("file")
        let recorder = ProgressRecorder()

        try await TestSupport.makeProvider().downloadAttachment(messageID: "m1", attachmentID: "ATT_BIG", expectedSize: 0,
                                                                to: destination, progress: recorder.record)

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(recorder.values, [])
    }

    /// A file larger than one decoding slice, at every padding length, decodes byte for byte.
    func testLargeFilesDecodeAcrossSlicesAtEveryPaddingLength() async throws {
        for count in [600_000, 600_001, 600_002] {
            let bytes = Self.bytes(count: count)
            server.reset()
            server.on("GET", resource, Self.reply(for: bytes))
            let destination = folder.appendingPathComponent("file-\(count)")

            try await TestSupport.makeProvider().downloadAttachment(messageID: "m1", attachmentID: "ATT_BIG", expectedSize: count,
                                                                    to: destination, progress: { _ in })

            XCTAssertEqual(try Data(contentsOf: destination), bytes, "\(count) bytes")
        }
    }

    // MARK: Errors on the download path

    /// The token is refused once: it is refreshed and the download sent again, from the start, still rising.
    func testA401RefreshesTheTokenAndDownloadsAgain() async throws {
        let bytes = Self.bytes(count: 12_000)
        server.sequence("GET", resource, [
            .json(#"{"error":{"code":401,"message":"Invalid Credentials","status":"UNAUTHENTICATED"}}"#, status: 401),
            Self.reply(for: bytes).chunked(4),
        ])
        let tokens = FakeTokenProvider()
        let destination = folder.appendingPathComponent("file")
        let recorder = ProgressRecorder()

        try await TestSupport.makeProvider(tokens: tokens).downloadAttachment(messageID: "m1", attachmentID: "ATT_BIG",
                                                                              expectedSize: bytes.count, to: destination,
                                                                              progress: recorder.record)

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(tokens.invalidations, 1)
        XCTAssertEqual(server.requests(to: resource).map { $0.header("Authorization") }, ["Bearer token-1", "Bearer token-2"])
        XCTAssertEqual(recorder.values, recorder.values.sorted())
        XCTAssertEqual(recorder.values.last, 1)
    }

    func testTwo401sNeedSigningInAgain() async throws {
        server.on("GET", resource, .json(#"{"error":{"code":401,"message":"Invalid Credentials"}}"#, status: 401))
        let destination = folder.appendingPathComponent("file")

        let error = await TestSupport.providerError {
            try await TestSupport.makeProvider().downloadAttachment(messageID: "m1", attachmentID: "ATT_BIG", expectedSize: 10,
                                                                    to: destination, progress: { _ in })
        }

        guard case .unauthorized? = error else { return XCTFail("expected unauthorized, got \(String(describing: error))") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testA429IsThrottledWithItsRetryAfter() async throws {
        server.on("GET", resource, .json(Self.rateLimitError, status: 429, headers: ["Retry-After": "30"]))
        let destination = folder.appendingPathComponent("file")
        let recorder = ProgressRecorder()

        let error = await TestSupport.providerError {
            try await TestSupport.makeProvider().downloadAttachment(messageID: "m1", attachmentID: "ATT_BIG", expectedSize: 10,
                                                                    to: destination, progress: recorder.record)
        }

        guard case .throttled(let retryAfter)? = error else { return XCTFail("expected throttled, got \(String(describing: error))") }
        XCTAssertEqual(retryAfter, 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(recorder.values, [0], "the error document is not the file")
    }

    /// Google's per-user refusals are a 403 with a reason, not a 429.
    func testA403RateLimitIsThrottled() async throws {
        server.on("GET", resource, .json(Self.rateLimitError, status: 403))
        let destination = folder.appendingPathComponent("file")

        let error = await TestSupport.providerError {
            try await TestSupport.makeProvider().downloadAttachment(messageID: "m1", attachmentID: "ATT_BIG", expectedSize: 10,
                                                                    to: destination, progress: { _ in })
        }

        guard case .throttled? = error else { return XCTFail("expected throttled, got \(String(describing: error))") }
    }

    func testAMissingAttachmentIsNotFound() async throws {
        server.on("GET", resource, .json(GmailFixtures.notFoundError, status: 404))
        let destination = folder.appendingPathComponent("file")

        let error = await TestSupport.providerError {
            try await TestSupport.makeProvider().downloadAttachment(messageID: "m1", attachmentID: "ATT_BIG", expectedSize: 10,
                                                                    to: destination, progress: { _ in })
        }

        guard case .notFound? = error else { return XCTFail("expected notFound, got \(String(describing: error))") }
    }

    func testAReplyWithoutBase64DataIsADecodingErrorAndLeavesNoFile() async throws {
        server.on("GET", resource, .json(#"{"size": 3, "data": "not base64!"}"#))
        let destination = folder.appendingPathComponent("file")

        let error = await TestSupport.providerError {
            try await TestSupport.makeProvider().downloadAttachment(messageID: "m1", attachmentID: "ATT_BIG", expectedSize: 3,
                                                                    to: destination, progress: { _ in })
        }

        guard case .decoding? = error else { return XCTFail("expected decoding, got \(String(describing: error))") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testANetworkFailureIsANetworkError() async throws {
        server.on("GET", resource, .failure(URLError(.networkConnectionLost)))
        let destination = folder.appendingPathComponent("file")

        let error = await TestSupport.providerError {
            try await TestSupport.makeProvider().downloadAttachment(messageID: "m1", attachmentID: "ATT_BIG", expectedSize: 10,
                                                                    to: destination, progress: { _ in })
        }

        guard case .network? = error else { return XCTFail("expected network, got \(String(describing: error))") }
    }

    // MARK: Decoder

    /// Only the top-level `data` counts, wherever it sits, whatever the other members hold.
    func testTheDecoderFindsTheTopLevelDataMember() throws {
        let reply = folder.appendingPathComponent("reply.json")
        let json = #"{ "attachmentId" : "a\"data\":\"QUJD", "nested": {"data": "WFla"}, "list": [1, "data", {"x": [2]}], "size": 3 ,"# +
            "\n  \"data\": \"SGk_-w\"\n}"
        try Data(json.utf8).write(to: reply)
        let destination = folder.appendingPathComponent("out")

        try GmailAttachmentDecoder.decode(reply: reply, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data([0x48, 0x69, 0x3F, 0xFB]), "base64url, unpadded")
    }

    func testTheDecoderRefusesAReplyWithoutData() throws {
        let reply = folder.appendingPathComponent("reply.json")
        try Data(#"{"size": 3, "nested": {"data": "QUJD"}}"#.utf8).write(to: reply)
        let destination = folder.appendingPathComponent("out")

        XCTAssertThrowsError(try GmailAttachmentDecoder.decode(reply: reply, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTheReplyLengthEstimateCoversTheBase64AndItsJSON() {
        XCTAssertNil(GmailProvider.replyLength(forAttachmentOf: 0))
        let size = 30_000
        let encoded = Base64URL.encode(Self.bytes(count: size))
        let reply = Self.reply(for: Self.bytes(count: size)).body.count
        let estimate = Int(GmailProvider.replyLength(forAttachmentOf: size) ?? 0)
        XCTAssertGreaterThanOrEqual(estimate, reply, "never short, so the bytes never run past it")
        XCTAssertLessThan(estimate - encoded.count, 100, "and close")
    }

    // MARK: Helpers

    static let rateLimitError = """
    {"error":{"code":403,"message":"Rate Limit Exceeded","errors":[{"message":"Rate Limit Exceeded","domain":"usageLimits","reason":"rateLimitExceeded"}]}}
    """

    static func bytes(count: Int) -> Data {
        var state: UInt32 = 2_463_534_242
        return Data((0..<count).map { _ -> UInt8 in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        })
    }

    /// Gmail's reply, pretty-printed as Google sends it.
    static func reply(for bytes: Data) -> StubResponse {
        .json("{\n  \"size\": \(bytes.count),\n  \"data\": \"\(Base64URL.encode(bytes))\"\n}\n")
    }
}

/// Collects the fractions a download reports, and how much of the file was on disk when it reported 1.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let watched: URL?
    private var recorded: [Double] = []
    private var sizeAtOne: Int?

    init(watching file: URL? = nil) {
        watched = file
    }

    var values: [Double] { lock.withLock { recorded } }
    var sizeOnDiskAtOne: Int? { lock.withLock { sizeAtOne } }

    var record: @Sendable (Double) -> Void {
        { [self] fraction in
            let size = fraction >= 1 ? watched.flatMap { try? Data(contentsOf: $0).count } : nil
            lock.withLock {
                recorded.append(fraction)
                if fraction >= 1 { sizeAtOne = size }
            }
        }
    }
}
