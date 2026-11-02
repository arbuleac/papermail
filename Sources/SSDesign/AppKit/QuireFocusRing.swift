import AppKit

/// The Quire focus ring (spec §4.1, `border.focusRing`), shared by every control.
///
/// Controls draw it themselves, in `draw(_:)`, with `focusRingType = .none`: the system ring's alpha falls
/// below 3:1 on `paper` and `canvas`. It is a 2 pt ring (3 pt in Increase Contrast) outside the control,
/// separated from it by a gap in the surface colour (1 pt; 2 pt around sheets and around anything filled with
/// `accentFill`), following the control's corner radius plus the gap. It is never animated.
public enum QuireFocusRing {
    /// The gap around ordinary controls.
    public static let gap: CGFloat = Quire.Border.FocusRing.gap
    /// The gap around controls filled with `accentFill` or `dangerFill`, so the ring never touches a fill of
    /// the same hue.
    public static let gapOnFill: CGFloat = Quire.Border.FocusRing.gapOnAccentFill
    /// The gap around sheets and cards.
    public static let gapAroundSheet: CGFloat = Quire.Border.FocusRing.gapAroundSheets

    /// Room a control leaves between its visual rect and its frame so the widest ring (the 2 pt gap plus the
    /// 3 pt Increase Contrast ring) is drawn inside the frame, where AppKit never clips it. Quire controls
    /// report it as `alignmentRectInsets`, so Auto Layout aligns the visual rect and the intrinsic size is the
    /// token size.
    public static let margin: CGFloat = max(gapOnFill, gapAroundSheet) + Quire.Border.FocusRing.widthHC

    /// The ring width: 2 pt, or 3 pt in Increase Contrast.
    public static func width(increasedContrast: Bool) -> CGFloat {
        increasedContrast ? Quire.Border.FocusRing.widthHC : Quire.Border.FocusRing.width
    }

    /// The ring width for the current drawing appearance (call inside `draw(_:)`).
    public static var currentWidth: CGFloat {
        width(increasedContrast: QuireMode(NSAppearance.currentDrawing()).isIncreasedContrast)
    }

    /// How far the ring's outer edge lies outside the control.
    public static func outset(gap: CGFloat, width: CGFloat) -> CGFloat { gap + width }

    /// The ring's centre line around a control of `rect` and `cornerRadius`: the rect grown by the gap and half
    /// the width, the radius grown by the same amount, so the ring keeps an even distance all round. A radius
    /// of half the height (a pill or a circle) stays a pill or a circle.
    public static func path(around rect: CGRect, cornerRadius: CGFloat, gap: CGFloat, width: CGFloat) -> CGPath {
        let grow = gap + width / 2
        let ringRect = rect.insetBy(dx: -grow, dy: -grow)
        let radius = min(max(0, cornerRadius) + grow, ringRect.width / 2, ringRect.height / 2)
        return CGPath(roundedRect: ringRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Draws the ring around a control in the current graphics context, resolving the colour and the Increase
    /// Contrast width at draw time. `gapColor`, when given, paints the gap, for controls that sit over
    /// something other than their surface (a badge over a tile); otherwise the surface shows through.
    public static func draw(around rect: NSRect, cornerRadius: CGFloat, gap: CGFloat = gap,
                            color: NSColor = .qFocus, gapColor: NSColor? = nil) {
        let width = currentWidth
        if let gapColor, gap > 0 {
            // A ring exactly as wide as the gap, its centre line half a gap outside the control.
            let gapRing = NSBezierPath(cgPath: path(around: rect, cornerRadius: cornerRadius, gap: 0, width: gap))
            gapRing.lineWidth = gap
            gapColor.setStroke()
            gapRing.stroke()
        }
        let ring = NSBezierPath(cgPath: path(around: rect, cornerRadius: cornerRadius, gap: gap, width: width))
        ring.lineWidth = width
        color.setStroke()
        ring.stroke()
    }

    /// Draws the ring inside `rect`, its outer edge on `rect`: for borderless rows that have no edge to draw
    /// outside (the composer's field rows, a list with no selection under Full Keyboard Access, §4.1).
    public static func drawInset(in rect: NSRect, cornerRadius: CGFloat, color: NSColor = .qFocus) {
        let width = currentWidth
        let inner = rect.insetBy(dx: width / 2, dy: width / 2)
        let radius = min(max(0, cornerRadius - width / 2), inner.width / 2, inner.height / 2)
        let ring = NSBezierPath(roundedRect: inner, xRadius: radius, yRadius: radius)
        ring.lineWidth = width
        color.setStroke()
        ring.stroke()
    }
}
