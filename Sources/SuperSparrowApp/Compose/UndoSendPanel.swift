import AppKit
import SSCore
import SSDesign

/// The undo-send panel (spec §5.31): a borderless, non-activating, transparent `NSPanel` holding a
/// `QuireUndoPanelView`, shown once a composer's send is queued. The window is the 280 × 52 slip grown by the
/// shadow margins (32 pt above, 48 at the sides, 68 below) so the `e3` shadow is never clipped; insets and
/// stacking measure the slip itself: 20 pt from the main window's bottom-trailing corner (above the quick
/// reply when it shows; the screen's visible frame when the main window is hidden), several panels 8 pt apart.
///
/// Counting (“Sending in 4 s”, the outlined Undo with “⌘Z”, the contrail draining) → Sending → Sent for 1500 ms,
/// or Failed with “Open draft”. Undo closes the panel at once and reopens the composer; an Undo that comes
/// after the message left shows “Already sent” for 3000 ms. Hover never pauses the countdown: the send time
/// is a promise. ⌘Z cancels the newest counting panel unless a text view can undo typing or a newer toast
/// took ⌘Z (§6.1).
@MainActor
final class UndoSendPanel: NSPanel {
    private let client: MailClient
    private let accounts: [Account]
    private let sendID: String
    private let draft: ComposeDraft
    private let undoWindow: TimeInterval
    private let slip: QuireUndoPanelView
    private let shownAt = Date()
    private var pollTimer: Timer?
    private var isFinished = false
    private var failureReason: String?

    // MARK: Showing

    @discardableResult
    static func show(client: MailClient, accounts: [Account], sendID: String, draft: ComposeDraft, undoWindow: TimeInterval) -> UndoSendPanel {
        let panel = UndoSendPanel(client: client, accounts: accounts, sendID: sendID, draft: draft, undoWindow: undoWindow)
        ComposeWindowRegistry.shared.register(panel)
        panel.slip.startCountdown(undoWindow)
        panel.presentRising()
        Self.updateUndoKeyOwner()
        UndoKeyMonitor.shared.install()
        PanelAnchorObserver.shared.install()
        return panel
    }

    init(client: MailClient, accounts: [Account], sendID: String, draft: ComposeDraft, undoWindow: TimeInterval) {
        self.client = client
        self.accounts = accounts
        self.sendID = sendID
        self.draft = draft
        self.undoWindow = undoWindow
        slip = QuireUndoPanelView(state: .counting(secondsLeft: Int(undoWindow.rounded(.up))), summary: Self.summary(for: draft))
        let margins = QuireUndoPanelView.shadowMargins
        let size = NSSize(width: QuireUndoPanelView.size.width + margins.left + margins.right,
                          height: QuireUndoPanelView.size.height + margins.top + margins.bottom)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        let container = PanelContainerView(frame: NSRect(origin: .zero, size: size))
        container.slip = slip
        slip.frame = NSRect(x: margins.left, y: margins.top, width: QuireUndoPanelView.size.width, height: QuireUndoPanelView.size.height)
        container.addSubview(slip)
        contentView = container
        slip.onAction = { [weak self] state in self?.actionClicked(in: state) }
        slip.onCountdownEnd = { [weak self] in self?.countdownEnded() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// “Re: Contoso rollout · to Ben Carter”.
    static func summary(for draft: ComposeDraft) -> String {
        let subject = draft.subject.trimmingCharacters(in: .whitespaces)
        let title = subject.isEmpty ? "New Message" : subject
        guard let name = draft.firstRecipientName else { return title }
        return "\(title) · to \(name)"
    }

    var isLive: Bool { !isFinished }

    // MARK: Placement

    /// The slip's frame in screen coordinates for stacking `slot` (0 = lowest).
    private static func visualFrame(slot: Int) -> NSRect {
        let u = Quire.Layout.UndoPanel.self
        var anchor = NSScreen.main?.visibleFrame ?? .zero
        var clearance: CGFloat = 0
        if let main = mainWindow() {
            anchor = main.frame
            if let quickReply = visibleQuickReply(in: main) {
                let top = main.convertToScreen(quickReply.convert(quickReply.bounds, to: nil)).maxY
                clearance = max(0, top - anchor.minY)
            }
        }
        return UndoSendPanelGeometry.visualFrame(anchor: anchor, bottomClearance: clearance, slot: slot, size: QuireUndoPanelView.size,
                                                 inset: u.inset, stackGap: u.stackGap)
    }

    private static func windowFrame(slot: Int) -> NSRect {
        let m = QuireUndoPanelView.shadowMargins
        return UndoSendPanelGeometry.windowFrame(visual: visualFrame(slot: slot), margins: .init(top: m.top, side: m.left, bottom: m.bottom))
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.windowController is MainWindowController && $0.isVisible && !$0.isMiniaturized }
    }

    private static func visibleQuickReply(in window: NSWindow) -> NSView? {
        func search(_ view: NSView) -> NSView? {
            if view is QuickReplyView { return view.isHiddenOrHasHiddenAncestor ? nil : view }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        return window.contentView.flatMap(search)
    }

    /// In: `dur.slow`, a 12 pt rise and a fade (`ease.settle`); under Reduce Motion the fade alone.
    private func presentRising() {
        let slot = ComposeWindowRegistry.shared.slot(for: self)
        let final = Self.windowFrame(slot: slot)
        let plan = Quire.Motion.plan(Quire.Motion.slow, .settle, reduced: .fade)
        setFrame(plan.isReduced ? final : final.offsetBy(dx: 0, dy: -Quire.Layout.UndoPanel.rise), display: false)
        alphaValue = 0
        orderFrontRegardless()
        Quire.Motion.run(Quire.Motion.slow, .settle, reduced: .fade) { _ in
            self.animator().setFrame(final, display: true)
            self.animator().alphaValue = 1
        }
    }

    /// Panels above a closing one drop into place instantly (§5.31).
    static func restack() {
        for (slot, panel) in ComposeWindowRegistry.shared.livePanels.enumerated() {
            panel.setFrame(windowFrame(slot: slot), display: true)
        }
    }

    // MARK: Countdown and outcome

    private func countdownEnded() {
        slip.state = .sending
        Self.updateUndoKeyOwner()
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollOutcome() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollOutcome()
    }

    /// The outbox is in the store: a sent message's row is removed, a failed one stays with its reason.
    private func pollOutcome() {
        guard let sends = try? client.store.pendingSends() else { return }
        let send = sends.first { $0.id == sendID }
        switch send?.status {
        case nil, .sent?:
            pollTimer?.invalidate()
            showSent()
        case .failed?:
            pollTimer?.invalidate()
            showFailed(reason: send?.lastError)
        case .scheduled?, .sending?:
            break
        }
    }

    private func showSent() {
        slip.state = .sent
        finish(after: Quire.Motion.sentConfirm)
    }

    private func showFailed(reason: String?) {
        let wording = SendFailureWording.banner(lastError: reason, provider: draft.account.kind)
        failureReason = wording
        slip.state = .failed
        Self.updateUndoKeyOwner()
        // “Your draft is kept on this Mac”: it is, from now on.
        var kept = draft
        kept.sendFailure = wording
        ComposeDraftStore.shared.save(kept)
    }

    private func actionClicked(in state: QuireUndoPanelView.State) {
        switch state {
        case .counting: undo()
        case .failed: openDraft()
        case .sending, .sent, .undoTooLate: break
        }
    }

    /// Cancels the held send and reopens the composer with the draft; too late, it says so.
    func undo() {
        guard case .counting = slip.state, !isFinished else { return }
        let cancelled = (try? client.cancelSend(id: sendID)) ?? false
        guard cancelled else {
            slip.state = .undoTooLate
            Self.updateUndoKeyOwner()
            finish(after: 3)
            return
        }
        dismissNow()
        ComposeWindowController.present(client: client, accounts: accounts, draft: draft)
    }

    private func openDraft() {
        var reopened = draft
        reopened.sendFailure = failureReason
        dismissNow()
        ComposeWindowController.present(client: client, accounts: accounts, draft: reopened)
    }

    /// Shows the final state for `seconds`, then fades out over `dur.quick`.
    private func finish(after seconds: TimeInterval) {
        isFinished = true
        Self.updateUndoKeyOwner()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            Quire.Motion.run(Quire.Motion.quick, .leave, reduced: .keep) { _ in
                self.animator().alphaValue = 0
            } completion: { [weak self] in
                self?.dismissNow()
            }
        }
    }

    private func dismissNow() {
        isFinished = true
        pollTimer?.invalidate()
        pollTimer = nil
        orderOut(nil)
        ComposeWindowRegistry.shared.unregister(self)
        Self.restack()
        Self.updateUndoKeyOwner()
    }

    // MARK: ⌘Z

    /// When the latest toast with Undo appeared; panels shown before it give ⌘Z up while it is up (§6.1).
    private static var toastShownAt: Date?
    private static var toastExpiry: Timer?

    /// The main window calls this when an undoable toast takes ⌘Z. When the toast's life is over, an older
    /// panel that is still counting takes ⌘Z (and its keycap) back.
    static func yieldUndoKey() {
        toastShownAt = Date()
        updateUndoKeyOwner()
        toastExpiry?.invalidate()
        let timer = Timer(timeInterval: Quire.Motion.toastLife, repeats: false) { _ in
            MainActor.assumeIsolated { updateUndoKeyOwner() }
        }
        RunLoop.main.add(timer, forMode: .common)
        toastExpiry = timer
    }

    /// The panel ⌘Z cancels now: the newest one still counting, unless a newer toast is up.
    static var undoKeyOwner: UndoSendPanel? {
        let panels = ComposeWindowRegistry.shared.livePanels
        let candidates = panels.map { panel -> UndoKeyPrecedence.Panel in
            if case .counting = panel.slip.state, !panel.isFinished {
                return UndoKeyPrecedence.Panel(shownAt: panel.shownAt, isCounting: true)
            }
            return UndoKeyPrecedence.Panel(shownAt: panel.shownAt, isCounting: false)
        }
        let index = UndoKeyPrecedence.owner(of: candidates, toastShownAt: toastShownAt, toastLife: Quire.Motion.toastLife, now: Date())
        return index.map { panels[$0] }
    }

    private static func updateUndoKeyOwner() {
        let owner = undoKeyOwner
        for panel in ComposeWindowRegistry.shared.livePanels {
            panel.slip.ownsUndoKey = panel === owner
        }
        if ComposeWindowRegistry.shared.livePanels.isEmpty {
            UndoKeyMonitor.shared.remove()
            PanelAnchorObserver.shared.remove()
        }
    }
}

/// The transparent window's content: clicks outside the slip fall through to whatever is below.
@MainActor
private final class PanelContainerView: NSView {
    weak var slip: NSView?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let slip, slip.frame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

/// Keeps live panels on the main window's bottom-trailing corner while it moves, resizes or is minimized
/// (§5.31: anchored to the main window, the screen when it is hidden).
@MainActor
private final class PanelAnchorObserver {
    static let shared = PanelAnchorObserver()
    private var observers: [NSObjectProtocol] = []

    func install() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                                          NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard window?.windowController is MainWindowController else { return }
                    UndoSendPanel.restack()
                }
            }
        }
    }

    func remove() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

/// Claims ⌘Z app-wide while an undo-send panel can take it, before the key window and the menus see it.
/// A text view that can undo typing keeps its ⌘Z (§6.1, row 1).
@MainActor
private final class UndoKeyMonitor {
    static let shared = UndoKeyMonitor()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { UndoKeyMonitor.handle(event) }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "z",
              let owner = UndoSendPanel.undoKeyOwner else { return false }
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable, text.undoManager?.canUndo == true {
            return false
        }
        owner.undo()
        return true
    }
}
