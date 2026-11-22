import AppKit
import PaperCore
import UniformTypeIdentifiers

/// What the composer's body reads from a paste or a drop besides text, and the copy of a selection that holds pictures
/// (spec §5.20, Images in the body). `ComposerPasteContent` decides; this reads the pasteboard for it.
@MainActor
enum ComposeBodyPasteboard {
    /// The body's own copy of a selection with pictures in it: its text and pictures, so a picture cut and pasted, or
    /// dragged, inside a composer stays a picture. Its text comes back plain, as every paste's does.
    static let fragmentType = NSPasteboard.PasteboardType("app.paperinbox.composer.fragment")

    /// The picture types the body takes besides files: every image type the Mac reads (`NSImage.imageTypes`), but not
    /// PDF or EPS, which are documents and attach.
    static let imageTypes: [NSPasteboard.PasteboardType] = NSImage.imageTypes
        .filter { ComposerImageFormat.isImage($0) }
        .map { NSPasteboard.PasteboardType(rawValue: $0) }

    /// What a pasteboard offers the body.
    struct Offer {
        var content: ComposerPasteContent
        var fileURLs: [URL] = []
        /// The text offered beside a picture: a browser's Copy Image offers the picture's address, which names it.
        var text: String?
    }

    static func offer(_ pboard: NSPasteboard) -> Offer {
        let types = (pboard.types ?? []).map(\.rawValue)
        let files = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []).compactMap { $0 as? URL }
        let text = pboard.string(forType: .string)
        let content = ComposerPasteContent.classify(hasFragment: types.contains(fragmentType.rawValue), fileTypes: files.map(typeIdentifier(of:)),
                                                    imageTypes: types.filter(ComposerImageFormat.isImage), text: text,
                                                    offersURL: types.contains(NSPasteboard.PasteboardType.URL.rawValue))
        return Offer(content: content, fileURLs: files, text: text)
    }

    /// A file's type: what the file system says, else what its extension says, else nothing (which is no picture).
    static func typeIdentifier(of url: URL) -> String {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type.identifier }
        return UTType(filenameExtension: url.pathExtension)?.identifier ?? ""
    }

    /// The pictures an `.image` or `.imageFiles` offer holds. Image files the Mac cannot read as pictures are
    /// returned as `unattached`, for the composer to attach as files instead. Only a file's header is read here; its
    /// bytes are read, and converted where they must be, off the main thread (`ComposeImageAttachment.make`).
    static func pictures(of offer: Offer, from pboard: NSPasteboard) -> (pictures: [ComposeImageAttachment], unattached: [URL]) {
        switch offer.content {
        case .imageFiles:
            return pictures(fromFiles: offer.fileURLs)
        case .image:
            let name = offer.text.flatMap(addressedName(_:))
            var pictures: [ComposeImageAttachment] = []
            for item in pboard.pasteboardItems ?? [] {
                guard let type = ComposerImageFormat.preferredType(among: item.types.map(\.rawValue)),
                      let data = item.data(forType: NSPasteboard.PasteboardType(type)),
                      let picture = ComposeImageAttachment.make(data: data, typeIdentifier: type, filename: name) else { continue }
                pictures.append(picture)
            }
            return (pictures, [])
        case .fragment, .files, .text:
            return ([], [])
        }
    }

    /// Picture files, in order, and those the Mac cannot read as pictures, to attach instead (a paste or drop of files,
    /// and Insert Picture…).
    static func pictures(fromFiles urls: [URL]) -> (pictures: [ComposeImageAttachment], unattached: [URL]) {
        var pictures: [ComposeImageAttachment] = []
        var unattached: [URL] = []
        for url in urls {
            if let picture = ComposeImageAttachment.make(.file(url), typeIdentifier: typeIdentifier(of: url), filename: url.lastPathComponent) {
                pictures.append(picture)
            } else {
                unattached.append(url)
            }
        }
        return (pictures, unattached)
    }

    /// The file name in a picture's web or file address (“sunset.jpg” from a browser's Copy Image), when it names a
    /// picture. Other addresses (data:, blob:, the reader's ss-cid:) name none, and the picture is “image.png”.
    static func addressedName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        let name = url.lastPathComponent
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension), type.conforms(to: .image) else { return nil }
        return name.removingPercentEncoding ?? name
    }

    // MARK: The body's own copy

    enum Segment: Codable, Equatable {
        case text(String)
        case picture(data: Data, filename: String, mimeType: String)
    }

    /// `selection` as the body's own copy, nil when it holds no picture (then plain text is copy enough). A picture
    /// still being prepared is waited for: its bytes are what is copied.
    static func fragment(of selection: NSAttributedString) -> Data? {
        var segments: [Segment] = []
        var hasPicture = false
        let text = selection.string as NSString
        ComposeInlineImages.finishPreparing(in: selection)
        selection.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selection.length)) { value, range, _ in
            if let picture = value as? ComposeImageAttachment {
                // One that could not be read is no picture, and was no words either.
                guard picture.isReady else { return }
                hasPicture = true
                for _ in 0..<range.length {
                    segments.append(.picture(data: picture.data, filename: picture.inlineImage.filename, mimeType: picture.inlineImage.mimeType))
                }
            } else {
                let words = text.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
                guard !words.isEmpty else { return }
                if case .text(let previous)? = segments.last {
                    segments[segments.count - 1] = .text(previous + words)
                } else {
                    segments.append(.text(words))
                }
            }
        }
        guard hasPicture else { return nil }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(segments)
    }

    static func segments(from data: Data) -> [Segment]? {
        try? PropertyListDecoder().decode([Segment].self, from: data)
    }
}
