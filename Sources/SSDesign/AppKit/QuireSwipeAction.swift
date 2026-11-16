import AppKit

/// What a swipe uncovers behind a list row (spec §5.7, Swipe), drawn by `QuireSwipeButton`: Archive on the trailing
/// edge, Mark as Read or Mark as Unread on the leading one. Each wears its own fill, a live token, under its symbol (the
/// menus' own) and its label, both white (`onSwipe`); every fill is chosen to hold white at 4.5:1 in every theme and mode
/// and under Graphite, which the contrast pairs assert.
public enum QuireSwipeAction: CaseIterable, Sendable {
    /// Archive, on the trailing edge: the theme's fill (`swipeArchive`; under Graphite and in Gallery
    /// `swipeArchiveNeutral`, the slip by day and a grey that stands out from the row at night).
    case archive
    /// Mark as Read, on the leading edge of a row with unread mail: the ramp's quiet grey (`swipeRead`).
    case markRead
    /// Mark as Unread, on the leading edge of a read row: the same quiet grey.
    case markUnread

    /// The button's fill: the live token, resolved when the button draws, so a button that is out follows a theme,
    /// appearance, Graphite or Increase Contrast change at its next redraw.
    public var fill: NSColor {
        switch self {
        case .archive: return .qSwipeArchive
        case .markRead, .markUnread: return .qSwipeRead
        }
    }

    /// The icon's and the label's colour: white, on every fill.
    public var contentColor: NSColor { .qOnSwipe }

    /// The icon: the one the Message menu and the toast show for the same change (`Quire.Icon`).
    public var symbolName: String {
        switch self {
        case .archive: return Quire.Icon.archive
        case .markRead: return Quire.Icon.markRead
        case .markUnread: return Quire.Icon.markUnread
        }
    }
}
