import AppKit

/// A view that shows the pointer its clicks call for (spec §4.17): the pointing hand over what a click acts on, the
/// I-beam over a field that takes typing, the arrow over a control that is disabled or would do nothing, and over a
/// surface that lies on something clickable (the find bar on the reader, a toast on the list).
///
/// Every `QuireControl` is one. Any other view that acts on a click adopts it: it lists its `pointerRegions`, overrides
/// `resetCursorRects()` to call `addPointerRects()`, and calls `pointerRegionsDidChange()` whenever something the
/// regions read changes. AppKit asks again by itself when the view's frame changes or it moves to another window, but
/// not when it is hidden or shown, so a target that hides calls it from `viewDidHide()` and `viewDidUnhide()` too.
///
///     final class RetryLink: NSControl, QuirePointerTarget {
///         var pointerRegions: [QuirePointerRegion] { [.control(bounds, acts: isEnabled)] }
///         override func resetCursorRects() { addPointerRects() }
///     }
///
/// A control AppKit makes (an alert's buttons) cannot adopt it; `QuirePointerOverlay` gives it the hand instead.
@MainActor
public protocol QuirePointerTarget: NSView {
    /// The regions to show now, in this view's coordinates. Empty adds none: the view then shows whatever is behind it,
    /// the arrow over a plain window.
    var pointerRegions: [QuirePointerRegion] { get }
}

extension QuirePointerTarget {
    /// Adds `pointerRegions` as cursor rects, cut to what is visible of the view. Call it from `resetCursorRects()`.
    public func addPointerRects() {
        // AppKit asks a hidden view too, and keeps what it adds.
        guard !isHiddenOrHasHiddenAncestor else { return }
        let visible = visibleRect
        for region in pointerRegions {
            let rect = region.rect.intersection(visible)
            if !rect.isEmpty { addCursorRect(rect, cursor: region.cursor) }
        }
    }

    /// Has AppKit ask for `pointerRegions` again, and for those of the nearest target around this view, which cuts this
    /// view's area out of its own.
    public func pointerRegionsDidChange() {
        guard let window else { return }
        window.invalidateCursorRects(for: self)
        var ancestor = superview
        while let view = ancestor {
            if view is QuirePointerTarget {
                window.invalidateCursorRects(for: view)
                return
            }
            ancestor = view.superview
        }
    }

    /// The areas of the visible targets inside this view, in its coordinates: a Quire control's hit rect, another
    /// target's bounds. A view cuts them out of its own regions, so that one region alone lies under any point.
    public func childPointerAreas() -> [NSRect] {
        var areas: [NSRect] = []
        func collect(_ view: NSView) {
            for child in view.subviews where !child.isHidden {
                if let control = child as? QuireControl {
                    areas.append(convert(control.hitRect, from: control))
                } else if child is QuirePointerTarget {
                    areas.append(convert(child.bounds, from: child))
                } else {
                    collect(child)
                }
            }
        }
        collect(self)
        return areas
    }
}
