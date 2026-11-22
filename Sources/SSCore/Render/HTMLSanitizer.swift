import Foundation
import SwiftSoup

/// Turns provider HTML into render-ready markup once, at sync time. The output is meant for a sandboxed
/// `<iframe srcdoc>`: no scripts, no forms, no navigation tricks and no network unless remote images are allowed.
///
/// Everything that can fetch or run is removed rather than neutralised; everything that only paints (inline
/// styles, `<style>` blocks, table layouts) is kept so newsletters look the way they were designed.
public struct HTMLSanitizer: BodySanitizing, Sendable {
    /// When true remote `<img>` sources and CSS url() references stay in place. When false they are replaced
    /// and counted so the UI can offer to load them for one message.
    public let allowRemoteImages: Bool

    public init(allowRemoteImages: Bool = false) {
        self.allowRemoteImages = allowRemoteImages
    }

    /// Class of the wrapper element around every rendered body.
    public static let bodyClass = "ss-body"
    /// Added next to `bodyClass` when the body came from text/plain.
    public static let plainBodyClass = "ss-plain"
    /// Class of the `<style>` element carrying `bodyStyleSheet`, so it can be told apart from message styles.
    public static let baseStyleClass = "ss-base"
    /// Keeps a blocked remote image URL so the UI can restore it on demand.
    public static let blockedSourceAttribute = "data-ss-src"
    /// A blocked remote `background=` attribute, parked so "Load images" can put it back.
    public static let blockedBackgroundAttribute = "data-ss-background"
    /// Marks a parked image `TrackerRules` calls a tracker (spec §5.60), its value the `TrackerRules.Reason`. Set whatever
    /// the remote-images setting, so Block trackers acts at render time: while it is on, the reader and the printout leave
    /// marked images parked when they put the others back. Like every `data-ss-` attribute, one in incoming mail is dropped.
    public static let trackerAttribute = "data-ss-tracker"
    /// 1x1 transparent GIF standing in for blocked remote images so layouts keep their shape.
    public static let placeholderImage = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
    /// Width constraints every body carries; the shell may add to them but a body renders acceptably alone.
    public static let bodyStyleSheet = ".ss-body{max-width:100%;overflow-wrap:break-word;word-wrap:break-word}"
        + ".ss-body img{max-width:100%;height:auto}.ss-body table{max-width:100%}.ss-body pre{white-space:pre-wrap}"

    public func sanitize(_ body: MessageBody, messageID: MessageID) -> SanitizedBody {
        if let html = body.html, !html.allSatisfy(\.isWhitespace) {
            // A parse failure must never leak the original markup, so fall through to the text part instead.
            if let sanitized = Self.onLargeStack({ try? sanitizeHTML(html, messageID: messageID) }) { return sanitized }
        }
        return renderText(body.text ?? "")
    }

    /// The stack the HTML work runs on. Parsing, the scrub, quote detection and serialising all walk the tree
    /// recursively, and a mailer's unclosed tags can nest a body hundreds deep: at `Pass.maxDepth` that took more
    /// than the 512 KB of the concurrency pool thread the body was fetched on, and the app crashed on every
    /// launch until that message was gone. 16 MB holds the deepest tree the scrub keeps many times over.
    static let workStackSize = 16 << 20

    /// Runs `work` on a thread of its own with `workStackSize`, waiting for it. The caller's thread is busy for
    /// the same time either way; only the stack differs.
    static func onLargeStack<T>(_ work: @escaping () -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = work()
            done.signal()
        }
        thread.stackSize = workStackSize
        thread.qualityOfService = Thread.current.qualityOfService
        thread.start()
        done.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    // MARK: HTML

    private func sanitizeHTML(_ html: String, messageID: MessageID) throws -> SanitizedBody {
        let document = Self.hasHTMLElement(html) ? try SwiftSoup.parseHTML(html) : try SwiftSoup.parseBodyFragment(html)
        document.outputSettings().prettyPrint(pretty: false).escapeMode(.base)
        guard let body = document.body() else { throw Failure.noBody }
        if let head = document.head() {
            // Newsletters keep their stylesheet in <head>; it has to travel with the body, ahead of the content.
            for style in try head.getElementsByTag("style").array().reversed() { try body.prependChild(style) }
        }
        // The body element is not part of the output: its paint attributes are read before the scrub so they can
        // move to the wrapper, and only its children are scrubbed like any other content.
        let bodyStyle = try Self.inlineStyle(ofBody: body)
        // `text` and `link` never reach the output (only paint that can move to the wrapper does), but they
        // still say the sender chose colours; `bgcolor` and `background` count as written, whatever the filter
        // later makes of them.
        let bodyDeclaresColors = try Self.bodyColorAttributes.contains { !(try body.attr($0)).allSatisfy(\.isWhitespace) }
        var pass = Pass(messageID: messageID, allowRemoteImages: allowRemoteImages)
        try pass.scrubContents(of: body)
        let hasQuotes = try QuoteDetector.wrapQuotes(in: body, candidates: pass.quoteCandidates)
        // Only after quote detection, which recognises Outlook's boundary markers by their original ids.
        try pass.prefixIdentifiers()
        let wrapperStyle = bodyStyle.isEmpty ? "" : pass.filterStyle(bodyStyle)
        // Serialised from the DOM rather than replayed from the sender's bytes: the serialiser re-escapes every
        // text node and re-quotes every attribute, so markup our parser read one way and WebKit might read
        // another cannot reach the stored body. It costs about a millisecond on a 200 KB newsletter.
        let inner = try body.htmlUTF8WithoutSourceReuse()
        let plainText = TextExtractor.plainText(from: body)
        let declaresColors = bodyDeclaresColors || pass.declaresColors
        return SanitizedBody(
            html: Self.wrapped(String(decoding: inner, as: UTF8.self), style: wrapperStyle),
            plainText: plainText,
            blockedRemoteImageCount: pass.blockedRemoteImages,
            hasQuotedContent: hasQuotes,
            trackerImageCount: pass.trackerImages,
            // A colour is author styling too, so an unstyled body never needs adapting in a dark appearance.
            typesetting: declaresColors || pass.styled ? .styled : .unstyled,
            declaresColors: declaresColors,
            coveredByNewYork: NewYorkCoverage.covers(plainText)
        )
    }

    /// Attributes on `<body>` that set its colours (`SanitizedBody.declaresColors`).
    private static let bodyColorAttributes = ["text", "link", "bgcolor", "background"]

    private func renderText(_ text: String) -> SanitizedBody {
        let rendered = PlainTextRenderer.render(text)
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let plainText = TextExtractor.limited(normalized)
        return SanitizedBody(
            html: "<div class=\"\(Self.bodyClass) \(Self.plainBodyClass)\">" + rendered.html + "</div>",
            plainText: plainText,
            blockedRemoteImageCount: 0,
            hasQuotedContent: rendered.hasQuotedContent,
            typesetting: .plain,
            declaresColors: false,
            coveredByNewYork: NewYorkCoverage.covers(plainText)
        )
    }

    /// Full documents go through the document parser so head and body are told apart; fragments must not,
    /// because the fragment parser ignores html/head/body tags and would lose nothing but also gain nothing.
    /// A byte scan rather than a Foundation search because this runs over every body at sync time.
    private static func hasHTMLElement(_ html: String) -> Bool {
        let bytes = html.utf8
        var index = bytes.startIndex
        while index < bytes.endIndex, let open = bytes[index...].firstIndex(of: UInt8(ascii: "<")) {
            var cursor = bytes.index(after: open)
            var matched = true
            for expected in "html".utf8 {
                guard cursor < bytes.endIndex, bytes[cursor] | 0x20 == expected else { matched = false; break }
                cursor = bytes.index(after: cursor)
            }
            if matched {
                guard cursor < bytes.endIndex else { return true }
                switch bytes[cursor] {
                case UInt8(ascii: ">"), UInt8(ascii: "/"), 0x20, 0x09, 0x0A, 0x0C, 0x0D: return true
                default: break
                }
            }
            index = bytes.index(after: open)
        }
        return false
    }

    /// The body's paint-only attributes expressed as CSS, so they go through the same filter (and remote-image
    /// accounting) as any style attribute once they land on the wrapper.
    private static func inlineStyle(ofBody body: Element) throws -> String {
        var style = ""
        let backgroundColor = try body.attr("bgcolor")
        if !backgroundColor.isEmpty { style += "background-color:\(backgroundColor);" }
        let backgroundImage = try body.attr("background")
        if !backgroundImage.isEmpty { style += "background-image:url(\(cssQuoted(backgroundImage)));" }
        style += try body.attr("style")
        return style
    }

    /// The wrapper is written by hand rather than built in the DOM: it is fixed markup, and moving the body's
    /// children into a new element is one of the costlier mutations SwiftSoup offers.
    private static func wrapped(_ inner: String, style: String) -> String {
        var html = "<div class=\"\(bodyClass)\""
        if !style.isEmpty { html += " style=\"\(HTMLEscaping.escape(style))\"" }
        html += "><style class=\"\(baseStyleClass)\">\(bodyStyleSheet)</style>"
        html += inner
        html += "</div>"
        return html
    }

    private static func cssQuoted(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        out.append("\"")
        for scalar in value.unicodeScalars where scalar != "\n" && scalar != "\r" {
            if scalar == "\"" || scalar == "\\" { out.append("\\") }
            out.append(scalar)
        }
        out.append("\"")
        return String(out)
    }

    private enum Failure: Error {
        case noBody
    }
}

/// One scrub of a document: removes what can run or fetch, rewrites what may load, counts what was blocked.
///
/// Attributes are visited once per element through `compactAndMutate`, and an element is only written to when
/// something about it has to change: each write costs SwiftSoup an owner notification and a walk up the
/// ancestor chain to invalidate its caches, which is more than the whole visit of an untouched element.
private struct Pass {
    let messageID: MessageID
    let allowRemoteImages: Bool
    private let css: CSSFilter
    private(set) var blockedRemoteImages = 0
    /// Remote images parked as trackers (`TrackerRules`), whether or not remote images are allowed; part of
    /// `blockedRemoteImages`, since each is parked.
    private(set) var trackerImages = 0
    /// The remote address `imagePolicy` last saw on an `<img src>`.
    private var lastRemoteImage: String?
    /// The body sets a colour (`SanitizedBody.declaresColors`); noticed while scrubbing, like everything here.
    private(set) var declaresColors = false
    /// The body carries author styling other than colour (`BodyTypesetting.unstyled` lists what counts).
    private(set) var styled = false
    /// Tables currently open around the element being scrubbed: a table inside a table is a layout grid.
    private var tableDepth = 0
    /// Quote starts noticed while scrubbing, so quote detection needs no traversal of its own.
    private(set) var quoteCandidates = QuoteCandidates()
    /// Elements whose id or name gets the `ss-` prefix, collected here so no second traversal is needed.
    private var identified: [Element] = []
    private var named: [Element] = []

    /// Nesting beyond this is never a legitimate message and would only serve to exhaust the stack.
    private static let maxDepth = 400

    init(messageID: MessageID, allowRemoteImages: Bool) {
        self.messageID = messageID
        self.allowRemoteImages = allowRemoteImages
        css = CSSFilter(allowRemoteImages: allowRemoteImages, messageID: messageID)
    }

    mutating func filterStyle(_ style: String) -> String {
        let result = css.filter(style, mode: .attribute)
        blockedRemoteImages += result.blockedRemoteImages
        note(result.facts, onImage: false)
        return result.css
    }

    private mutating func note(_ facts: CSSFilter.Facts, onImage: Bool) {
        if facts.declaresColors { declaresColors = true }
        if onImage ? facts.stylesBeyondSizing : facts.styles { styled = true }
    }

    mutating func scrubContents(of body: Element) throws {
        try scrubChildren(of: body, depth: 0, inForeign: false)
    }

    /// Ids get a prefix so message markup can never address elements of the shell document; fragment links
    /// were rewritten to match during the scrub and `#id` selectors by the CSS filter.
    func prefixIdentifiers() throws {
        for element in identified {
            let id = element.id()
            if id.isEmpty { try element.removeAttr("id") } else { try element.attr("id", "ss-" + id) }
        }
        // A named <img> becomes a property of the frame's document, where it would shadow the expandos the
        // shell keeps there (`doc.ssLinksHooked`); the prefix keeps message names out of that namespace too.
        for element in named {
            let name = try element.attr("name")
            if !name.isEmpty { try element.attr("name", "ss-" + name) }
        }
    }

    /// `inForeign` is true below an `<svg>`. SwiftSoup parses SVG content with HTML rules, WebKit does not:
    /// there a `<style>` holds markup rather than raw text, so an `<img onerror>` inside it that SwiftSoup saw
    /// as CSS would come back to life in the frame.
    private mutating func scrub(_ element: Element, depth: Int, inForeign: Bool) throws {
        let tag = element.tagNameNormalUTF8()
        let role = Pass.tagRoles[tag]
        if depth > Pass.maxDepth || role == .removed || (role == .style && inForeign) {
            try element.remove()
            return
        }
        if role == .style {
            _ = try scrubAttributes(of: element, role: role)
            try filterStyleElement(element)
            return
        }
        if role == .unwrapped {
            // The container adds nothing once its fetching children are gone, but the fallback <img> inside is content.
            try scrubChildren(of: element, depth: depth, inForeign: inForeign)
            if element.parent() != nil { try element.unwrap() }
            return
        }
        if role == .rawText {
            // SwiftSoup writes xmp and plaintext contents back unescaped; inside SVG WebKit would parse them as
            // markup. As a <pre> the same text is escaped on output and still reads the way it was meant.
            try convertToPreformatted(element)
        }
        let facts = try scrubAttributes(of: element, role: role)
        quoteCandidates.consider(element, tag: tag, facts: facts)
        guard role == .table else {
            try scrubChildren(of: element, depth: depth, inForeign: inForeign || role == .svg)
            return
        }
        if tableDepth > 0 { styled = true }
        tableDepth += 1
        defer { tableDepth -= 1 }
        try scrubChildren(of: element, depth: depth, inForeign: inForeign)
    }

    private mutating func scrubChildren(of element: Element, depth: Int, inForeign: Bool) throws {
        for node in element.getChildNodes() {
            if let child = node as? Element {
                try scrub(child, depth: depth + 1, inForeign: inForeign)
            } else if node is Comment || node is XmlDeclaration || node is DocumentType {
                try node.remove()
            }
        }
    }

    private func convertToPreformatted(_ element: Element) throws {
        try element.tagName(Pass.preTag)
        for node in element.getChildNodes() {
            if let data = node as? DataNode {
                try data.replaceWith(TextNode(data.getWholeData(), nil))
            }
        }
    }

    private mutating func scrubAttributes(of element: Element, role: TagRole?) throws -> QuoteCandidates.Facts {
        var facts = QuoteCandidates.Facts()
        guard let attributes = element.getAttributes(), attributes.size() > 0 else { return facts }
        let isImage = role == .img
        let isSVGImage = role == .svgImage
        let isLink = role == .anchor
        let isDiv = role == .div
        let isFont = role == .font
        let isTable = role == .table
        // Set when a remote image source was blocked; added after the pass because the pass can only keep,
        // drop or rewrite what is already there (and an incoming data-ss-src is dropped by it first).
        var blockedSource: String?
        var blockedBackground: String?
        // An image's remote source and what its own attributes say about its size and visibility, for `TrackerRules`
        // once every attribute has been seen (the source may come before the size).
        var remoteSource: String?
        var hints = TrackerRules.ImageHints()
        attributes.compactAndMutate { attribute in
            let key = Pass.lowercased(attribute.getKeyUTF8())
            if Pass.hasPrefix(key, Pass.eventPrefix) || Pass.hasPrefix(key, Pass.reservedAttributePrefix) {
                return Pass.drop
            }
            if isImage {
                if key == Pass.widthKey {
                    hints.width = attribute.getValue()
                } else if key == Pass.heightKey {
                    hints.height = attribute.getValue()
                } else if key == Pass.hiddenKey {
                    hints.hidden = true
                }
            }
            if isTable, !styled, let hint = Pass.layoutTableAttributes[key] {
                // The table's own grid markup; colours and backgrounds are caught by their roles below.
                let value = attribute.getValueUTF8()
                if hint == .anyValue ? !Pass.isBlank(value) : Pass.lowercased(Pass.trimmed(value)) == Pass.presentationValue {
                    styled = true
                }
            }
            guard let role = Pass.attributeRoles[key] else { return Pass.keep }
            switch role {
            case .removed:
                return Pass.drop
            case .style:
                let value = attribute.getValueUTF8()
                if isImage { hints.style = String(decoding: value, as: UTF8.self) }
                if isDiv, QuoteCandidates.mentionsBorderTop(value) { facts.styleMentionsBorderTop = true }
                let result = css.filter(bytes: value, mode: .attribute)
                blockedRemoteImages += result.blockedRemoteImages
                note(result.facts, onImage: isImage)
                guard let rewritten = result.css else { return Pass.keep }
                return rewritten.isEmpty ? Pass.drop : AttributeMutation(keep: true, newValue: rewritten)
            case .class:
                let value = attribute.getValueUTF8()
                guard let stripped = Pass.strippingReservedClasses(value) else {
                    facts.classValue = value
                    return Pass.keep
                }
                facts.classValue = stripped
                return stripped.isEmpty ? Pass.drop : AttributeMutation(keep: true, newValue: stripped)
            case .id:
                facts.id = attribute.getValueUTF8()
                identified.append(element)
                return Pass.keep
            case .name:
                named.append(element)
                return Pass.keep
            case .usemap:
                let value = attribute.getValue()
                guard value.hasPrefix("#"), value.count > 1 else { return Pass.drop }
                return Pass.replacing("#ss-" + value.dropFirst())
            case .paint:
                let result = css.filter(presentationValue: attribute.getValueUTF8())
                blockedRemoteImages += result.blockedRemoteImages
                if result.drop { return Pass.drop }
                guard let rewritten = result.css else { return Pass.keep }
                return AttributeMutation(keep: true, newValue: rewritten)
            case .type:
                facts.type = attribute.getValueUTF8()
                return Pass.keep
            case .src:
                if isImage {
                    lastRemoteImage = nil
                    let mutation = imagePolicy(attribute.getValue(), isImageSource: true, blockedSource: &blockedSource)
                    remoteSource = lastRemoteImage
                    return mutation
                }
                if isSVGImage { return imagePolicy(attribute.getValue(), isImageSource: false, blockedSource: &blockedSource) }
                return Pass.drop
            case .background:
                // Counted before the image policy: a blocked background is still part of the design.
                if !Pass.isBlank(attribute.getValueUTF8()) { declaresColors = true }
                return imagePolicy(attribute.getValue(), isImageSource: false, parks: true, blockedSource: &blockedBackground)
            case .backgroundColor:
                if !Pass.isBlank(attribute.getValueUTF8()) { declaresColors = true }
                return Pass.keep
            case .fontColor:
                if isFont, !Pass.isBlank(attribute.getValueUTF8()) { declaresColors = true }
                return Pass.keep
            case .fontFace:
                if isFont, !Pass.isBlank(attribute.getValueUTF8()) { styled = true }
                return Pass.keep
            case .href:
                if isSVGImage { return imagePolicy(attribute.getValue(), isImageSource: false, blockedSource: &blockedSource) }
                if isLink { return linkPolicy(attribute.getValue()) }
                // Anywhere else (SVG pattern, textPath, mpath, cursor...) an href is a resource reference that
                // may fetch; only same-document fragments are worth keeping.
                return fragmentPolicy(attribute.getValue())
            case .link:
                return linkPolicy(attribute.getValue())
            }
        }
        if let remoteSource, let reason = TrackerRules.reason(forImageAt: remoteSource, hints: hints) {
            trackerImages += 1
            if blockedSource == nil {
                // Remote images are allowed, so the source was kept live: a tracker is parked all the same.
                blockedRemoteImages += 1
                blockedSource = remoteSource
                try element.attr("src", HTMLSanitizer.placeholderImage)
            }
            try element.attr(HTMLSanitizer.trackerAttribute, reason.rawValue)
        }
        if let blockedSource { try element.attr(HTMLSanitizer.blockedSourceAttribute, blockedSource) }
        if let blockedBackground { try element.attr(HTMLSanitizer.blockedBackgroundAttribute, blockedBackground) }
        return facts
    }

    /// `isImageSource` is true only for `<img src>`: that is the one place a data: payload or a blocked-image
    /// placeholder makes sense. Backgrounds, posters and SVG image references are dropped instead; with `parks`
    /// (a `background=` attribute) a blocked remote URL is still handed back so it can be parked. The remote address of
    /// an `<img src>`, parked or kept, is left in `lastRemoteImage` for the tracker rules.
    private mutating func imagePolicy(_ value: String, isImageSource: Bool, parks: Bool = false, blockedSource: inout String?) -> AttributeMutation {
        switch URLPolicy.classify(value) {
        case .inlineImage(let contentID):
            return Pass.replacing(RenderURLScheme.inlineImageURL(for: messageID, contentID: contentID).absoluteString)
        case .inlineData(let data):
            guard isImageSource else { return Pass.drop }
            return data == value ? Pass.keep : Pass.replacing(data)
        case .remote(let url):
            if isImageSource { lastRemoteImage = url }
            if allowRemoteImages { return url == value ? Pass.keep : Pass.replacing(url) }
            blockedRemoteImages += 1
            guard isImageSource else {
                if parks { blockedSource = url }
                return Pass.drop
            }
            blockedSource = url
            return AttributeMutation(keep: true, newValue: Pass.placeholderBytes)
        case .contact, .fragment, .rejected:
            return Pass.drop
        }
    }

    private func linkPolicy(_ value: String) -> AttributeMutation {
        switch URLPolicy.classify(value) {
        case .remote(let url), .contact(let url):
            // Already-clean links (the common case) are left alone rather than rewritten with the same value.
            return url == value ? Pass.keep : Pass.replacing(url)
        case .inlineImage(let contentID):
            return Pass.replacing(RenderURLScheme.inlineImageURL(for: messageID, contentID: contentID).absoluteString)
        case .fragment(let fragment):
            let name = fragment.dropFirst()
            return Pass.replacing(name.isEmpty ? "#" : "#ss-" + name)
        case .inlineData, .rejected:
            return Pass.drop
        }
    }

    private func fragmentPolicy(_ value: String) -> AttributeMutation {
        guard case .fragment(let fragment) = URLPolicy.classify(value) else { return Pass.drop }
        let name = fragment.dropFirst()
        return name.isEmpty ? Pass.drop : Pass.replacing("#ss-" + name)
    }

    private mutating func filterStyleElement(_ element: Element) throws {
        for node in element.getChildNodes() {
            let result: CSSFilter.Result
            if let data = node as? DataNode {
                result = css.filter(data.getWholeData(), mode: .sheet)
                if result.changed { _ = data.setWholeData(result.css) }
            } else if let text = node as? TextNode {
                result = css.filter(text.getWholeText(), mode: .sheet)
                try text.replaceWith(DataNode(Array(result.css.utf8), []))
            } else {
                try node.remove()
                continue
            }
            blockedRemoteImages += result.blockedRemoteImages
            if result.facts.declaresColors { declaresColors = true }
            // A stylesheet is held to the same neutral-property rule as a style attribute: Fastmail puts
            // `p.MsoNormal{margin:0}` in every message and Outlook on the web `P {margin-top:0}`, which are
            // no more a design than `<p style="margin:0">`. One left empty by the filter is not styling either.
            if result.facts.styles { styled = true }
        }
    }

    // MARK: Attribute helpers

    /// `ss-` classes mark the wrappers the shell styles and folds; a sender must not be able to pre-fold or
    /// restyle content by using them, the same way ids are prefixed to keep them out of the shell's namespace.
    /// Returns nil when no token needs stripping.
    private static func strippingReservedClasses(_ value: [UInt8]) -> [UInt8]? {
        guard value.count >= reservedPrefix.count else { return nil }
        var kept: [UInt8] = []
        var stripped = false
        var start = 0
        let count = value.count
        while start < count {
            while start < count, isSpace(value[start]) { start += 1 }
            var end = start
            while end < count, !isSpace(value[end]) { end += 1 }
            guard end > start else { break }
            if hasPrefix(lowercased(Array(value[start..<end])), reservedPrefix) {
                stripped = true
            } else {
                if !kept.isEmpty { kept.append(0x20) }
                kept.append(contentsOf: value[start..<end])
            }
            start = end
        }
        return stripped ? kept : nil
    }

    private static func lowercased(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(where: { $0 >= 0x41 && $0 <= 0x5A }) else { return bytes }
        return bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
    }

    private static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        bytes.count >= prefix.count && bytes[0..<prefix.count].elementsEqual(prefix)
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    private static func isBlank(_ value: [UInt8]) -> Bool {
        value.allSatisfy(isSpace)
    }

    private static func trimmed(_ value: [UInt8]) -> [UInt8] {
        guard let first = value.firstIndex(where: { !isSpace($0) }), let last = value.lastIndex(where: { !isSpace($0) }) else {
            return []
        }
        return Array(value[first...last])
    }

    private static let keep = AttributeMutation(keep: true)
    private static let drop = AttributeMutation(keep: false)
    private static func replacing(_ value: String) -> AttributeMutation {
        AttributeMutation(keep: true, newValue: Array(value.utf8))
    }

    private static let preTag = "pre"
    private static let widthKey = Array("width".utf8)
    private static let heightKey = Array("height".utf8)
    private static let hiddenKey = Array("hidden".utf8)
    private static let placeholderBytes = Array(HTMLSanitizer.placeholderImage.utf8)

    private enum AttributeRole {
        case removed, style, `class`, id, name, type, src, background, href, link, usemap, paint
        /// Design facts only; the attribute itself is kept as it is.
        case backgroundColor, fontColor, fontFace
    }

    private enum LayoutHint {
        case anyValue, presentation
    }

    /// `<table>` attributes that make it a layout grid rather than a table of data (`BodyTypesetting.unstyled`).
    private static let layoutTableAttributes: [[UInt8]: LayoutHint] = {
        var map: [[UInt8]: LayoutHint] = [:]
        for key in ["width", "height", "align", "cellpadding", "cellspacing"] {
            map[Array(key.utf8)] = .anyValue
        }
        map[Array("role".utf8)] = .presentation
        return map
    }()
    private static let presentationValue = Array("presentation".utf8)

    /// One lookup per attribute decides everything about it.
    private static let attributeRoles: [[UInt8]: AttributeRole] = {
        var map: [[UInt8]: AttributeRole] = [:]
        // Resource attributes of elements that are removed anyway (poster, data, action...) go too, so they
        // never depend on the tag list being complete; srcdoc likewise in case an iframe ever got through.
        for key in ["srcset", "imagesrcset", "ping", "download", "accesskey", "autofocus", "contenteditable", "is",
                    "nonce", "http-equiv", "manifest", "srcdoc", "action", "formaction", "poster", "data", "dynsrc",
                    "lowsrc", "codebase", "classid", "archive"] {
            map[Array(key.utf8)] = .removed
        }
        map[Array("style".utf8)] = .style
        map[Array("class".utf8)] = .class
        map[Array("id".utf8)] = .id
        map[Array("name".utf8)] = .name
        map[Array("type".utf8)] = .type
        map[Array("src".utf8)] = .src
        map[Array("background".utf8)] = .background
        map[Array("href".utf8)] = .href
        map[Array("xlink:href".utf8)] = .href
        for key in ["cite", "longdesc", "profile", "itemtype"] {
            map[Array(key.utf8)] = .link
        }
        map[Array("usemap".utf8)] = .usemap
        map[Array("bgcolor".utf8)] = .backgroundColor
        map[Array("color".utf8)] = .fontColor
        map[Array("face".utf8)] = .fontFace
        map[Array("size".utf8)] = .fontFace
        for key in ["fill", "stroke", "filter", "mask", "clip-path", "marker", "marker-start", "marker-mid",
                    "marker-end", "cursor"] {
            map[Array(key.utf8)] = .paint
        }
        return map
    }()

    private static let eventPrefix = Array("on".utf8)
    /// Classes the shell owns; a sender using them could pre-fold or restyle content.
    private static let reservedPrefix = Array("ss-".utf8)
    /// Attributes the shell reads back (data-ss-src); an incoming one must never survive to be "restored".
    private static let reservedAttributePrefix = Array("data-ss-".utf8)

    private enum TagRole {
        case removed, unwrapped, rawText, style, img, svgImage, anchor, div, svg, font, table
    }

    /// One lookup per element decides everything about it.
    private static let tagRoles: [[UInt8]: TagRole] = {
        var map: [[UInt8]: TagRole] = [:]
        for tag in ["script", "iframe", "frame", "frameset", "object", "embed", "applet", "form", "input", "button",
                    "select", "textarea", "option", "optgroup", "datalist", "keygen", "meta", "link", "base", "basefont",
                    "title", "noscript", "template", "slot", "math", "video", "audio", "source", "track", "portal",
                    "param", "foreignobject", "set", "animate", "animatemotion", "animatetransform", "menuitem", "use",
                    "feimage", "noembed", "noframes"] {
            map[Array(tag.utf8)] = .removed
        }
        map[Array("picture".utf8)] = .unwrapped
        map[Array("xmp".utf8)] = .rawText
        map[Array("plaintext".utf8)] = .rawText
        map[Array("svg".utf8)] = .svg
        map[Array("area".utf8)] = .anchor
        map[Array("style".utf8)] = .style
        map[Array("img".utf8)] = .img
        map[Array("image".utf8)] = .svgImage
        map[Array("a".utf8)] = .anchor
        map[Array("div".utf8)] = .div
        map[Array("font".utf8)] = .font
        map[Array("table".utf8)] = .table
        return map
    }()
}
