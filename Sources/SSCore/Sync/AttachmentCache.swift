import CryptoKit
import Foundation

/// Disk cache for attachment bytes at `<root>/<account>/<message>/<attachmentID>`. On a miss it fetches
/// through the provider, and concurrent requests for the same attachment share one fetch so the conversation
/// view's inline images never hit the network twice.
actor AttachmentCache {
    private let root: URL
    private var inFlight: [String: Task<Data, Error>] = [:]

    init(root: URL) {
        self.root = root
    }

    func data(for message: MessageID, attachmentID: String, provider: MailProvider) async throws -> Data {
        let url = fileURL(for: message, attachmentID: attachmentID)
        if let cached = try? Data(contentsOf: url) { return cached }
        let key = url.absoluteString
        if let existing = inFlight[key] { return try await existing.value }
        let task = Task.detached(priority: .userInitiated) { () throws -> Data in
            let data = try await provider.attachment(messageID: message.providerID, attachmentID: attachmentID)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return data
        }
        inFlight[key] = task
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
