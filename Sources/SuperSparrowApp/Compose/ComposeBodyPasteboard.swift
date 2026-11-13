import AppKit
import SSCore
import UniformTypeIdentifiers

/// What the composer's body reads from a paste or a drop besides text, and the copy of a selection that holds pictures
/// (spec §5.20, Images in the body). `ComposerPasteContent` decides; this reads the pasteboard for it.
@MainActor
enum ComposeBodyPasteboard {
    /// The body's own copy of a selection with pictures in it: its text and pictures, so a picture cut and pasted, or
    /// dragged, inside a composer stays a picture. Its text comes back plain, as every paste's does.
    static let fragmentType = NSPasteboard.PasteboardType("io.supersparrow.composer.fragment")

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
                                                    imageTypes: types.filter(ComposerImageFormat.isImage), text: text)
        return Offer(content: content, fileURLs: files, text: text)
    }

    /// A file's type: what the file system says, else what its extension says, else nothing (which is no picture).
    static func typeIdentifier(of url: URL) -> String {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type.identifier }
        return UTType(filenameExtension: url.pathExtension)?.identifier ?? ""
    }

    /// The pictures an `.image` or `.imageFiles` offer holds. Image files the Mac cannot read as pictures are
    /// returned as `unattached`, for the composer to attach as files instead.
    static func pictures(of offer: Offer, from pboard: NSPasteboard) -> (pictures: [ComposeImageAttachment], unattached: [URL]) {
        switch offer.content {
        case .imageFiles:
            var pictures: [ComposeImageAttachment] = []
            var unattached: [URL] = []
            for url in offer.fileURLs {
                // Read whole, not mapped: the draft keeps these bytes, and a mapped file changed under it would change them.
                if let data = try? Data(contentsOf: url),
                   let picture = ComposeImageAttachment.make(data: data, typeIdentifier: typeIdentifier(of: url), filename: url.lastPathComponent) {
                    pictures.append(picture)
                } else {
                    unattached.append(url)
                }
            }
            return (pictures, unattached)
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

    /// The file name in a picture's address (“sunset.jpg” from a browser's Copy Image), when it names a picture.
    static func addressedName(_ text: String) -> String? {
        guard ComposerPasteContent.isOnlyAnAddress(text), let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() != "data" else { return nil }
        let name = url.lastPathComponent
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension), type.conforms(to: .image) else { return nil }
        return name.removingPercentEncoding ?? name
    }

    // MARK: The body's own copy

    enum Segment: Codable, Equatable {
        case text(String)
        case picture(data: Data, filename: String, mimeType: String)
    }

    /// `selection` as the body's own copy, nil when it holds no picture (then plain text is copy enough).
    static func fragment(of selection: NSAttributedString) -> Data? {
        var segments: [Segment] = []
        var hasPicture = false
        let text = selection.string as NSString
        selection.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selection.length)) { value, range, _ in
            if let picture = value as? ComposeImageAttachment {
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
