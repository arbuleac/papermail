import Foundation
import SwiftSoup

/// Finds the earlier messages a reply carries along and wraps each in `<div class="ss-quote" data-ss-collapsed="true">`
/// so the conversation view can fold them. Knows the markup of Gmail, Outlook, Apple Mail and Yahoo, plus the
/// generic "On <date>, <name> wrote:" line followed by a blockquote.
public enum QuoteDetector {
    public static let quoteClass = "ss-quote"
    public static let collapsedAttribute = "data-ss-collapsed"

    /// Wraps quotes in a body fragment and returns the rewritten markup. The sanitizer calls the DOM-level
    /// variant directly; this entry point exists for callers that already hold safe HTML.
    public static func wrapQuotedContent(inHTML html: String) -> (html: String, hasQuotedContent: Bool) {
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            document.outputSettings().prettyPrint(pretty: false)
            guard let body = document.body() else { return (html, false) }
            var candidates = QuoteCandidates()
            collect(into: &candidates, under: body)
            let found = try wrapQuotes(in: body, candidates: candidates)
            return (try body.html(), found)
        } catch {
            return (html, false)
        }
    }

    /// Mutates `root` in place. Returns true when at least one quote was wrapped. The candidates must be in
    /// document order; each phase skips what an earlier one already folded.
    static func wrapQuotes(in root: Element, candidates: QuoteCandidates) throws -> Bool {
        var wrapped = false

        // Vendor containers that hold the whole quoted message, attribution included.
        for element in candidates.vendorContainers {
            guard element !== root, element.parent() != nil, !isInsideQuote(element) else { continue }
            try wrap(attributionRun(before: element) + [element])
            wrapped = true
        }

        // Outlook on the web marks the boundary with an id; everything after it is the earlier message.
        for marker in candidates.outlookMarkers {
            guard marker.parent() != nil, !isInsideQuote(marker) else { continue }
            var start: Node = marker
            if let previous = try marker.previousElementSibling(), previous.tagNameNormal() == "hr" { start = previous }
            try wrap(followingRun(from: start))
            wrapped = true
        }

        // Outlook desktop: a rule (or a bordered div) followed by the From:/Sent:/To:/Subject: header.
        for rule in candidates.rules {
            guard rule.parent() != nil, !isInsideQuote(rule), let header = try rule.nextElementSibling(),
                  try looksLikeOutlookHeader(header) else { continue }
            try wrap(followingRun(from: rule))
            wrapped = true
        }
        for header in candidates.borderedBlocks {
            guard header.parent() != nil, !isInsideQuote(header), try looksLikeOutlookHeader(header) else { continue }
            try wrap(followingRun(from: header))
            wrapped = true
        }

        // Anything else: a blockquote introduced by an attribution line.
        for quote in candidates.blockquotes {
            guard quote.parent() != nil, !isInsideQuote(quote) else { continue }
            let attribution = attributionRun(before: quote)
            guard !attribution.isEmpty else { continue }
            try wrap(attribution + [quote])
            wrapped = true
        }

        return wrapped
    }

    private static func collect(into candidates: inout QuoteCandidates, under root: Element) {
        for node in root.getChildNodes() {
            guard let element = node as? Element else { continue }
            let tag = element.tagNameNormalUTF8()
            candidates.consider(element, tag: tag, facts: QuoteCandidates.Facts(of: element, tag: tag))
            collect(into: &candidates, under: element)
        }
    }

    // MARK: Matching

    private static func isInsideQuote(_ element: Element) -> Bool {
        var current = element.parent()
        while let candidate = current {
            if candidate.hasClass(quoteClass) { return true }
            current = candidate.parent()
        }
        return false
    }

    private static func looksLikeOutlookHeader(_ element: Element) throws -> Bool {
        let head = leadingText(of: element, limit: 400)
        guard headerStarts.contains(where: { head.hasPrefix($0) }) else { return false }
        return headerMarkers.contains(where: { head.contains($0) })
    }

    private static let headerStarts = ["From:", "Von:", "De:", "Da:", "Van:", "Från:", "Fra:"]
    private static let headerMarkers = [
        "Sent:", "Date:", "To:", "Gesendet:", "An:", "Envoyé", "À:", "Enviado", "Para:", "Inviato", "Verzonden",
        "Skickat", "Sendt",
    ]

    /// The attribution line right before `element`, with the line breaks between them, in document order.
    /// Empty when the preceding content is not an attribution.
    private static func attributionRun(before element: Element) -> [Node] {
        var run: [Node] = []
        var node = element.previousSibling()
        while let current = node {
            if let text = current as? TextNode {
                if text.isBlank() {
                    run.insert(current, at: 0)
                    node = current.previousSibling()
                    continue
                }
                return QuoteAttribution.isAttributionLine(text.text()) ? [current] + run : []
            }
            if let candidate = current as? Element {
                let tag = candidate.tagNameNormal()
                if tag == "br" {
                    run.insert(current, at: 0)
                    node = current.previousSibling()
                    continue
                }
                guard attributionTags.contains(tag) else { return [] }
                let text = leadingText(of: candidate, limit: 401)
                guard text.count <= 400 else { return [] }
                return QuoteAttribution.isAttributionLine(text) ? [current] + run : []
            }
            // Comments and the like carry no meaning either way.
            node = current.previousSibling()
        }
        return []
    }

    /// The element's text with whitespace collapsed the way `Element.text()` does it, but cut off after
    /// `limit` characters. `text()` builds the text of the whole subtree, and candidates nest: 400 bordered
    /// divs around a large body made quote detection quadratic in the body size.
    static func leadingText(of element: Element, limit: Int) -> String {
        let byteLimit = limit * 4
        var out: [UInt8] = []
        var pendingSpace = false
        var stack: [Node] = element.getChildNodes().reversed()
        while out.count < byteLimit, let node = stack.popLast() {
            if let text = node as? TextNode {
                let bytes = text.getWholeTextUTF8()
                var index = 0
                while index < bytes.count, out.count < byteLimit {
                    let byte = bytes[index]
                    if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C {
                        pendingSpace = !out.isEmpty
                        index += 1
                        continue
                    }
                    // U+00A0, which text() also treats as a space.
                    if byte == 0xC2, index + 1 < bytes.count, bytes[index + 1] == 0xA0 {
                        pendingSpace = !out.isEmpty
                        index += 2
                        continue
                    }
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    out.append(byte)
                    index += 1
                }
            } else if let child = node as? Element {
                if child.isBlock() || child.tagNameNormal() == "br" { pendingSpace = !out.isEmpty }
                stack.append(contentsOf: child.getChildNodes().reversed())
            }
        }
        return String(String(decoding: out, as: UTF8.self).prefix(limit))
    }

    private static let attributionTags: Set<String> = ["div", "p", "span", "font", "b", "i", "em", "strong", "small"]

    private static func followingRun(from start: Node) -> [Node] {
        var nodes: [Node] = [start]
        var next = start.nextSibling()
        while let node = next {
            nodes.append(node)
            next = node.nextSibling()
        }
        return nodes
    }

    // MARK: Mutation

    /// Moves `nodes` (siblings, in order) into a fresh quote wrapper placed where the first one was.
    private static func wrap(_ nodes: [Node]) throws {
        guard let first = nodes.first, first.parent() != nil, let document = first.ownerDocument() else { return }
        let wrapper = try document.createElement("div")
        try wrapper.attr("class", quoteClass)
        try wrapper.attr(collapsedAttribute, "true")
        try first.before(wrapper)
        for node in nodes { try wrapper.appendChild(node) }
    }
}
