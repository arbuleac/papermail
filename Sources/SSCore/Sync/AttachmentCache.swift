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
actor AttachmentCache {
    private struct Download {
        var task: Task<Data, Error>
        var progress: AttachmentProgressRelay
    }

    private let root: URL
    /// Where downloads write until they are complete: one folder on the cache's volume, so the rename into place is
    /// one step, named with a dot so no account's folder can be it. A download cut off by quitting or a crash never
    /// removes its own file, so the folder is emptied before this cache's first download.
    private let partials: URL
    private var sweptPartials = false
    private var inFlight: [String: Download] = [:]

    init(root: URL) {
        self.root = root
        self.partials = root.appendingPathComponent(".partial", isDirectory: true)
    }

    /// The attachment's bytes, from disk or downloaded once. `progress` hears the download's fractions (at most
    /// about ten a second); a file already cached returns without a word, and so does a download whose size is
    /// unknown until it ends.
    func data(
        for message: MessageID,
        attachmentID: String,
        expectedSize: Int,
        provider: MailProvider,
        budget: QuotaBudget,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        let url = fileURL(for: message, attachmentID: attachmentID)
        if let cached = try? Data(contentsOf: url) { return cached }
        let key = url.absoluteString
        if let existing = inFlight[key] {
            if let progress { existing.progress.add(progress) }
            return try await existing.task.value
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
        return try await task.value
    }

    func removeAll(for accountID: AccountID) {
        let directory = root.appendingPathComponent(Self.safeComponent(accountID.rawValue), isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
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
