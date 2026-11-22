import AppKit
import PaperDesign

/// The top 52 pt of the column's and the week's headers is the title-bar zone (spec §3.2), as the reader header's is:
/// a drag there moves the window and a double click does what the system setting says, while the buttons in it take
/// their own clicks first. Below it nothing drags the window.
@MainActor
enum CalendarTitleBarZone {
    /// Handles a mouse-down on a header's own surface; false when it is below the zone and the view should go on.
    static func handle(_ event: NSEvent, in view: NSView) -> Bool {
        let point = view.convert(event.locationInWindow, from: nil)
        guard point.y < Quire.Layout.Window.titlebarZone, let window = view.window else { return false }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
            return true
        }
        window.performDrag(with: event)
        return true
    }
}
