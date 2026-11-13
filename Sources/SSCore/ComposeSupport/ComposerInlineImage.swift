import Foundation

/// An image pasted or dropped into the composer's body (spec §5.20, Images in the body). The editor holds it as an
/// attachment character marked with `attributeKey`, whose value is `contentID`; this is what sending it needs besides
/// its bytes. It travels as a `cid:` part beside the HTML, the path a forward's inline parts already take: the MIME
/// builder's `multipart/related` on Gmail, an inline attachment with a content id on Graph.
public struct ComposerInlineImage: Hashable, Codable, Sendable {
    public var contentID: String
    public var filename: String
    public var mimeType: String
    /// The size it shows at, in points (pixels over the image's resolution), so a Retina screenshot reads at the size
    /// it had on screen rather than at twice that.
    public var width: Int
    public var height: Int

    public init(contentID: String, filename: String, mimeType: String, width: Int, height: Int) {
        self.contentID = contentID
        self.filename = filename
        self.mimeType = mimeType
        self.width = max(1, width)
        self.height = max(1, height)
    }

    /// Marks an image's attachment character in the composer's text; the value is its `contentID`. It outlives the
    /// attachment itself in a kept draft's archived body, which stores the bytes beside it (`ComposeDraftRecord.images`).
    public static let attributeKey = NSAttributedString.Key("ss.composer.image")

    /// A fresh content id. Every paste or drop gets its own, so two copies of one picture are two parts and deleting
    /// one never takes the other's bytes with it.
    public static func makeContentID() -> String {
        UUID().uuidString.lowercased() + "@supersparrow.local"
    }

    /// The `<img>` the exporter writes. The width and height are for clients that ignore CSS (Outlook for Windows);
    /// `max-width` keeps a wide picture inside a phone's screen, and `height: auto` keeps its shape when it does.
    public var html: String {
        let source = ComposerHTMLExporter.escape("cid:" + contentID)
        return "<img src=\"\(source)\" alt=\"\(ComposerHTMLExporter.escape(filename))\" width=\"\(width)\" height=\"\(height)\""
            + " style=\"max-width: 100%; height: auto;\">"
    }

    /// Where the picture stood, in the plain-text alternative: the form Gmail's own alternative uses.
    public var plainText: String {
        "[image: \(filename)]"
    }

    /// The part sent with the message; its content id is what `html` points at.
    public func outgoing(_ data: Data) -> OutgoingAttachment {
        OutgoingAttachment(filename: filename, mimeType: mimeType, data: data, contentID: contentID)
    }
}
