import AppKit
import SSCore
import SSDesign

/// Help me write's card (spec §5.55): app-drawn under the caret, as the link popover is (`raised`, `e2`, radius 8,
/// padding 12, 380 pt wide; `ruleStrong` edge in Increase Contrast). A single-line instruction field (“What should it
/// say?”, optional) beside a small primary Write (↩), and under them one `meta` line: the source in `ink3` (“Claude Opus
/// 5.5 · Anthropic”), so text the model writes is always attributed where it is asked for. With text selected the line
/// leads with “Rewrite selection” and the button is Rewrite.
///
/// The other states replace the line or the row (§5.55's table): Writing (spinner, “Writing…”, Stop esc), a failure
/// (“Couldn't write · Try Again” in `danger`, the reason under it, Open Settings… when the fix is there), Off and
/// needs-setup (the words and Open Settings…). The card shows; `WriteSession` decides.
@MainActor
final class WriteCardView: NSView, NSTextFieldDelegate, QuirePointerCover {
    enum State: Equatable {
        /// No provider chosen in Settings › AI.
        case off
        /// The chosen provider needs a key, a CLI or a sign-in: its words.
        case needsSetup(reason: String)
        case idle
        case writing
        /// The write failed and the field is as it was: the reason, and whether Settings › AI holds the fix.
        case failed(reason: String, offersSettings: Bool)
    }

    static let placeholder = "What should it say?"
    static let offWords = "Help Me Write is off"
    static let writingWords = "Writing\u{2026}"
    static let failureWords = "Couldn\u{2019}t write"
    static let rewriteWords = "Rewrite selection"

    var onWrite: (() -> Void)?
    var onStop: (() -> Void)?
    /// Esc anywhere in the card: the session stops a write, or closes the card.
    var onEscape: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private(set) var state: State = .idle
    private(set) var isRewrite = false
    private(set) var sourceLine = ""

    private let sheet = QuireSheetView(frame: .zero)
    let field = QuireTextField(placeholder: WriteCardView.placeholder)
    let actionButton = QuireButton(title: "Write", variant: .primary, size: .small)
    let settingsButton = QuireButton(title: "Open Settings\u{2026}", variant: .secondary, size: .small)
    let tryAgainLink = SyncLineActionButton()
    let settingsLink = SyncLineActionButton()
    /// The middle dot between Try Again and Open Settings…, as the sync line separates its parts (§4.13).
    private let linkSeparator = NSTextField(labelWithString: "\u{00b7}")
    private let spinner = QuireSpinnerView(size: .small, color: .qInk2)
    private let statusGlyph = NSImageView()
    /// The status line: the source, “Writing…”, or the failure.
    let statusLabel = NSTextField(labelWithString: "")
    /// The failure's reason, or the needs-setup and Off words.
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var isClosing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        sheet.fillColor = .qRaised
        sheet.elevation = Quire.Elevation.e2
        sheet.cornerRadius = Quire.Layout.WriteCard.radius
        sheet.showsEdge = false
        addSubview(sheet)
        let content = sheet.contentView
        field.textField.delegate = self
        field.textField.setAccessibilityLabel("Instruction")
        field.textField.setAccessibilityPlaceholderValue(Self.placeholder)
        actionButton.keycap = "\u{21a9}"
        actionButton.keycapLeads = true
        actionButton.keycapGap = Quire.Layout.WriteCard.buttonGap
        actionButton.target = self
        actionButton.action = #selector(actionPressed(_:))
        settingsButton.target = self
        settingsButton.action = #selector(openSettings(_:))
        tryAgainLink.title = "Try Again"
        tryAgainLink.isAlertLine = true
        tryAgainLink.target = self
        tryAgainLink.action = #selector(tryAgain(_:))
        settingsLink.title = "Open Settings\u{2026}"
        settingsLink.isAlertLine = true
        settingsLink.target = self
        settingsLink.action = #selector(openSettings(_:))
        // Shown at once: the line says Writing… from the first frame, so a spinner that waited would only flicker in.
        spinner.delay = 0
        spinner.setAccessibilityElement(false)
        statusGlyph.imageScaling = .scaleNone
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        messageLabel.maximumNumberOfLines = Int(Quire.Layout.WriteCard.reasonMaxLines)
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.cell?.truncatesLastVisibleLine = true
        linkSeparator.setAccessibilityElement(false)
        // The links last, above the labels: their frames reach past the status line by the focus ring's margin, and the
        // whole 24 pt hit area must answer.
        for view in [field, actionButton, settingsButton, linkSeparator, spinner, statusGlyph, statusLabel, messageLabel,
                     tryAgainLink, settingsLink] as [NSView] {
            content.addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.popover)
        setAccessibilityLabel("Help Me Write")
        apply()
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WriteCardView is built in code")
    }

    override var isFlipped: Bool { true }


    // MARK: Content

    func configure(state: State, isRewrite: Bool, sourceLine: String) {
        let changed = state != self.state || isRewrite != self.isRewrite || sourceLine != self.sourceLine
        self.state = state
        self.isRewrite = isRewrite
        self.sourceLine = sourceLine
        if changed { apply() }
    }

    /// The instruction typed in the field (kept across Stop and a failure).
    var instruction: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    private var showsField: Bool {
        switch state {
        case .idle, .writing, .failed: return true
        case .off, .needsSetup: return false
        }
    }

    @objc private func environmentDidChange(_ note: Notification) {
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func apply() {
        let writing = state == .writing
        field.isHidden = !showsField
        actionButton.isHidden = !showsField
        actionButton.title = writing ? "Stop" : (isRewrite ? "Rewrite" : "Write")
        actionButton.variant = writing ? .secondary : .primary
        actionButton.keycap = writing ? "esc" : "\u{21a9}"
        actionButton.toolTip = writing ? "Stop  esc" : (isRewrite ? "Rewrite  \u{21a9}" : "Write  \u{21a9}")
        settingsButton.isHidden = showsField
        spinner.isHidden = !writing
        if writing { spinner.startAnimation() } else { spinner.stopAnimation() }

        let source = QuireFont.attributedString(sourceLine, role: .meta, color: .qInk3)
        let line = NSMutableAttributedString()
        var glyph: (name: String, color: NSColor)?
        var message: NSAttributedString?
        var links = false
        var settings = false
        switch state {
        case .idle:
            if isRewrite { line.append(QuireFont.attributedString(Self.rewriteWords + " \u{00b7} ", role: .meta, color: .qInk2)) }
            line.append(source)
        case .writing:
            line.append(QuireFont.attributedString(Self.writingWords + " \u{00b7} ", role: .meta, color: .qInk2))
            line.append(source)
        case .failed(let reason, let offersSettings):
            glyph = (Quire.Icon.failed, .qDanger)
            line.append(QuireFont.attributedString(Self.failureWords + " \u{00b7}", role: .meta, color: .qDanger))
            message = QuireFont.attributedString(reason, role: .meta, color: .qInk2)
            links = true
            settings = offersSettings
        case .off:
            message = QuireFont.attributedString(Self.offWords, role: .snippet, color: .qInk)
        case .needsSetup(let reason):
            message = QuireFont.attributedString(reason, role: .snippet, color: .qInk2)
            line.append(source)
        }
        statusLabel.attributedStringValue = line
        statusLabel.isHidden = line.length == 0
        if let glyph {
            statusGlyph.image = QuireSymbol.image(glyph.name, size: .custom(Quire.Layout.WriteCard.statusGlyph, weight: .semibold))
            statusGlyph.contentTintColor = glyph.color
        }
        statusGlyph.isHidden = glyph == nil
        messageLabel.attributedStringValue = message ?? NSAttributedString()
        messageLabel.isHidden = message == nil
        tryAgainLink.isHidden = !links
        settingsLink.isHidden = !settings
        linkSeparator.attributedStringValue = QuireFont.attributedString("\u{00b7}", role: .meta, color: .qInk3)
        linkSeparator.isHidden = !settings
        setAccessibilityValue(accessibilityWords)
        needsLayout = true
    }

    /// What the card says now, for VoiceOver and the app's tests: its status line and its message.
    var accessibilityWords: String {
        var words: [String] = []
        if !statusLabel.stringValue.isEmpty { words.append(statusLabel.stringValue) }
        if case .failed = state { words.append("Try Again") }
        if !messageLabel.stringValue.isEmpty { words.append(messageLabel.stringValue) }
        return words.joined(separator: " ")
    }

    // MARK: Geometry

    private var metrics: (pad: CGFloat, width: CGFloat, field: CGFloat, line: CGFloat) {
        let c = Quire.Layout.WriteCard.self
        return (c.pad, c.width, Quire.Layout.TextField.height, QuireFont.Role.meta.lineHeight)
    }

    private func messageHeight(width: CGFloat) -> CGFloat {
        guard !messageLabel.isHidden else { return 0 }
        let text = messageLabel.attributedStringValue
        let role: QuireFont.Role = state == .off || { if case .needsSetup = state { return true } else { return false } }() ? .snippet : .meta
        let bounds = text.boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lines = min(Quire.Layout.WriteCard.reasonMaxLines, max(1, (ceil(bounds.height) / role.lineHeight).rounded()))
        return lines * role.lineHeight
    }

    /// The card's size for its state: the row, the status line, a failure's reason.
    var preferredSize: NSSize {
        let m = metrics
        let inner = m.width - 2 * m.pad
        var height = m.pad
        switch state {
        case .idle, .writing:
            height += m.field + Quire.Layout.WriteCard.rowGap + m.line
        case .failed:
            let indent = Quire.Layout.WriteCard.statusGlyph + Quire.Layout.WriteCard.statusGlyphGap
            height += m.field + Quire.Layout.WriteCard.rowGap + m.line + messageHeight(width: inner - indent)
        case .off:
            height += m.field
        case .needsSetup:
            let words = inner - Quire.Layout.WriteCard.buttonGap - settingsButton.intrinsicContentSize.width
            height += max(m.field, messageHeight(width: words)) + Quire.Layout.WriteCard.rowGap + m.line
        }
        return NSSize(width: m.width, height: ceil(height + m.pad))
    }

    override func layout() {
        super.layout()
        let m = metrics
        let c = Quire.Layout.WriteCard.self
        sheet.frame = bounds
        let inner = bounds.width - 2 * m.pad
        var y = m.pad
        if showsField {
            let button = actionButton.intrinsicContentSize
            let buttonX = bounds.width - m.pad - button.width
            actionButton.frame = actionButton.frame(forVisualRect: NSRect(x: buttonX, y: y + (m.field - button.height) / 2,
                                                                         width: button.width, height: button.height))
            let fieldWidth = max(40, buttonX - c.buttonGap - m.pad)
            field.frame = field.frame(forVisualRect: NSRect(x: m.pad, y: y, width: fieldWidth, height: m.field))
            y += m.field + c.rowGap
            layoutStatusLine(y: y, width: inner)
            y += m.line
            if !messageLabel.isHidden {
                // Under the failure's words, past its glyph, so the reason reads as their continuation.
                let indent = statusGlyph.isHidden ? 0 : c.statusGlyph + c.statusGlyphGap
                messageLabel.frame = NSRect(x: m.pad + indent, y: y, width: inner - indent, height: messageHeight(width: inner - indent))
            }
        } else {
            let button = settingsButton.intrinsicContentSize
            let buttonX = bounds.width - m.pad - button.width
            let wordsWidth = max(40, buttonX - c.buttonGap - m.pad)
            let rowHeight = max(m.field, messageHeight(width: wordsWidth))
            settingsButton.frame = settingsButton.frame(forVisualRect: NSRect(x: buttonX, y: y + (rowHeight - button.height) / 2,
                                                                             width: button.width, height: button.height))
            let wordsHeight = messageHeight(width: wordsWidth)
            messageLabel.frame = NSRect(x: m.pad, y: (y + (rowHeight - wordsHeight) / 2).rounded(), width: wordsWidth, height: wordsHeight)
            y += rowHeight + c.rowGap
            layoutStatusLine(y: y, width: inner)
        }
        pointerRegionsDidChange()
    }

    private func layoutStatusLine(y: CGFloat, width: CGFloat) {
        let m = metrics
        let c = Quire.Layout.WriteCard.self
        var x = m.pad
        if !spinner.isHidden {
            let side = spinner.intrinsicContentSize.width
            spinner.frame = NSRect(x: x, y: (y + (m.line - side) / 2).rounded(), width: side, height: side)
            x += side + c.statusGlyphGap
        }
        if !statusGlyph.isHidden {
            statusGlyph.frame = NSRect(x: x - 1, y: (y + (m.line - c.statusGlyph) / 2).rounded(), width: c.statusGlyph, height: c.statusGlyph)
            x += c.statusGlyph + c.statusGlyphGap
        }
        // A label draws its text `labelInset` in from each edge; `x` follows the text, not the frames.
        let inset = Self.labelInset
        let labelWidth = ceil(statusLabel.attributedStringValue.size().width) + 2 * inset
        statusLabel.frame = NSRect(x: x - inset, y: y, width: max(0, min(labelWidth, m.pad + width - x + inset)), height: m.line)
        x = statusLabel.frame.maxX - inset
        // “Couldn't write · Try Again · Open Settings…”: one space of the line's own type on each side of every dot.
        let space = ceil(QuireFont.attributedString(" ", role: .meta, color: .qInk3).size().width)
        for link in [tryAgainLink, settingsLink] where !link.isHidden {
            if link === settingsLink, !linkSeparator.isHidden {
                let dot = ceil(linkSeparator.attributedStringValue.size().width)
                linkSeparator.frame = NSRect(x: x + space - inset, y: y, width: dot + 2 * inset, height: m.line)
                x += space + dot
            }
            // Placed by its visual rect, as the sync line places its link: the frame adds the focus ring's margin, so the
            // ring, the 24 pt hit area and the text all sit where the face is.
            let size = link.intrinsicContentSize
            let visual = NSRect(x: x + space - SyncLineActionButton.padX, y: (y + (m.line - size.height) / 2).rounded(),
                                width: size.width, height: size.height)
            link.frame = link.frame(forVisualRect: visual)
            x = link.alignmentRect(forFrame: link.frame).maxX - SyncLineActionButton.padX
        }
    }

    /// How far an `NSTextField` label draws its text in from each edge.
    private static let labelInset: CGFloat = 2

    // MARK: Pointer

    /// The arrow over the card around its field and buttons, which keep their own I-beam and hand (§4.17). It lies on the
    /// reader's page, the quick reply or the composer's body, whose pointers would otherwise show through it.
    var pointerRegions: [QuirePointerRegion] {
        QuirePointerRegion.regions(bounds, cursor: .arrow, cutting: childPointerAreas())
    }

    override func resetCursorRects() {
        addPointerRects()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointerCoverDidChange()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let old = frame.origin
        super.setFrameOrigin(newOrigin)
        if frame.origin != old { pointerCoverDidChange() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        if frame.size != old { pointerCoverDidChange() }
    }

    // MARK: Showing

    /// Adds the card to `host` at `frame` and fades it in (`dur.quick`). Focus is the session's to give.
    func present(in host: NSView, frame: NSRect) {
        self.frame = frame
        alphaValue = 0
        host.addSubview(self, positioned: .above, relativeTo: nil)
        layoutSubtreeIfNeeded()
        wantsLayer = true
        Quire.Motion.run(Quire.Motion.quick, .settle, reduced: .keep, participants: [self]) { _ in
            self.animator().alphaValue = 1
        }
    }

    /// Fades the card out and removes it.
    func dismiss() {
        guard !isClosing else { return }
        isClosing = true
        spinner.stopAnimation()
        Quire.Motion.run(Quire.Motion.quick, .leave, reduced: .keep, participants: [self]) { _ in
            self.animator().alphaValue = 0
        } completion: { [weak self] in
            self?.removeFromSuperview()
        }
    }

    /// Puts the keyboard in the instruction field, writing or not, so Esc and ↩ reach the card and no single-key command
    /// of the window fires while a reply is asked for (§6). False in the states without a field (Off, needs setup), where
    /// the keyboard stays in the text.
    @discardableResult
    func takeFocus() -> Bool {
        guard showsField, let window else { return false }
        if !holdsFocus { window.makeFirstResponder(field.textField) }
        return true
    }

    /// Keeps the keyboard on the card itself in a state without a field: the instruction field it was in went away
    /// (needs setup, found after the card opened), and keys meant for it must not land in the reply. ↩ opens Settings,
    /// Esc closes the card and gives the keyboard back to the text; other keys go nowhere.
    func holdKeyboard() {
        guard !showsField, let window else { return }
        holdsKeyboard = true
        if !window.makeFirstResponder(self) { holdsKeyboard = false }
    }

    /// Only `holdKeyboard` makes the card itself the first responder: a click on it never takes the keyboard from the text.
    private var holdsKeyboard = false

    override var acceptsFirstResponder: Bool { holdsKeyboard && !showsField }

    override func resignFirstResponder() -> Bool {
        holdsKeyboard = false
        return super.resignFirstResponder()
    }

    /// Whether the keyboard is in the card (its field's editor included).
    var holdsFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self { return true }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let owner = editor.delegate as? NSView {
            return owner.isDescendant(of: self)
        }
        return (responder as? NSView)?.isDescendant(of: self) ?? false
    }

    // MARK: Actions

    @objc private func actionPressed(_ sender: Any?) {
        if state == .writing { onStop?() } else { onWrite?() }
    }

    @objc private func tryAgain(_ sender: Any?) {
        onWrite?()
    }

    @objc private func openSettings(_ sender: Any?) {
        onOpenSettings?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if state != .writing { onWrite?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
            return true
        default:
            return false
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        // ↩ on the card itself (Off and needs-setup show only Open Settings…) does what its button says.
        if event.keyCode == 36 || event.keyCode == 76 {
            if !showsField { onOpenSettings?() } else if state != .writing { onWrite?() }
            return
        }
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        // Holding the keyboard, the rest of what was being typed for the instruction goes nowhere: not into the reply, and
        // not to a single-key command (`KeyboardRouter.isTextInput` counts the card as text). Tab still moves on.
        if holdsKeyboard, event.modifierFlags.intersection([.command, .control]).isEmpty,
           event.specialKey != .tab, event.specialKey != .backTab {
            return
        }
        super.keyDown(with: event)
    }

    /// The card holds the keyboard itself (`holdKeyboard`): it takes the keys a text field would.
    var takesTyping: Bool { holdsKeyboard && window?.firstResponder === self }

    override func mouseDown(with event: NSEvent) {
        // Clicks on the card's own surface stay in it.
    }
}
