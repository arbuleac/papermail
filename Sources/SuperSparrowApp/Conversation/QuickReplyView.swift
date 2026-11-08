import AppKit
import SSCore
import SSDesign

/// The quick reply bar (spec §5.18): docked to the bottom of the reader and drawn over the web view, which
/// is told the bar's height as a bottom inset instead of being resized. The field sits on the reading column;
/// at rest it is one 38 pt line with the replying account's face, the R keycap and a send glyph; focused it
/// grows with the text to five lines and shows the tool row (Reply · Reply all, Attach, Open in Composer, Send).
///
/// The view owns no mail logic: it reports the text on ⌘↩ and the commands of its buttons, and shows the
/// strip and the states its owner asks for.
@MainActor
final class QuickReplyView: NSView {
    enum Mode: Int, Equatable {
        case reply = 0
        case replyAll = 1
    }

    /// What the tool row's leading status says instead of the mode tabs.
    enum Status: Equatable {
        case none
        /// The send could not be queued: 1.5 pt danger edge, text kept, Send stays enabled to retry.
        case error
        /// The reply has no recipients: Send disabled, Open in Composer available.
        case noRecipients
        /// The countdown went on after the field came back for a new reply.
        case counting(endsAt: Date)
    }

    var onSend: ((String, Mode) -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    /// The bar's height changed; the owner moves the web view's bottom inset, once per change.
    var onHeightChange: ((CGFloat) -> Void)?
    var onOpenInComposer: ((String, Mode) -> Void)?
    /// Attach (⇧⌘A): the reply moves to the composer, which then asks for the files.
    var onAttach: ((String, Mode) -> Void)?
    var onUndo: (() -> Void)?
    var onShowDraft: (() -> Void)?
    /// A click on the field while a composer holds this conversation's draft.
    var onDisabledClick: (() -> Void)?

    /// The replying account's rail face (spec §5.18).
    /// The reader sets these on every selection change (key repeat included), so each one acts only on a change.
    var face: (monogram: String, inkSlot: Int)? {
        didSet { if oldValue?.monogram != face?.monogram || oldValue?.inkSlot != face?.inkSlot { needsDisplay = true } }
    }

    var replyName = "" { didSet { if oldValue != replyName { updatePlaceholder() } } }
    var replyAllName = "" { didSet { if oldValue != replyAllName { updatePlaceholder() } } }
    var replyAllAvailable = true {
        didSet {
            guard oldValue != replyAllAvailable else { return }
            tabs.items = Self.tabItems(replyAll: replyAllAvailable)
            if !replyAllAvailable, mode == .replyAll { mode = .reply }
        }
    }

    var mode: Mode = .reply {
        didSet {
            tabs.selectedIndex = mode.rawValue
            updatePlaceholder()
        }
    }

    var status: Status = .none {
        didSet { if oldValue != status { statusDidChange() } }
    }

    /// A composer window holds this conversation's draft: the field is a quiet `fill` that brings it forward.
    var isComposerOpen = false {
        didSet {
            guard oldValue != isComposerOpen else { return }
            if isComposerOpen { blur() }
            // VoiceOver hears a dimmed field that cannot be typed in; a click still brings the composer forward.
            textView.setAccessibilityEnabled(!isComposerOpen)
            updatePlaceholder()
            updateHeight(animated: false)
            needsDisplay = true
            needsLayout = true
        }
    }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textDidChange()
        }
    }

    private(set) var isFocused = false
    private(set) var barHeight: CGFloat = Quire.Layout.QuickReply.rest
    var stripState: QuickReplyStripView.State? { strip.state }

    private let scrollView = NSScrollView()
    private let textView = QuickReplyTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let restSend = QuireIconButton(symbolName: Quire.Icon.send, size: .large, accessibilityLabel: "Send")
    private let restKeycap = QuireKeycap("R")
    private let tabs = QuireUnderlineTabs(items: QuickReplyView.tabItems(replyAll: true))
    private let attach = QuireIconButton(symbolName: Quire.Icon.attach, size: .small, accessibilityLabel: "Attach")
    private let openInComposer = QuireIconButton(symbolName: Quire.Icon.openInComposer, size: .small, accessibilityLabel: "Open in Composer")
    private let send = QuireButton(title: "Send", variant: .primary, size: .small)
    private let statusGlyph = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusAction = QuireButton(title: "Undo", variant: .link, size: .small)
    private let statusContrail = QuireContrailView(mode: .determinate(0))
    private let strip = QuickReplyStripView()
    private var heightConstraint: NSLayoutConstraint!
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    private var stripTimer: Timer?
    private var statusTicker: Timer?

    private static let lineHeight = QuireFont.Role.writing.lineHeight

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        stripTimer?.invalidate()
        statusTicker?.invalidate()
    }

    override var isFlipped: Bool { true }

    private static func tabItems(replyAll: Bool) -> [QuireUnderlineTabs.Item] {
        [QuireUnderlineTabs.Item("Reply", symbolName: Quire.Icon.reply),
         QuireUnderlineTabs.Item("Reply all", symbolName: Quire.Icon.replyAll, isEnabled: replyAll)]
    }

    // MARK: Building

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = false
        addSubview(scrollView)

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        if let layoutManager = textView.layoutManager { QuireFont.configure(layoutManager) }
        let writing = QuireFont.attributes(.writing, color: .qInk)
        textView.font = writing[.font] as? NSFont
        textView.textColor = .qInk
        textView.typingAttributes = writing
        textView.defaultParagraphStyle = writing[.paragraphStyle] as? NSParagraphStyle
        textView.insertionPointColor = .qAccent
        textView.isRichText = false
        textView.allowsUndo = true
        // Spelling checked as you type, grammar not, as in the composer: a text view built in code does not check as you
        // type, so a reply typed here went unchecked where the same reply in a composer did not.
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.delegate = self
        textView.onCommandReturn = { [weak self] in self?.sendPressed() }
        textView.onOpenInComposer = { [weak self] in self?.openInComposerPressed() }
        textView.onAttach = { [weak self] in self?.attachPressed() }
        // The placeholder is a separate label that goes away while typing, so the field carries its own name.
        textView.setAccessibilityLabel("Reply")
        textView.onEscape = { [weak self] in self?.escape() }
        textView.onFocusChange = { [weak self] focused in self?.focusDidChange(focused) }

        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.maximumNumberOfLines = 1
        placeholder.cell?.truncatesLastVisibleLine = true
        placeholder.isSelectable = false
        placeholder.setAccessibilityElement(false)
        addSubview(placeholder)

        restSend.target = self
        restSend.action = #selector(sendPressed)
        restSend.toolTip = "Send  ⌘↩"
        addSubview(restSend)
        addSubview(restKeycap)

        tabs.onChange = { [weak self] index in
            guard let self else { return }
            self.mode = Mode(rawValue: index) ?? .reply
            self.focus()
        }
        addSubview(tabs)
        attach.target = self
        attach.action = #selector(attachPressed)
        attach.toolTip = "Attach Files…  ⇧⌘A"
        addSubview(attach)
        openInComposer.target = self
        openInComposer.action = #selector(openInComposerPressed)
        openInComposer.toolTip = "Open in Composer  ⇧⌘R"
        addSubview(openInComposer)
        send.keycap = "⌘↩"
        send.keycapLeads = true
        send.keycapGap = Quire.Layout.QuickReply.sendKeycapGap
        send.target = self
        send.action = #selector(sendPressed)
        addSubview(send)

        statusGlyph.imageScaling = .scaleNone
        addSubview(statusGlyph)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(statusLabelClicked)))
        addSubview(statusLabel)
        statusAction.target = self
        statusAction.action = #selector(statusActionPressed)
        addSubview(statusAction)
        addSubview(statusContrail)

        strip.isHidden = true
        strip.onUndo = { [weak self] in self?.onUndo?() }
        strip.onShow = { [weak self] in self?.onShowDraft?() }
        strip.onDismiss = { [weak self] in self?.stripDismissed() }
        addSubview(strip)

        heightConstraint = heightAnchor.constraint(equalToConstant: Quire.Layout.QuickReply.rest)
        heightConstraint.isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
        updatePlaceholder()
        statusDidChange()
    }

    /// Graphite and Increase Contrast change token values (the ring, the edges) without changing the appearance.
    @objc private func environmentDidChange(_ note: Notification) {
        updatePlaceholder()
        statusDidChange()
        needsDisplay = true
    }

    // MARK: Public controls

    func focus() {
        guard !isComposerOpen else { return }
        if !strip.isHidden, case .counting = strip.state { stripDismissed() }
        window?.makeFirstResponder(textView)
    }

    func focus(mode: Mode) {
        if mode == .replyAll, !replyAllAvailable { self.mode = .reply } else { self.mode = mode }
        focus()
    }

    /// Hands focus back to the window; the owner decides where it goes next via `onEscape`.
    func blur() {
        if window?.firstResponder === textView { window?.makeFirstResponder(nil) }
    }

    func clear() {
        text = ""
        status = .none
        updateHeight(animated: true)
    }

    func restoreDraft(_ draft: String) {
        text = draft
        updateHeight(animated: false)
    }

    // MARK: Strip

    /// Puts the strip over the field: the countdown, or an outcome that leaves by itself after its time.
    func showStrip(_ state: QuickReplyStripView.State) {
        stripTimer?.invalidate()
        stripTimer = nil
        if status != .none, case .counting = status { status = .none }
        strip.apply(state)
        strip.isHidden = false
        hideFieldContents(true)
        let life: TimeInterval?
        switch state {
        case .counting: life = nil
        case .sent: life = Quire.Motion.sentConfirm
        case .queuedOffline, .alreadySent, .notSent: life = Quire.Motion.stripNotice
        }
        if let life {
            stripTimer = Timer.scheduledTimer(withTimeInterval: life, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideStrip(fade: true) }
            }
        }
        needsLayout = true
    }

    /// Closes the strip; the field comes back (cross-fade `dur.quick` after an outcome, at once after Undo).
    func hideStrip(fade: Bool = false) {
        stripTimer?.invalidate()
        stripTimer = nil
        if case .counting = status { status = .none }
        guard !strip.isHidden else { return }
        strip.apply(nil)
        if fade, let layer = strip.layer ?? { strip.wantsLayer = true; return strip.layer }() {
            Quire.Motion.animate(layer, keyPath: "opacity", to: 0, duration: Quire.Motion.quick, curve: .leave, reduced: .keep) { [weak self] in
                guard let self else { return }
                self.strip.isHidden = true
                layer.opacity = 1
                self.hideFieldContents(false)
            }
        } else {
            strip.isHidden = true
            hideFieldContents(false)
        }
        needsLayout = true
    }

    /// The countdown, if one is running, so the bar can hand it to an undo panel when it hides.
    var countdownEnd: Date? {
        if case let .counting(endsAt, _, _) = strip.state { return endsAt }
        if case let .counting(endsAt) = status { return endsAt }
        return nil
    }

    private func stripDismissed() {
        guard case let .counting(endsAt, _, _) = strip.state else { return }
        hideStrip()
        status = .counting(endsAt: endsAt)
        window?.makeFirstResponder(textView)
    }

    private func hideFieldContents(_ hidden: Bool) {
        scrollView.isHidden = hidden
        placeholder.isHidden = hidden || !text.isEmpty
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Geometry

    private var showsKeycaps: Bool { ReaderColumn.showsKeycaps(readerWidth: bounds.width) }

    /// Text lines, 1 to 5; past five the text scrolls inside the field.
    private var lineCount: Int {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return 1 }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let lines = Int(ceil(max(used, Self.lineHeight) / Self.lineHeight - 0.01))
        return max(1, min(Int(Quire.Layout.QuickReply.maxLines), lines))
    }

    /// Field height: 9 + lines × 21 + 8 at rest (one line), 9 + lines × 21 + 4 + 28 + 4 focused (spec §5.18).
    private var fieldHeight: CGFloat {
        let m = Quire.Layout.QuickReply.self
        guard isFocused, !isComposerOpen else { return m.field }
        return min(m.fieldMax, m.fieldPadTop + CGFloat(lineCount) * Self.lineHeight + m.toolRowGap + m.toolRow + m.toolRowBottom)
    }

    private var fieldRect: NSRect {
        let column = ReaderColumn.frame(readerWidth: bounds.width)
        let m = Quire.Layout.QuickReply.self
        return NSRect(x: column.x, y: m.barPadY, width: column.width, height: max(m.field, bounds.height - 2 * m.barPadY))
    }

    private var showsToolRow: Bool { isFocused && !isComposerOpen && strip.isHidden }

    private func updateHeight(animated: Bool) {
        let target = min(Quire.Layout.QuickReply.max, fieldHeight + 2 * Quire.Layout.QuickReply.barPadY)
        guard abs(heightConstraint.constant - target) > 0.5 else {
            needsLayout = true
            return
        }
        barHeight = target
        onHeightChange?(target)
        if animated, window != nil {
            Quire.Motion.run(Quire.Motion.standard, .glide, reduced: .instant, participants: [self]) { _ in
                heightConstraint.animator().constant = target
                superview?.layoutSubtreeIfNeeded()
            }
        } else {
            heightConstraint.constant = target
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let m = Quire.Layout.QuickReply.self
        let field = fieldRect
        let keycaps = showsKeycaps
        let toolRow = showsToolRow
        let trailing = toolRow ? m.focusedTrailing : m.restTrailing
        let textWidth = max(0, field.width - m.textX - trailing)
        let lines = isFocused ? lineCount : 1
        scrollView.frame = NSRect(x: field.minX + m.textX, y: field.minY + m.fieldPadTop, width: textWidth, height: CGFloat(lines) * Self.lineHeight)
        textView.frame.size.width = scrollView.contentSize.width
        scrollView.hasVerticalScroller = isFocused && lineCount >= Int(m.maxLines)
        let placeholderHeight = ReaderFonts.fieldHeight(placeholder)
        placeholder.frame = NSRect(x: field.minX + m.textX - 2, y: (field.minY + m.fieldPadTop + (Self.lineHeight - placeholderHeight) / 2).rounded(),
                                   width: textWidth + 4, height: placeholderHeight)
        // Unfocused with text, the field shows its first line tail-truncated so the reader does not jump.
        let showsPreview = !isFocused && !text.isEmpty && strip.isHidden
        scrollView.isHidden = !strip.isHidden || showsPreview
        placeholder.isHidden = !strip.isHidden || (!text.isEmpty && !showsPreview)

        let restVisible = !toolRow && strip.isHidden && !isComposerOpen
        restSend.isHidden = !restVisible
        restKeycap.isHidden = !restVisible || !keycaps
        restSend.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status != .noRecipients
        let sendRect = NSRect(x: field.maxX - m.restSendInset - m.restSend, y: field.minY + m.restSendInset, width: m.restSend, height: m.restSend)
        restSend.frame = restSend.frame(forVisualRect: sendRect)
        let cap = restKeycap.intrinsicContentSize
        restKeycap.frame = NSRect(x: sendRect.minX - m.restKeycapGap - cap.width, y: (field.minY + m.field / 2 - cap.height / 2).rounded(),
                                  width: cap.width, height: cap.height)

        let rowY = field.minY + m.fieldPadTop + CGFloat(lines) * Self.lineHeight + m.toolRowGap
        let showsStatus = status != .none
        tabs.isHidden = !toolRow || showsStatus
        attach.isHidden = !toolRow || showsStatus
        openInComposer.isHidden = !toolRow || (showsStatus && status == .error)
        send.isHidden = !toolRow
        send.keycap = keycaps ? "⌘↩" : nil
        send.isEnabled = status != .noRecipients && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.toolTip = status == .noRecipients ? "No one to reply to" : "Send  ⌘↩"
        let tabSize = tabs.intrinsicContentSize
        tabs.frame = tabs.frame(forVisualRect: NSRect(x: field.minX + m.textX, y: rowY, width: tabSize.width, height: m.toolRow))
        var x = field.minX + m.textX + tabSize.width + m.toolGroupGap
        let iconY = rowY + (m.toolRow - m.toolIcon) / 2
        attach.frame = attach.frame(forVisualRect: NSRect(x: x, y: iconY, width: m.toolIcon, height: m.toolIcon))
        x += m.toolIcon + m.toolIconGap
        let composerX = showsStatus ? nil : x
        send.sizeToFit()
        let sendSize = send.alignmentRect(forFrame: send.frame).size
        let sendVisual = NSRect(x: field.maxX - m.sendInset - sendSize.width, y: rowY + (m.toolRow - sendSize.height) / 2,
                                width: sendSize.width, height: sendSize.height)
        send.frame = send.frame(forVisualRect: sendVisual)

        // The leading status replaces the tabs and tools; Open in Composer follows it when it applies.
        statusGlyph.isHidden = !toolRow || !showsStatus || { if case .counting = status { return true } else { return false } }()
        statusLabel.isHidden = !toolRow || !showsStatus
        statusAction.isHidden = !toolRow || !showsStatus
        statusContrail.isHidden = true
        if toolRow, showsStatus {
            var sx = field.minX + m.textX
            if !statusGlyph.isHidden {
                statusGlyph.frame = NSRect(x: sx - 1, y: rowY + (m.toolRow - 14) / 2, width: 14, height: 14)
                sx += 12 + 6
            }
            let labelWidth = ceil(statusLabel.attributedStringValue.size().width) + 4
            let labelHeight = ReaderFonts.fieldHeight(statusLabel)
            statusLabel.frame = NSRect(x: sx, y: (rowY + (m.toolRow - labelHeight) / 2).rounded(),
                                       width: min(labelWidth, max(0, sendVisual.minX - sx - 8)), height: labelHeight)
            sx = statusLabel.frame.maxX + 2
            statusAction.sizeToFit()
            let actionSize = statusAction.alignmentRect(forFrame: statusAction.frame).size
            statusAction.frame = statusAction.frame(forVisualRect: NSRect(x: sx, y: rowY + (m.toolRow - actionSize.height) / 2,
                                                                         width: actionSize.width, height: actionSize.height))
            sx += actionSize.width + m.toolGroupGap
            if case .counting = status {
                statusContrail.isHidden = false
                statusContrail.frame = NSRect(x: field.minX + m.textX, y: rowY + m.toolRow - 4, width: max(0, sx - field.minX - m.textX), height: 4)
            }
            if status == .noRecipients {
                openInComposer.frame = openInComposer.frame(forVisualRect: NSRect(x: sx, y: iconY, width: m.toolIcon, height: m.toolIcon))
            }
        } else if let composerX {
            openInComposer.frame = openInComposer.frame(forVisualRect: NSRect(x: composerX, y: iconY, width: m.toolIcon, height: m.toolIcon))
        }

        strip.frame = field.insetBy(dx: 1, dy: 1)
        strip.showsKeycaps = keycaps
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Views no longer clip to their bounds, and the dirty rect can reach past them.
        NSColor.qPaper.setFill()
        bounds.intersection(dirtyRect).fill()
        QuireHairline.fill(along: NSRect(x: 0, y: 0, width: bounds.width, height: 1), orientation: .horizontal,
                           width: QuireHairline.width(for: self), color: .qRule, atMaxEdge: false)
        let m = Quire.Layout.QuickReply.self
        let field = fieldRect
        let radius = m.fieldRadius
        if isComposerOpen {
            QuireDraw.fill(field, radius: radius, .qFill)
            return
        }
        QuireDraw.fill(field, radius: radius, .qSheet)
        if status == .error {
            QuireDraw.strokeInside(field, radius: radius, width: Quire.Border.Error.width, .qDanger)
        } else {
            QuireDraw.strokeInside(field, radius: radius, width: 1, hovering && !isFocused ? .qInk3 : .qRuleStrong)
        }
        if isFocused, window?.isKeyWindow == true {
            QuireFocusRing.draw(around: field, cornerRadius: radius, gap: QuireFocusRing.gap, gapColor: .qPaper)
        }
        if let face, strip.isHidden {
            let rect = NSRect(x: field.minX + m.faceX, y: field.minY + m.faceTop, width: m.face, height: m.face)
            QuireAvatarRenderer.drawAccountFace(monogram: face.monogram, slot: face.inkSlot, in: rect)
            QuireAvatarRenderer.drawRing(around: rect, accountSlot: face.inkSlot)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let inside = fieldRect.contains(convert(event.locationInWindow, from: nil))
        if inside != hovering {
            hovering = inside
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hovering {
            hovering = false
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard fieldRect.contains(point) else { return }
        if isComposerOpen {
            onDisabledClick?()
            return
        }
        focus()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePlaceholder()
        statusDidChange()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowKeyChanged() {
        needsDisplay = true
    }

    // MARK: Behavior

    @objc private func sendPressed() {
        let typed = text
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, status != .noRecipients else { return }
        onSend?(typed, mode)
    }

    @objc private func openInComposerPressed() {
        onOpenInComposer?(text, mode)
    }

    @objc private func attachPressed() {
        if let onAttach { onAttach(text, mode) } else { onOpenInComposer?(text, mode) }
    }

    @objc private func statusLabelClicked() {
        if status == .error { onOpenInComposer?(text, mode) }
    }

    @objc private func statusActionPressed() {
        switch status {
        case .counting: onUndo?()
        case .error: onOpenInComposer?(text, mode)
        case .noRecipients, .none: break
        }
    }

    /// The owner applies the window's Esc order (§6.1: a toast first, then back to the list); with no owner the
    /// field just lets go of focus. The text stays either way.
    private func escape() {
        if let onEscape { onEscape() } else { blur() }
    }

    private func focusDidChange(_ focused: Bool) {
        isFocused = focused
        updateHeight(animated: true)
        needsDisplay = true
        onFocusChange?(focused)
    }

    private func updatePlaceholder() {
        let words: String
        if isComposerOpen {
            words = "Reply in the composer"
        } else if !isFocused, !text.isEmpty {
            let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? text
            placeholder.attributedStringValue = ReaderFonts.fieldString(QuireFont.attributedString(first, role: .writing, color: .qInk))
            return
        } else if mode == .replyAll {
            words = replyAllName.isEmpty ? "Reply all…" : "Reply all to \(replyAllName)…"
        } else {
            words = replyName.isEmpty ? "Reply…" : "Reply to \(replyName)…"
        }
        textView.setAccessibilityPlaceholderValue(words)
        placeholder.attributedStringValue = ReaderFonts.fieldString(QuireFont.attributedString(words, role: .writing, color: .qInk3))
    }

    private func statusDidChange() {
        statusTicker?.invalidate()
        statusTicker = nil
        switch status {
        case .none:
            statusLabel.stringValue = ""
        case .error:
            setStatusGlyph(Quire.Icon.failed, color: .qDanger)
            // One danger phrase (spec §5.18); a click on it opens the composer with the text.
            statusLabel.attributedStringValue = ReaderFonts.fieldString(QuireFont.attributedString(
                "Couldn\u{2019}t send \u{00b7} Open in composer", role: .snippet, color: .qDanger))
            statusAction.title = ""
        case .noRecipients:
            setStatusGlyph(Quire.Icon.warning, color: .qWarning)
            statusLabel.attributedStringValue = ReaderFonts.fieldString(QuireFont.attributedString("No one to reply to", role: .snippet, color: .qInk2))
            statusAction.title = ""
        case .counting(let endsAt):
            statusAction.title = "Undo"
            statusContrail.mode = .countdown(duration: max(1, endsAt.timeIntervalSinceNow), remaining: max(0, endsAt.timeIntervalSinceNow))
            updateCountdownStatus(endsAt)
            statusTicker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCountdownStatus(endsAt) }
            }
        }
        statusAction.isHidden = statusAction.title.isEmpty
        needsLayout = true
        needsDisplay = true
    }

    private func updateCountdownStatus(_ endsAt: Date) {
        let left = max(0, Int(ceil(endsAt.timeIntervalSinceNow)))
        statusLabel.attributedStringValue = ReaderFonts.fieldString(QuireFont.attributedString("Sending in \(left) s \u{00b7}", role: .snippet, color: .qInk2))
        if left == 0 {
            statusTicker?.invalidate()
            statusTicker = nil
        }
        needsLayout = true
    }

    private func setStatusGlyph(_ name: String, color: NSColor) {
        statusGlyph.image = QuireSymbol.image(name, size: .custom(12, weight: .semibold))
        statusGlyph.contentTintColor = color
    }
}

extension QuickReplyView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        textDidChange()
    }

    private func textDidChange() {
        if status == .error || status == .noRecipients, text.isEmpty { status = .none }
        updatePlaceholder()
        placeholder.isHidden = !text.isEmpty && isFocused
        updateHeight(animated: false)
        needsLayout = true
    }
}

/// Catches the keys the delegate protocol cannot: ⌘↩ is not a text command, ⇧⌘R opens the composer, ⇧⌘A
/// attaches there, and Escape must go to the owner rather than cancel completion.
private final class QuickReplyTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    var onOpenInComposer: (() -> Void)?
    var onAttach: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if ReaderShortcuts.isSend(keyCode: event.keyCode, rawModifierFlags: event.modifierFlags.rawValue) {
            onCommandReturn?()
            return
        }
        let chord = ReaderShortcuts.chord(event.modifierFlags.rawValue)
        if chord == ReaderShortcuts.shift | ReaderShortcuts.command, event.charactersIgnoringModifiers?.lowercased() == "r" {
            onOpenInComposer?()
            return
        }
        if chord == ReaderShortcuts.shift | ReaderShortcuts.command, event.charactersIgnoringModifiers?.lowercased() == "a" {
            onAttach?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}
