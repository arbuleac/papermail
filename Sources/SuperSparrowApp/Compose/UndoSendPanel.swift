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
/// or Failed with “Open draft”, the message kept as a draft with its reason and its outbox row cleared once that draft is
/// on disk, so it leaves the Outbox for Drafts (§5.53). The panel answers for its send from the moment it shows until the
/// outcome is settled (`SendOwnership`), so the main window never keeps a second draft of it; dismissed before then
/// (“Already sent”), it lets go and the window settles a later failure. Undo closes the panel at once and reopens the
/// composer; an Undo that comes after the message left shows “Already sent” for 3000 ms. A Send and Archive's panel says “Archived” first on its
/// second line, and its Undo also brings the conversation back to the Inbox (§5.23). Hover never pauses the countdown: the send time
/// is a promise. ⌘Z cancels the newest counting panel unless a text view can undo typing or, in the main
/// window, a newer toast or quick-reply countdown holds ⌘Z (§6.1, `UndoPrecedence`).
@MainActor
final class UndoSendPanel: NSPanel {
    private let client: MailClient
    private let accounts: [Account]
    let sendID: String
    private let draft: ComposeDraft
    private let undoWindow: TimeInterval
    private let slip: QuireUndoPanelView
    /// When the send began counting: a quick reply moved here keeps its own start (§5.18).
    private let shownAt: Date
    /// Runs instead of reopening the composer when Undo cancels the send in time.
    private var onUndone: (() -> Void)?
    /// Runs once the message has left: work that Undo must be able to take back waits for it.
    private var onSent: (() -> Void)?
    /// What Send and Archive archived when this send was queued: Undo puts it back with the send.
    private var archive: SendArchive?
    private var pollTimer: Timer?
    private var isFinished = false
    private var failureReason: String?
    /// What a failure kept: the draft under its kept id (`FailedSend.draftID`), which Open draft opens, so the composer
    /// continues the draft listed in Drafts rather than starting a second.
    private var keptDraft: ComposeDraft?
    /// The panel holds its send's claim (`SendOwnership`), from `show` until the outcome is settled or the panel goes.
    private var ownsSend = false

    // MARK: Showing

    /// `remaining` is the part of `undoWindow` still to run (a quick reply's countdown moving here mid-way,
    /// §5.18); `startedAt` when it began, so ⌘Z still ranks it by its own send.
    @discardableResult
    static func show(client: MailClient, accounts: [Account], sendID: String, draft: ComposeDraft, undoWindow: TimeInterval,
                     remaining: TimeInterval? = nil, startedAt: Date = Date(), archive: SendArchive? = nil,
                     onUndone: (() -> Void)? = nil, onSent: (() -> Void)? = nil) -> UndoSendPanel {
        let left = max(0, min(undoWindow, remaining ?? undoWindow))
        let panel = UndoSendPanel(client: client, accounts: accounts, sendID: sendID, draft: draft, undoWindow: left, startedAt: startedAt,
                                  archived: archive != nil)
        panel.archive = archive
        panel.onUndone = onUndone
        panel.onSent = onSent
        // In the turn that queued the send, before the outbox's observation can say anything about it.
        SendOwnership.claim(sendID)
        panel.ownsSend = true
        ComposeWindowRegistry.shared.register(panel)
        panel.slip.startCountdown(left)
        panel.presentRising()
        Self.updateUndoKeyOwner()
        UndoKeyMonitor.shared.install()
        PanelAnchorObserver.shared.install()
        return panel
    }

    init(client: MailClient, accounts: [Account], sendID: String, draft: ComposeDraft, undoWindow: TimeInterval, startedAt: Date = Date(),
         archived: Bool = false) {
        self.client = client
        self.accounts = accounts
        self.sendID = sendID
        self.draft = draft
        self.undoWindow = undoWindow
        self.shownAt = startedAt
        slip = QuireUndoPanelView(state: .counting(secondsLeft: Int(undoWindow.rounded(.up))),
                                  summary: Self.summary(for: draft, archived: archived))
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

    /// “Re: Contoso rollout · to Ben Carter”; after Send and Archive “Archived · Re: Contoso rollout · to Ben Carter”,
    /// the archive first, since the line is tail-truncated and Undo takes the archive back too (§5.31).
    static func summary(for draft: ComposeDraft, archived: Bool = false) -> String {
        let subject = draft.subject.trimmingCharacters(in: .whitespaces)
        let title = subject.isEmpty ? "New Message" : subject
        let message = draft.firstRecipientName.map { "\(title) · to \($0)" } ?? title
        return archived ? "Archived · " + message : message
    }

    /// The summary as the panel shows it (tests).
    var summary: String { slip.summary }

    /// Edit › Undo's title while ⌘Z would cancel this send: “Undo Send and Archive” while it holds an archive to put back.
    var undoMenuTitle: String { SendAction.undoMenuTitle(archived: archive?.isArchived ?? false) }

    var isLive: Bool { !isFinished }

    /// Still counting down: ⌘Z can cancel it.
    var isCounting: Bool {
        if case .counting = slip.state, !isFinished { return true }
        return false
    }

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

    /// The outbox is in the store: a sent message's row is removed, a failed one stays with its reason until this panel
    /// has kept its draft.
    private func pollOutcome() {
        guard let sends = try? client.store.pendingSendSummaries() else { return }
        let send = sends.first { $0.id == sendID }
        switch send?.status {
        case nil, .sent?:
            pollTimer?.invalidate()
            showSent()
        case .failed?:
            pollTimer?.invalidate()
            showFailed(reason: send?.lastError)
        case .scheduled?, .sending?, .later?, .missed?:
            // An undo-send is never `later` or `missed`; those are Send Later's.
            break
        }
    }

    private func showSent() {
        onSent?()
        onSent = nil
        // The message has left: the archive it went with stays.
        archive = nil
        slip.state = .sent
        finish(after: Quire.Motion.sentConfirm)
    }

    /// “Your draft is kept on this Mac”: it is, from now on, under the id the window would keep it under too, and the row
    /// leaves the Outbox once it is on disk. The claim goes with the save, so a panel closed by Open draft before the write
    /// lands never lets the window keep a second draft beside it.
    private func showFailed(reason: String?) {
        let wording = SendFailureWording.banner(lastError: reason, provider: draft.account.kind)
        failureReason = wording
        slip.state = .failed
        Self.updateUndoKeyOwner()
        var kept = draft
        kept.id = FailedSend.draftID(sendID: sendID, writtenIn: nil)
        kept.sendFailure = wording
        keptDraft = kept
        let releasing = ownsSend
        ownsSend = false
        SendOwnership.keepFailed(kept, sendID: sendID, store: client.store, releasing: releasing)
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
        // A quick reply's countdown moved to this panel brings its text back to the bar (`onUndone`).
        Analytics.send(.sendUndone(onUndone == nil ? .composer : .quickReply))
        // The conversation comes back to the Inbox before the composer takes the screen.
        archive?.revert()
        archive = nil
        if let onUndone {
            onUndone()
        } else {
            ComposeWindowController.present(client: client, accounts: accounts, draft: draft)
        }
    }

    private func openDraft() {
        var reopened = keptDraft ?? draft
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
        // Gone before its outcome (Undo, “Already sent” while it still goes, sent): a failure from now on is the window's.
        if ownsSend {
            ownsSend = false
            SendOwnership.release(sendID)
        }
        // An ordered-out panel sends its action no exit event, so a pointer resting on Undo or Open draft would keep the
        // hand the action set over whatever lies under it; hidden, the action takes it back first (§4.17).
        slip.isHidden = true
        orderOut(nil)
        ComposeWindowRegistry.shared.unregister(self)
        Self.restack()
        Self.updateUndoKeyOwner()
    }

    // MARK: ⌘Z

    /// The app's undo center, which ranks the panels against its toast and the quick replies' countdowns (§6.1).
    /// Without one, the newest counting panel holds ⌘Z.
    static weak var undoKeyArbiter: UndoKeyArbiter?

    /// Every counting panel as a send ⌘Z can still cancel.
    static var liveSends: [UndoPrecedence.LiveSend] {
        ComposeWindowRegistry.shared.livePanels.filter(\.isCounting).map { UndoPrecedence.LiveSend(id: $0.sendID, startedAt: $0.shownAt) }
    }

    static func panel(sendID: String) -> UndoSendPanel? {
        ComposeWindowRegistry.shared.livePanels.first { $0.sendID == sendID }
    }

    /// The panel ⌘Z cancels now, and the one showing the “⌘Z” keycap.
    static var undoKeyOwner: UndoSendPanel? {
        let id = undoKeyArbiter.map { $0.sendOwningCommandZ() }
            ?? UndoPrecedence.sendOwningCommandZ(sends: liveSends, toast: nil)
        return id.flatMap(panel(sendID:))
    }

    /// Re-ranks ⌘Z after anything that could change its owner: a panel's state, a toast, a quick send.
    static func refreshUndoKeyOwner() {
        updateUndoKeyOwner()
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

/// Ranks ⌘Z for the panels: the app's undo center (`MailUndoCenter`), which also knows its toast and the quick replies' countdowns.
@MainActor
protocol UndoKeyArbiter: AnyObject {
    /// The send ⌘Z would cancel with no text in the way, if any.
    func sendOwningCommandZ() -> String?
}

/// Claims ⌘Z while an undo-send panel can take it and the key window has no undo order of its own (Settings,
/// or no window at all). The main window, reader windows and composers rank ⌘Z themselves through Edit › Undo, so the menu
/// item and the key always agree. A text view that can undo typing keeps its ⌘Z (§6.1, row 1).
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
              !(NSApp.keyWindow is MainWindow), !(NSApp.keyWindow is ComposeWindow), !(NSApp.keyWindow is ReaderWindow),
              let owner = UndoSendPanel.undoKeyOwner else { return false }
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable, text.undoManager?.canUndo == true {
            return false
        }
        owner.undo()
        return true
    }
}
