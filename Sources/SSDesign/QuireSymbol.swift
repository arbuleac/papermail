import AppKit

/// Symbol images at Quire's sizes (spec §4.11). Takes any name from `Quire.Icon`: SF Symbols come from the
/// system, `ss.` names are the custom glyphs, so call sites never care which kind an action uses.
public enum QuireSymbol {
    /// A template image for `name` at `size`, or nil when the system has no such symbol.
    public static func image(_ name: String, size: QuireSymbolSize = .inText, accessibilityDescription: String? = nil) -> NSImage? {
        if let glyph = Quire.CustomGlyph(rawValue: name) {
            // Custom glyphs scale with point size; their stroke is part of the design, so weight does not apply.
            let image = QuireGlyph.image(glyph, pointSize: size.pointSize)
            guard let accessibilityDescription else { return image }
            let copy = image.copy() as? NSImage ?? image
            copy.accessibilityDescription = accessibilityDescription
            return copy
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: size.pointSize, weight: size.weight)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    /// The template image for `name` at `size` from the shared cache: what components draw with. Building a
    /// configured symbol image costs tens of microseconds, too much for every row's `draw(_:)`.
    public static func cachedImage(_ name: String, size: QuireSymbolSize = .inText) -> NSImage? {
        QuireDraw.symbolImage(name, size: size)
    }

    /// Draws `name` in `color` (resolved now, in the current drawing appearance), centred on `rect` at its
    /// natural size on whole points, from the shared cache. Returns the rect it drew in.
    @discardableResult
    public static func draw(_ name: String, size: QuireSymbolSize = .inText, color: NSColor, centredIn rect: NSRect) -> NSRect {
        QuireDraw.symbol(name, size: size, color: color, centredIn: rect)
    }

    /// True when `name` is one Quire can draw: an SF Symbol the system has, or a custom glyph.
    public static func exists(_ name: String) -> Bool {
        Quire.CustomGlyph(rawValue: name) != nil || NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}
