import CoreGraphics
import SSCore
import SSDesign

/// The two-finger swipe on the list's rows (spec §5.7, Swipe) as a state machine fed the trackpad's scroll events: their
/// phases, their deltas, and the row under the pointer when a gesture starts. It decides which gestures are swipes, where
/// the row's content is under the fingers and what letting go does; `RowSwipeController` turns NSEvents into `Scroll`s
/// and its answers into views. Pure, so every rule is tested without fingers or windows.
///
/// - A gesture is a swipe when its first movement is more sideways than up or down, over a conversation row that offers a
///   change on some edge. Anything else is a scroll and goes to the table: up and down, sideways over a head or the tail,
///   a mouse's wheel, and a scroll's momentum. A swipe's momentum is swallowed, so a flick's tail neither scrolls the list
///   nor moves the row.
/// - The content follows the fingers one to one: to the left it uncovers the trailing edge's button, to the right the
///   leading one's; toward an edge that offers nothing it does not move. Past the full-swipe distance it rubber-bands,
///   slowing toward the row's width and never reaching it.
/// - Let go past the full-swipe distance, the change is made (`commit`). Let go past half the button's width (`snapOpen`)
///   while still opening, or anywhere past the whole button, it stays open (`open`); otherwise the row closes.
/// - One row at a time: a swipe on another row, any scroll and the list's close rules (`close()`) close the open one.
struct RowSwipeGesture {
    /// One edge's button on a row: what it shows and how wide it opens.
    struct Button: Equatable {
        var kind: QuireSwipeAction
        var title: String
        var openWidth: CGFloat
    }

    /// A row a swipe can move, as the list describes it when a gesture starts over it.
    struct Row: Equatable {
        var id: ConversationID
        var width: CGFloat
        var trailing: Button?
        var leading: Button?

        func button(_ edge: RowSwipe.Edge) -> Button? {
            edge == .trailing ? trailing : leading
        }
    }

    /// One scroll event: AppKit's phases, and the fingers' travel since the last event in points, x to the right and y
    /// downward. (AppKit's deltas follow the content; the controller turns them back into the fingers' direction.)
    struct Scroll: Equatable {
        enum Phase: Equatable {
            case none, mayBegin, began, changed, stationary, ended, cancelled
        }

        var phase: Phase = .none
        var momentum: Phase = .none
        var dx: CGFloat = 0
        var dy: CGFloat = 0
    }

    /// Who gets the event.
    enum Disposition: Equatable {
        /// The table: the list scrolls.
        case pass
        /// The table, after the gesture's first event, held back while the fingers had not moved yet.
        case passHeld
        /// Nobody: the swipe takes it.
        case consume
    }

    /// What letting go of a swipe does.
    enum Release: Equatable {
        case open(RowSwipe.Edge)
        case close
        case commit(RowSwipe.Edge)
    }

    /// What one event did.
    struct Step: Equatable {
        var disposition: Disposition
        /// A row that was open and closes now: another row's swipe, or a scroll.
        var closed: Row?
        /// The row the fingers move, or the one let go of, which `moved` and `release` are about.
        var row: Row?
        /// The row's content moved: draw it at `offset`.
        var moved = false
        var release: Release?
    }

    /// The thresholds, as fractions (`layout.swipe`).
    struct Metrics: Equatable {
        /// Of the open width: a release past it, while opening, leaves the button open.
        var snapOpen: CGFloat
        /// Of the row's width: a release past it makes the change.
        var fullSwipe: CGFloat
        /// How hard the row pulls back past the full swipe (the scroll view's constant, 0.55).
        var rubberBand: CGFloat

        static let tokens = Metrics(snapOpen: Quire.Layout.Swipe.snapOpen, fullSwipe: Quire.Layout.Swipe.fullSwipe,
                                    rubberBand: Quire.Layout.Swipe.rubberBand)
    }

    var metrics = Metrics.tokens

    private enum Tracking: Equatable {
        case idle
        /// Began without moving: its first event is held back until the fingers say which way they go.
        case pending
        case scrolling
        case swiping
        /// Let go of, or closed under the fingers: the rest of the gesture and its momentum are swallowed.
        case swiped
    }

    private var tracking = Tracking.idle
    /// The row under the pointer when a gesture that has not moved yet began.
    private var pendingRow: Row?

    /// The row open, or under the fingers.
    private(set) var row: Row?
    /// How far its content has moved: negative to the left (the trailing edge's button), positive to the right.
    private(set) var offset: CGFloat = 0
    /// The fingers' travel since the row was at rest, before the rubber band.
    private var travel: CGFloat = 0
    /// The last movement brought the content back toward rest.
    private var closing = false

    /// The fingers are moving a row.
    var isSwiping: Bool { tracking == .swiping }
    /// A gesture began and has not moved yet; its first event is held back.
    var isPending: Bool { tracking == .pending }
    /// A row's content is away from rest: open, or under the fingers.
    var isOpen: Bool { row != nil && offset != 0 }
    /// The edge whose button shows.
    var edge: RowSwipe.Edge? { offset < 0 ? .trailing : offset > 0 ? .leading : nil }
    var button: Button? { edge.flatMap { row?.button($0) } }

    // MARK: Events

    /// Takes one scroll event. `target` is the swipe the row under the pointer offers (nil over a head, the tail, the
    /// server row, empty space, or a row that offers nothing); it is asked only when a gesture starts.
    @discardableResult
    mutating func handle(_ scroll: Scroll, over target: @autoclosure () -> Row?) -> Step {
        if scroll.phase == .none {
            guard scroll.momentum != .none else {
                // A mouse's wheel, which has no phases: it scrolls, and a turn up or down closes what is open.
                return Step(disposition: .pass, closed: scroll.dy != 0 && tracking != .swiping ? closeOpen() : nil)
            }
            // Momentum never starts a swipe. After one it is swallowed until it stops.
            guard tracking == .swiped else { return Step(disposition: .pass) }
            if scroll.momentum == .ended || scroll.momentum == .cancelled { tracking = .idle }
            return Step(disposition: .consume)
        }
        switch scroll.phase {
        case .mayBegin:
            // Fingers down and still: the table takes it (it stops a scroll's momentum).
            if tracking == .swiped { tracking = .idle }
            return Step(disposition: .pass)
        case .began:
            tracking = .idle
            pendingRow = nil
            guard scroll.dx != 0 || scroll.dy != 0 else {
                tracking = .pending
                pendingRow = target()
                return Step(disposition: .consume)
            }
            return decide(scroll, over: target())
        case .changed, .stationary:
            switch tracking {
            case .pending:
                guard scroll.dx != 0 || scroll.dy != 0 else { return Step(disposition: .consume) }
                var step = decide(scroll, over: pendingRow)
                pendingRow = nil
                if step.disposition == .pass { step.disposition = .passHeld }
                return step
            case .swiping:
                return drag(scroll.dx)
            case .swiped:
                return Step(disposition: .consume)
            case .idle, .scrolling:
                return Step(disposition: .pass)
            }
        case .ended, .cancelled:
            switch tracking {
            case .pending:
                // The fingers never moved: the table sees the whole gesture, which went nowhere.
                tracking = .idle
                pendingRow = nil
                return Step(disposition: .passHeld)
            case .swiping:
                tracking = .swiped
                return release(cancelled: scroll.phase == .cancelled)
            case .swiped:
                return Step(disposition: .consume)
            case .idle, .scrolling:
                tracking = .idle
                return Step(disposition: .pass)
            }
        case .none:
            return Step(disposition: .pass)
        }
    }

    /// A close rule (spec §5.7): a click anywhere but the button, Esc, a selection change, a refresh, the list scrolling.
    /// Returns the row that was open. Fingers still on the trackpad move nothing more until they lift.
    @discardableResult
    mutating func close() -> Row? {
        if tracking == .swiping { tracking = .swiped }
        return closeOpen()
    }

    // MARK: Rules

    /// The gesture's first movement says what it is: more sideways than up or down, over a row that swipes, it is a swipe.
    private mutating func decide(_ scroll: Scroll, over target: Row?) -> Step {
        guard abs(scroll.dx) > abs(scroll.dy), let target, target.trailing != nil || target.leading != nil else {
            // Up and down, or sideways where nothing swipes: the list scrolls, and a row that is open closes.
            tracking = .scrolling
            return Step(disposition: .pass, closed: closeOpen())
        }
        // Another row's swipe closes the open one; the open row itself carries on from where it is.
        let closed = row?.id == target.id ? nil : closeOpen()
        row = target
        travel = offset
        closing = false
        tracking = .swiping
        var step = drag(scroll.dx)
        step.closed = closed
        return step
    }

    private mutating func drag(_ dx: CGFloat) -> Step {
        guard let row else { return Step(disposition: .consume) }
        let before = offset
        travel += dx
        // An edge that offers nothing stays shut: the content does not move that way.
        if travel < 0, row.trailing == nil { travel = 0 }
        if travel > 0, row.leading == nil { travel = 0 }
        offset = banded(travel, row: row)
        if abs(offset) != abs(before) { closing = abs(offset) < abs(before) }
        return Step(disposition: .consume, row: row, moved: offset != before)
    }

    private mutating func release(cancelled: Bool) -> Step {
        guard let row, let edge, let button = row.button(edge) else {
            let row = self.row
            reset()
            return Step(disposition: .consume, row: row, release: .close)
        }
        let distance = abs(offset)
        // A cancelled gesture (the system took the fingers) never makes a change.
        if !cancelled, distance >= fullSwipeDistance(row: row, button: button) {
            reset()
            return Step(disposition: .consume, row: row, release: .commit(edge))
        }
        if distance > button.openWidth || (distance >= button.openWidth * metrics.snapOpen && !closing) {
            offset = edge == .trailing ? -button.openWidth : button.openWidth
            travel = offset
            closing = false
            return Step(disposition: .consume, row: row, release: .open(edge))
        }
        reset()
        return Step(disposition: .consume, row: row, release: .close)
    }

    /// Where the content is for the fingers' `travel`: one to one up to the full-swipe distance, then slowing toward the
    /// row's width, which it never reaches (the scroll view's rubber band, `layout.swipe.rubberBand`).
    func banded(_ travel: CGFloat, row: Row) -> CGFloat {
        guard travel != 0, let button = row.button(travel < 0 ? .trailing : .leading) else { return 0 }
        let full = fullSwipeDistance(row: row, button: button)
        let distance = abs(travel)
        guard distance > full else { return travel }
        let room = row.width - full
        let past = room > 0 ? room * (1 - 1 / ((distance - full) * metrics.rubberBand / room + 1)) : 0
        return travel < 0 ? -(full + past) : full + past
    }

    /// How far the content must travel for a release to make the change: `fullSwipe` of the row's width, and never less
    /// than half a button past the open width, so even a narrow list leaves room to open the button.
    func fullSwipeDistance(row: Row, button: Button) -> CGFloat {
        max(row.width * metrics.fullSwipe, button.openWidth * (1 + metrics.snapOpen))
    }

    private mutating func closeOpen() -> Row? {
        let open = isOpen ? row : nil
        reset()
        return open
    }

    private mutating func reset() {
        row = nil
        offset = 0
        travel = 0
        closing = false
    }
}
