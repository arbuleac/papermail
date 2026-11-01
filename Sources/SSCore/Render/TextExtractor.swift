import Foundation
import SwiftSoup

/// HTML to plain text for search, snippets and the text/plain alternative of replies.
///
/// Block elements become line breaks, list items get a "- " marker, link targets survive only when they add
/// information, whitespace collapses the way a browser would render it.
public enum TextExtractor {
    /// Bodies are capped so one pathological newsletter cannot bloat the full-text index.
    public static let maxLength = 200 * 1024

    public static func plainText(fromHTML html: String) -> String {
        guard let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body() else { return "" }
        return plainText(from: body)
    }

    static func plainText(from root: Element) -> String {
        var builder = Builder()
        builder.walk(root)
        return builder.finish()
    }

    /// Enforces `maxLength` in UTF-8 bytes without splitting a character.
    static func limited(_ text: String) -> String {
        guard text.utf8.count > maxLength else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: maxLength)
        while end > text.utf8.startIndex {
            if let cut = String(text.utf8[..<end]) { return cut }
            end = text.utf8.index(before: end)
        }
        return ""
    }
}

/// Works on UTF-8 bytes throughout: this runs for every message at sync time and most text is ASCII, so the
/// per-scalar path is reserved for text nodes that actually contain non-ASCII bytes.
private struct Builder {
    private var out: [UInt8] = []
    private var pendingNewlines = 0
    private var pendingSpace = false
    /// Set right after a list marker so the blocks inside an item start on the marker's line.
    private var inhibitNewlines = false
    private var listDepth = 0
    private var preDepth = 0
    private var full = false

    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let space = UInt8(ascii: " ")
    private static let altKey = Array("alt".utf8)

    private enum Kind {
        case inline, block, paragraph, cell, row, listItem, list, pre, link, lineBreak, image, skipped
    }

    mutating func walk(_ element: Element) {
        if full { return }
        let kind = Builder.kinds[element.tagNameNormalUTF8()] ?? .inline
        switch kind {
        case .skipped:
            return
        case .lineBreak:
            hardBreak()
            return
        case .image:
            if let alt = try? element.attr(Builder.altKey), !alt.isEmpty {
                appendText(Array("[image: ".utf8) + alt + [UInt8(ascii: "]")])
            }
            return
        default:
            break
        }
        let textStart = out.count
        enter(kind)
        for node in element.getChildNodes() {
            if full { break }
            if let text = node as? TextNode {
                appendText(text.getWholeTextUTF8())
            } else if let child = node as? Element {
                walk(child)
            }
        }
        leave(kind)
        if kind == .link { appendLinkTarget(of: element, textStart: textStart) }
    }

    mutating func finish() -> String {
        while let last = out.last, last == Builder.newline || last == Builder.space { out.removeLast() }
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return TextExtractor.limited(text)
    }

    // MARK: Structure

    private mutating func enter(_ kind: Kind) {
        switch kind {
        case .paragraph:
            requestNewlines(2)
        case .block, .row:
            requestNewlines(1)
        case .list:
            requestNewlines(listDepth == 0 ? 2 : 1)
            listDepth += 1
        case .listItem:
            inhibitNewlines = false
            requestNewlines(1)
            flushPending()
            for _ in 1..<max(listDepth, 1) { out.append(contentsOf: [Builder.space, Builder.space]) }
            out.append(contentsOf: Array("- ".utf8))
            inhibitNewlines = true
        case .cell:
            pendingSpace = true
        case .pre:
            requestNewlines(2)
            preDepth += 1
        case .inline, .link, .lineBreak, .image, .skipped:
            break
        }
    }

    private mutating func leave(_ kind: Kind) {
        switch kind {
        case .paragraph:
            requestNewlines(2)
        case .block, .row:
            requestNewlines(1)
        case .list:
            listDepth -= 1
            requestNewlines(listDepth == 0 ? 2 : 1)
        case .listItem:
            inhibitNewlines = false
            requestNewlines(1)
        case .cell:
            pendingSpace = true
        case .pre:
            preDepth -= 1
            requestNewlines(2)
        case .inline, .link, .lineBreak, .image, .skipped:
            break
        }
    }

    private mutating func appendLinkTarget(of element: Element, textStart: Int) {
        guard let href = try? element.attr("href") else { return }
        let target: String
        switch URLPolicy.classify(href) {
        case .remote(let url), .contact(let url): target = url
        default: return
        }
        // Long tracking URLs add nothing a reader wants; only short targets differing from the text are kept.
        guard target.count <= 80, textStart <= out.count else { return }
        let text = String(decoding: out[textStart...], as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard Builder.comparable(text) != Builder.comparable(target) else { return }
        appendText(Array(" (\(target))".utf8))
    }

    private static func comparable(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "mailto:"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: Text

    private mutating func appendText(_ bytes: [UInt8]) {
        if preDepth > 0 {
            flushPending()
            for byte in bytes where byte != Builder.carriageReturn { out.append(byte) }
            inhibitNewlines = false
            checkFull()
            return
        }
        if bytes.contains(where: { $0 >= 0x80 }) {
            appendScalars(of: String(decoding: bytes, as: UTF8.self))
            return
        }
        var index = 0
        let count = bytes.count
        while index < count {
            if Builder.isCollapsibleASCII(bytes[index]) {
                pendingSpace = true
                index += 1
                continue
            }
            var end = index + 1
            while end < count, !Builder.isCollapsibleASCII(bytes[end]) { end += 1 }
            flushPending()
            out.append(contentsOf: bytes[index..<end])
            inhibitNewlines = false
            index = end
        }
        checkFull()
    }

    private mutating func appendScalars(of text: String) {
        for scalar in text.unicodeScalars {
            if Builder.isCollapsible(scalar) {
                pendingSpace = true
                continue
            }
            if Builder.isZeroWidth(scalar) { continue }
            flushPending()
            for byte in scalar.utf8 { out.append(byte) }
            inhibitNewlines = false
        }
        checkFull()
    }

    private mutating func requestNewlines(_ count: Int) {
        pendingNewlines = max(pendingNewlines, count)
    }

    private mutating func flushPending() {
        if pendingNewlines > 0 {
            if !inhibitNewlines, !out.isEmpty { ensureTrailingNewlines(pendingNewlines) }
            pendingNewlines = 0
            pendingSpace = false
        } else if pendingSpace {
            pendingSpace = false
            if let last = out.last, last != Builder.newline, last != Builder.space { out.append(Builder.space) }
        }
    }

    private mutating func hardBreak() {
        flushPending()
        while out.last == Builder.space { out.removeLast() }
        guard !out.isEmpty, trailingNewlines(limit: 2) < 2 else { return }
        out.append(Builder.newline)
    }

    private mutating func ensureTrailingNewlines(_ count: Int) {
        let wanted = min(count, 2)
        while out.last == Builder.space { out.removeLast() }
        let existing = trailingNewlines(limit: wanted)
        for _ in existing..<wanted { out.append(Builder.newline) }
    }

    private func trailingNewlines(limit: Int) -> Int {
        var count = 0
        var index = out.count - 1
        while index >= 0, count < limit, out[index] == Builder.newline {
            count += 1
            index -= 1
        }
        return count
    }

    private mutating func checkFull() {
        if out.count > TextExtractor.maxLength { full = true }
    }

    private static func isCollapsibleASCII(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D || byte == 0x0B || byte == 0x0C
    }

    private static func isCollapsible(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x80 { return isCollapsibleASCII(UInt8(scalar.value)) }
        return scalar.properties.isWhitespace
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0xAD: return true
        default: return false
        }
    }

    private static let kinds: [[UInt8]: Kind] = {
        var map: [[UInt8]: Kind] = [:]
        for tag in ["script", "style", "head", "title", "template", "noscript", "svg", "math", "select", "option",
                    "datalist", "textarea", "iframe", "object", "embed"] {
            map[Array(tag.utf8)] = .skipped
        }
        for tag in ["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "table", "hr", "dl", "figure", "address"] {
            map[Array(tag.utf8)] = .paragraph
        }
        for tag in ["div", "section", "article", "header", "footer", "nav", "aside", "main", "center", "form",
                    "fieldset", "legend", "details", "summary", "figcaption", "caption", "thead", "tbody", "tfoot",
                    "dt", "dd", "menu", "dialog"] {
            map[Array(tag.utf8)] = .block
        }
        map[Array("tr".utf8)] = .row
        map[Array("td".utf8)] = .cell
        map[Array("th".utf8)] = .cell
        map[Array("li".utf8)] = .listItem
        map[Array("ul".utf8)] = .list
        map[Array("ol".utf8)] = .list
        map[Array("pre".utf8)] = .pre
        map[Array("a".utf8)] = .link
        map[Array("br".utf8)] = .lineBreak
        map[Array("img".utf8)] = .image
        return map
    }()
}
