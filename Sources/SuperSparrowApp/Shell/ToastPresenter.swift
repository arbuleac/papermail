import AppKit
import SSDesign

/// Presents feedback toasts (spec §5.30): one at a time across the app, a new one replacing the old instantly in whichever
/// window it was in;
/// an undoable toast lives 5000 ms with its contrail draining, an undo confirmation 2000 ms with no action and
/// no contrail; the pointer resting on a toast freezes both its clock and its contrail. Esc dismisses (§6.1).
/// Each toast is announced to VoiceOver as it appears (“Archived. Press Z to undo.”, “Undid Archive.”).
///
/// The presenter owns timing only. Which action a toast undoes, and for how long Z still reaches it after the
/// toast has gone, is the undo center's (`onEnd` tells it when a toast stops being visible). A toast shows on the main
/// window's list unless the step it reports was taken in a reader window, whose own host is passed in (§5.49).
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

    /// The main window's list, where a toast shows unless it is given another host.
    private let defaultHost: ToastView
    /// The host the visible toast is in, or the last one was.
    private var host: ToastView
    private var slip: QuireSlipView?
    private var currentID = 0
    private var currentKind: Kind?
    private var action: (() -> Void)?
    private var timer: Timer?
    private var remaining: TimeInterval = 0
    private var startedAt = Date()
    private var isPaused = false

    init(host: ToastView) {
        defaultHost = host
        self.host = host
    }

    var isVisible: Bool { slip != nil }
    /// Whether the visible toast is in `view`: Esc in a window dismisses only its own (§6.1).
    func isVisible(in view: ToastView) -> Bool { slip != nil && host === view }
    var visibleKind: Kind? { slip == nil ? nil : currentKind }
    var visibleID: Int? { slip == nil ? nil : currentID }

    // MARK: Showing

    /// Shows a toast in `place` (the main window's list when nil) and returns its identifier. With `updating` equal to the
    /// visible toast's identifier, in the same place, the visible slip is updated in place (a coalesced count) and its life
    /// starts over.
    @discardableResult
    func show(_ message: String, kind: Kind, symbol: String? = nil, actionTitle: String? = nil, keycap: String? = nil,
              updating updatingID: Int? = nil, in place: ToastView? = nil, action: (() -> Void)? = nil) -> Int {
        let target = place ?? defaultHost
        let life = kind == .confirmation ? Quire.Motion.toastConfirm : Quire.Motion.toastLife
        let slipKind: QuireSlipView.Kind
        switch kind {
        case .undoable: slipKind = .undoable
        case .confirmation: slipKind = .confirmation
        case .error: slipKind = .error
        case .notice: slipKind = .notice
        }
        let reuse = updatingID != nil && updatingID == currentID && slip != nil && currentKind == kind && target === host
        if !reuse, slip != nil {
            let old = currentID
            stopTimer()
            // One toast across the app: a new one in another window takes the old one off its own.
            if host !== target { host.hide(animated: true) }
            onEnd?(old, .replaced)
        }
        host = target
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

    /// Whether an undoable toast of `message` shows it whole in `place` (the list when nil) as it is now, beside the action
    /// if it has one.
    func fits(_ message: String, symbol: String?, actionTitle: String?, keycap: String?, in place: ToastView? = nil) -> Bool {
        let slip = QuireSlipView(kind: .undoable, message: message, symbolName: symbol)
        if let actionTitle { slip.setAction(actionTitle, keycap: keycap) }
        return slip.intrinsicContentSize.width <= (place ?? defaultHost).slipRoom
    }

    /// Esc: the toast goes; its undo keeps working for the grace period (§6.1).
    func dismiss() {
        guard slip != nil else { return }
        end(.dismissed)
    }

    /// Dismisses the toast only if it is in `view`: Esc in that window, or the window closing.
    func dismiss(in view: ToastView) {
        guard isVisible(in: view) else { return }
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
