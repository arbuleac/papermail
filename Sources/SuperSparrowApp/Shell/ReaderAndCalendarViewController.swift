import AppKit
import SSCore
import SSDesign

/// The main window's third split item (spec §5.1, §5.54): the reader with the day column at its trailing edge, the column
/// folded to its 28 pt strip while the reader would fall under 400 pt beside it, or the week in the place of both.
///
/// The split keeps its three items, so its autosave, its dividers and the list's resizing are what they were: the column
/// has one width and no divider to drag. The week hides the reader rather than taking it out of the window, so the pool's
/// web views and their pre-renders stay attached and the reader keeps following the selection underneath. Everything is
/// placed by hand in one frame, as the rail hides: the column never animates, on a toggle or in a live resize.
@MainActor
final class ReaderAndCalendarViewController: NSViewController {
    typealias Pane = Quire.Layout.CalendarPane

    /// What the trailing side of the window shows.
    enum Placement: Equatable {
        /// The column is hidden (D); the reader takes its width.
        case none
        /// The column in full beside the reader.
        case column
        /// The column folded to its strip: the window is too narrow for it beside a 400 pt reader.
        case strip
        /// The week, in the reader's place and the column's.
        case week
    }

    let conversationPane: ConversationPaneViewController
    let column: DayColumnView
    let strip: DayStripView
    let week: WeekView
    /// Over the reader while the column is open over its edge: a click there closes the column and does nothing else.
    let readerCover = CalendarOverlayCover()

    /// D's choice, kept in the app's settings: the column at the reader's edge, in full or as its strip.
    private(set) var isColumnOn: Bool
    private(set) var isWeekShown = false
    /// The column opened over the reader's edge from its strip (only while folded).
    private(set) var isOverlayOpen = false
    private(set) var placement: Placement = .none

    /// After what shows changed: the reader header's Day button, the menus and the calendar's span follow it.
    var onPlacementChange: (() -> Void)?
    /// A click in the reader while the column is open over it: the window closes the column (and takes focus that was
    /// in it back to the list). Without one the column only closes.
    var onCoverClick: (() -> Void)?

    init(conversationPane: ConversationPaneViewController, state: CalendarState, isColumnOn: Bool) {
        self.conversationPane = conversationPane
        self.isColumnOn = isColumnOn
        column = DayColumnView(state: state)
        strip = DayStripView(state: state)
        week = WeekView(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = ReaderAndCalendarView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // As the reader pane's root was: the split controller sizes its items through constraints.
        root.translatesAutoresizingMaskIntoConstraints = false
        root.onLayout = { [weak self] in self?.place() }
        addChild(conversationPane)
        let reader = conversationPane.view
        // Placed by hand beside the column; its own minimum stays, and the frame never goes under it.
        reader.translatesAutoresizingMaskIntoConstraints = true
        reader.autoresizingMask = []
        readerCover.onClick = { [weak self] in
            guard let self else { return }
            if let onCoverClick = self.onCoverClick { onCoverClick() } else { self.setOverlayOpen(false) }
        }
        // Back to front: the reader, the cover over it, the column (over the reader's edge when opened from the strip),
        // its strip, and the week, which takes the place of all of them.
        for subview in [reader, readerCover, column, strip, week] as [NSView] {
            subview.isHidden = true
            root.addSubview(subview)
        }
        reader.isHidden = false
        view = root
        place()
    }

    // MARK: Changes

    /// D's setting changed: the column at the reader's edge, or not.
    func setColumnOn(_ on: Bool) {
        guard on != isColumnOn else { return }
        isColumnOn = on
        if !on { isOverlayOpen = false }
        place()
    }

    func setWeekShown(_ shown: Bool) {
        guard shown != isWeekShown else { return }
        isWeekShown = shown
        isOverlayOpen = false
        place()
    }

    /// Opens or closes the column over the reader's edge; only the strip opens it.
    func setOverlayOpen(_ open: Bool) {
        let open = open && placement == .strip
        guard open != isOverlayOpen else { return }
        isOverlayOpen = open
        place()
    }

    /// The day column shows: in full, or opened over the reader's edge. Not its strip alone, and not the week.
    var isDayShowing: Bool { placement == .column || (placement == .strip && isOverlayOpen) }

    /// The column or the week shows, so [ ] and T have something to turn.
    var isCalendarShowing: Bool { isDayShowing || placement == .week }

    // MARK: Layout

    /// Places the reader, the column, the strip and the week for the width the split gave: the column folds to its strip
    /// while the reader would keep less than 400 pt beside it (`calendarPane.readerMinWithColumn`), and comes back in
    /// place once the window is wide enough again, closing the column opened over the reader.
    private func place() {
        guard isViewLoaded else { return }
        let bounds = view.bounds
        let width = bounds.width
        let folds = width < Pane.columnWidth + Pane.readerMinWithColumn
        let next: Placement = isWeekShown ? .week : !isColumnOn ? .none : folds ? .strip : .column
        if next != .strip { isOverlayOpen = false }

        let readerWidth: CGFloat
        switch next {
        case .none, .week: readerWidth = width
        case .column: readerWidth = width - Pane.columnWidth
        case .strip: readerWidth = width - Pane.stripWidth
        }
        let reader = conversationPane.view
        // Never under the reader's own minimum, which its constraints hold: a split not laid out yet is narrower.
        reader.frame = NSRect(x: 0, y: 0, width: max(readerWidth, Quire.Layout.Window.readerMinWidth), height: bounds.height)
        reader.isHidden = next == .week

        let overlay = next == .strip && isOverlayOpen
        column.isOverlay = next == .strip
        let columnX = next == .strip ? width - Pane.stripWidth - Pane.columnWidth : width - Pane.columnWidth
        column.frame = NSRect(x: columnX, y: 0, width: Pane.columnWidth, height: bounds.height)
        column.isHidden = !(next == .column || overlay)
        strip.frame = NSRect(x: width - Pane.stripWidth, y: 0, width: Pane.stripWidth, height: bounds.height)
        strip.isHidden = next != .strip
        strip.isOpen = overlay
        readerCover.frame = NSRect(x: 0, y: 0, width: max(0, columnX), height: bounds.height)
        readerCover.isHidden = !overlay
        week.frame = bounds
        week.isHidden = next != .week

        let changed = next != placement || overlay != wasOverlay
        placement = next
        wasOverlay = overlay
        if changed { onPlacementChange?() }
    }

    private var wasOverlay = false
}

/// The container's root: it lays its panes out by hand whenever the split resizes it.
@MainActor
private final class ReaderAndCalendarView: NSView {
    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        // In one frame, the column folding or unfolding with the reader's width (§5.1, Live resize).
        if changed { onLayout?() }
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Covers the reader while the column is open over its edge (spec §5.54): a click in the reader closes the column and
/// does nothing else there, so it never selects text or presses a button the column had hidden.
@MainActor
final class CalendarOverlayCover: NSView {
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Only a click is taken: the page under it keeps its scrolling and its pointer.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let type = NSApp.currentEvent?.type, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func otherMouseDown(with event: NSEvent) { onClick?() }

    override func isAccessibilityElement() -> Bool { false }
}
