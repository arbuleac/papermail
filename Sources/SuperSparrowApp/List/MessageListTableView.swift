import AppKit
import SSDesign

/// The list's table: Return opens, the pointer's hover wash, the pointer itself, and the swipe on its rows.
///
/// Return and keypad Enter open the selected conversation in a window of its own (spec §5.49) when no window's router has
/// taken them first. Every other key falls through the responder chain
/// so the window controller can map j/k and friends; type-select is off so letters are not swallowed here.
///
/// Hover is tracked by one tracking area on the table, not one per row, and it is suspended while the list
/// scrolls (spec §5.7, §8.2): rows that slide under a still pointer draw no wash, and when scrolling ends the
/// row under the pointer, if any, takes the wash once. That keeps a scroll from redrawing rows for hover and
/// from asking the avatar cache for anything a plain scroll would not.
///
/// The pointer (spec §4.17) is the table's too, not each row view's: row views are recycled and their rects would be
/// cut to whatever was visible when AppKit last asked, so the table lists one region per visible row and has AppKit ask
/// again whenever rows scroll, come or go.
///
/// A two-finger sideways swipe on a conversation row is the list's own (spec §5.7, Swipe): every scroll event goes to the
/// list's `RowSwipeController` first, which keeps a swipe's events and hands every other scroll back to the table, so
/// scrolling up and down, a mouse's wheel and the hover's pause work as they always have.
final class MessageListTableView: NSTableView, QuirePointerTarget {
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    /// A wheel scroll has no end notification; this long without a scroll event counts as its end.
    private static let wheelScrollSettle: TimeInterval = 0.15

    var onReturn: (() -> Void)?
    /// Asked whether a row takes the hover wash (conversation rows do; heads and the footer do not).
    var isHoverableRow: ((Int) -> Bool)?
    /// The context menu for a right-click (or control-click) on `row`; nil for rows that have none.
    var menuForRow: ((Int) -> NSMenu?)?
    /// The swipe on the rows; nil leaves every scroll to the table.
    weak var swipe: RowSwipeController?

    private(set) var hoveredRow = -1
    private(set) var isHoverSuspended = false
    private var hoverArea: NSTrackingArea?
    private var wheelSettleTimer: Timer?
    private var isLiveScrolling = false

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isOpenKey = event.keyCode == MessageListTableView.returnKeyCode
            || event.keyCode == MessageListTableView.keypadEnterKeyCode
        if isOpenKey, modifiers.isEmpty, let onReturn {
            onReturn()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Swipe

    override func scrollWheel(with event: NSEvent) {
        guard let swipe else { return super.scrollWheel(with: event) }
        swipe.scrollWheel(event) { super.scrollWheel(with: $0) }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0, let menuForRow else { return nil }
        return menuForRow(index)
    }

    // MARK: Hit testing

    /// NSTableView hit-tests only into the cell views of its columns and answers itself everywhere else, so a
    /// control a row view owns directly (the list tail's Retry link, spec §5.10) would never see a click: the
    /// table would take it as a click on an unselectable row. Such a control gets the click it is under, and so does
    /// a swipe's open button, which lies over its row's cell.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let button = swipe?.buttonHit(point) { return button }
        let hit = super.hitTest(point)
        guard hit === self else { return hit }
        let local = convert(point, from: superview)
        let index = row(at: local)
        guard index >= 0, let rowView = rowView(atRow: index, makeIfNecessary: false),
              let control = rowView.hitTest(local) as? NSControl else { return hit }
        return control
    }

    // MARK: Pointer

    /// The hand over each visible conversation row, selected or not, swiped open or not: a click, ⌘-click, double-click
    /// or drag acts on it. The arrow over heads, the tail and the server row, which a click leaves as they
    /// are, with the links they hold (Retry, Search Gmail) left to their own hand. The empty space below the rows adds
    /// none.
    var pointerRegions: [QuirePointerRegion] {
        let visible = rows(in: visibleRect)
        guard visible.length > 0 else { return [] }
        let holes = childPointerAreas()
        var regions: [QuirePointerRegion] = []
        for row in visible.location..<(visible.location + visible.length) {
            let acts = isHoverableRow?(row) ?? true
            regions += QuirePointerRegion.regions(rect(ofRow: row), cursor: acts ? .pointingHand : .arrow, cutting: holes)
        }
        return regions
    }

    override func resetCursorRects() {
        addPointerRects()
    }

    /// Rows were reloaded, and a row may now be another kind: AppKit asks again. Edits and scrolls add and remove row
    /// views (`didAdd`, `didRemove`), and `refreshHoverAfterRowEdits()` and `boundsDidScroll()` ask too.
    override func reloadData() {
        super.reloadData()
        pointerRegionsDidChange()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !isHoverSuspended else { return }
        setHoveredRow(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHoverSuspended else { return }
        setHoveredRow(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredRow(-1)
    }

    /// Moves the wash to `row`. Rows that are not hoverable clear it; a selected row keeps `isHovered` so the
    /// wash comes back if it is deselected under the pointer, but draws none while selected.
    func setHoveredRow(_ row: Int) {
        let target = (row >= 0 && row < numberOfRows && isHoverableRow?(row) != false) ? row : -1
        guard target != hoveredRow else { return }
        if hoveredRow >= 0, hoveredRow < numberOfRows, let old = rowView(atRow: hoveredRow, makeIfNecessary: false) as? ConversationRowView {
            old.isHovered = false
        }
        hoveredRow = target
        if target >= 0, let new = rowView(atRow: target, makeIfNecessary: false) as? ConversationRowView {
            new.isHovered = true
        }
    }

    /// The row under the pointer right now, from the window's mouse location (no event needed).
    private func rowUnderPointer() -> Int {
        guard let window, window.isVisible else { return -1 }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point) else { return -1 }
        return row(at: point)
    }

    /// Rows were inserted, removed or moved: the hovered index may now name another row, so the wash goes to
    /// whatever is under the pointer now.
    func refreshHoverAfterRowEdits() {
        pointerRegionsDidChange()
        guard !isHoverSuspended else { return }
        setHoveredRow(-1)
        setHoveredRow(rowUnderPointer())
    }

    /// Live scroll began (a trackpad gesture, momentum included): stop following the pointer.
    func beginScrollHoverSuspension() {
        isLiveScrolling = true
        suspendHover()
    }

    /// Live scroll ended: the row under the pointer, if any, takes the wash once.
    func endScrollHoverSuspension() {
        isLiveScrolling = false
        resumeHover()
    }

    /// Any scroll, wheel or programmatic: rows moved under the pointer, so the wash goes until the scroll
    /// settles. Programmatic scrolls (j/k keeping the selection in view) settle at once.
    func boundsDidScroll() {
        // The regions are the rows in view, and AppKit cut them to what was visible when it last asked.
        pointerRegionsDidChange()
        guard !isLiveScrolling else { return }
        guard let event = NSApp.currentEvent, event.type == .scrollWheel else {
            if hoveredRow >= 0 { setHoveredRow(-1) }
            return
        }
        suspendHover()
        wheelSettleTimer?.invalidate()
        let timer = Timer(timeInterval: MessageListTableView.wheelScrollSettle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isLiveScrolling else { return }
                self.resumeHover()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wheelSettleTimer = timer
    }

    private func suspendHover() {
        isHoverSuspended = true
        setHoveredRow(-1)
    }

    private func resumeHover() {
        wheelSettleTimer?.invalidate()
        wheelSettleTimer = nil
        isHoverSuspended = false
        setHoveredRow(rowUnderPointer())
    }

    /// Row views are recycled while scrolling; a recycled view must not carry another row's wash.
    override func didAdd(_ rowView: NSTableRowView, forRow row: Int) {
        super.didAdd(rowView, forRow: row)
        (rowView as? ConversationRowView)?.isHovered = (row == hoveredRow && !isHoverSuspended)
        pointerRegionsDidChange()
    }

    override func didRemove(_ rowView: NSTableRowView, forRow row: Int) {
        super.didRemove(rowView, forRow: row)
        pointerRegionsDidChange()
    }

    // MARK: Focus

    /// Called when the table gains or loses first responder, for the Full Keyboard Access ring overlay.
    var onFocusChange: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?() }
        return resigned
    }
}
