import Foundation
import XCTest
@testable import PaperCore

/// The attachment cache's cap (roadmap Q1.6, docs/ARCHITECTURE.md "Storage bounds"): 1 GB on disk, least recently used
/// first by modification date (set to now whenever the cache serves a file), trimmed at launch and after a download
/// that takes it past the cap, down to nine tenths of it, never touching the partial files of downloads under way or the
/// file just downloaded.
final class AttachmentCacheTrimTests: XCTestCase {
    private var root: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentCacheTrimTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    private let fileSize = 16_384

    private func message(_ number: Int) -> MessageID {
        MessageID(accountID: Fixtures.accountID, providerID: "m\(number)")
    }

    /// Writes a cached attachment last used `daysAgo` days ago and returns its URL.
    @discardableResult
    private func cached(_ cache: AttachmentCache, _ number: Int, daysAgo: Double) throws -> URL {
        let url = cache.fileURL(for: message(number), attachmentID: "a\(number)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: UInt8(number % 255), count: fileSize).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
        return url
    }

    private func onDisk(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? 0)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func testTheCapIsOneGigabyte() {
        XCTAssertEqual(AttachmentCache.capacityBytes, 1_000_000_000)
    }

    func testTrimDeletesTheLeastRecentlyUsedUntilTheCacheFitsAndSparesPartialFiles() async throws {
        let root = try XCTUnwrap(root)
        let probe = AttachmentCache(root: root)
        let oldest = try cached(probe, 1, daysAgo: 30)
        let older = try cached(probe, 2, daysAgo: 20)
        let newer = try cached(probe, 3, daysAgo: 10)
        let newest = try cached(probe, 4, daysAgo: 1)
        // A download under way writes here; it is bigger than everything else and the oldest of all.
        let partials = root.appendingPathComponent(".partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partials, withIntermediateDirectories: true)
        let partial = partials.appendingPathComponent("\(UUID().uuidString).partial")
        try Data(count: fileSize * 4).write(to: partial)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86_400)], ofItemAtPath: partial.path)
        let each = onDisk(oldest)

        // Room for two files and a half.
        let cache = AttachmentCache(root: root, capacity: each * 5 / 2)
        let freed = await cache.trim()

        XCTAssertEqual(freed, each * 2)
        XCTAssertFalse(exists(oldest))
        XCTAssertFalse(exists(older))
        XCTAssertTrue(exists(newer))
        XCTAssertTrue(exists(newest))
        XCTAssertTrue(exists(partial), "a file being written is never deleted, nor counted")
        XCTAssertFalse(exists(oldest.deletingLastPathComponent()), "a message's folder goes with its last file")
        let again = await cache.trim()
        XCTAssertEqual(again, 0, "a cache under its cap is left alone")
    }

    /// Serving a file from the cache counts as using it, so an old file opened today outlives a newer one nobody opened.
    func testAFileServedFromTheCacheCountsAsJustUsed() async throws {
        let root = try XCTUnwrap(root)
        let probe = AttachmentCache(root: root)
        let reopened = try cached(probe, 1, daysAgo: 30)
        let untouched = try cached(probe, 2, daysAgo: 5)
        let each = onDisk(reopened)
        let cache = AttachmentCache(root: root, capacity: each * 3 / 2)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)

        let served = try await cache.data(for: message(1), attachmentID: "a1", expectedSize: fileSize, provider: provider,
                                          budget: QuotaBudget(quota: .unlimited))
        XCTAssertEqual(served.data.count, fileSize)
        XCTAssertFalse(served.trimmed, "a file already cached trims nothing")
        XCTAssertEqual(provider.attachmentCalls.count, 0)

        await cache.trim()
        XCTAssertTrue(exists(reopened))
        XCTAssertFalse(exists(untouched))
    }

    /// A download adds what it wrote; once that takes the cache past its cap, the oldest files go and the one just
    /// downloaded stays, even when it alone is larger than the cap.
    func testADownloadTrimsTheCacheAndKeepsTheFileItWrote() async throws {
        let root = try XCTUnwrap(root)
        let probe = AttachmentCache(root: root)
        let oldest = try cached(probe, 1, daysAgo: 30)
        let newer = try cached(probe, 2, daysAgo: 2)
        let each = onDisk(oldest)
        let cache = AttachmentCache(root: root, capacity: each * 5 / 2)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.attachments["m3/a3"] = Data(repeating: 3, count: fileSize)
        provider.attachments["m4/a4"] = Data(repeating: 4, count: fileSize * 4)
        let budget = QuotaBudget(quota: .unlimited)
        await cache.trim()
        XCTAssertTrue(exists(oldest), "two files fit")

        let third = try await cache.data(for: message(3), attachmentID: "a3", expectedSize: fileSize, provider: provider, budget: budget)
        XCTAssertTrue(third.trimmed)
        XCTAssertFalse(exists(oldest), "the least recently used went")
        XCTAssertTrue(exists(newer))
        let thirdURL = cache.fileURL(for: message(3), attachmentID: "a3")
        XCTAssertTrue(exists(thirdURL))

        let large = try await cache.data(for: message(4), attachmentID: "a4", expectedSize: fileSize * 4, provider: provider, budget: budget)
        XCTAssertEqual(large.data.count, fileSize * 4)
        XCTAssertTrue(exists(cache.fileURL(for: message(4), attachmentID: "a4")), "the file just downloaded is kept")
        XCTAssertFalse(exists(newer))
        XCTAssertFalse(exists(thirdURL))
    }

    /// A trim walks the whole cache on the cache's actor, where cached images wait behind it. So once the cache is past
    /// its cap a trim takes it down to nine tenths, and the downloads after it fill that room without walking the cache
    /// again, rather than every download walking tens of thousands of files.
    func testATrimMakesRoomForTheNextDownloadsInsteadOfStoppingAtTheCap() async throws {
        let root = try XCTUnwrap(root)
        let probe = AttachmentCache(root: root)
        let files = try (1...11).map { try cached(probe, $0, daysAgo: Double(40 - $0)) }
        let each = onDisk(files[0])
        let cache = AttachmentCache(root: root, capacity: each * 10)
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.attachments["m20/a20"] = Data(repeating: 20, count: fileSize)
        let budget = QuotaBudget(quota: .unlimited)

        let freed = await cache.trim()
        XCTAssertEqual(freed, each * 2, "down to nine tenths of the cap, not to the cap")
        XCTAssertFalse(exists(files[0]))
        XCTAssertFalse(exists(files[1]))
        XCTAssertTrue(exists(files[2]))

        let next = try await cache.data(for: message(20), attachmentID: "a20", expectedSize: fileSize, provider: provider, budget: budget)
        XCTAssertFalse(next.trimmed, "the next download fits the room the trim made")
        XCTAssertTrue(files[2...].allSatisfy(exists))
    }

    /// A download in flight renames its file into its message's folder only when it ends. A trim meanwhile (another
    /// download finishing past the cap) that deletes that message's last cached file leaves the folder in place, so the
    /// download still lands instead of failing after its bytes arrived.
    func testATrimLeavesTheFolderADownloadInFlightWillLandIn() async throws {
        let root = try XCTUnwrap(root)
        let probe = AttachmentCache(root: root)
        let oldest = try cached(probe, 1, daysAgo: 90)
        try cached(probe, 5, daysAgo: 2)
        let cache = AttachmentCache(root: root, capacity: onDisk(oldest) * 5 / 2)
        await cache.trim()
        XCTAssertTrue(exists(oldest), "two files fit")
        let budget = QuotaBudget(quota: .unlimited)

        // Message 1's second attachment, downloading and held.
        let held = ScriptedProvider(accountID: Fixtures.accountID)
        held.attachments["m1/b1"] = Data(repeating: 2, count: fileSize)
        held.holdAttachmentDownloads = true
        let download = Task {
            try await cache.data(for: self.message(1), attachmentID: "b1", expectedSize: self.fileSize, provider: held, budget: budget)
        }
        try await waitUntil("the held download under way") { held.attachmentCalls.count == 1 }

        // Another message's download finishes and takes the cache past its cap: message 1's old file goes.
        let other = ScriptedProvider(accountID: Fixtures.accountID)
        other.attachments["m3/c3"] = Data(repeating: 3, count: fileSize)
        let third = try await cache.data(for: message(3), attachmentID: "c3", expectedSize: fileSize, provider: other, budget: budget)
        XCTAssertTrue(third.trimmed)
        XCTAssertFalse(exists(oldest), "the least recently used went")
        XCTAssertTrue(exists(oldest.deletingLastPathComponent()), "its folder stays: a download in flight lands there")

        held.holdAttachmentDownloads = false
        let landed = try await download.value
        XCTAssertEqual(landed.data.count, fileSize)
        XCTAssertTrue(exists(cache.fileURL(for: message(1), attachmentID: "b1")))
    }

    /// The engine measures and trims the cache when it starts, off the main thread, and tells Settings the size changed.
    func testTheEngineTrimsTheCacheAtLaunch() async throws {
        let root = try XCTUnwrap(root)
        let probe = AttachmentCache(root: root)
        let files = try (1...3).map { try cached(probe, $0, daysAgo: Double(10 - $0)) }

        let small = try EngineHarness(seedAccount: false, cacheDirectory: root, cacheCapacity: onDisk(files[0]) * 3 / 2)
        let changes = Counter()
        let observation = small.engine.observeStorageChanges { changes.increment() }
        defer { observation.cancel() }
        small.engine.start()
        try await waitUntil("the launch trim") { !self.exists(files[0]) && !self.exists(files[1]) }
        XCTAssertTrue(exists(files[2]))
        try await waitUntil("subscribers told") { changes.value == 1 }
        await small.shutdown()
    }
}
