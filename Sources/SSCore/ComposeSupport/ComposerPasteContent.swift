import Foundation

/// What a paste or a drop on the composer's body puts there (spec §5.20, Images in the body). The body reads what the
/// pasteboard offers and does what this says; pure, so the rule is tested without a pasteboard.
public enum ComposerPasteContent: Equatable, Sendable {
    /// The body's own copy (its text and images), from a cut, copy or drag in a composer.
    case fragment
    /// Files that are all images: they go into the text where they are pasted or dropped.
    case imageFiles
    /// Files, at least one of them not an image: they attach, as files dropped anywhere else in the window do.
    case files
    /// An image without a file: a screenshot copied to the clipboard, a picture copied or dragged from a browser.
    case image
    /// Text, pasted plain as it always is.
    case text

    /// - Parameters:
    ///   - fileTypes: the type identifier of each file offered (empty when it has none), in order.
    ///   - imageTypes: the image types offered besides files.
    ///   - text: the plain text offered, if any.
    ///   - offersURL: whether the source also offers a web address as such (`public.url`), not only as text.
    public static func classify(hasFragment: Bool, fileTypes: [String], imageTypes: [String], text: String?,
                                offersURL: Bool) -> ComposerPasteContent {
        if hasFragment { return .fragment }
        // Files win over the rest: a file copied in the Finder also offers its name as text and its icon as a TIFF.
        if !fileTypes.isEmpty {
            return fileTypes.allSatisfy(ComposerImageFormat.isImage) ? .imageFiles : .files
        }
        if !imageTypes.isEmpty, !isWriting(text, offersURL: offersURL) { return .image }
        return .text
    }

    /// Whether text offered beside an image is what the user copied. A browser's Copy Image offers the picture's
    /// address as text too, and then the picture is the paste; a word processor or a spreadsheet offers a picture of
    /// the selected text or cells beside the text itself, and then the text is, even when that text is one link.
    /// Blank text is no text.
    public static func isWriting(_ text: String?, offersURL: Bool) -> Bool {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return false }
        return !isPicturesAddress(trimmed, offersURL: offersURL)
    }

    /// Schemes whose address can only be a picture's own, wherever it comes from: data: and a web app's blob: hold no
    /// page, and the reader serves the pictures of received mail from its own schemes (`ss-cid:`, `ss-attachment:`,
    /// and the message's `cid:` behind them).
    public static let pictureOnlySchemes: Set<String> = ["data", "blob", "cid", "ss-cid", "ss-attachment"]

    /// Whether `text` is one address, and nothing else, that names the picture beside it. WebKit's Copy Image and a
    /// picture dragged from a page offer the address as a URL (`public.url`) too, in a browser and in SuperSparrow's
    /// own reader, so with `offersURL` any scheme is the picture's. Without it, only the schemes that can name nothing
    /// but a picture are: a spreadsheet cell or a paragraph holding one link offers that link and a picture of the
    /// cell, and no URL, and there the link is what was copied.
    public static func isPicturesAddress(_ text: String, offersURL: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return offersURL || pictureOnlySchemes.contains(scheme)
    }
}
