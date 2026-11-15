import AppKit
import ObjectiveC

/// What AppKit gets from every view in a window when it resets the window's cursor rects (spec §4.17): each view's own
/// rects and AppKit's (a text view's I-beam, a split view's resize pointer), in window coordinates. App views are final,
/// so `addCursorRect(_:cursor:)` is recorded on `NSView` itself for the length of one reset.
@MainActor
struct CursorRectRecorder {
    struct Rect {
        let view: NSView
        /// In window coordinates.
        let rect: NSRect
        let cursor: NSCursor
    }

    let rects: [Rect]

    fileprivate static var recording: [Rect]?

    /// Has `window` reset its cursor rects, and records what every view adds.
    init(_ window: NSWindow) {
        window.layoutIfNeeded()
        let original = class_getInstanceMethod(NSView.self, #selector(NSView.addCursorRect(_:cursor:)))
        let spy = class_getInstanceMethod(NSView.self, #selector(NSView.recorderAddCursorRect(_:cursor:)))
        guard let original, let spy else {
            rects = []
            return
        }
        Self.recording = []
        method_exchangeImplementations(original, spy)
        window.resetCursorRects()
        method_exchangeImplementations(original, spy)
        rects = Self.recording ?? []
        Self.recording = nil
    }

    /// The pointers of the rects under `point` (window coordinates), one per rect.
    func cursors(at point: NSPoint) -> [NSCursor] {
        rects.filter { $0.rect.contains(point) }.map(\.cursor)
    }

    /// The pointers of the rects under the centre of `rect`, given in `view`'s coordinates.
    func cursors(atCentreOf rect: NSRect, in view: NSView) -> [NSCursor] {
        let local = NSPoint(x: rect.midX, y: rect.midY)
        return cursors(at: view.convert(local, to: nil))
    }

    /// The rects `view` added.
    func rects(of view: NSView) -> [Rect] {
        rects.filter { $0.view === view }
    }

    /// Every view of type `T` under `view`, to find the controls the views keep private.
    static func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, as: type) }
    }
}

extension NSView {
    /// Swapped with `addCursorRect(_:cursor:)` while a recorder resets a window; the call inside reaches AppKit's.
    @objc fileprivate func recorderAddCursorRect(_ rect: NSRect, cursor: NSCursor) {
        CursorRectRecorder.recording?.append(.init(view: self, rect: convert(rect, to: nil), cursor: cursor))
        recorderAddCursorRect(rect, cursor: cursor)
    }
}
