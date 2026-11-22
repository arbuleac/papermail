import Foundation
import SSCore
import SSDesign
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

    /// Where the chip stands (spec §5.22): a forwarded part is fetched after the window opens, and a part or
    /// file can fail. Failed attachments stay visible, with the problem in the tooltip, and are never sent.
    enum State: Hashable, Sendable {
        case ready
        case loading
        /// `short` replaces the size on the chip (“Too large”); `detail` is the tooltip.
        case failed(short: String, detail: String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let id: UUID
    var filename: String
    var mimeType: String
    var sizeBytes: Int
    var source: Source
    /// Present for inline parts referenced as `cid:` from a quoted original. Those never show as chips.
    var contentID: String?
    var state: State = .ready

    var isInline: Bool { contentID != nil }
    /// Parts still loading or that failed have nothing to send.
    var isSendable: Bool { state == .ready }

    init(id: UUID = UUID(), filename: String, mimeType: String, sizeBytes: Int, source: Source, contentID: String? = nil,
         state: State = .ready) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.source = source
        self.contentID = contentID
        self.state = state
    }

    init(fileURL: URL) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey, .nameKey, .isReadableKey])
        if values.isDirectory == true {
            throw AttachError.folder
        }
        if values.isReadable == false {
            throw AttachError.unreadable
        }
        self.init(
            filename: values.name ?? fileURL.lastPathComponent,
            mimeType: values.contentType?.preferredMIMEType ?? Self.mimeType(forExtension: fileURL.pathExtension),
            sizeBytes: values.fileSize ?? 0,
            source: .file(fileURL)
        )
    }

    /// Why a dropped item was not attached, so the composer can word the status (§5.20, Rejected drop).
    enum AttachError: Error {
        case folder
        case unreadable
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

    /// The chip shown while a forwarded part is fetched; `info.sizeBytes` is what the original declared.
    static func loading(info: AttachmentInfo, contentID: String?) -> ComposeAttachment {
        ComposeAttachment(
            filename: info.filename.isEmpty ? "attachment" : info.filename,
            mimeType: info.mimeType.isEmpty ? "application/octet-stream" : info.mimeType,
            sizeBytes: info.sizeBytes,
            source: .data(Data()),
            contentID: contentID,
            state: .loading
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

    /// What the chip's mark and meta say about the file (spec §5.57): the reader's own mapping, so a file looks the same
    /// on its way out as on its way in.
    var fileMark: FileMark { FileMark(filename: filename, mimeType: mimeType) }

    static func mimeType(forExtension pathExtension: String) -> String {
        UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
