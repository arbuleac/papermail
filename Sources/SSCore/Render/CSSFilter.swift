import Foundation

/// Rewrites CSS so it can only paint. Comments go, remote fetches become `none`, cid references become `ss-cid`
/// URLs, `#id` selectors follow the `ss-` prefix applied to id attributes, and the legacy script-ish vectors
/// (expression(), behavior, -moz-binding, @import, position: fixed) disappear.
///
/// The scanner works on UTF-8 bytes rather than a CSS grammar: a newsletter carries tens of kilobytes of style
/// and sanitizing runs for every message at sync time, so this has to stay a single linear pass. CSS that needs
/// no change comes back byte for byte, which lets the sanitizer leave the DOM alone for the common case.
struct CSSFilter: Sendable {
    enum Mode: Sendable {
        /// The contents of a `style="…"` attribute: declarations only.
        case attribute
        /// The contents of a `<style>` element: rules, at-rules and nested blocks.
        case sheet
    }

    struct Result: Sendable {
        var css: String
        var blockedRemoteImages: Int
        /// False when nothing was dropped or rewritten; `css` is then the input itself.
        var changed: Bool
        var facts = Facts()
    }

    /// What the declarations a call kept say about the body's design, gathered in the same pass so the
    /// sanitizer can classify a body (`BodyTypesetting`, `SanitizedBody.declaresColors`) without a second scan.
    struct Facts: Sendable {
        /// A `color` or `background` family declaration whose value sets something.
        var declaresColors = false
        /// A declaration outside the neutral text-flow and spacing properties.
        var styles = false
        /// The same, also leaving out box sizing (`width`, `height`, `max-width`, `max-height`), which is
        /// neutral on an image: a resized picture in a personal note is not a designed layout.
        var stylesBeyondSizing = false
    }

    let allowRemoteImages: Bool
    let messageID: MessageID

    func filter(_ css: String, mode: Mode) -> Result {
        let result = filter(bytes: Array(css.utf8), mode: mode)
        guard let rewritten = result.css else {
            return Result(css: css, blockedRemoteImages: result.blockedRemoteImages, changed: false, facts: result.facts)
        }
        return Result(
            css: String(decoding: rewritten, as: UTF8.self), blockedRemoteImages: result.blockedRemoteImages,
            changed: true, facts: result.facts
        )
    }

    /// The DOM hands out attribute values as bytes; going through String for every style attribute would cost
    /// two allocations per element. `css` is nil when nothing needed changing.
    func filter(bytes: [UInt8], mode: Mode) -> (css: [UInt8]?, blockedRemoteImages: Int, facts: Facts) {
        var scanner = Scanner(filter: self, mode: mode, bytes: bytes)
        scanner.run()
        return (scanner.altered ? scanner.output : nil, scanner.blocked, scanner.facts)
    }

    /// An SVG presentation attribute (`fill`, `mask`, `filter`...) is a CSS value in all but name: its url()
    /// references fetch like any in a style attribute and its fragment references must follow prefixed ids.
    /// `css` is nil when nothing needed changing; `drop` means the attribute has to go entirely.
    func filter(presentationValue bytes: [UInt8]) -> (css: [UInt8]?, drop: Bool, blockedRemoteImages: Int) {
        guard bytes.contains(where: { $0 == ASCII.backslash }) || Scanner.containsIgnoringCase(bytes, Scanner.urlNeedle) else {
            return (nil, false, 0)
        }
        var scanner = Scanner(filter: self, mode: .attribute, bytes: [])
        guard let value = scanner.filteredValue(lowerName: [], value: Scanner.trim(bytes[...])) else {
            return (nil, true, scanner.blocked)
        }
        return (scanner.altered ? value : nil, false, scanner.blocked)
    }

    fileprivate enum URLRewrite {
        /// The original `url(...)` token is fine as written.
        case keep
        case replace([UInt8])
    }

    fileprivate func rewrite(url inner: [UInt8]) -> (rewrite: URLRewrite, blocked: Bool) {
        let value = String(decoding: inner, as: UTF8.self)
        switch URLPolicy.classify(value) {
        case .inlineImage(let contentID):
            let url = RenderURLScheme.inlineImageURL(for: messageID, contentID: contentID).absoluteString
            return (.replace(Scanner.urlToken(url)), false)
        case .inlineData(let data):
            return (data == value ? .keep : .replace(Scanner.urlToken(data)), false)
        case .remote(let url):
            guard allowRemoteImages else { return (.replace(Scanner.none), true) }
            return (url == value ? .keep : .replace(Scanner.urlToken(url)), false)
        case .fragment(let fragment):
            // Ids carry the ss- prefix in the output, so gradient, clip-path and marker references must too.
            let name = fragment.dropFirst()
            return (.replace(name.isEmpty ? Scanner.none : Scanner.urlToken("#ss-" + name)), false)
        case .contact, .rejected:
            return (.replace(Scanner.none), false)
        }
    }
}

private struct Scanner {
    let filter: CSSFilter
    let mode: CSSFilter.Mode
    let bytes: [UInt8]
    var output: [UInt8] = []
    var blocked = 0
    /// Set the moment anything is dropped or rewritten. Formatting differences alone never set it.
    var altered = false
    private(set) var facts = CSSFilter.Facts()

    private var segment: [UInt8] = []
    /// Depth inside a block whose prelude was dropped (everything in it is discarded).
    private var skipDepth = 0
    /// Blocks opened in the output, so stray braces never unbalance what we emit.
    private var openBlocks = 0

    private enum Terminator { case semicolon, open, close, end }

    init(filter: CSSFilter, mode: CSSFilter.Mode, bytes: [UInt8]) {
        self.filter = filter
        self.mode = mode
        self.bytes = bytes
    }

    mutating func run() {
        output.reserveCapacity(bytes.count)
        var index = 0
        var parens = 0
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            if byte == ASCII.slash, index + 1 < count, bytes[index + 1] == ASCII.star {
                index = skipComment(from: index + 2)
                altered = true
                // A comment is a token boundary ("a/**/b" is two idents), so leave a space in its place.
                segment.append(ASCII.space)
                continue
            }
            if byte == ASCII.quote || byte == ASCII.apostrophe {
                index = copyString(from: index)
                continue
            }
            // An escaped character is never structure: `\"` does not open a string and `\;` ends nothing.
            // Copying the pair keeps this scanner tokenising the way WebKit does.
            if byte == ASCII.backslash {
                index = copyEscape(from: index)
                continue
            }
            if byte == ASCII.lessThan, mode == .sheet {
                if Scanner.hasBytes(bytes, at: index, Scanner.cdo) {
                    // `<!--` and `-->` are no-ops in a sheet; old mailers still wrap their rules in them.
                    index += Scanner.cdo.count
                    segment.append(ASCII.space)
                } else {
                    index += 1
                    segment.append(contentsOf: Scanner.escapedLessThan)
                }
                altered = true
                continue
            }
            if byte == ASCII.hyphen, mode == .sheet, Scanner.hasBytes(bytes, at: index, Scanner.cdc) {
                index += Scanner.cdc.count
                segment.append(ASCII.space)
                altered = true
                continue
            }
            if byte == ASCII.openParen {
                parens += 1
            } else if byte == ASCII.closeParen {
                parens = max(0, parens - 1)
            } else if parens == 0 {
                if byte == ASCII.semicolon { flush(.semicolon); index += 1; continue }
                if byte == ASCII.openBrace { flush(.open); index += 1; continue }
                if byte == ASCII.closeBrace { flush(.close); index += 1; continue }
            }
            segment.append(byte)
            index += 1
        }
        flush(.end)
        if openBlocks > 0 { altered = true }
        while openBlocks > 0 { output.append(ASCII.closeBrace); openBlocks -= 1 }
    }

    private func skipComment(from start: Int) -> Int {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == ASCII.star, bytes[index + 1] == ASCII.slash { return index + 2 }
            index += 1
        }
        return bytes.count
    }

    /// A sheet is raw text inside `<style>`; a `<` in it is the one byte that could ever be read as markup
    /// (inside foreign content, or by any later re-parse), so it is always written as the CSS escape.
    private mutating func appendSheetByte(_ byte: UInt8) {
        if byte == ASCII.lessThan, mode == .sheet {
            segment.append(contentsOf: Scanner.escapedLessThan)
            altered = true
        } else {
            segment.append(byte)
        }
    }

    private mutating func copyEscape(from start: Int) -> Int {
        guard start + 1 < bytes.count, bytes[start + 1] != ASCII.newline else {
            segment.append(ASCII.backslash)
            return start + 1
        }
        if bytes[start + 1] == ASCII.lessThan, mode == .sheet {
            appendSheetByte(ASCII.lessThan)
        } else {
            segment.append(ASCII.backslash)
            segment.append(bytes[start + 1])
        }
        return start + 2
    }

    private mutating func copyString(from start: Int) -> Int {
        let quote = bytes[start]
        segment.append(quote)
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == ASCII.backslash, index + 1 < bytes.count {
                index = copyEscape(from: index)
                continue
            }
            appendSheetByte(byte)
            index += 1
            if byte == quote { return index }
            // An unescaped newline ends a bad string; the parser would drop the declaration, we just stop copying.
            if byte == ASCII.newline { return index }
        }
        return index
    }

    private mutating func flush(_ terminator: Terminator) {
        defer { segment.removeAll(keepingCapacity: true) }
        let trimmed = Scanner.trim(segment[...])
        switch terminator {
        case .open:
            if skipDepth > 0 { skipDepth += 1; return }
            // Braces have no meaning in a style attribute; whatever surrounds them is garbage.
            if mode == .attribute { altered = true; return }
            if Scanner.isDroppedPrelude(trimmed) { skipDepth = 1; altered = true; return }
            output.append(contentsOf: Scanner.rewriteIDSelectors(Array(trimmed), altered: &altered))
            output.append(ASCII.openBrace)
            openBlocks += 1
        case .close:
            if skipDepth > 0 { skipDepth -= 1; return }
            emitDeclaration(trimmed)
            if mode == .sheet, openBlocks > 0 {
                output.append(ASCII.closeBrace)
                openBlocks -= 1
            } else {
                altered = true
            }
        case .semicolon, .end:
            if skipDepth > 0 { return }
            emitDeclaration(trimmed)
        }
    }

    private mutating func emitDeclaration(_ declaration: ArraySlice<UInt8>) {
        guard let first = declaration.first else { return }
        // Statement at-rules (@import, @charset, @namespace, @layer) never help an email paint.
        if first == ASCII.at { altered = true; return }
        guard let colon = declaration.firstIndex(of: ASCII.colon) else { altered = true; return }
        let name = Scanner.trim(declaration[declaration.startIndex..<colon])
        let value = Scanner.trim(declaration[(colon + 1)...])
        guard !name.isEmpty else { altered = true; return }
        // CSS resolves escapes in a property name before looking the property up: `pos\69tion` is position.
        let lowerName = Scanner.decodedLowercase(name) ?? Scanner.lowercased(name)
        if Scanner.droppedProperties.contains(lowerName) { altered = true; return }
        guard let finalValue = filteredValue(lowerName: lowerName, value: value) else { altered = true; return }
        // The value as written, not as filtered: a blocked background became `none` here but is still part of
        // the design, and loading images brings it back.
        noteFacts(lowerName: lowerName, value: value)
        output.append(contentsOf: name)
        output.append(ASCII.colon)
        output.append(ASCII.space)
        output.append(contentsOf: finalValue)
        output.append(ASCII.semicolon)
    }

    private mutating func noteFacts(lowerName: [UInt8], value: ArraySlice<UInt8>) {
        // Once both are known nothing more can change, and a newsletter has thousands of declarations.
        if facts.declaresColors, facts.stylesBeyondSizing { return }
        if !Scanner.isNeutral(lowerName) {
            facts.styles = true
            if !Scanner.sizingProperties.contains(lowerName) { facts.stylesBeyondSizing = true }
        }
        if !facts.declaresColors, Scanner.colorProperties.contains(lowerName), !Scanner.setsNoColor(value) {
            facts.declaresColors = true
        }
    }

    /// The value with its url() references rewritten, or nil when the whole declaration has to go.
    mutating func filteredValue(lowerName: [UInt8], value: ArraySlice<UInt8>) -> [UInt8]? {
        let lowerValue = Scanner.lowercased(value)
        // The tokenizer resolves escapes outside strings, so `u\72l(` is a url token and `f\69xed` is fixed.
        // Rewriting through escapes is not worth it: a value that only reaches a dangerous form once decoded
        // is dropped. Escapes inside strings (`content: "\201C"`) never form a function name.
        let decodedValue = Scanner.decodedLowercase(value)
        if let decodedValue, Scanner.contains(decodedValue, Scanner.urlNeedle) || Scanner.contains(decodedValue, Scanner.imageSetNeedle)
            || Scanner.contains(Scanner.compact(decodedValue), Scanner.expressionCall) {
            return nil
        }
        let checkedValue = decodedValue ?? lowerValue
        if Scanner.contains(checkedValue, Scanner.expressionNeedle), Scanner.contains(Scanner.compact(checkedValue), Scanner.expressionCall) {
            return nil
        }
        if lowerName == Scanner.positionName, Scanner.contains(checkedValue, Scanner.fixedNeedle) { return nil }
        // image-set() accepts bare strings as URLs, which would bypass the url() rewriting below.
        if Scanner.contains(lowerValue, Scanner.imageSetNeedle) { return nil }
        guard Scanner.contains(lowerValue, Scanner.urlNeedle) else { return Array(value) }
        return rewriteURLs(Array(value))
    }

    private mutating func rewriteURLs(_ value: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(value.count)
        var index = 0
        let count = value.count
        while index < count {
            let byte = value[index]
            if byte == ASCII.quote || byte == ASCII.apostrophe {
                let end = Scanner.endOfString(in: value, from: index)
                out.append(contentsOf: value[index..<end])
                index = end
                continue
            }
            if byte == ASCII.backslash, index + 1 < count {
                out.append(byte)
                out.append(value[index + 1])
                index += 2
                continue
            }
            if Scanner.isURLFunctionStart(value, at: index) {
                var cursor = index + 4
                var inner: [UInt8] = []
                var closed = false
                while cursor < count, Scanner.isWhitespace(value[cursor]) { cursor += 1 }
                if cursor < count, value[cursor] == ASCII.quote || value[cursor] == ASCII.apostrophe {
                    let quote = value[cursor]
                    cursor += 1
                    while cursor < count {
                        let inside = value[cursor]
                        if inside == ASCII.backslash, cursor + 1 < count {
                            inner.append(value[cursor + 1])
                            cursor += 2
                            continue
                        }
                        cursor += 1
                        if inside == quote { break }
                        inner.append(inside)
                    }
                    while cursor < count, Scanner.isWhitespace(value[cursor]) { cursor += 1 }
                    // `url("a" ...)` is a function whose further arguments are ordinary tokens, another url()
                    // among them. Nothing an email needs looks like that, so the declaration goes.
                    if cursor < count, value[cursor] != ASCII.closeParen { return nil }
                } else {
                    while cursor < count, value[cursor] != ASCII.closeParen {
                        inner.append(value[cursor])
                        cursor += 1
                    }
                }
                if cursor < count {
                    closed = true
                    cursor += 1
                }
                // An unterminated url( swallows the rest of the value in a real parser too.
                let tokenEnd = closed ? cursor : count
                let decision = filter.rewrite(url: Array(Scanner.trim(inner[...])))
                if decision.blocked { blocked += 1 }
                switch decision.rewrite {
                case .keep:
                    out.append(contentsOf: value[index..<tokenEnd])
                case .replace(let replacement):
                    altered = true
                    out.append(contentsOf: replacement)
                }
                index = tokenEnd
                continue
            }
            out.append(byte)
            index += 1
        }
        return out
    }

    // MARK: Helpers

    static let none = Array("none".utf8)

    static func urlToken(_ url: String) -> [UInt8] {
        var out = Array("url(\"".utf8)
        for byte in url.utf8 {
            if byte == ASCII.quote || byte == ASCII.backslash { out.append(ASCII.backslash) }
            out.append(byte)
        }
        out.append(contentsOf: Array("\")".utf8))
        return out
    }

    private static func isURLFunctionStart(_ value: [UInt8], at index: Int) -> Bool {
        guard index + 3 < value.count else { return false }
        guard value[index] | 0x20 == ASCII.u, value[index + 1] | 0x20 == ASCII.r, value[index + 2] | 0x20 == ASCII.l,
              value[index + 3] == ASCII.openParen else {
            return false
        }
        // "xurl(" would be a different (unknown) function; only a standalone url token matters.
        return index == 0 || !isIdentByte(value[index - 1])
    }

    private static func endOfString(in value: [UInt8], from start: Int) -> Int {
        let quote = value[start]
        var index = start + 1
        while index < value.count {
            let byte = value[index]
            if byte == ASCII.backslash, index + 1 < value.count { index += 2; continue }
            index += 1
            if byte == quote || byte == ASCII.newline { return index }
        }
        return index
    }

    private static func isDroppedPrelude(_ prelude: ArraySlice<UInt8>) -> Bool {
        guard prelude.first == ASCII.at else { return false }
        let lower = decodedLowercase(prelude) ?? lowercased(prelude)
        if contains(lower, urlNeedle) { return true }
        return hasPrefix(lower, importNeedle) || hasPrefix(lower, charsetNeedle) || hasPrefix(lower, namespaceNeedle)
    }

    /// `#foo` in a selector must keep matching the element whose id became `ss-foo`.
    private static func rewriteIDSelectors(_ prelude: [UInt8], altered: inout Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(prelude.count + 8)
        var index = 0
        while index < prelude.count {
            let byte = prelude[index]
            if byte == ASCII.quote || byte == ASCII.apostrophe {
                let end = endOfString(in: prelude, from: index)
                out.append(contentsOf: prelude[index..<end])
                index = end
                continue
            }
            if byte == ASCII.backslash, index + 1 < prelude.count {
                out.append(byte)
                out.append(prelude[index + 1])
                index += 2
                continue
            }
            out.append(byte)
            if byte == ASCII.hash, index + 1 < prelude.count, isIdentStartByte(prelude[index + 1]) {
                out.append(contentsOf: idPrefix)
                altered = true
            }
            index += 1
        }
        return out
    }

    static func trim(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var start = slice.startIndex
        var end = slice.endIndex
        while start < end, isWhitespace(slice[start]) { start += 1 }
        while end > start, isWhitespace(slice[end - 1]) { end -= 1 }
        return slice[start..<end]
    }

    static func lowercased(_ slice: ArraySlice<UInt8>) -> [UInt8] {
        slice.map { $0 >= ASCII.upperA && $0 <= ASCII.upperZ ? $0 + 0x20 : $0 }
    }

    static func compact(_ bytes: [UInt8]) -> [UInt8] {
        bytes.filter { !isWhitespace($0) }
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count, let first = needle.first else { return needle.isEmpty }
        var index = 0
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first {
                var match = true
                var offset = 1
                while offset < needle.count {
                    if haystack[index + offset] != needle[offset] { match = false; break }
                    offset += 1
                }
                if match { return true }
            }
            index += 1
        }
        return false
    }

    static func containsIgnoringCase(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        var index = 0
        let last = haystack.count - needle.count
        while index <= last {
            var offset = 0
            while offset < needle.count, haystack[index + offset] | 0x20 == needle[offset] { offset += 1 }
            if offset == needle.count { return true }
            index += 1
        }
        return false
    }

    static func hasBytes(_ bytes: [UInt8], at index: Int, _ expected: [UInt8]) -> Bool {
        index + expected.count <= bytes.count && bytes[index..<(index + expected.count)].elementsEqual(expected)
    }

    /// Lowercased text with CSS escapes outside strings resolved, or nil when there were none: the common
    /// case, where the plain lowercased bytes already are what the tokenizer sees.
    static func decodedLowercase(_ slice: ArraySlice<UInt8>) -> [UInt8]? {
        guard slice.contains(ASCII.backslash) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(slice.count)
        var decodedAny = false
        var quote: UInt8?
        var index = slice.startIndex
        let end = slice.endIndex
        while index < end {
            let byte = slice[index]
            if let open = quote {
                out.append(lowercasedByte(byte))
                if byte == ASCII.backslash, index + 1 < end {
                    out.append(lowercasedByte(slice[index + 1]))
                    index += 2
                    continue
                }
                if byte == open || byte == ASCII.newline { quote = nil }
                index += 1
                continue
            }
            if byte == ASCII.quote || byte == ASCII.apostrophe {
                quote = byte
                out.append(byte)
                index += 1
                continue
            }
            guard byte == ASCII.backslash else {
                out.append(lowercasedByte(byte))
                index += 1
                continue
            }
            index += 1
            guard index < end else { break }
            if let first = hexValue(slice[index]) {
                var value = UInt32(first)
                var digits = 1
                index += 1
                while index < end, digits < 6, let digit = hexValue(slice[index]) {
                    value = value * 16 + UInt32(digit)
                    digits += 1
                    index += 1
                }
                if index < end, isWhitespace(slice[index]) { index += 1 }
                let scalar = value == 0 ? nil : Unicode.Scalar(value)
                for unit in String(scalar ?? "\u{FFFD}").utf8 { out.append(lowercasedByte(unit)) }
            } else if slice[index] != ASCII.newline {
                out.append(lowercasedByte(slice[index]))
                index += 1
            }
            decodedAny = true
        }
        return decodedAny ? out : nil
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case ASCII.zero...ASCII.nine: return byte - ASCII.zero
        case ASCII.lowerA...ASCII.lowerF: return byte - ASCII.lowerA + 10
        case ASCII.upperA...ASCII.upperF: return byte - ASCII.upperA + 10
        default: return nil
        }
    }

    private static func lowercasedByte(_ byte: UInt8) -> UInt8 {
        byte >= ASCII.upperA && byte <= ASCII.upperZ ? byte + 0x20 : byte
    }

    static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        bytes.count >= prefix.count && bytes[0..<prefix.count].elementsEqual(prefix)
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == ASCII.space || byte == ASCII.tab || byte == ASCII.newline || byte == ASCII.carriageReturn || byte == ASCII.formFeed
    }

    private static func isIdentByte(_ byte: UInt8) -> Bool {
        isIdentStartByte(byte) || (byte >= ASCII.zero && byte <= ASCII.nine)
    }

    private static func isIdentStartByte(_ byte: UInt8) -> Bool {
        (byte >= ASCII.lowerA && byte <= ASCII.lowerZ) || (byte >= ASCII.upperA && byte <= ASCII.upperZ)
            || byte == ASCII.underscore || byte == ASCII.hyphen || byte == ASCII.backslash || byte >= 0x80
    }

    static let escapedLessThan = Array("\\3c ".utf8)
    static let cdo = Array("<!--".utf8)
    static let cdc = Array("-->".utf8)

    /// Properties ordinary personal mail carries without being designed: Apple Mail's wrapping on `<body>`,
    /// Gmail's quote bar (margin, border, padding), direction and alignment. Anything else is author styling.
    static func isNeutral(_ lowerName: [UInt8]) -> Bool {
        neutralProperties.contains(lowerName)
            || hasPrefix(lowerName, marginPrefix) || hasPrefix(lowerName, paddingPrefix) || hasPrefix(lowerName, borderPrefix)
    }

    private static let neutralProperties: Set<[UInt8]> = Set([
        "margin", "padding", "border", "direction", "unicode-bidi", "text-align", "word-wrap", "overflow-wrap",
        "word-break", "white-space", "line-break", "-webkit-line-break", "-webkit-nbsp-mode", "caret-color",
        "-webkit-text-size-adjust", "-ms-text-size-adjust", "text-size-adjust",
    ].map { Array($0.utf8) })
    private static let marginPrefix = Array("margin-".utf8)
    private static let paddingPrefix = Array("padding-".utf8)
    private static let borderPrefix = Array("border-".utf8)
    static let sizingProperties: Set<[UInt8]> = Set(["width", "height", "max-width", "max-height"].map { Array($0.utf8) })
    static let colorProperties: Set<[UInt8]> = Set(["color", "background", "background-color", "background-image"].map { Array($0.utf8) })

    /// A colour declaration whose whole value (before any `!important`) is one of these paints nothing of its own.
    static func setsNoColor(_ value: ArraySlice<UInt8>) -> Bool {
        var keyword = trim(value)
        if let bang = keyword.firstIndex(of: ASCII.bang) { keyword = trim(keyword[keyword.startIndex..<bang]) }
        return keyword.isEmpty || noColorValues.contains(lowercased(keyword))
    }

    private static let noColorValues: Set<[UInt8]> = Set([
        "inherit", "initial", "unset", "revert", "revert-layer", "currentcolor", "transparent", "none",
    ].map { Array($0.utf8) })

    static let droppedProperties: Set<[UInt8]> = [
        Array("behavior".utf8), Array("-ms-behavior".utf8), Array("-moz-binding".utf8),
    ]
    static let expressionNeedle = Array("expression".utf8)
    static let expressionCall = Array("expression(".utf8)
    static let positionName = Array("position".utf8)
    static let fixedNeedle = Array("fixed".utf8)
    static let imageSetNeedle = Array("image-set(".utf8)
    static let urlNeedle = Array("url(".utf8)
    private static let importNeedle = Array("@import".utf8)
    private static let charsetNeedle = Array("@charset".utf8)
    private static let namespaceNeedle = Array("@namespace".utf8)
    private static let idPrefix = Array("ss-".utf8)
}

private enum ASCII {
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let formFeed: UInt8 = 0x0C
    static let slash = UInt8(ascii: "/")
    static let star = UInt8(ascii: "*")
    static let quote = UInt8(ascii: "\"")
    static let apostrophe = UInt8(ascii: "'")
    static let backslash = UInt8(ascii: "\\")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let semicolon = UInt8(ascii: ";")
    static let colon = UInt8(ascii: ":")
    static let at = UInt8(ascii: "@")
    static let bang = UInt8(ascii: "!")
    static let hash = UInt8(ascii: "#")
    static let lessThan = UInt8(ascii: "<")
    static let lowerF = UInt8(ascii: "f")
    static let upperF = UInt8(ascii: "F")
    static let underscore = UInt8(ascii: "_")
    static let hyphen = UInt8(ascii: "-")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
    static let lowerA = UInt8(ascii: "a")
    static let lowerZ = UInt8(ascii: "z")
    static let upperA = UInt8(ascii: "A")
    static let upperZ = UInt8(ascii: "Z")
    static let u = UInt8(ascii: "u")
    static let r = UInt8(ascii: "r")
    static let l = UInt8(ascii: "l")
}
