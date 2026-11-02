import AppKit
import SSDesign

/// Where toasts appear (spec §5.30): a transparent overlay over the list, between the header and the sync
/// line, that holds at most one `QuireSlipView` at its bottom centre, 16 pt above the sync line and never wider
/// than the list less 16 pt a side (the message truncates). Only the slip takes clicks; the list under the rest
/// of the overlay works as if it were not there.
///
/// The slip rises 8 pt and fades in over `dur.standard` (`ease.settle`) and fades out over `dur.quick`
/// (`ease.leave`); under Reduce Motion both are fades only. `ToastPresenter` decides what to show and when.
@MainActor
final class ToastView: NonDraggingView {
    private(set) var slip: QuireSlipView?
    private var leaving: QuireSlipView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let slip, !slip.isHidden, slip.alphaValue > 0 else { return nil }
        let local = convert(point, from: superview)
        guard slip.frame.contains(local) else { return nil }
        return slip.hitTest(convert(local, to: slip.superview)) ?? slip
    }

    override func isAccessibilityElement() -> Bool { false }

    // MARK: Layout

    private func frame(for slip: QuireSlipView) -> NSRect {
        let t = Quire.Layout.Toast.self
        let width = min(slip.intrinsicContentSize.width, max(0, bounds.width - 2 * t.sideMargin))
        return NSRect(x: ((bounds.width - width) / 2).rounded(), y: bounds.height - t.aboveSyncLine - t.height,
                      width: width, height: t.height)
    }

    override func layout() {
        super.layout()
        if let slip { slip.frame = frame(for: slip) }
    }

    // MARK: Showing

    /// Puts `slip` up. A slip already showing is replaced at once, without stacking; only a toast arriving on
    /// an empty overlay rises in.
    func show(_ slip: QuireSlipView) {
        let replacing = self.slip != nil
        if let old = self.slip, old !== slip { old.removeFromSuperview() }
        if let leaving, leaving !== slip { leaving.removeFromSuperview() }
        leaving = nil
        self.slip = slip
        slip.wantsLayer = true
        if slip.superview !== self { addSubview(slip) }
        let target = frame(for: slip)
        guard !replacing, window != nil else {
            slip.frame = target
            slip.alphaValue = 1
            return
        }
        slip.frame = target.offsetBy(dx: 0, dy: Quire.Layout.Toast.rise)
        slip.alphaValue = 0
        Quire.Motion.run(Quire.Motion.standard, .settle, reduced: .fade, participants: [slip]) { plan in
            if plan.isReduced {
                slip.frame = target
            } else {
                slip.animator().frame = target
            }
            slip.animator().alphaValue = 1
        }
    }

    /// Re-fits the slip after its message or action changed (a coalesced count).
    func refit() {
        guard let slip else { return }
        slip.frame = frame(for: slip)
    }

    /// Fades the slip out and removes it.
    func hide(animated: Bool) {
        guard let slip else { return }
        self.slip = nil
        guard animated, window != nil else {
            slip.removeFromSuperview()
            return
        }
        leaving = slip
        Quire.Motion.run(Quire.Motion.quick, .leave, reduced: .fade, participants: [slip], animations: { _ in
            slip.animator().alphaValue = 0
        }, completion: { [weak self, weak slip] in
            guard let slip else { return }
            if self?.slip !== slip { slip.removeFromSuperview() }
            if self?.leaving === slip { self?.leaving = nil }
        })
    }
}
