import Foundation
import SSCore
import UniformTypeIdentifiers

/// A file the user attached (still on disk until send) or bytes already in memory (forwarded parts).
///
/// Keeping dropped files as URLs defers reading them until send, so attaching a large file never stalls
/// the window; the bytes are read off the main thread when the message is built.
struct ComposeAttachment: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case file(URL)
        case data(Data)
    }

    let id: UUID
    var filename: String
    var mimeType: String
    var sizeBytes: Int
    var source: Source
    /// Present for inline parts referenced as `cid:` from a quoted original. Those never show as chips.
    var contentID: String?

    var isInline: Bool { contentID != nil }

    init(id: UUID = UUID(), filename: String, mimeType: String, sizeBytes: Int, source: Source, contentID: String? = nil) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.source = source
        self.contentID = contentID
    }

    init(fileURL: URL) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey, .nameKey])
        if values.isDirectory == true {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        self.init(
            filename: values.name ?? fileURL.lastPathComponent,
            mimeType: values.contentType?.preferredMIMEType ?? Self.mimeType(forExtension: fileURL.pathExtension),
            sizeBytes: values.fileSize ?? 0,
            source: .file(fileURL)
        )
    }

    /// A part of a quoted original. `contentID` is the caller's decision (`QuotedReply.partsToCarry`): what
    /// matters is whether the quote references the part, not the disposition its sender gave it, since
    /// Outlook marks referenced images as attachments and a forward carries unreferenced inline parts as files.
    init(info: AttachmentInfo, data: Data, contentID: String?) {
        self.init(
            filename: info.filename.isEmpty ? "attachment" : info.filename,
            mimeType: info.mimeType.isEmpty ? "application/octet-stream" : info.mimeType,
            sizeBytes: data.count,
            source: .data(data),
            contentID: contentID
        )
    }

    /// Reads the bytes. Blocking for file sources; call it off the main thread.
    func loadData() throws -> Data {
        switch source {
        case .data(let data): return data
        case .file(let url): return try Data(contentsOf: url, options: [.mappedIfSafe])
        }
    }

    func outgoing() throws -> OutgoingAttachment {
        OutgoingAttachment(filename: filename, mimeType: mimeType, data: try loadData(), contentID: contentID)
    }

    static func mimeType(forExtension pathExtension: String) -> String {
        UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
