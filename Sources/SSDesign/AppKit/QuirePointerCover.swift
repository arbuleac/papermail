import AppKit

/// A surface laid over other views that shows its own pointer over its whole frame (spec §4.17): the cheat sheet's
/// overlay over the window, a toast's slip over the list, the composer's popovers. AppKit gives overlapping cursor rects
/// no order, so a row's hand under a slip, or a button's under the cheat sheet's panel, would show through whenever the
/// pointer crossed into it. The targets under a cover leave its frame out of their rects instead (`addPointerRects()`
/// does it, and a text view's `addTextPointerRects()`), and a cover has every view in its window asked again whenever it
/// comes, goes, hides, shows or moves: call `pointerCoverDidChange()` from `viewDidMoveToWindow()`, `viewDidHide()`,
/// `viewDidUnhide()` and the frame setters, there only when the frame did change, since a layout pass sets an unchanged
/// frame again.
@MainActor
public protocol QuirePointerCover: QuirePointerTarget {}

extension QuirePointerCover {
    /// Has every view in the cover's window, and in the window it was in before, ask for its cursor rects again.
    public func pointerCoverDidChange() {
        let previous = PointerCoverRegistry.covers.object(forKey: self)
        PointerCoverRegistry.covers.setObject(window, forKey: self)
        if let previous, previous !== window { PointerCoverRegistry.invalidate(previous) }
        if let window { PointerCoverRegistry.invalidate(window) }
    }
}

/// The covers there are, each with the window it was last in, so the one it leaves is asked again too, and the windows
/// whose views are to be asked again.
@MainActor
enum PointerCoverRegistry {
    static let covers = NSMapTable<NSView, NSWindow>.weakToWeakObjects()
    private static let pending = NSHashTable<NSWindow>.weakObjects()
    private static var isFlushScheduled = false

    /// Asking means walking the whole window, so it waits for the end of this turn of the run loop: a cover moved and
    /// resized in one layout pass, or in every step of a live resize, walks it once. AppKit asks the views it marks only
    /// before the next event, by which time every frame of the turn is set.
    static func invalidate(_ window: NSWindow) {
        pending.add(window)
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.async { MainActor.assumeIsolated { flush() } }
    }

    /// Marks the views of every pending window now. Tests call it in place of waiting for the turn to end.
    static func flush() {
        isFlushScheduled = false
        let windows = pending.allObjects
        pending.removeAllObjects()
        for window in windows { window.invalidateAllCursorRects() }
    }
}

extension NSView {
    /// The frames of the visible covers drawn above this view in its window, the dividers of the split views it lies in
    /// and the overlay scrollers showing over it, in its coordinates: what its cursor rects leave out. A cover around this
    /// view, or inside it, is not above it.
    public func pointerCoverAreas() -> [NSRect] {
        guard let window else { return [] }
        var areas = splitDividerAreas() + shownOverlayScrollerAreas()
        for case let cover as NSView in PointerCoverRegistry.covers.keyEnumerator().allObjects {
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

    /// The overlay scrollers of the scroll views this view lies in, while they show: a click there drags the knob, and
    /// AppKit adds no pointer for a scroller, so a row's hand or a page's I-beam would lie over it. At rest an overlay
    /// scroller is drawn as nothing and takes no clicks, which go to what is under it, so it is left out only while the
    /// scroll view's hit test gives it its own centre. AppKit tells nothing of its fading out: `OverlayScrollerWatch` asks
    /// the scroll view's views again once it no longer takes the click.
    private func shownOverlayScrollerAreas() -> [NSRect] {
        var areas: [NSRect] = []
        var ancestor = superview
        while let view = ancestor {
            defer { ancestor = view.superview }
            guard let scrollView = view as? NSScrollView, scrollView.scrollerStyle == .overlay, let host = scrollView.superview else {
                continue
            }
            for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller].compactMap({ $0 })
            where scroller.superview != nil && !scroller.isHiddenOrHasHiddenAncestor && !isDescendant(of: scroller) {
                guard OverlayScrollerWatch.takesClicks(scroller, in: scrollView, host: host) else { continue }
                areas.append(convert(scroller.bounds, from: scroller))
                OverlayScrollerWatch.watch(scroller, in: scrollView)
            }
        }
        return areas
    }

    /// Whether a cover lies over all of this view that shows: its bounds within its visible rect, which reaches past them
    /// now that views no longer clip to their bounds (a field's is the whole window). Only AppKit's own pointers, which
    /// cannot be cut, are left out on it (a split view's dividers); a text view cuts the covers out of its I-beam piece by
    /// piece instead (`addTextPointerRects()`).
    public var isUnderPointerCover: Bool {
        let visible = bounds.intersection(visibleRect)
        return !visible.isEmpty && pointerCoverAreas().contains { $0.contains(visible) }
    }

    /// The I-beam over `rect` (this view's bounds by default), cut to what is visible of the view and out of what lies on
    /// it: the covers drawn above it, the dividers and scrollers beside it (`pointerCoverAreas()`) and `holes`. A text
    /// view or field adds it in place of AppKit's own, which lies over its whole visible rect, which reaches past its
    /// bounds now that views no longer clip to them (§4.17): over a reader's page, a composer's quote, a popover. None
    /// while the view is hidden, since AppKit asks a hidden view too and keeps what it adds.
    public func addTextPointerRects(over rect: NSRect? = nil, cutting holes: [NSRect] = []) {
        guard !isHiddenOrHasHiddenAncestor else { return }
        let area = (rect ?? bounds).intersection(visibleRect)
        for piece in QuirePointerRegion.regions(area, cursor: .iBeam, cutting: holes + pointerCoverAreas()) {
            addCursorRect(piece.rect, cursor: piece.cursor)
        }
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

extension NSTextField {
    /// AppKit lays the field editor of a field being edited in a clip view whose document cursor is the arrow, over the
    /// field's text area: under the field's own I-beam, in no order with it, so the arrow could show over text that
    /// takes typing (§4.17). Call it once the field has become first responder: the clip then adds none, and the field's
    /// I-beam, cut out of what lies on it, and the editor's own over its text are all there is.
    public func leaveTheFieldEditorsPointerToTheField() {
        guard let clip = currentEditor()?.superview as? NSClipView, clip.documentCursor != nil else { return }
        clip.documentCursor = nil
    }
}

extension NSWindow {
    /// Marks the cursor rects of every view in the window invalid; AppKit asks each for them again before the next
    /// event.
    fileprivate func invalidateAllCursorRects() {
        guard let root = contentView else { return }
        invalidateCursorRects(inTreeOf: root)
    }

    /// Marks the cursor rects of `root` and every view inside it invalid.
    func invalidateCursorRects(inTreeOf root: NSView) {
        var stack = [root]
        while let view = stack.popLast() {
            invalidateCursorRects(for: view)
            stack.append(contentsOf: view.subviews)
        }
    }
}

/// The overlay scrollers left out of the pointer while they showed (`shownOverlayScrollerAreas()`), until they fade:
/// AppKit says nothing when one does, so while any is watched a timer asks each scroll view's hit test again, and once
/// its scroller no longer takes the click the views of its document are asked for their rects again, the scroller's
/// strip given back to the rows under it.
@MainActor
enum OverlayScrollerWatch {
    private static let watched = NSMapTable<NSScroller, NSScrollView>.weakToWeakObjects()
    private static var timer: Timer?
    static let interval: TimeInterval = 0.25

    static func takesClicks(_ scroller: NSScroller, in scrollView: NSScrollView, host: NSView) -> Bool {
        let centre = host.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), from: scroller)
        guard let hit = scrollView.hitTest(centre) else { return false }
        return hit === scroller || hit.isDescendant(of: scroller)
    }

    static func watch(_ scroller: NSScroller, in scrollView: NSScrollView) {
        watched.setObject(scrollView, forKey: scroller)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
    }

    static func poll() {
        for case let scroller as NSScroller in watched.keyEnumerator().allObjects {
            guard let scrollView = watched.object(forKey: scroller), let window = scrollView.window, let host = scrollView.superview else {
                watched.removeObject(forKey: scroller)
                continue
            }
            guard !takesClicks(scroller, in: scrollView, host: host) else { continue }
            watched.removeObject(forKey: scroller)
            window.invalidateCursorRects(inTreeOf: scrollView.contentView)
        }
        if watched.count == 0 {
            timer?.invalidate()
            timer = nil
        }
    }
}
