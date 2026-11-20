import AppKit
import SSCore
import UniformTypeIdentifiers

/// One dragged attachment on the pasteboard (spec §5.17): a file promise the Finder, the Desktop, a folder or any app
/// that takes files calls in once the drop lands, plus the app's own `MailAttachmentReference`, which the composer and
/// the quick reply read instead, so a drop inside the app never goes through the disk.
///
/// It is its own delegate: the provider's delegate is weak, and the pasteboard keeps the provider until the next drag, by
/// which time the Finder has long asked for the file.
final class AttachmentFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    let reference: MailAttachmentReference
    /// The name the file is promised under: its own, made safe, and numbered when another file of the same drag has it
    /// (`AttachmentDragController`), since a receiver other than the Finder reads the file at the name it was promised.
    let promisedName: String
    private let fulfiller: AttachmentPromiseFulfiller

    /// The promises are written here, never on the main queue (which a provider uses unless told otherwise): a fetch's
    /// wait and the write stay off the window's thread.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.supersparrow.mac.attachment-promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(reference: MailAttachmentReference, fulfiller: AttachmentPromiseFulfiller, promisedName: String? = nil) {
        self.reference = reference
        self.promisedName = promisedName ?? reference.filename
        self.fulfiller = fulfiller
        super.init()
        fileType = Self.fileType(filename: reference.info.filename, mimeType: reference.info.mimeType).identifier
        delegate = self
    }

    /// The file's type, for the receiver to decide whether it takes it: from the MIME type, else from the name's extension,
    /// else plain data. A promise must be data (or a folder), or AppKit throws, so a type that is neither is data too.
    static func fileType(filename: String, mimeType: String) -> UTType {
        let byMIME = mimeType.isEmpty || mimeType.lowercased() == "application/octet-stream" ? nil : UTType(mimeType: mimeType)
        let byName = UTType(filenameExtension: (filename as NSString).pathExtension)
        // The extension wins over a generic MIME type (a .pages sent as application/zip is a Pages document to the Finder).
        let candidates = [byName.flatMap { $0.isDynamic ? nil : $0 }, byMIME, byName].compactMap { $0 }
        return candidates.first { $0.conforms(to: .data) } ?? .data
    }

    // MARK: NSPasteboardWriting

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [AttachmentPasteboard.referenceType]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == AttachmentPasteboard.referenceType { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == AttachmentPasteboard.referenceType {
            return AttachmentPasteboard.encode(reference)
        }
        return super.pasteboardPropertyList(forType: type)
    }

    // MARK: NSFilePromiseProviderDelegate

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        promisedName
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.queue
    }

    /// Called on `queue` once a drop lands outside the app. The completion handler is the promise's end: the Finder shows
    /// the file, or nothing when it hears an error.
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let fulfiller = fulfiller
        let reference = reference
        let done = UncheckedCompletion(completionHandler)
        Task.detached(priority: .userInitiated) {
            do {
                _ = try await fulfiller.fulfil(reference, at: url)
                done.call(nil)
            } catch {
                done.call(error)
            }
        }
    }
}

/// AppKit's completion handler, which is safe to call from any thread but not declared Sendable.
private struct UncheckedCompletion: @unchecked Sendable {
    let handler: (Error?) -> Void
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func call(_ error: Error?) { handler(error) }
}
