import AppKit
import SSDesign

/// Presents feedback toasts on the list (spec §5.30): one at a time, a new one replacing the old instantly;
/// an undoable toast lives 5000 ms with its contrail draining, an undo confirmation 2000 ms with no action and
/// no contrail; the pointer resting on a toast freezes both its clock and its contrail. Esc dismisses (§6.1).
/// Each toast is announced to VoiceOver as it appears (“Archived. Press Z to undo.”, “Undid Archive.”).
///
/// The presenter owns timing only. Which action a toast undoes, and for how long Z still reaches it after the
/// toast has gone, is the window controller's (`onEnd` tells it when a toast stops being visible).
@MainActor
final class ToastPresenter {
    enum Kind: Equatable {
        /// Past tense plus “Undo” and its Z keycap.
        case undoable
        /// “Undid Archive”: no action, no divider, no contrail.
        case confirmation
        /// “Couldn't archive. Restored.”, with an optional action that is never Undo.
        case error
        /// “Saved 3 attachments to Downloads”: done, nothing to undo, with an optional action that is never Undo.
        case notice
    }

    /// Why a toast stopped being visible.
    enum End {
        case timedOut
        case dismissed
        case replaced
        case acted
    }

    /// Called when the visible toast leaves, with its identifier and why.
    var onEnd: ((Int, End) -> Void)?

    private let host: ToastView
    private var slip: QuireSlipView?
    private var currentID = 0
    private var currentKind: Kind?
    private var action: (() -> Void)?
    private var timer: Timer?
    private var remaining: TimeInterval = 0
    private var startedAt = Date()
    private var isPaused = false

    init(host: ToastView) {
        self.host = host
    }

    var isVisible: Bool { slip != nil }
    var visibleKind: Kind? { slip == nil ? nil : currentKind }
    var visibleID: Int? { slip == nil ? nil : currentID }

    // MARK: Showing

    /// Shows a toast and returns its identifier. With `replacingID` equal to the visible toast's identifier the
    /// visible slip is updated in place (a coalesced count) and its life starts over.
    @discardableResult
    func show(_ message: String, kind: Kind, symbol: String? = nil, actionTitle: String? = nil, keycap: String? = nil,
              updating updatingID: Int? = nil, action: (() -> Void)? = nil) -> Int {
        let life = kind == .confirmation ? Quire.Motion.toastConfirm : Quire.Motion.toastLife
        let slipKind: QuireSlipView.Kind
        switch kind {
        case .undoable: slipKind = .undoable
        case .confirmation: slipKind = .confirmation
        case .error: slipKind = .error
        case .notice: slipKind = .notice
        }
        let reuse = updatingID != nil && updatingID == currentID && slip != nil && currentKind == kind
        if !reuse, slip != nil {
            let old = currentID
            stopTimer()
            onEnd?(old, .replaced)
        }
        currentID += reuse ? 0 : 1
        currentKind = kind
        self.action = action
        let slip: QuireSlipView
        if reuse, let existing = self.slip {
            slip = existing
            slip.message = message
            slip.symbolName = symbol
        } else {
            slip = QuireSlipView(kind: slipKind, message: message, symbolName: symbol)
            slip.onPointerHover = { [weak self, weak slip] inside in
                guard let self, let slip, slip === self.slip else { return }
                self.setPaused(inside)
            }
        }
        if let actionTitle, action != nil {
            slip.setAction(actionTitle, keycap: keycap, target: self, action: #selector(actionClicked(_:)))
        } else {
            slip.setAction(nil)
        }
        self.slip = slip
        host.show(slip)
        host.refit()
        slip.startLifetime(life)
        startTimer(life)
        slip.announce()
        return currentID
    }

    /// Whether an undoable toast of `message` shows it whole in the list as it is now, beside the action if it has one.
    func fits(_ message: String, symbol: String?, actionTitle: String?, keycap: String?) -> Bool {
        let slip = QuireSlipView(kind: .undoable, message: message, symbolName: symbol)
        if let actionTitle { slip.setAction(actionTitle, keycap: keycap) }
        return slip.intrinsicContentSize.width <= host.slipRoom
    }

    /// Esc: the toast goes; its undo keeps working for the grace period (§6.1).
    func dismiss() {
        guard slip != nil else { return }
        end(.dismissed)
    }

    // MARK: Timing

    private func startTimer(_ life: TimeInterval) {
        stopTimer()
        remaining = life
        isPaused = false
        resumeTimer()
    }

    private func resumeTimer() {
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: max(0.05, remaining), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(.timedOut) }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// The pointer resting on the toast freezes its life (the slip freezes its own contrail).
    private func setPaused(_ paused: Bool) {
        guard paused != isPaused, slip != nil else { return }
        isPaused = paused
        if paused {
            remaining = max(0, remaining - Date().timeIntervalSince(startedAt))
            stopTimer()
        } else {
            resumeTimer()
        }
    }

    private func end(_ reason: End) {
        stopTimer()
        guard let slip else { return }
        self.slip = nil
        action = nil
        slip.stopLifetime()
        host.hide(animated: true)
        onEnd?(currentID, reason)
    }

    @objc private func actionClicked(_ sender: Any?) {
        let action = self.action
        end(.acted)
        action?()
    }
}
