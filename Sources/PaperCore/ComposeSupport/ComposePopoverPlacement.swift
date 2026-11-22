import CoreGraphics

/// Where the composer's two app-drawn popovers go (spec §5.20 link popover, §5.21 autocomplete). All rects
/// are in the composer content view's flipped coordinates (y grows downward); `bounds` is that view's bounds.
public enum ComposePopoverPlacement {
    /// The link popover: its top `offsetY` below the selection's last line, or its bottom `offsetY` above the
    /// first line when there is no room below; its leading edge at the selection's start minus `pad`, so the
    /// Link field starts under the selected text; kept `edgeMin` inside the window.
    public static func linkPopover(firstLine: CGRect, lastLine: CGRect, selectionStartX: CGFloat, size: CGSize,
                                   bounds: CGRect, pad: CGFloat, offsetY: CGFloat, edgeMin: CGFloat) -> CGRect {
        var y = lastLine.maxY + offsetY
        if y + size.height > bounds.maxY - edgeMin {
            y = firstLine.minY - offsetY - size.height
        }
        return clamp(CGRect(x: selectionStartX - pad, y: y, width: size.width, height: size.height), in: bounds, edgeMin: edgeMin)
    }

    /// Autocomplete: anchored to the start of the text being completed, its leading edge `offsetX` from there
    /// (−46, so suggested names line up with the typed letters), its top `offsetY` below the token line that
    /// holds the caret; above that line when there is no room below; kept `edgeMin` inside the window.
    public static func autocomplete(tokenStartX: CGFloat, caretLine: CGRect, size: CGSize, bounds: CGRect,
                                    offsetX: CGFloat, offsetY: CGFloat, edgeMin: CGFloat) -> CGRect {
        var y = caretLine.maxY + offsetY
        if y + size.height > bounds.maxY - edgeMin {
            y = caretLine.minY - offsetY - size.height
        }
        return clamp(CGRect(x: tokenStartX + offsetX, y: y, width: size.width, height: size.height), in: bounds, edgeMin: edgeMin)
    }

    static func clamp(_ rect: CGRect, in bounds: CGRect, edgeMin: CGFloat) -> CGRect {
        var r = rect
        r.origin.x = min(max(r.minX, bounds.minX + edgeMin), max(bounds.minX + edgeMin, bounds.maxX - edgeMin - r.width))
        r.origin.y = min(max(r.minY, bounds.minY + edgeMin), max(bounds.minY + edgeMin, bounds.maxY - edgeMin - r.height))
        return r
    }
}
