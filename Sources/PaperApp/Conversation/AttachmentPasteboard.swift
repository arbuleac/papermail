import AppKit
import PaperCore

/// An attachment of a stored message, named so that any window can fetch it: what a dragged reader chip carries for the
/// app's own drop targets (spec §5.17), beside the file promise every other app reads. The composer that takes it asks
/// the engine for the bytes, so nothing goes through the disk on the way.
struct MailAttachmentReference: Codable, Hashable, Sendable {
    let message: MessageID
    let info: AttachmentInfo

    init(message: MessageID, info: AttachmentInfo) {
        self.message = message
        self.info = info
    }

    /// The name the file goes by: the attachment's, made safe for a file system (`AttachmentSafety.safeFilename`).
    var filename: String { AttachmentSafety.safeFilename(info.filename) }
}

/// One thing dropped on a composer or the quick reply: an attachment of a message in this app, or a file.
enum AttachmentDropItem: Hashable, Sendable {
    case mail(MailAttachmentReference)
    case file(URL)
}

/// The pasteboard side of dragging attachments (spec §5.17, §5.18, §5.20): the app's own type, what a drop target
/// registers for and what it reads from a drag.
@MainActor
enum AttachmentPasteboard {
    /// One `MailAttachmentReference`, as JSON, per pasteboard item.
    nonisolated static let referenceType = NSPasteboard.PasteboardType("app.paperinbox.mac.attachment")

    /// What the composer and the quick reply register for: the app's own attachments, and files.
    static let dropTypes: [NSPasteboard.PasteboardType] = [referenceType, .fileURL]

    nonisolated static func encode(_ reference: MailAttachmentReference) -> Data? {
        try? JSONEncoder().encode(reference)
    }

    nonisolated static func decode(_ data: Data) -> MailAttachmentReference? {
        try? JSONDecoder().decode(MailAttachmentReference.self, from: data)
    }

    /// The app's attachments on `pasteboard`, in item order; empty when it holds none (files, text, anything else).
    static func references(on pasteboard: NSPasteboard) -> [MailAttachmentReference] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: referenceType).flatMap(decode)
        }
    }

    /// What a drop of `pasteboard` attaches: the app's own attachments when it carries them (a dragged chip also promises
    /// its file to other apps, which the app never needs), else its files. Empty for anything else. Any process can write
    /// the app's type, so what takes these looks each reference up in the store before using it (`ComposeWindowController`).
    static func dropItems(on pasteboard: NSPasteboard) -> [AttachmentDropItem] {
        let references = references(on: pasteboard)
        if !references.isEmpty { return references.map(AttachmentDropItem.mail) }
        return files(on: pasteboard)
    }

    /// What a drag attaches: the app's own attachments only from a drag of a reader's chips (another process never names a
    /// source), else the files it carries.
    static func dropItems(for drag: NSDraggingInfo) -> [AttachmentDropItem] {
        guard drag.draggingSource is AttachmentDragController else { return files(on: drag.draggingPasteboard) }
        return dropItems(on: drag.draggingPasteboard)
    }

    private static func files(on pasteboard: NSPasteboard) -> [AttachmentDropItem] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        return urls.compactMap { ($0 as? URL).map(AttachmentDropItem.file) }
    }

    /// The items a file attaches as, leaving out folders (packages too) and files that cannot be read: the quick reply,
    /// which moves the reply to a composer for what is dropped, takes nothing it would not attach.
    nonisolated static func attachable(_ items: [AttachmentDropItem]) -> [AttachmentDropItem] {
        items.filter { item in
            guard case .file(let url) = item else { return true }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == false && FileManager.default.isReadableFile(atPath: url.path)
        }
    }

    /// The chip menu's Copy (spec §5.17): the file this Mac holds for the reader, which the Finder pastes, and the app's
    /// reference, which a composer pastes instead, so its attachment never rests on a session file that goes with the reader.
    static func copyItem(file: URL, reference: MailAttachmentReference) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        if let data = encode(reference) { item.setData(data, forType: referenceType) }
        return item
    }

    /// The pasteboard carries one of the app's attachments: the drag of a reader chip.
    static func carriesReference(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [referenceType]) != nil
    }

    /// The pasteboard holds something a drop target attaches: the app's attachments or files.
    static func carriesAttachments(_ pasteboard: NSPasteboard) -> Bool {
        carriesReference(pasteboard) || pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
}
