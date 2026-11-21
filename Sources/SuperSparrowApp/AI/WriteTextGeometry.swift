import AppKit
import SSDesign

/// Where things are in a reply's text, as Help me write's accessories need them (§5.56): the caret, the line it sits on
/// and its baseline, in the text view's coordinates. TextKit 1 only (both hosts are), read from the layout manager, which
/// lays out only up to what is asked.
@MainActor
enum WriteTextGeometry {
    /// A caret and its line.
    struct Caret: Equatable {
        /// The caret's x, in the text view.
        var x: CGFloat
        /// The caret's line, from the text column's leading edge to its trailing edge, in the text view.
        var line: NSRect
        /// The line's baseline, in the text view.
        var baseline: CGFloat
        /// Text follows the caret on its line (a caret mid-line, a rewrite's tail).
        var textFollows: Bool
    }

    /// The text column: where lines start and end, in the text view (the container less its padding).
    static func column(of textView: NSTextView) -> NSRect {
        guard let container = textView.textContainer else { return textView.bounds }
        let origin = textView.textContainerOrigin
        let padding = container.lineFragmentPadding
        return NSRect(x: origin.x + padding, y: origin.y, width: max(0, container.size.width - 2 * padding),
                      height: max(0, textView.bounds.height - origin.y))
    }

    /// The caret at `location` (a selection's end, a stream's end), laid out up to it. `attributes` set the line's
    /// baseline where no letter on it says (an empty line).
    static func caret(at location: Int, in textView: NSTextView, attributes: [NSAttributedString.Key: Any]) -> Caret? {
        guard let manager = textView.layoutManager, let container = textView.textContainer, let storage = textView.textStorage else {
            return nil
        }
        let length = storage.length
        let at = max(0, min(location, length))
        var count = 0
        let caretRange = NSRange(location: at, length: 0)
        guard let rects = manager.rectArray(forCharacterRange: caretRange, withinSelectedCharacterRange: caretRange, in: container,
                                            rectCount: &count), count > 0 else { return nil }
        let origin = textView.textContainerOrigin
        let local = rects[0]
        let column = column(of: textView)
        let line = NSRect(x: column.minX, y: local.minY + origin.y, width: column.width, height: local.height)
        let x = local.minX + origin.x
        var baseline = line.minY + probeBaseline(attributes)
        var follows = false
        let text = storage.string as NSString
        if at < length, !isLineEnd(text.character(at: at)) {
            // A letter after the caret on its line: the caret is mid-line.
            let glyph = manager.glyphIndexForCharacter(at: at)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            follows = abs(fragment.minY + origin.y - line.minY) < 0.5
        }
        if at > 0, !isLineEnd(text.character(at: at - 1)) {
            // The letter before the caret is on its line: its baseline is the line's (a picture's line is taller).
            let glyph = manager.glyphIndexForCharacter(at: at - 1)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if abs(fragment.minY + origin.y - line.minY) < 0.5 {
                baseline = fragment.minY + origin.y + manager.location(forGlyphAt: glyph).y
            }
        }
        return Caret(x: x, line: line, baseline: baseline, textFollows: follows)
    }

    /// The line fragment the character before `end` sits on (a selection's or a draft's last line), or the caret's line
    /// at `end` when nothing comes before it, in the text container's coordinates.
    static func lastLine(endingAt end: Int, in textView: NSTextView) -> NSRect? {
        guard let manager = textView.layoutManager, let container = textView.textContainer, let storage = textView.textStorage else {
            return nil
        }
        let length = storage.length
        let at = max(0, min(end, length))
        if at > 0 {
            let text = storage.string as NSString
            // A selection that ends with its line break (a triple-clicked paragraph) ends on the line before it.
            let last = isLineEnd(text.character(at: at - 1)) && at - 1 > 0 ? at - 2 : at - 1
            let glyph = manager.glyphIndexForCharacter(at: max(0, last))
            if glyph < manager.numberOfGlyphs {
                return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
        }
        var count = 0
        let caret = NSRange(location: at, length: 0)
        guard let rects = manager.rectArray(forCharacterRange: caret, withinSelectedCharacterRange: caret, in: container,
                                            rectCount: &count), count > 0 else { return nil }
        let rect = rects[0]
        return NSRect(x: 0, y: rect.minY, width: container.size.width, height: rect.height)
    }

    static func isLineEnd(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x2029 || character == 0x2028
    }

    private struct ProbeKey: Hashable {
        let font: String
        let size: CGFloat
        let lineHeight: CGFloat
        let offset: CGFloat
    }

    private static var probes: [ProbeKey: CGFloat] = [:]

    /// Where a line set in `attributes` has its baseline, from its top: laid out once by TextKit, as the text view lays a
    /// line out (the paragraph's exact line height, the role's baseline offset), and kept.
    static func probeBaseline(_ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
        let style = attributes[.paragraphStyle] as? NSParagraphStyle
        let offset = (attributes[.baselineOffset] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        let key = ProbeKey(font: font.fontName, size: font.pointSize, lineHeight: style?.maximumLineHeight ?? 0, offset: offset)
        if let known = probes[key] { return known }
        var probe = attributes
        probe[.attachment] = nil
        let storage = NSTextStorage(string: "x", attributes: probe)
        let manager = NSLayoutManager()
        QuireFont.configure(manager)
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 1_000, height: 1_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let baseline = manager.location(forGlyphAt: 0).y
        probes[key] = baseline
        return baseline
    }
}

/// Help me write's quiet keycap (§5.56): the shortcut set in the text's ghost ink, no fill and a hairline edge, so it reads
/// as part of the words it sits in, not as a control. `layout.writeCaret.keycapHeight` tall, the `kbd` legend
/// `keycapPadX` in from each side, radius `kbd.radius`.
@MainActor
enum WriteQuietKeycap {
    static func size(_ legend: String) -> NSSize {
        let c = Quire.Layout.WriteCaret.self
        let words = QuireFont.attributedString(legend, role: .kbd, color: .qInk3)
        let width = max(c.keycapHeight, ceil(words.size().width) + 2 * c.keycapPadX)
        return NSSize(width: width, height: c.keycapHeight)
    }

    /// Draws the cap filling `rect`: the edge one device pixel (1 pt in Increase Contrast, in `ruleStrong`).
    static func draw(_ legend: String, in rect: NSRect, ink: NSColor, edge: NSColor = .qRule, hairline: CGFloat) {
        let radius = Quire.Layout.Kbd.radius
        let strong = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        QuireDraw.strokeInside(rect, radius: radius, width: strong ? 1 : hairline, strong ? .qRuleStrong : edge)
        let words = QuireFont.attributedString(legend, role: .kbd, color: ink)
        let lineHeight = QuireFont.Role.kbd.lineHeight
        let width = ceil(words.size().width)
        let textRect = NSRect(x: rect.midX - width / 2, y: rect.minY + ((rect.height - lineHeight) / 2).rounded(.down),
                              width: width + 1, height: lineHeight)
        words.draw(with: textRect, options: QuireFont.drawingOptions, context: nil)
    }
}
