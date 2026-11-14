import AppKit
import ImageIO
import SSCore
import SSDesign

/// A picture in the composer's body (spec §5.20, Images in the body): the bytes it is sent as, what sending needs to
/// know of them (`inlineImage`), and the cell that draws it no wider than the text. Its character also carries
/// `ComposerInlineImage.attributeKey`, the content id, which is all a kept draft's archived body keeps of it
/// (`ComposeInlineImages`).
///
/// A picture pasted or dropped goes into the text at once, its size read from its header, and is prepared off the main
/// thread, one picture at a time in the order they came (`make`): its file read, its bytes encoded again where they
/// must be, its location taken out, a copy decoded for the screen. A HEIC converted, a camera raw decoded or ten photos
/// dropped together never stall the window. Until it is ready the cell draws a skeleton of its size; sending waits for
/// it, an autosave leaves it out until it is in, and closing, saving at once or copying it waits for it
/// (`finishNow`). A picture whose bytes turn out not to read after all is `failed`: the text view takes it out again
/// and attaches its file instead.
///
/// The picture is drawn by a cell, not through `NSTextAttachment.image`: a cell is what the text view hands VoiceOver
/// as the attachment's element (an image-only attachment gave it none, seen on macOS 27.0.1), so the picture is read
/// by its name.
final class ComposeImageAttachment: NSTextAttachment {
    enum State: Equatable {
        case preparing
        case ready
        case failed
    }

    /// Where a picture's bytes come from: the pasteboard (or the demo's sample), or a file.
    enum Source: Sendable {
        case data(Data)
        case file(URL)
    }

    let inlineImage: ComposerInlineImage
    /// The file the picture was read from, attached instead if its bytes turn out not to be a picture.
    let fileURL: URL?
    /// The bytes sent, in the format `inlineImage.mimeType` names; empty until the picture is ready.
    private(set) var data = Data()
    private(set) var state: State
    private let cell: ComposeImageCell
    private var job: PreparationJob?
    private var waiters: [@MainActor (ComposeImageAttachment) -> Void] = []

    var isReady: Bool { state == .ready }
    var isPreparing: Bool { state == .preparing }

    private init(inlineImage: ComposerInlineImage, size: CGSize, fileURL: URL?) {
        self.inlineImage = inlineImage
        self.fileURL = fileURL
        state = .preparing
        cell = ComposeImageCell(size: size, name: inlineImage.filename)
        super.init(data: nil, ofType: nil)
        attachmentCell = cell
    }

    /// Pictures are never archived with the text (`ComposeInlineImages.detached`), so there is nothing to decode.
    required init?(coder: NSCoder) {
        nil
    }

    // MARK: Making one

    /// The longest side a picture is decoded at for the editor. The bytes sent stay whole; a 48-megapixel photo
    /// decoded whole would hold some 190 MB for a picture shown 500 pt wide.
    static let displayPixelLimit = 2400

    /// A picture pasted: `data` of type `typeIdentifier` (a pasteboard type). See `make(_:typeIdentifier:filename:)`.
    @MainActor
    static func make(data: Data, typeIdentifier: String, filename: String?) -> ComposeImageAttachment? {
        make(.data(data), typeIdentifier: typeIdentifier, filename: filename)
    }

    /// A picture pasted or dropped, of type `typeIdentifier` (a pasteboard type or a file's): kept when it is PNG, JPEG
    /// or GIF, encoded again otherwise (`ComposerImageFormat`), with a content id of its own. Here, on the main thread,
    /// only its header is read, for its size; the rest is prepared off it (see the type). Nil when the header names no
    /// picture the Mac can read.
    @MainActor
    static func make(_ source: Source, typeIdentifier: String, filename: String?) -> ComposeImageAttachment? {
        let header: CGImageSource?
        var fileURL: URL?
        switch source {
        case .data(let data):
            header = CGImageSourceCreateWithData(data as CFData, nil)
        case .file(let url):
            header = CGImageSourceCreateWithURL(url as CFURL, nil)
            fileURL = url
        }
        guard let header, CGImageSourceGetCount(header) > 0, let size = pointSize(of: header) else { return nil }
        let format = ComposerImageFormat.sent(as: typeIdentifier)
        let keep = ComposerImageFormat.kept(typeIdentifier) != nil
        let inlineImage = ComposerInlineImage(contentID: ComposerInlineImage.makeContentID(), filename: format.filename(from: filename),
                                              mimeType: format.mimeType, width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        let picture = ComposeImageAttachment(inlineImage: inlineImage, size: size, fileURL: fileURL)
        let job = PreparationJob { prepare(source, as: format, keep: keep) }
        picture.job = job
        job.notify { [picture] prepared in picture.finish(prepared) }
        return picture
    }

    /// A picture whose bytes are already as they are sent (a kept draft's, the body's own copy), ready at once. Nil
    /// when they no longer read as a picture.
    @MainActor
    static func restore(data: Data, contentID: String, filename: String, mimeType: String) -> ComposeImageAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let size = pointSize(of: source), let decoded = decodeForScreen(data) else { return nil }
        let inlineImage = ComposerInlineImage(contentID: contentID, filename: filename, mimeType: mimeType,
                                              width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        let picture = ComposeImageAttachment(inlineImage: inlineImage, size: size, fileURL: nil)
        picture.finish(Prepared(data: data, display: decoded))
        return picture
    }

    // MARK: Waiting for one

    /// Runs `body` once the picture is ready or has failed: now, when it already has.
    @MainActor
    func whenPrepared(_ body: @escaping @MainActor (ComposeImageAttachment) -> Void) {
        guard state == .preparing else {
            body(self)
            return
        }
        waiters.append(body)
    }

    /// Waits on this thread for the picture still being prepared, for the few paths that cannot wait otherwise:
    /// closing a composer or quitting (the draft is saved before the window goes), and copying the picture.
    @MainActor
    func finishNow() {
        guard state == .preparing, let job else { return }
        finish(job.wait())
    }

    @MainActor
    private func finish(_ prepared: Prepared?) {
        guard state == .preparing else { return }
        job = nil
        if let prepared {
            data = prepared.data
            cell.picture = NSImage(cgImage: prepared.display, size: cell.size)
            state = .ready
        } else {
            cell.isGone = true
            state = .failed
        }
        let waiting = waiters
        waiters = []
        waiting.forEach { $0(self) }
    }

    // MARK: Preparing

    /// What preparing a picture yields: the bytes it is sent as and a copy decoded for the screen. A `CGImage` is
    /// immutable, so handing it from the preparing queue to the main thread is safe.
    private struct Prepared: @unchecked Sendable {
        var data: Data
        var display: CGImage
    }

    /// The work off the main thread: read the file whole (not mapped: the draft keeps these bytes, and a mapped file
    /// changed under it would change them), encode it again unless its format is kept, take its location out, decode it
    /// for the screen.
    private nonisolated static func prepare(_ source: Source, as format: ComposerImageFormat, keep: Bool) -> Prepared? {
        let original: Data
        switch source {
        case .data(let data):
            original = data
        case .file(let url):
            guard let data = try? Data(contentsOf: url) else { return nil }
            original = data
        }
        guard let bytes = keep ? withoutLocation(original, as: format) : encode(original, as: format),
              let display = decodeForScreen(bytes) else { return nil }
        return Prepared(data: bytes, display: display)
    }

    /// The copy the cell draws: decoded no larger than the screen needs, turned upright.
    nonisolated static func decodeForScreen(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: displayPixelLimit,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The picture's size on screen in points: its pixels, upright, over its resolution. A resolution under 72 dpi is
    /// read as 72, so a file with a missing or nonsensical one is never shown larger than its pixels.
    nonisolated static func pointSize(of source: CGImageSource) -> CGSize? {
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

    /// `data` as a PNG or a JPEG, its resolution and orientation kept, so it shows at the size it had, and its location
    /// left out: a photo put into the text of a message is not expected to say where it was taken.
    nonisolated static func encode(_ data: Data, as format: ComposerImageFormat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.typeIdentifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [kCGImagePropertyGPSDictionary: kCFNull as Any]
        if format == .jpeg { options[kCGImageDestinationLossyCompressionQuality] = 0.85 }
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }

    /// A kept PNG or JPEG as it came, unless it says where it was taken: then its metadata is written again without the
    /// location and its pixels are copied untouched (`kCGImageMetadataShouldExcludeGPS`), or, where ImageIO cannot do
    /// that, it is encoded again without it. Nil when it is no picture.
    nonisolated static func withoutLocation(_ data: Data, as format: ComposerImageFormat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        guard hasLocation(source) else { return data }
        let output = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(output, format.typeIdentifier as CFString, 1, nil),
           CGImageDestinationCopyImageSource(destination, source, [kCGImageMetadataShouldExcludeGPS: true] as CFDictionary, nil),
           output.length > 0 {
            return output as Data
        }
        return encode(data, as: format)
    }

    /// Whether the picture records where it was taken (an EXIF GPS block).
    nonisolated static func hasLocation(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] else { return false }
        return !gps.isEmpty
    }
}

/// One picture's preparation on the composer's picture queue. The queue is serial, so a drop of many photos holds one
/// decoded at a time, and they come in in the order they were dropped.
private final class PreparationJob: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "io.supersparrow.compose.pictures", qos: .userInitiated)
    private let group = DispatchGroup()
    /// Written once on the queue before the group is left; read only after it has been.
    private var result: Any?

    init<Result>(_ work: @escaping @Sendable () -> Result?) {
        group.enter()
        Self.queue.async { [self] in
            result = work()
            group.leave()
        }
    }

    func wait<Result>() -> Result? {
        group.wait()
        return result as? Result
    }

    func notify<Result>(_ completion: @escaping @MainActor (Result?) -> Void) {
        group.notify(queue: .main) { [self] in
            MainActor.assumeIsolated { completion(result as? Result) }
        }
    }
}

/// Draws a picture in the body: at its size in points, scaled down to the width the text has (its shape kept), sitting
/// on the line's baseline. The line grows to hold it (`ComposeLayoutManager`). Clicks place the caret, as on text.
/// Until the picture is ready it draws a skeleton of that size in `fill`; a picture that could not be read takes no
/// room at all.
final class ComposeImageCell: NSTextAttachmentCell {
    /// The picture's size in points.
    let size: NSSize
    /// The copy decoded for the screen; nil while the picture is being prepared.
    var picture: NSImage? {
        didSet { image = picture }
    }
    /// Set when the picture could not be read: the text view takes its character out, and until then it is nothing.
    var isGone = false

    init(size: NSSize, name: String) {
        self.size = size
        super.init(imageCell: nil)
        // VoiceOver reads the attachment as an image by this name.
        setAccessibilityLabel(name)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ComposeImageCell is built in code")
    }

    override func cellSize() -> NSSize {
        isGone ? .zero : size
    }

    override func cellBaselineOffset() -> NSPoint {
        .zero
    }

    override func wantsToTrackMouse() -> Bool {
        false
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
                            characterIndex charIndex: Int) -> NSRect {
        guard !isGone else { return .zero }
        var available = lineFrag.width - 2 * textContainer.lineFragmentPadding
        // A list item or a quote starts further in; the line fragment is the container's whole width.
        if let storage = textContainer.layoutManager?.textStorage, charIndex < storage.length,
           let style = storage.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle {
            available -= max(style.headIndent, style.firstLineHeadIndent)
            if style.tailIndent < 0 { available += style.tailIndent }
        }
        return NSRect(origin: .zero, size: Self.fitted(size, toWidth: available))
    }

    /// `size` scaled down, never up, to `width`, in whole points.
    static func fitted(_ size: NSSize, toWidth width: CGFloat) -> NSSize {
        let scale = min(1, max(1, width) / max(1, size.width))
        return NSSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard !isGone else { return }
        guard let picture else {
            // Still being prepared: a skeleton of the picture's size, as quiet as the list's rows before they load.
            NSColor.qFill.setFill()
            cellFrame.fill(using: .sourceOver)
            return
        }
        picture.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
        // The text view paints a selection behind the glyphs, where the picture hides it; a selected picture is washed
        // with the same colour over it instead (`layout.composer.pictureSelectedWash`), so ⌫ never removes a picture the
        // user could not see was selected.
        guard !isGone, let textView = controlView as? NSTextView,
              textView.selectedRanges.contains(where: { NSLocationInRange(charIndex, $0.rangeValue) }) else { return }
        let selection = (textView.selectedTextAttributes[.backgroundColor] as? NSColor) ?? .selectedTextBackgroundColor
        selection.withAlphaComponent(Quire.Layout.Composer.pictureSelectedWash).setFill()
        cellFrame.fill(using: .sourceOver)
    }
}
