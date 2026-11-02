import AppKit

/// The custom glyphs of spec §4.11, drawn from their SVG path data. Each is parsed once into a `CGPath` in
/// grid units and rendered into template images (cached per point size), so it tints like an SF Symbol.
public enum QuireGlyph {
    private struct ImageKey: Hashable {
        let glyph: Quire.CustomGlyph
        let pointSize: CGFloat
    }

    private static let paths = LockedCache<Quire.CustomGlyph, CGPath>()
    private static let images = LockedCache<ImageKey, NSImage>()

    /// The glyph's outline paths joined into one `CGPath`, in grid units with y down. The filled circles are
    /// not included (`Quire.CustomGlyph.fills`). Path data is generated from tokens.json and covered by
    /// GlyphPathTests, so a parse failure is a build defect, reported here rather than drawn half-way.
    public static func path(_ glyph: Quire.CustomGlyph) -> CGPath {
        paths.value(for: glyph) {
            let joined = CGMutablePath()
            for d in glyph.paths {
                do {
                    joined.addPath(try QuireSVGPath.parse(d))
                } catch {
                    assertionFailure("\(glyph.rawValue): \(error)")
                }
            }
            return joined.copy() ?? joined
        }
    }

    /// A template image of `pointSize` × `pointSize` points, cached per size. Drawn by a handler, so it is
    /// sharp at every backing scale.
    public static func image(_ glyph: Quire.CustomGlyph, pointSize: CGFloat) -> NSImage {
        images.value(for: ImageKey(glyph: glyph, pointSize: pointSize)) {
            let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                draw(glyph, in: rect, context: context, color: NSColor.black.cgColor)
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = glyph.meaning
            return image
        }
    }

    /// Draws the glyph scaled to `rect` (a square) in `color`. `rect` is in a y-down space, as SVG is; flipped
    /// views and flipped images are. Strokes scale with the glyph: grid units × point size / grid.
    public static func draw(_ glyph: Quire.CustomGlyph, in rect: CGRect, context: CGContext, color: CGColor) {
        let scale = min(rect.width, rect.height) / glyph.grid
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(color)
        context.setStrokeColor(color)
        if glyph.stroke > 0 {
            context.setLineWidth(glyph.stroke)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path(glyph))
            context.strokePath()
        } else {
            context.addPath(path(glyph))
            context.fillPath(using: glyph.fillRule)
        }
        for circle in glyph.fills {
            context.fillEllipse(in: circle.rect)
        }
        context.restoreGState()
    }

    /// Everything the glyph inks, in grid units: the paths' geometry, half the stroke around it, and the
    /// filled circles. GlyphPathTests holds it inside the grid.
    public static func inkBounds(_ glyph: Quire.CustomGlyph) -> CGRect {
        let p = path(glyph)
        var bounds = glyph.stroke > 0
            ? p.copy(strokingWithWidth: glyph.stroke, lineCap: .round, lineJoin: .round, miterLimit: 10).boundingBoxOfPath
            : p.boundingBoxOfPath
        for circle in glyph.fills { bounds = bounds.union(circle.rect) }
        return bounds
    }
}
