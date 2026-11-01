import Foundation

/// Output of sanitizing one message body at sync time.
public struct SanitizedBody: Hashable, Sendable {
    /// Safe to load inside a sandboxed iframe: no scripts, no forms, no external resources unless allowed.
    public var html: String
    /// Text extracted from the HTML (or the text part), used for search and the list snippet.
    public var plainText: String
    public var blockedRemoteImageCount: Int
    /// True when quoted earlier messages were detected and wrapped in `<div class="ss-quote">`.
    public var hasQuotedContent: Bool
    public init(html: String, plainText: String, blockedRemoteImageCount: Int, hasQuotedContent: Bool) {
        self.html = html
        self.plainText = plainText
        self.blockedRemoteImageCount = blockedRemoteImageCount
        self.hasQuotedContent = hasQuotedContent
    }
}

/// URL scheme the app registers with WebKit to serve inline images from the local store.
/// Form: ss-cid://<accountID>/<providerMessageID>/<contentID>
public enum RenderURLScheme {
    public static let inlineImage = "ss-cid"
    public static let attachment = "ss-attachment"
    public static func inlineImageURL(for message: MessageID, contentID: String) -> URL {
        var components = URLComponents()
        components.scheme = inlineImage
        components.host = message.accountID.rawValue
        components.path = "/" + message.providerID + "/" + contentID
        return components.url!
    }
}

/// Turns a provider body into render-ready HTML and search text. Pure and thread-safe; called from sync actors.
public protocol BodySanitizing: Sendable {
    func sanitize(_ body: MessageBody, messageID: MessageID) -> SanitizedBody
}
