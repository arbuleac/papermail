import Foundation
import UniformTypeIdentifiers

/// What an image put into the composer's body is sent as (spec §5.20, Images in the body). PNG, JPEG and GIF go as
/// they came: every mail client shows them, and encoding them again would cost a JPEG quality and a GIF its frames.
/// A photo in a format many clients cannot show (HEIC from an iPhone, HEIF, AVIF, WebP, JPEG XL, camera raw) becomes
/// a JPEG; anything else (the TIFF a copied picture often arrives as, BMP, SVG) becomes a PNG, which loses nothing.
public enum ComposerImageFormat: String, Hashable, Codable, Sendable {
    case png
    case jpeg
    case gif

    /// HEIC, HEIF and AVIF all conform to it (seen on macOS 27.0.1); HEIC does not conform to `UTType.heif`.
    private static let heifFamily = UTType("public.heif-standard")
    private static let photoTypes: [UTType] = [heifFamily, .rawImage, .webP, UTType("public.jpeg-xl")].compactMap { $0 }

    /// The format whose MIME type is `mimeType`, nil for any other.
    public init?(mimeType: String) {
        switch mimeType.lowercased() {
        case "image/png": self = .png
        case "image/jpeg", "image/jpg": self = .jpeg
        case "image/gif": self = .gif
        default: return nil
        }
    }

    /// The format an image of `typeIdentifier` is sent in.
    public static func sent(as typeIdentifier: String) -> ComposerImageFormat {
        if let kept = kept(typeIdentifier) { return kept }
        guard let type = UTType(typeIdentifier) else { return .png }
        return photoTypes.contains(where: type.conforms(to:)) ? .jpeg : .png
    }

    /// The format of `typeIdentifier` when its bytes are sent unchanged, nil when they have to be encoded again.
    public static func kept(_ typeIdentifier: String) -> ComposerImageFormat? {
        switch UTType(typeIdentifier) {
        case UTType.png?: return .png
        case UTType.jpeg?: return .jpeg
        case UTType.gif?: return .gif
        default: return nil
        }
    }

    /// Whether `typeIdentifier` names an image (a file's type, or a pasteboard type).
    public static func isImage(_ typeIdentifier: String) -> Bool {
        UTType(typeIdentifier)?.conforms(to: .image) ?? false
    }

    /// The image type to read from what a paste or drop offers: one sent unchanged first (PNG, then JPEG, then GIF),
    /// then any other image type in the order the source listed them, since a source lists its richest first. Nil
    /// when nothing offered is an image.
    public static func preferredType(among typeIdentifiers: [String]) -> String? {
        for format in [ComposerImageFormat.png, .jpeg, .gif] {
            if let match = typeIdentifiers.first(where: { kept($0) == format }) { return match }
        }
        return typeIdentifiers.first(where: isImage)
    }

    public var mimeType: String {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        case .gif: return "image/gif"
        }
    }

    public var typeIdentifier: String {
        switch self {
        case .png: return UTType.png.identifier
        case .jpeg: return UTType.jpeg.identifier
        case .gif: return UTType.gif.identifier
        }
    }

    public var pathExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .gif: return "gif"
        }
    }

    /// The name the part is sent under: the file's own when it has one (with this format's extension when it was
    /// encoded again, IMG_0412.HEIC going as IMG_0412.jpg), else “image” as Gmail names a pasted picture.
    public func filename(from original: String?) -> String {
        let trimmed = original?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "image." + pathExtension }
        let name = trimmed as NSString
        let current = name.pathExtension
        if !current.isEmpty, let type = UTType(filenameExtension: current), Self.kept(type.identifier) == self {
            return trimmed
        }
        let stem = current.isEmpty ? trimmed : name.deletingPathExtension
        return (stem.isEmpty ? "image" : stem) + "." + pathExtension
    }
}
