import AppKit

/// The button a swipe uncovers on a list row (spec §5.7, Swipe): the table's own `NSTableViewRowAction`, so AppKit
/// tracks the swipe and lays out and draws the button, a capsule of the action's `backgroundColor` with its title on it.
///
/// AppKit draws that title in white and keeps no other colour: it sets its label back to white at every layout, and an
/// action's image takes a 16 pt glyph slot with the title moved under the capsule in the system's grey (macOS 26 and
/// later). So the title's colour is AppKit's, recorded as `onSwipe`, and each fill is chosen to hold it at 4.5:1 in
/// every theme and mode and under Graphite, which the contrast pairs assert.
public enum QuireSwipeAction: CaseIterable, Sendable {
    /// Archive, on the trailing edge: the theme's fill (`swipeArchive`; under Graphite and in Gallery
    /// `swipeArchiveNeutral`, the slip by day and a grey that stands out from the row at night).
    case archive
    /// Mark as Read or Mark as Unread, on the leading edge: the ramp's quiet grey (`swipeRead`).
    case readState

    /// The capsule's fill: the live token, never a colour resolved when the action is made. AppKit resolves it again
    /// only on an appearance change or when the button's views are marked for display, so a button already out follows
    /// a theme, Graphite or Increase Contrast change because the list marks it (spec §5.7).
    public var fill: NSColor {
        switch self {
        case .archive: return .qSwipeArchive
        case .readState: return .qSwipeRead
        }
    }

    /// The colour AppKit draws the title in, named so the pairs and the tests can hold the fills to it.
    public var titleColor: NSColor { .qOnSwipe }

    /// A row action in this style. Regular, never destructive: AppKit animates a destructive button's row as it goes,
    /// and the list never animates a row leaving (§4.10). No image, which would push the title out of the capsule.
    public func rowAction(title: String, handler: @escaping (NSTableViewRowAction, Int) -> Void) -> NSTableViewRowAction {
        let action = NSTableViewRowAction(style: .regular, title: title, handler: handler)
        action.backgroundColor = fill
        return action
    }
}
