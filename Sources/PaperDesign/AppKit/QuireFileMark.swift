import AppKit
import CoreText

/// The file mark (spec §5.57): a sheet of paper with its top trailing corner folded down and, across its lower part, a
/// band in the family's file ink carrying the type in capitals (“PDF”). Scanned by colour, confirmed by the word.
///
/// Drawn in code from `layout.fileMark`, at any size (the design grid scaled to the side of the square it is given) and
/// in the current drawing appearance, so it is crisp at every scale and follows Light, Dark, Increase Contrast and the
/// themes: the sheet is `raised` with a `ruleStrong` edge, the fold's face `raised` under `fill`, the band its family's
/// `Quire.FileInk` (fixed across themes) and the label `qFileLabel`. The reader draws the same paths, numbers and font
/// (inline SVG from `QuireCSS.fileMarkScript`), so both match at 2x.
///
/// An empty label draws the plain sheet with no band: a file whose type is unknown.
public struct QuireFileMark: Hashable, Sendable {
    public var ink: Quire.FileInk
    public var label: String

    public init(ink: Quire.FileInk, label: String) {
        self.ink = ink
        self.label = String(label.prefix(Int(Quire.Layout.FileMark.labelMax)))
    }

    private typealias M = Quire.Layout.FileMark

    /// The band, in grid units: between the sheet's edges, from `bandTop`.
    public static var bandRect: CGRect {
        CGRect(x: M.sheetX + M.edge, y: M.bandTop, width: M.sheetWidth - 2 * M.edge, height: M.bandHeight)
    }

    /// The widest a label may be drawn before it is squeezed to fit, in grid units.
    public static var labelRoom: CGFloat { bandRect.width - 2 * M.labelPad }

    /// Draws the mark filling the square `rect` (its side is the size the grid is drawn at) in the current context.
    public func draw(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, rect.width > 0 else { return }
        let paths = Self.paths
        let scale = rect.width / M.grid
        context.saveGState()
        defer { context.restoreGState() }
        // The paths are y down, as SVG writes them.
        if NSGraphicsContext.current?.isFlipped == true {
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: scale, y: scale)
        } else {
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: scale, y: -scale)
        }
        NSColor.qRaised.setFill()
        context.addPath(paths.sheet)
        context.fillPath()
        NSColor.qFill.setFill()
        context.addPath(paths.fold)
        context.fillPath()
        NSColor.qRuleStrong.setStroke()
        context.setLineWidth(M.edge)
        context.setLineJoin(.round)
        context.addPath(paths.sheet)
        context.addPath(paths.crease)
        context.strokePath()
        guard !label.isEmpty else { return }
        ink.color.setFill()
        context.fill(Self.bandRect)
        drawLabel(in: context)
    }

    /// The label on its baseline, centred on the sheet, squeezed only when it is wider than the band's room.
    private func drawLabel(in context: CGContext) {
        let line = Self.line(label)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let squeeze = width > Self.labelRoom ? Self.labelRoom / width : 1
        NSColor.qFileLabel.setFill()
        context.saveGState()
        // Plain grayscale antialiasing, no stem darkening: the reader's `-webkit-font-smoothing: antialiased`, so the label
        // has one weight in both renderers.
        context.setShouldSmoothFonts(false)
        context.translateBy(x: M.sheetX + M.sheetWidth / 2 - width * squeeze / 2, y: M.labelBaseline)
        context.scaleBy(x: squeeze, y: 1)
        // The context is y down here; text draws y up.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The label's natural width in grid units, before any squeeze.
    public static func labelWidth(_ label: String) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(label), nil, nil, nil))
    }

    // MARK: Shared resources

    private struct Paths: @unchecked Sendable {
        let sheet: CGPath
        let fold: CGPath
        let crease: CGPath
    }

    /// The outline, the fold's face and the creases, parsed once from the tokens' own path data.
    private static let paths: Paths = {
        func parse(_ data: String) -> CGPath {
            do { return try QuireSVGPath.parse(data) } catch { preconditionFailure("layout.fileMark path: \(error)") }
        }
        return Paths(sheet: parse(M.sheetPath), fold: parse(M.foldPath), crease: parse(M.foldEdgePath))
    }()

    /// SF Pro at the label's size, weight and width, set on the variable font's own axes (`wght`, `wdth`), which is what
    /// WebKit sets for `font-weight` and `font-stretch`: the two renderers draw the same glyphs at the same advances.
    static let labelFont: CTFont = {
        let base = NSFont.systemFont(ofSize: M.labelSize, weight: .bold) as CTFont
        let weight = 0x7767_6874 // 'wght'
        let width = 0x7764_7468 // 'wdth'
        let variation: [Int: Double] = [weight: Double(M.labelWeight), width: Double(M.labelWidth)]
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: variation] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, M.labelSize, nil, descriptor)
    }()

    private static let lines = LockedCache<String, CTLine>()

    private static func line(_ label: String) -> CTLine {
        lines.value(for: label) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
        }
    }
}
