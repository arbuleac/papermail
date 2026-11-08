import CryptoKit
import Foundation

/// Disk cache for attachment bytes at `<root>/<account>/<message>/<attachmentID>`. On a miss it downloads through
/// the provider into a partial file in `<root>/.partial` and renames it into place once complete, so a download
/// that fails or stops never leaves a truncated file to be served later. Concurrent requests for the same attachment
/// share one download, and its progress, so the conversation view's inline images never hit the network twice.
///
/// A download is something the user asked for (a chip opened or saved, an inline image shown), so it is recorded as
/// live spend in the account's quota budget and never waits for it, like a message the user opens; a throttle on it
/// pauses the backfill (`QuotaBudget.liveThrottled`).
///
/// The cache holds at most `capacity` bytes on disk (docs/ARCHITECTURE.md, "Storage bounds"). Past it, files go least
/// recently used first, by modification date, which the cache sets to now whenever it serves a file (access times are
/// not kept reliably on every volume), down to nine tenths of the cap: a trim walks the whole folder on this actor, so a
/// full cache must not walk it again for every download. It trims at launch and after a download that takes it past
/// the cap, and never deletes a file being written (the `.partial` folder), one a download in flight is about to read
/// back, or the file just downloaded, nor the folder a download in flight will rename its file into.
/// Quick Look previews copies in their own temporary folder, so no preview ever holds a cache file open.
actor AttachmentCache {
    private struct Download {
        var task: Task<Data, Error>
        var progress: AttachmentProgressRelay
    }

    /// The most the cache keeps on disk: 1 GB, as Finder counts.
    static let capacityBytes: Int64 = 1_000_000_000

    private let root: URL
    private let capacity: Int64
    /// The bytes on disk as last measured plus what downloads wrote since; nil until the first trim measures them, so a
    /// download trims (and so walks the folder) only once the cache may be over its cap.
    private var knownBytes: Int64?
    /// Where downloads write until they are complete: one folder on the cache's volume, so the rename into place is
    /// one step, named with a dot so no account's folder can be it. A download cut off by quitting or a crash never
    /// removes its own file, so the folder is emptied before this cache's first download.
    private let partials: URL
    private var sweptPartials = false
    private var inFlight: [String: Download] = [:]

    init(root: URL, capacity: Int64 = AttachmentCache.capacityBytes) {
        self.root = root
        self.capacity = capacity
        self.partials = root.appendingPathComponent(".partial", isDirectory: true)
    }

    /// The attachment's bytes, from disk or downloaded once, and whether the download made the cache delete older
    /// files to stay under its cap. `progress` hears the download's fractions (at most about ten a second); a file
    /// already cached returns without a word, and so does a download whose size is unknown until it ends.
    func data(
        for message: MessageID,
        attachmentID: String,
        expectedSize: Int,
        provider: MailProvider,
        budget: QuotaBudget,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (data: Data, trimmed: Bool) {
        let url = fileURL(for: message, attachmentID: attachmentID)
        if let cached = try? Data(contentsOf: url) {
            Self.markUsed(url)
            return (cached, false)
        }
        let key = url.absoluteString
        if let existing = inFlight[key] {
            if let progress { existing.progress.add(progress) }
            return (try await existing.task.value, false)
        }
        if !sweptPartials {
            // Downloads start only here, on this actor, and the app keeps one cache per folder, so whatever is in
            // there is an earlier run's.
            sweptPartials = true
            try? FileManager.default.removeItem(at: partials)
        }
        let relay = AttachmentProgressRelay()
        if let progress { relay.add(progress) }
        let partials = partials
        let task = Task.detached(priority: .userInitiated) { () throws -> Data in
            await budget.recordLive(budget.quota.attachmentCost)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: partials, withIntermediateDirectories: true)
            let partial = partials.appendingPathComponent(UUID().uuidString + ".partial", isDirectory: false)
            defer { try? FileManager.default.removeItem(at: partial) }
            do {
                try await provider.downloadAttachment(messageID: message.providerID, attachmentID: attachmentID,
                                                      expectedSize: expectedSize, to: partial, progress: { relay.report($0) })
            } catch {
                // Live spend, so a throttle here pauses the backfill as one on the live lane does.
                if case .throttled(let retryAfter)? = error as? ProviderError {
                    await budget.liveThrottled(retryAfter: retryAfter)
                }
                throw error
            }
            // rename(2) replaces whatever is there in one step, so a reader never sees half a file.
            guard rename(partial.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return try Data(contentsOf: url)
        }
        inFlight[key] = Download(task: task, progress: relay)
        defer { inFlight[key] = nil }
        let data = try await task.value
        var trimmed = false
        if let known = knownBytes {
            let total = known + Self.diskSize(of: url)
            knownBytes = total
            if total > capacity { trimmed = trim(keeping: url) > 0 }
        } else {
            trimmed = trim(keeping: url) > 0
        }
        return (data, trimmed)
    }

    func removeAll(for accountID: AccountID) {
        let directory = root.appendingPathComponent(Self.safeComponent(accountID.rawValue), isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        knownBytes = nil
    }

    /// Measures the cache and, when it is over `capacity`, deletes files least recently used first until it holds no
    /// more than `lowWater`. Spares `keeping`, the files downloads in flight will read back, and everything under the
    /// hidden `.partial` folder (cache entries never have a dot in their names, so skipping hidden files skips exactly
    /// that). Returns how many bytes it freed.
    @discardableResult
    func trim(keeping: URL? = nil) -> Int64 {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            knownBytes = 0
            return 0
        }
        var files: [(url: URL, size: Int64, used: Date)] = []
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        var freed: Int64 = 0
        if total > capacity {
            // Compared as resolved paths: the walk can hand back /private/var/… for a root spelled /var/….
            let downloading = inFlight.keys.compactMap(URL.init(string:))
            let spared = Set((downloading + [keeping].compactMap { $0 }).map(Self.resolvedPath))
            // A download in flight renames its file into its message's folder when it ends, so that folder stays even
            // while it looks empty (the file is still under `.partial`).
            let landing = Set(downloading.map { Self.resolvedPath($0.deletingLastPathComponent()) })
            for file in files.sorted(by: { $0.used < $1.used }) where total - freed > lowWater {
                guard !spared.contains(Self.resolvedPath(file.url)) else { continue }
                guard (try? fileManager.removeItem(at: file.url)) != nil else { continue }
                freed += file.size
                // A message's folder goes with its last file.
                let folder = file.url.deletingLastPathComponent()
                if !landing.contains(Self.resolvedPath(folder)),
                   (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                    try? fileManager.removeItem(at: folder)
                }
            }
        }
        knownBytes = total - freed
        if freed > 0 { SyncLog.logger.info("attachment cache: freed \(freed, privacy: .public) bytes to stay under its cap") }
        return freed
    }

    /// Where a trim stops: about the next 100 MB of downloads (at the 1 GB cap) go on disk before the folder is walked
    /// again, instead of every download walking tens of thousands of files while cached images wait behind it.
    private var lowWater: Int64 {
        capacity - capacity / 10
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// A file served from the cache counts as used now, which is what the trim orders by.
    private static func markUsed(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private static func diskSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    nonisolated func fileURL(for message: MessageID, attachmentID: String) -> URL {
        root.appendingPathComponent(Self.safeComponent(message.accountID.rawValue), isDirectory: true)
            .appendingPathComponent(Self.safeComponent(message.providerID), isDirectory: true)
            .appendingPathComponent(Self.safeComponent(attachmentID), isDirectory: false)
    }

    /// Provider ids are opaque: they can contain path separators or dots, or run far past the file-name limit
    /// (Gmail attachment ids are hundreds of characters). Keep only safe characters and hash anything long.
    private static func safeComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        if encoded.isEmpty { return "_" }
        if encoded.utf8.count <= 180 { return encoded }
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
