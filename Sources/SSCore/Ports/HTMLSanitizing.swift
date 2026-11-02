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
    /// Whether the reader sets the body on its own page or keeps the sender's design; see `BodyTypesetting`.
    public var typesetting: BodyTypesetting
    /// True when the body sets its own background or text colour (docs/DESIGN-LANGUAGE.md §8.5), so a dark
    /// appearance has to adapt it and the reader offers Original colors. Any one of these makes it true:
    /// - a `color`, `background`, `background-color` or `background-image` declaration in a `style` attribute
    ///   or a `<style>` block, unless its whole value is a keyword that sets no colour (`inherit`, `initial`,
    ///   `unset`, `revert`, `revert-layer`, `currentcolor`, `transparent`, `none`);
    /// - a non-empty `bgcolor` or `background` attribute on any element;
    /// - a non-empty `color` attribute on `<font>`;
    /// - a non-empty `text` or `link` attribute on `<body>`.
    /// A remote background that was blocked still counts: the fact describes the body as designed, and
    /// loading images brings it back. Plain bodies never declare colours.
    public var declaresColors: Bool
    /// True when New York draws every letter and decimal digit of `plainText` itself (`NewYorkCoverage`), so
    /// the serif reading face can set the body without falling back mid-word.
    public var coveredByNewYork: Bool

    /// The defaults describe a body whose facts are unknown, which renders like a body stored before the
    /// sanitizer recorded them: styled, colours assumed.
    public init(
        html: String,
        plainText: String,
        blockedRemoteImageCount: Int,
        hasQuotedContent: Bool,
        typesetting: BodyTypesetting = .styled,
        declaresColors: Bool = true,
        coveredByNewYork: Bool = false
    ) {
        self.html = html
        self.plainText = plainText
        self.blockedRemoteImageCount = blockedRemoteImageCount
        self.hasQuotedContent = hasQuotedContent
        self.typesetting = typesetting
        self.declaresColors = declaresColors
        self.coveredByNewYork = coveredByNewYork
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
