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
    public static func classify(hasFragment: Bool, fileTypes: [String], imageTypes: [String], text: String?) -> ComposerPasteContent {
        if hasFragment { return .fragment }
        // Files win over the rest: a file copied in the Finder also offers its name as text and its icon as a TIFF.
        if !fileTypes.isEmpty {
            return fileTypes.allSatisfy(ComposerImageFormat.isImage) ? .imageFiles : .files
        }
        if !imageTypes.isEmpty, !isWriting(text) { return .image }
        return .text
    }

    /// Whether text offered beside an image is what the user copied. A browser's Copy Image offers the picture's
    /// address as text too, and then the picture is the paste; a word processor or a spreadsheet offers a picture of
    /// the selected text or cells beside the text itself, and then the text is. Blank text is no text.
    public static func isWriting(_ text: String?) -> Bool {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return false }
        return !isOnlyAnAddress(trimmed)
    }

    /// One web, file or data address and nothing else.
    public static func isOnlyAnAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "data"].contains(scheme)
    }
}
