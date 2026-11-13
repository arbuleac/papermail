import AppKit
import ImageIO
import SSCore
import SSDesign

/// A picture in the composer's body (spec §5.20, Images in the body): the bytes it is sent as, what sending needs to
/// know of them (`inlineImage`), and the cell that draws it no wider than the text. Its character also carries
/// `ComposerInlineImage.attributeKey`, the content id, which is all a kept draft's archived body keeps of it
/// (`ComposeInlineImages`).
///
/// The picture is drawn by a cell, not through `NSTextAttachment.image`: a cell is what the text view hands VoiceOver
/// as the attachment's element (an image-only attachment gave it none, seen on macOS 27.0.1), so the picture is read
/// by its name.
final class ComposeImageAttachment: NSTextAttachment {
    let inlineImage: ComposerInlineImage
    /// The bytes sent, in the format `inlineImage.mimeType` names.
    let data: Data
    /// What the cell draws: the picture at its size in points, decoded no larger than the screen needs.
    let display: NSImage

    init(inlineImage: ComposerInlineImage, data: Data, display: NSImage) {
        self.inlineImage = inlineImage
        self.data = data
        self.display = display
        super.init(data: nil, ofType: nil)
        attachmentCell = ComposeImageCell(picture: display, name: inlineImage.filename)
    }

    /// Pictures are never archived with the text (`ComposeInlineImages.detached`), so there is nothing to decode.
    required init?(coder: NSCoder) {
        nil
    }

    /// The same picture as a part of its own: a paste of the body's own copy gets a content id of its own (§5.20).
    func copy(contentID: String) -> ComposeImageAttachment {
        var inlineImage = self.inlineImage
        inlineImage.contentID = contentID
        return ComposeImageAttachment(inlineImage: inlineImage, data: data, display: display)
    }

    // MARK: Making one

    /// The longest side a picture is decoded at for the editor. The bytes sent stay whole; a 48-megapixel photo
    /// decoded whole would hold some 190 MB for a picture shown 500 pt wide.
    static let displayPixelLimit = 2400

    /// A picture pasted or dropped: `data` of type `typeIdentifier` (a pasteboard type or a file's), kept when it is
    /// PNG, JPEG or GIF, encoded again otherwise (`ComposerImageFormat`), with a content id of its own. Nil when the
    /// Mac cannot read it as a picture.
    static func make(data: Data, typeIdentifier: String, filename: String?) -> ComposeImageAttachment? {
        let format = ComposerImageFormat.sent(as: typeIdentifier)
        let bytes: Data
        if ComposerImageFormat.kept(typeIdentifier) != nil {
            bytes = data
        } else {
            guard let encoded = encode(data, as: format) else { return nil }
            bytes = encoded
        }
        return restore(data: bytes, contentID: ComposerInlineImage.makeContentID(), filename: format.filename(from: filename),
                       mimeType: format.mimeType)
    }

    /// A picture whose bytes are already as they are sent (a kept draft's, the body's own copy). Nil when they no
    /// longer read as a picture.
    static func restore(data: Data, contentID: String, filename: String, mimeType: String) -> ComposeImageAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let size = pointSize(of: source) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: displayPixelLimit,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let inlineImage = ComposerInlineImage(contentID: contentID, filename: filename, mimeType: mimeType,
                                              width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        return ComposeImageAttachment(inlineImage: inlineImage, data: data, display: NSImage(cgImage: decoded, size: size))
    }

    /// The picture's size on screen in points: its pixels, upright, over its resolution. A resolution under 72 dpi is
    /// read as 72, so a file with a missing or nonsensical one is never shown larger than its pixels.
    static func pointSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let dpiWidth = max(72, (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72)
        let dpiHeight = max(72, (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 72)
        var size = CGSize(width: pixelWidth * 72 / dpiWidth, height: pixelHeight * 72 / dpiHeight)
        // EXIF orientations 5 to 8 turn the picture a quarter: a portrait photo from a phone is stored on its side.
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
            size = CGSize(width: size.height, height: size.width)
        }
        return CGSize(width: max(1, size.width), height: max(1, size.height))
    }

    /// `data` as a PNG or a JPEG, its resolution and orientation kept, so it shows at the size it had.
    static func encode(_ data: Data, as format: ComposerImageFormat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.typeIdentifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }
}

/// Draws a picture in the body: at its size in points, scaled down to the width the text has (its shape kept), sitting
/// on the line's baseline. The line grows to hold it (`ComposeLayoutManager`). Clicks place the caret, as on text.
final class ComposeImageCell: NSTextAttachmentCell {
    private let picture: NSImage

    init(picture: NSImage, name: String) {
        self.picture = picture
        super.init(imageCell: picture)
        // VoiceOver reads the attachment as an image by this name.
        setAccessibilityLabel(name)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ComposeImageCell is built in code")
    }

    override func cellSize() -> NSSize {
        picture.size
    }

    override func cellBaselineOffset() -> NSPoint {
        .zero
    }

    override func wantsToTrackMouse() -> Bool {
        false
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
                            characterIndex charIndex: Int) -> NSRect {
        var available = lineFrag.width - 2 * textContainer.lineFragmentPadding
        // A list item or a quote starts further in; the line fragment is the container's whole width.
        if let storage = textContainer.layoutManager?.textStorage, charIndex < storage.length,
           let style = storage.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle {
            available -= max(style.headIndent, style.firstLineHeadIndent)
            if style.tailIndent < 0 { available += style.tailIndent }
        }
        return NSRect(origin: .zero, size: Self.fitted(picture.size, toWidth: available))
    }

    /// `size` scaled down, never up, to `width`, in whole points.
    static func fitted(_ size: NSSize, toWidth width: CGFloat) -> NSSize {
        let scale = min(1, max(1, width) / max(1, size.width))
        return NSSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        picture.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
        // The text view paints a selection behind the glyphs, where the picture hides it; a selected picture is washed
        // with the same colour over it instead (`layout.composer.pictureSelectedWash`), so ⌫ never removes a picture the
        // user could not see was selected.
        guard let textView = controlView as? NSTextView,
              textView.selectedRanges.contains(where: { NSLocationInRange(charIndex, $0.rangeValue) }) else { return }
        let selection = (textView.selectedTextAttributes[.backgroundColor] as? NSColor) ?? .selectedTextBackgroundColor
        selection.withAlphaComponent(Quire.Layout.Composer.pictureSelectedWash).setFill()
        cellFrame.fill(using: .sourceOver)
    }
}
