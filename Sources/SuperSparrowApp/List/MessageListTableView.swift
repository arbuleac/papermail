import AppKit
import SSDesign

/// The list's table: Return opens, and the pointer's hover wash.
///
/// Return and keypad Enter open the selected conversation. Every other key falls through the responder chain
/// so the window controller can map j/k and friends; type-select is off so letters are not swallowed here.
///
/// Hover is tracked by one tracking area on the table, not one per row, and it is suspended while the list
/// scrolls (spec §5.7, §8.2): rows that slide under a still pointer draw no wash, and when scrolling ends the
/// row under the pointer, if any, takes the wash once. That keeps a scroll from redrawing rows for hover and
/// from asking the avatar cache for anything a plain scroll would not.
final class MessageListTableView: NSTableView {
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    /// A wheel scroll has no end notification; this long without a scroll event counts as its end.
    private static let wheelScrollSettle: TimeInterval = 0.15

    var onReturn: (() -> Void)?
    /// Asked whether a row takes the hover wash (conversation rows do; heads and the footer do not).
    var isHoverableRow: ((Int) -> Bool)?

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
