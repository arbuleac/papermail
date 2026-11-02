import AppKit
import SSDesign

/// The top 52 pt of a pane (spec §3.2): it drags the window and answers a double-click with the system's
/// title-bar action, while the controls placed in it opt out (they are `NSControl`s, which never move the
/// window). Views below the zone return `mouseDownCanMoveWindow = false` themselves, because from macOS 26 the
/// toolbar's container reaches 66 pt and a click in header row 2 must never drag.
///
/// AppKit normally runs the drag and the double-click itself for a view that can move the window; the
/// `mouseDown` fallback covers a release that delivers the event to the view instead.
@MainActor
class TitleBarZoneView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            QuireWindowChrome.performTitlebarDoubleClick(in: window)
        } else if event.clickCount == 1 {
            window?.performDrag(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { false }
}

/// A plain container below the title-bar zone: clicks on its empty parts never drag the window.
@MainActor
class NonDraggingView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
