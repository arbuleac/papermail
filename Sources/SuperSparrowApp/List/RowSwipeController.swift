import AppKit
import SSCore
import SSDesign

/// Runs the swipe on the list's rows (spec §5.7, Swipe), drawn by the list itself, as Apple Mail's is: the table's scroll
/// events go through `RowSwipeGesture`, which keeps the swipes and hands back the scrolls; the row's content and the
/// button it uncovers move with the fingers (`ConversationRowView.setSwipe`); a release settles the row open or closed
/// or, for a full swipe, makes the change; and the open row closes on the close rules: a scroll, another row's swipe, a
/// click anywhere but its button, Esc, a selection change and a refresh of the list (the list calls `close()` and
/// `listDidRefresh()` for the last two).
///
/// Settling runs along the motion tokens: open and closed over `dur.standard` `ease.settle`, a full swipe's Archive out
/// over `dur.quick` `ease.leave`; under Reduce Motion the row is simply where it settles. The row follows the fingers
/// either way, as a scroll does. One row is open at a time.
@MainActor
final class RowSwipeController {
    private unowned let tableView: MessageListTableView

    /// The swipe table row `row` offers: nil for heads, the tail, the server row and a row that offers nothing.
    var rowAt: (Int) -> RowSwipeGesture.Row? = { _ in nil }
    /// The row view showing a conversation now, if its row is in view.
    var rowViewFor: (ConversationID) -> ConversationRowView? = { _ in nil }
    /// Makes the change of a full swipe, or of a click on the open button: the key's, through the list's host.
    var perform: (ConversationID, RowSwipe.Edge) -> Void = { _, _ in }

    private(set) var gesture = RowSwipeGesture()
    /// A gesture's first event, held back while the fingers have not moved.
    private var heldBegan: NSEvent?
    /// The row view of the row open, or under the fingers.
    private(set) weak var activeView: ConversationRowView?
    /// Row views whose Archive a commit slid out, until the refresh it causes takes their rows away.
    private var leaving: [WeakRowView] = []
    private var leavingCheck: Timer?
    private var monitor: Any?

    /// How long a row a commit slid out waits for the refresh that takes it away before it comes back: the change left
    /// it listed (or made no change), and it must not stay covered.
    static let leavingGrace: TimeInterval = 1

    private struct WeakRowView {
        weak var view: ConversationRowView?
    }

    init(tableView: MessageListTableView) {
        self.tableView = tableView
    }

    /// A row is open, under the fingers, or settling: something a close rule has to close.
    var isActive: Bool { gesture.row != nil || activeView != nil }

    // MARK: Scroll events

    /// Takes `event` if it belongs to a swipe; hands it, and any event held back before it, to `scroll` otherwise.
    func scrollWheel(_ event: NSEvent, scroll: (NSEvent) -> Void) {
        let tableView = self.tableView
        handle(Self.scroll(from: event), atRow: tableView.row(at: tableView.convert(event.locationInWindow, from: nil)), event: event,
               scroll: scroll)
    }

    /// One scroll event already read, over table row `row` (−1 for none), which is looked up only when a gesture starts,
    /// so a scroll pays nothing for it. Internal so tests can swipe without fingers.
    func handle(_ input: RowSwipeGesture.Scroll, atRow row: @autoclosure () -> Int, event: NSEvent? = nil,
                scroll: (NSEvent) -> Void = { _ in }) {
        let step = gesture.handle(input, over: self.offer(atRow: row()))
        apply(step)
        switch step.disposition {
        case .pass:
            if let event { scroll(event) }
        case .passHeld:
            if let heldBegan { scroll(heldBegan) }
            if let event { scroll(event) }
        case .consume:
            break
        }
        heldBegan = gesture.isPending ? (heldBegan ?? event) : nil
    }

    private func offer(atRow row: Int) -> RowSwipeGesture.Row? {
        row >= 0 ? rowAt(row) : nil
    }

    /// The fingers' travel in a scroll event. AppKit's deltas follow the content, which follows the fingers under natural
    /// scrolling and runs against them without it.
    static func scroll(from event: NSEvent) -> RowSwipeGesture.Scroll {
        let toFingers: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        return RowSwipeGesture.Scroll(phase: phase(event.phase), momentum: phase(event.momentumPhase),
                                      dx: event.scrollingDeltaX * toFingers, dy: event.scrollingDeltaY * toFingers)
    }

    private static func phase(_ phase: NSEvent.Phase) -> RowSwipeGesture.Scroll.Phase {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.stationary) { return .stationary }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.mayBegin) { return .mayBegin }
        return .none
    }

    private func apply(_ step: RowSwipeGesture.Step) {
        if let closed = step.closed {
            let view = activeView?.swipeRow?.id == closed.id ? activeView : rowViewFor(closed.id)
            if view === activeView { activeView = nil }
            settle(view, to: 0)
        }
        guard let row = step.row else {
            if !isActive { removeMonitor() }
            return
        }
        if step.moved {
            let view = activeView?.swipeRow?.id == row.id ? activeView : rowViewFor(row.id)
            activeView = view
            view?.onSwipePress = { [weak self] pressed in self?.pressButton(of: pressed) }
            view?.setSwipe(row, offset: gesture.offset)
            installMonitor()
        }
        switch step.release {
        case .open?:
            settle(activeView, to: gesture.offset)
            installMonitor()
        case .close?:
            settle(activeView, to: 0)
            activeView = nil
            removeMonitor()
        case .commit(let edge)?:
            commit(row, edge: edge)
        case nil:
            break
        }
    }

    // MARK: Settling

    private func settle(_ view: ConversationRowView?, to offset: CGFloat) {
        view?.settleSwipe(to: offset, Quire.Motion.standard, .settle)
    }

    /// The change is made: Archive's content slides the rest of the way out and its fill covers the row until the refresh
    /// takes the row away (in the frame the change lands, as after E); a read change's row settles back and shows it.
    private func commit(_ row: RowSwipeGesture.Row, edge: RowSwipe.Edge) {
        let view = activeView ?? rowViewFor(row.id)
        activeView = nil
        removeMonitor()
        if let view, row.button(edge)?.kind == .archive {
            view.settleSwipe(to: edge == .trailing ? -row.width : row.width, Quire.Motion.quick, .leave)
            leaving.append(WeakRowView(view: view))
            scheduleLeavingCheck()
        } else {
            settle(view, to: 0)
        }
        perform(row.id, edge)
    }

    /// A click on the open button, or VoiceOver's press: its change, as a full swipe's.
    private func pressButton(of view: ConversationRowView) {
        guard view === activeView, !gesture.isSwiping, let row = gesture.row, let edge = gesture.edge else { return }
        gesture.close()
        commit(row, edge: edge)
    }

    // MARK: Close rules

    /// Closes the open row: a click elsewhere, Esc, a selection change, the list scrolling (spec §5.7). It settles back,
    /// or with `animated` false (a click that acts on the rows at once) is back at once; Reduce Motion is always at once.
    func close(animated: Bool = true) {
        let view = activeView
        activeView = nil
        removeMonitor()
        gesture.close()
        guard let view, view.swipeOffset != 0 else { return }
        if animated {
            settle(view, to: 0)
        } else {
            view.resetSwipe()
        }
    }

    /// The list's rows changed. The open row closes (rows may have moved or gone under it), and a row a commit slid out
    /// comes back if the change left it listed, or is let go of where its row left.
    func listDidRefresh() {
        if isActive { close() }
        settleLeaving()
    }

    private func scheduleLeavingCheck() {
        leavingCheck?.invalidate()
        let timer = Timer(timeInterval: Self.leavingGrace, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleLeaving() }
        }
        RunLoop.main.add(timer, forMode: .common)
        leavingCheck = timer
    }

    private func settleLeaving() {
        leavingCheck?.invalidate()
        leavingCheck = nil
        let views = leaving.compactMap(\.view)
        leaving = []
        for view in views {
            if view.superview === tableView, tableView.row(for: view) >= 0 {
                settle(view, to: 0)
            } else {
                view.resetSwipe()
            }
        }
    }

    // MARK: Clicks and keys

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// A click or a key anywhere in the app while a row is open (a local monitor, installed only then): Esc closes the row
    /// and goes no further; a click anywhere but on the button closes it and goes on to what it was on. A click in the list
    /// acts on its rows at once, so the row is back at once. True when the event goes no further. Internal so tests can
    /// send events.
    func consumes(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        switch event.type {
        case .keyDown:
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard event.keyCode == Self.escapeKeyCode, modifiers.isEmpty, event.window === tableView.window else { return false }
            close()
            return true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard !isOnOpenButton(event) else { return false }
            let inList = event.window === tableView.window
                && tableView.visibleRect.contains(tableView.convert(event.locationInWindow, from: nil))
            close(animated: !inList)
            return false
        default:
            return false
        }
    }

    private static let escapeKeyCode: UInt16 = 53

    private func isOnOpenButton(_ event: NSEvent) -> Bool {
        guard event.window === tableView.window, let button = activeView?.swipeButton, button.window != nil else { return false }
        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }

    /// The open button under `point`, in the table's superview's coordinates as `hitTest(_:)` takes them, so a click
    /// there reaches the button and not the cell under it.
    func buttonHit(_ point: NSPoint) -> NSView? {
        guard gesture.isOpen, let button = activeView?.swipeButton, !button.isHidden, let superview = button.superview else { return nil }
        return button.frame.contains(superview.convert(point, from: tableView.superview)) ? button : nil
    }
}
