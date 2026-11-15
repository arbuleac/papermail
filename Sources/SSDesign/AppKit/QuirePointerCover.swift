import AppKit

/// A surface laid over other views that shows its own pointer over its whole frame (spec §4.17): the cheat sheet's
/// overlay over the window, a toast's slip over the list. AppKit gives overlapping cursor rects no order, so a row's hand
/// under a slip, or a button's under the cheat sheet's panel, would show through whenever the pointer crossed into it.
/// The targets under a cover leave its frame out of their rects instead (`addPointerRects()` does it), and a cover has
/// every view in its window asked again whenever it comes, goes, hides, shows or moves: call `pointerCoverDidChange()`
/// from `viewDidMoveToWindow()`, `viewDidHide()`, `viewDidUnhide()` and the frame setters.
@MainActor
public protocol QuirePointerCover: QuirePointerTarget {}

/// The covers there are, each with the window it was last in, so the one it leaves is asked again too.
@MainActor private let pointerCovers = NSMapTable<NSView, NSWindow>.weakToWeakObjects()

extension QuirePointerCover {
    /// Has every view in the cover's window, and in the window it was in before, ask for its cursor rects again.
    public func pointerCoverDidChange() {
        let previous = pointerCovers.object(forKey: self)
        pointerCovers.setObject(window, forKey: self)
        if let previous, previous !== window { previous.invalidateAllCursorRects() }
        window?.invalidateAllCursorRects()
    }
}

extension NSView {
    /// The frames of the visible covers drawn above this view in its window, and the dividers of the split views it lies
    /// in, in its coordinates: what its cursor rects leave out. A cover around this view, or inside it, is not above it.
    public func pointerCoverAreas() -> [NSRect] {
        guard let window else { return [] }
        var areas = splitDividerAreas()
        for case let cover as NSView in pointerCovers.keyEnumerator().allObjects {
            guard cover !== self, cover.window === window, !cover.isHiddenOrHasHiddenAncestor,
                  !isDescendant(of: cover), !cover.isDescendant(of: self), cover.isDrawn(above: self) else { continue }
            let area = convert(cover.bounds, from: cover)
            if !area.isEmpty { areas.append(area) }
        }
        return areas
    }

    /// The dividers of the split views this view lies in a pane of, as their delegates grow them to take the drag: the
    /// system's resize pointer there stays (§4.17), while a pane's rows or lines reach right up to the divider's hairline.
    /// A view laid over the panes (the cheat sheet over the window's split view) covers the dividers too.
    ///
    /// AppKit says nothing of the rect it proposes to the delegate. For a thin divider it is the drawn one grown by
    /// `thinDividerSlop` either side, as measured at 1×, 2× and 3×; rounded out to whole points, the area holds the rect
    /// AppKit adds, which it rounds too.
    private func splitDividerAreas() -> [NSRect] {
        var areas: [NSRect] = []
        var child: NSView = self
        while let view = child.superview {
            defer { child = view }
            guard let split = view as? NSSplitView else { continue }
            let panes = split.arrangedSubviews
            guard panes.contains(where: { $0 === child }) else { continue }
            for index in panes.indices.dropLast() {
                let before = panes[index], after = panes[index + 1]
                guard !before.isHidden, !after.isHidden else { continue }
                let drawn = split.isVertical
                    ? NSRect(x: before.frame.maxX, y: split.bounds.minY, width: after.frame.minX - before.frame.maxX, height: split.bounds.height)
                    : NSRect(x: split.bounds.minX, y: before.frame.maxY, width: split.bounds.width, height: after.frame.minY - before.frame.maxY)
                let slop = split.dividerStyle == .thin ? NSView.thinDividerSlop : 0
                let proposed = split.isVertical ? drawn.insetBy(dx: -slop, dy: 0) : drawn.insetBy(dx: 0, dy: -slop)
                let effective = split.delegate?.splitView?(split, effectiveRect: proposed, forDrawnRect: drawn, ofDividerAt: index) ?? proposed
                let area = convert(NSIntegralRect(effective), from: split)
                if !area.isEmpty { areas.append(area) }
            }
        }
        return areas
    }

    private static let thinDividerSlop: CGFloat = 2.5

    /// Whether a cover lies over all that is visible of this view. A text view's own I-beam is AppKit's and cannot be cut,
    /// only left out: one under the cheat sheet takes no typing, so it adds none.
    public var isUnderPointerCover: Bool {
        let visible = visibleRect
        return !visible.isEmpty && pointerCoverAreas().contains { $0.contains(visible) }
    }

    /// Whether this view is drawn above `other`: under their nearest common ancestor, this view's branch comes later.
    fileprivate func isDrawn(above other: NSView) -> Bool {
        var branches: [ObjectIdentifier: NSView] = [:]
        var view: NSView = self
        while let parent = view.superview {
            branches[ObjectIdentifier(parent)] = view
            view = parent
        }
        var theirs: NSView = other
        while let parent = theirs.superview {
            if let mine = branches[ObjectIdentifier(parent)] {
                let order = parent.subviews
                guard let mineIndex = order.firstIndex(where: { $0 === mine }),
                      let theirIndex = order.firstIndex(where: { $0 === theirs }) else { return false }
                return mineIndex > theirIndex
            }
            theirs = parent
        }
        return false
    }
}

extension NSWindow {
    /// Marks the cursor rects of every view in the window invalid; AppKit asks each for them again before the next
    /// event.
    fileprivate func invalidateAllCursorRects() {
        guard let root = contentView else { return }
        var stack = [root]
        while let view = stack.popLast() {
            invalidateCursorRects(for: view)
            stack.append(contentsOf: view.subviews)
        }
    }
}
