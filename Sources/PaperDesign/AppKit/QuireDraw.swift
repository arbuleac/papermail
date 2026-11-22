import AppKit

/// Drawing helpers the AppKit components share. Everything here runs inside `draw(_:)` (or a drawing handler)
/// and resolves colours at that moment, under the current drawing appearance, so a component never caches a
/// colour that an appearance, Increase Contrast or Graphite change would make stale.
///
/// The shape helpers are public for views that draw several Quire marks in one `draw(_:)` (list rows, §8.2),
/// so their pips, chips and edges match the components exactly.
public enum QuireDraw {
    // MARK: Mode

    /// The mode the current drawing appearance resolves to (Increase Contrast included).
    static var mode: QuireMode { QuireMode(NSAppearance.currentDrawing()) }
    static var isIncreasedContrast: Bool { mode.isIncreasedContrast }

    // MARK: Shapes

    /// A rounded rect whose radius never exceeds half the shorter side, so a "pill" radius stays a pill.
    public static func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let r = min(max(0, radius), rect.width / 2, rect.height / 2)
        return NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    }

    public static func fill(_ rect: NSRect, radius: CGFloat, _ color: NSColor) {
        color.setFill()
        roundedRect(rect, radius: radius).fill()
    }

    /// An edge drawn inside the shape (CSS `inset 0 0 0 1px`): the stroke's outer edge lies on `rect`.
    public static func strokeInside(_ rect: NSRect, radius: CGFloat, width: CGFloat, _ color: NSColor) {
        let inner = rect.insetBy(dx: width / 2, dy: width / 2)
        let path = roundedRect(inner, radius: radius - width / 2)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    public static func fillCircle(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    // MARK: Symbols

    private struct SymbolKey: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: CGFloat
    }

    private static let symbols = LockedCache<SymbolKey, NSImage?>()

    /// The template image for a symbol (SF Symbol or `paper.` glyph), cached: building a configured symbol image
    /// is too slow to repeat in every `draw(_:)`.
    static func symbolImage(_ name: String, size: QuireSymbolSize) -> NSImage? {
        symbols.value(for: SymbolKey(name: name, pointSize: size.pointSize, weight: size.weight.rawValue)) {
            QuireSymbol.image(name, size: size)
        }
    }

    static func symbolSize(_ name: String, size: QuireSymbolSize) -> NSSize {
        symbolImage(name, size: size)?.size ?? NSSize(width: size.pointSize, height: size.pointSize)
    }

    /// Draws a symbol in `color`, centred on `rect`'s centre at its natural size, on whole points so it
    /// stays sharp. Returns the rect it drew in.
    @discardableResult
    static func symbol(_ name: String, size: QuireSymbolSize, color: NSColor, centredIn rect: NSRect) -> NSRect {
        guard let image = symbolImage(name, size: size) else { return .zero }
        let s = image.size
        let target = NSRect(x: (rect.midX - s.width / 2).rounded(), y: (rect.midY - s.height / 2).rounded(),
                            width: s.width, height: s.height)
        template(image, color: color, in: target)
        return target
    }

    /// Tints a template image: the image is drawn into a transparency layer and the colour is laid over it
    /// with source-atop, so only the symbol's own pixels take the colour (dynamic colours resolve here).
    static func template(_ image: NSImage, color: NSColor, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(in: rect.insetBy(dx: -1, dy: -1), auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.setFill()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: Text

    /// A single line in `role`: the role's font, exact line height and tracking (spec §4.4).
    static func line(_ text: String, _ role: QuireFont.Role, _ color: NSColor) -> NSAttributedString {
        QuireFont.attributedString(text, role: role, color: color)
    }

    /// The line's advance width, rounded up to whole points.
    static func width(_ string: NSAttributedString) -> CGFloat {
        ceil(string.size().width)
    }

    /// Draws one line with its line box's top at `y`, truncating at `maxWidth`. The role's paragraph style and
    /// baseline offset centre the glyphs in the line box, which is how labels centre on a control.
    static func draw(_ string: NSAttributedString, x: CGFloat, top y: CGFloat, maxWidth: CGFloat, lineHeight: CGFloat) {
        guard maxWidth > 0 else { return }
        string.draw(with: NSRect(x: x, y: y, width: maxWidth, height: lineHeight), options: QuireFont.drawingOptions, context: nil)
    }

    private static let baselines = LockedCache<String, CGFloat>()

    /// The baseline's distance from the top of `role`'s line box, measured once with TextKit, for marks that
    /// sit relative to the baseline (the link underline, `textStyle.linkUnderlineOffset`).
    static func baselineFromTop(_ role: QuireFont.Role) -> CGFloat {
        baselines.value(for: role.rawValue) {
            let storage = NSTextStorage(attributedString: QuireFont.attributedString("Hxg", role: role, color: .black))
            let manager = NSLayoutManager()
            QuireFont.configure(manager)
            let container = NSTextContainer(size: NSSize(width: 1_000, height: 1_000))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            let fragment = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            return fragment.minY + manager.location(forGlyphAt: 0).y
        }
    }

    // MARK: Values

    /// "#RRGGBBAA" (or "#RRGGBB") as 0xRRGGBBAA, for the few colours tokens.json writes as strings
    /// (`layout.toggle.knobShadow`).
    static func rgba(hex: String) -> UInt32 {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 6 { digits += "FF" }
        return UInt32(digits, radix: 16) ?? 0x000000FF
    }

    /// Spec numbers use the locale's grouping (§4.13: "3,412 of 8,120").
    static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
