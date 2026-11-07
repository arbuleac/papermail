import AppKit
import SSCore
import SSDesign

/// The sync status line (spec §5.11): 28 pt at the bottom of the list pane, always present so the list never
/// changes height. A top hairline, 16 pt padding, a 12 pt glyph or spinner, 6 pt, then the lead phrase in
/// `metaMedium` `ink2` and the rest in `meta` `ink3` (the whole line in `danger` for Sign in required and
/// errors), and the trailing action link in `metaStrong` `accent`. While mail downloads, a contrail runs along
/// the top edge; behind Up to date it shows older mail's progress only while the total is known.
///
/// The line is a button: a click (or Space and Return with Full Keyboard Access, the only way it takes focus)
/// opens Settings › Accounts, and hovering shows every account's state as a tooltip. Its action link joins the
/// Tab order whenever it is there, because no other surface offers Reconnect, Retry or Cancel in place.
@MainActor
final class SyncStatusBar: QuireControl {
    static let height: CGFloat = Quire.Layout.SyncLine.height

    /// A click on the line: Settings › Accounts.
    var onOpenSettings: (() -> Void)?
    /// The trailing link was used.
    var onAction: ((SyncLineSummary.Action) -> Void)?

    private(set) var summary = SyncLineSummary(state: .upToDate, glyph: .upToDate, lead: "Up to date")
    private var hasApplied = false

    /// Reconnect and Retry wait while another sign-in runs (§5.44); Cancel never does.
    var actionsEnabled = true { didSet { updateAction() } }

    let actionButton = SyncLineActionButton(frame: .zero)
    private let spinner = QuireSpinnerView(size: .small, color: .qInk3)
    private let contrail = QuireContrailView(mode: .indeterminate)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Without an action the line is reachable only with Full Keyboard Access (§5.11).
        requiresFullKeyboardAccess = true
        actionButton.target = self
        actionButton.action = #selector(actionClicked(_:))
        actionButton.isHidden = true
        contrail.isHidden = true
        addSubview(contrail)
        addSubview(spinner)
        addSubview(actionButton)
        apply(summary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Geometry

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
    override var hitRect: NSRect { bounds }
    override var faceRect: NSRect { bounds }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    private var glyphRect: NSRect {
        let s = Quire.Layout.SyncLine.self
        return NSRect(x: s.padX, y: ((bounds.height - s.glyph) / 2).rounded(), width: s.glyph, height: s.glyph)
    }

    /// Frames are set by hand; a new size lays the contents out again.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let s = Quire.Layout.SyncLine.self
        let d = QuireSpinnerView.Size.small.diameter
        spinner.frame = NSRect(x: glyphRect.midX - d / 2, y: (bounds.midY - d / 2).rounded(), width: d, height: d)
        let size = actionButton.intrinsicContentSize
        let visual = NSRect(x: bounds.width - s.padX - size.width, y: ((bounds.height - size.height) / 2).rounded(),
                            width: size.width, height: size.height)
        actionButton.frame = actionButton.frame(forVisualRect: visual)
        let head = Quire.Layout.Progress.contrailHead
        let line = Quire.Layout.Progress.contrail
        // The contrail's line lies on the top edge.
        contrail.frame = NSRect(x: 0, y: -(head - line) / 2, width: bounds.width, height: head)
    }

    // MARK: State

    func apply(_ summary: SyncLineSummary) {
        // Every status update and the check's 250 ms tick re-apply; an unchanged line neither lays out nor draws.
        guard summary != self.summary || !hasApplied else { return }
        hasApplied = true
        let changedSpinner = (summary.glyph == .spinner) != (self.summary.glyph == .spinner)
        self.summary = summary
        toolTip = summary.tooltip
        if summary.glyph == .spinner {
            if changedSpinner || !spinner.isAnimating { spinner.startAnimation() }
        } else {
            spinner.stopAnimation()
        }
        // Older mail behind Up to date shows only a known fraction: an indeterminate sweep would read as the
        // mailbox being busy when new mail is already current.
        if summary.state == .downloading || summary.progress != nil {
            // Set only on a change: re-setting the mode would restart the sweep on every status update.
            let mode: QuireProgressMode = summary.progress.map { .determinate($0) } ?? .indeterminate
            if contrail.mode != mode || contrail.isHidden { contrail.mode = mode }
            contrail.isHidden = false
        } else {
            contrail.isHidden = true
        }
        updateAction()
        setAccessibilityLabel(summary.spokenText)
        needsLayout = true
        needsDisplay = true
    }

    private func updateAction() {
        if let action = summary.action {
            actionButton.title = action.title
            actionButton.isHidden = false
            actionButton.isEnabled = actionsEnabled || action == .cancelSignIn
            actionButton.isAlertLine = summary.isAlert
            actionButton.setAccessibilityLabel(action.title)
        } else {
            if actionButton.window?.firstResponder === actionButton { window?.makeFirstResponder(nil) }
            actionButton.isHidden = true
        }
        needsLayout = true
    }

    @objc private func actionClicked(_ sender: Any?) {
        guard let action = summary.action else { return }
        onAction?(action)
    }

    override func activate() {
        onOpenSettings?()
    }

    override func keyDown(with event: NSEvent) {
        if event.isPlainReturn {
            activate()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        // Views do not clip to their bounds by default, so the fill is limited to them by hand.
        dirtyRect.intersection(bounds).fill()
        QuireHairline.fill(along: bounds, orientation: .horizontal, width: QuireHairline.width(for: self), color: .qRule,
                           atMaxEdge: false, flipped: true)
        let s = Quire.Layout.SyncLine.self
        let glyph = glyphRect
        if let (name, color) = symbol(for: summary.glyph) {
            QuireSymbol.draw(name, size: .custom(s.glyph - 1), color: color, centredIn: glyph)
        }
        let text = NSMutableAttributedString(attributedString: QuireFont.attributedString(
            summary.lead, role: .metaMedium, color: summary.isAlert ? .qDanger : .qInk2))
        if let detail = summary.detail {
            text.append(QuireFont.attributedString(" · " + detail, role: .meta, color: summary.isAlert ? .qDanger : .qInk3))
        }
        let x = glyph.maxX + s.gap
        let end = actionButton.isHidden ? bounds.width - s.padX : actionButton.alignmentRect(forFrame: actionButton.frame).minX - 8
        let lineHeight = QuireFont.Role.meta.lineHeight
        text.draw(with: NSRect(x: x, y: ((bounds.height - lineHeight) / 2).rounded(), width: max(0, end - x), height: lineHeight),
                  options: QuireFont.drawingOptions, context: nil)
        if showsFocusRing {
            QuireFocusRing.drawInset(in: bounds.insetBy(dx: 2, dy: 2), cornerRadius: Quire.Radius.sm)
        }
    }

    private func symbol(for glyph: SyncLineSummary.Glyph) -> (String, NSColor)? {
        switch glyph {
        case .upToDate: return (Quire.Icon.upToDate, .qInk3)
        case .spinner: return nil
        case .offline: return (Quire.Icon.offline, .qInk2)
        case .retrying: return (Quire.Icon.retrying, .qWarning)
        case .alert: return (Quire.Icon.error, .qDanger)
        case .info: return (Quire.Icon.demo, .qInk3)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    // MARK: Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityHelp() -> String? { "Opens Settings, Accounts" }
}

/// The sync line's trailing link (Reconnect, Retry, Cancel): `metaStrong` in `accent`, never a wash. Hover adds
/// the underline, a press turns the label `ink2`, and focus rings the link (radius `r.sm`).
@MainActor
final class SyncLineActionButton: QuireControl {
    var title = "" { didSet { if oldValue != title { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    /// On a `danger` line the link keeps `accent`: it is the remedy, not part of the alarm.
    var isAlertLine = false

    private static let padX: CGFloat = 3

    private func label(_ color: NSColor) -> NSAttributedString {
        QuireFont.attributedString(title, role: .metaStrong, color: color)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label(.black).size().width) + 2 * Self.padX, height: QuireFont.Role.metaStrong.lineHeight + 2)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Tab lands on the link and ↩ runs it (§5.11), as Space does.
    override func keyDown(with event: NSEvent) {
        if isEnabled, event.isPlainReturn {
            activate()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let face = faceRect
        let state = interactionState
        let color: NSColor = !isEnabled ? .qInkDisabled : (state == .pressed ? .qInk2 : .qAccent)
        let text = label(color)
        let width = ceil(text.size().width)
        let lineHeight = QuireFont.Role.metaStrong.lineHeight
        let textRect = NSRect(x: face.minX + Self.padX, y: (face.midY - lineHeight / 2).rounded(), width: width + 1, height: lineHeight)
        text.draw(with: textRect, options: QuireFont.drawingOptions, context: nil)
        if isEnabled, state != .rest || QuireEnvironment.isGraphite {
            color.setFill()
            NSRect(x: textRect.minX, y: (face.midY + lineHeight / 2 - 2).rounded(), width: width, height: 1).fill()
        }
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: Quire.Radius.sm)
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? title }
}

extension SyncStatusBar: ShellKeyHandling {
    /// ↩ opens Settings › Accounts from the focused line (§5.11).
    func handlesKey(_ event: NSEvent) -> Bool { event.isPlainReturn }
}

extension SyncLineActionButton: ShellKeyHandling {
    /// ↩ runs the focused link: Reconnect, Retry or Cancel (§5.11).
    func handlesKey(_ event: NSEvent) -> Bool { isEnabled && event.isPlainReturn }
}
