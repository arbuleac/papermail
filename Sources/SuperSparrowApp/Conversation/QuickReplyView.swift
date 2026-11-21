import AppKit
import SSCore
import SSDesign

/// The quick reply bar (spec §5.18): docked to the bottom of the reader and drawn over the web view, which
/// is told the bar's height as a bottom inset instead of being resized. The field sits on the reading column;
/// at rest it is one 38 pt line with the replying account's face, the R keycap and a send glyph; focused it
/// grows with the text to five lines and shows the tool row (Reply · Reply all, Attach, Open in Composer, Send and its
/// drop-down). Help me write lives in the text itself (§5.56, `WriteInlineLayer`): its prompt line and afterline open a
/// space in the text's flow, and the field grows by it beyond its five lines.
///
/// The view owns no mail logic: it reports the text on ⌘↩ (with what Send does now, `sendAction`) and on ⇧⌘↩ (send and
/// archive), the drop-down's choice and the commands of its buttons, and shows the strip and the states its owner asks for.
///
/// Files, and attachments dragged from a message (§5.17), can be dropped on it while its field takes typing: the field
/// shows Quire's drop treatment with “Drop to reply with attachment”, and the drop is reported with the text and mode, for
/// the owner to move the reply to a composer with them attached.
@MainActor
final class QuickReplyView: NSView, QuirePointerTarget {
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
        /// The countdown went on after the field came back for a new reply; `archived` after Send and Archive.
        case counting(endsAt: Date, archived: Bool)
    }

    /// ⌘↩, Send or the rest glyph (with `sendAction`), or ⇧⌘↩ (`.sendAndArchive`).
    var onSend: ((String, Mode, SendAction) -> Void)?
    /// The drop-down's choice: the owner makes it the default (§5.23). Nothing is sent.
    var onChooseSendAction: ((SendAction) -> Void)?
    /// A Send Later time chosen from the drop-down or ⇧⌘L (§5.23), or nil for Pick a Time…, with the text and mode.
    var onSendLater: ((String, Mode, Date?) -> Void)?
    /// Esc in the field, `repeated` when it is the key's repeat (Esc held down), which never closes a reader window (§6.1).
    var onEscape: ((_ repeated: Bool) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    /// The bar's height changed; the owner moves the web view's bottom inset, once per change.
    var onHeightChange: ((CGFloat) -> Void)?
    var onOpenInComposer: ((String, Mode) -> Void)?
    /// Attach (⇧⌘A): the reply moves to the composer, which then asks for the files.
    var onAttach: ((String, Mode) -> Void)?
    /// Files or the app's own attachments dropped on the bar: the reply moves to the composer with them attached.
    var onDropAttachments: ((String, Mode, [AttachmentDropItem]) -> Void)?
    var onUndo: (() -> Void)?
    var onShowDraft: (() -> Void)?
    /// A click on the field while a composer holds this conversation's draft.
    var onDisabledClick: (() -> Void)?

    /// The replying account's rail face (spec §5.18).
    /// The reader sets these on every selection change (key repeat included), so each one acts only on a change.
    var face: (face: QuireAccountFace, inkSlot: Int)? {
        didSet { if oldValue?.face != face?.face || oldValue?.inkSlot != face?.inkSlot { needsDisplay = true } }
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

    /// What Send, the rest glyph and ⌘↩ do now (§5.23): their tooltips and VoiceOver names say it.
    var sendAction: SendAction = .default {
        didSet { if oldValue != sendAction { sendActionDidChange() } }
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
            if isComposerOpen {
                // The text goes behind “Reply in the composer”: a reply streaming into it stops first (§5.56).
                willHideText?()
                blur()
            }
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
            // A reply streaming in writes the storage itself; any other change to the text ends it first, so the stream
            // never edits text it did not put there (the owner ends Help me write there, putting the field back).
            willReplaceText?()
            textView.string = newValue
            textDidChange()
            // Setting the string reports no edit: Help me write's hint reads the new text here (a send undone or failed
            // puts the draft back while the keyboard may still be in the field).
            onUserEdit?()
        }
    }

    /// Called before the text is set from outside the field (`text`, `clear`, `restoreDraft`): its owner stops Help me
    /// write's write there first.
    var willReplaceText: (() -> Void)?

    /// Called as a composer takes the reply and the field hides behind its quiet fill: its owner closes Help me write's
    /// card there, the field put back, so nothing streams into text no one sees.
    var willHideText: (() -> Void)?

    // MARK: Help me write (§5.56)

    /// The field's text view, which Help me write writes into.
    var writingTextView: NSTextView { textView }

    /// Help me write's prompt line is open or a reply streams in: the bar stays open around its text, as if focused, while
    /// the keyboard is in the prompt line (§5.56).
    var isHeldOpen = false {
        didSet {
            guard oldValue != isHeldOpen else { return }
            updatePlaceholder()
            updateHeight(animated: false)
            needsLayout = true
            needsDisplay = true
        }
    }

    /// While Help me write streams a reply into the field, the user's own edits are refused and nothing sends or is
    /// scheduled: Send, its drop-down and Send Later wait with them, and so does a drop, which would move the half-written
    /// reply to a composer (a drag already over the bar loses its treatment).
    var refusesEdits = false {
        didSet {
            guard oldValue != refusesEdits else { return }
            if refusesEdits { dropOverlay.show(for: nil) }
            needsLayout = true
        }
    }

    /// Asked first on Esc in the field: Help me write takes it to stop a write, close its prompt line or dismiss its
    /// afterline (§6.1) before the window's order runs.
    var claimsEscape: (() -> Bool)?

    /// The user changed the text (typing, a paste, an undo, a reply landing, the text set from outside): Help me write's
    /// marks follow.
    var onUserEdit: (() -> Void)?

    /// The selection in the text changed: Help me write's ghost and pill follow.
    var onSelectionChange: (() -> Void)?

    /// Help me write's group for the text's right-click menu (§5.56), at its top; none while it is off.
    var writeMenuItems: (() -> [NSMenuItem])?

    /// Help me write's marks in the text (§5.56): the pill floats on the bar, out of the text's clip.
    var writeLayer: WriteInlineLayer {
        if let madeWriteLayer { return madeWriteLayer }
        let layer = WriteInlineLayer(textView: textView, floatHost: self)
        textView.markAreas = { [weak layer] in layer?.pointerHoles ?? [] }
        madeWriteLayer = layer
        return layer
    }

    /// A block (the prompt line, the afterline) opened, closed or moved in the text: the text view holds it, and the field
    /// grows by it.
    func writeSpaceDidChange() {
        let block = madeWriteLayer?.blockRect != nil
        textView.minSize = NSSize(width: 0, height: block ? madeWriteLayer?.contentHeight ?? 0 : 0)
        textView.sizeToFit()
        updateHeight(animated: false)
        needsLayout = true
    }

    /// The layer, once Help me write has made it (the bar never makes it for nothing).
    private var madeWriteLayer: WriteInlineLayer?

    /// The block's share of the field's height: all of it, whether it lies inside the text or hangs below its last line.
    /// It does not count against the five lines.
    private var writeSpace: CGFloat {
        guard looksFocused, !isComposerOpen, strip.isHidden else { return 0 }
        return madeWriteLayer?.reservedHeight ?? 0
    }

    /// The block's part inside the text's used rect: lines below it moved down, which `lineCount` must not count as lines.
    private var writeSpaceInText: CGFloat {
        guard let layer = madeWriteLayer else { return 0 }
        return layer.reservedHeight - layer.overflow
    }

    /// Where the ghost starts on an empty reply: after the placeholder's words (“Reply to Sam…”), as one line of ghost
    /// text. nil while the placeholder does not show.
    var placeholderGhostOffset: CGFloat? {
        guard text.isEmpty, looksFocused, !isComposerOpen else { return nil }
        return ceil(placeholder.attributedStringValue.size().width)
    }

    /// The text changed under the field without an edit (a reply streaming in): its height and placeholder follow.
    func textDidChangeByWriting() {
        textDidChange()
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// The bar looks focused: it is, or Help me write's prompt line or a write holds it open.
    private var looksFocused: Bool { isFocused || isHeldOpen }

    private(set) var isFocused = false
    private(set) var barHeight: CGFloat = QuickReplyView.restBarHeight(at: QuireEnvironment.textSize)
    var stripState: QuickReplyStripView.State? { strip.state }

    private let scrollView = NSScrollView()
    private let textView = QuickReplyTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let restSend = QuireIconButton(symbolName: Quire.Icon.send, size: .large, accessibilityLabel: "Send")
    private let restKeycap = QuireKeycap("R")
    private let tabs = QuireUnderlineTabs(items: QuickReplyView.tabItems(replyAll: true))
    private let attach = QuireIconButton(symbolName: Quire.Icon.attach, size: .small, accessibilityLabel: "Attach")
    private let openInComposer = QuireIconButton(symbolName: Quire.Icon.openInComposer, size: .small, accessibilityLabel: "Open in Composer")
    /// Send, the composer's split button at the small size (§5.23): its face carries “⌘↩” and its drop-down. No glyph, as
    /// before: the row is tight, and the bar's rest glyph is already the paper plane.
    private let sendSplit = QuireSplitButton(title: "Send", size: .small, keycap: SendKey.commandReturn.legend,
                                             menuAccessibilityLabel: "Send Options")
    private var send: QuireSplitSegment { sendSplit.actionSegment }
    /// Send's drop-down, its menu segment: the menu that chooses what Send and ⌘↩ do.
    private var sendOptions: QuireSplitSegment { sendSplit.menuSegment }
    private lazy var sendActionMenu = SendActionMenu(choose: { [weak self] action in self?.onChooseSendAction?(action) },
                                                     send: { [weak self] action in self?.send(as: action) },
                                                     sendLater: { [weak self] date in self?.sendLater(at: date) })
    private let statusGlyph = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusAction = QuireButton(title: "Undo", variant: .link, size: .small)
    private let statusContrail = QuireContrailView(mode: .determinate(0))
    private let strip = QuickReplyStripView()
    /// The drop treatment over the field while something that attaches is dragged over the bar (§5.18).
    private let dropOverlay = AttachmentDropOverlay(label: "Drop to reply with attachment", compactLabel: "Drop to attach",
                                                    inset: Quire.Layout.QuickReply.dropInset, radius: Quire.Layout.QuickReply.fieldRadius,
                                                    fill: .qSheet)
    private var heightConstraint: NSLayoutConstraint!
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    private var stripTimer: Timer?
    private var statusTicker: Timer?

    /// Text size (spec §4.15): the text is `writing` at it, and the field gains its step per line, so the bar at rest
    /// is 60 pt at Default and one point more or less per step.
    private var textSize = QuireEnvironment.textSize
    private var lineHeight: CGFloat { QuireFont.Role.writing.lineHeight(at: textSize) }
    private var lineStep: CGFloat { QuireFont.Role.writing.step(at: textSize) }
    /// The field at rest: one line between its pads.
    private var restField: CGFloat { Quire.Layout.QuickReply.field + lineStep }

    private static func restBarHeight(at textSize: QuireFont.TextSize) -> CGFloat {
        Quire.Layout.QuickReply.rest + QuireFont.Role.writing.step(at: textSize)
    }

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

        scrollView.contentView = QuickReplyClipView()
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
        textView.textStorage?.delegate = self
        applyWritingStyle()
        textView.textColor = .qInk
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
        textView.onCommandShiftReturn = { [weak self] in self?.sendAndArchivePressed() }
        textView.onSendLater = { [weak self] in self?.showSendLater() }
        textView.onOpenInComposer = { [weak self] in self?.openInComposerPressed() }
        textView.onAttach = { [weak self] in self?.attachPressed() }
        // The placeholder is a separate label that goes away while typing, so the field carries its own name.
        textView.setAccessibilityLabel("Reply")
        textView.onEscape = { [weak self] repeated in self?.escape(repeated: repeated) }
        textView.onFocusChange = { [weak self] focused in self?.focusDidChange(focused) }

        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.maximumNumberOfLines = 1
        placeholder.cell?.truncatesLastVisibleLine = true
        placeholder.isSelectable = false
        placeholder.setAccessibilityElement(false)
        addSubview(placeholder)

        restSend.target = self
        restSend.action = #selector(sendPressed)
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
        send.target = self
        send.action = #selector(sendPressed)
        // VoiceOver hears the key the face shows, as it hears a menu item's (the name says what Send does, §5.23).
        send.setAccessibilityHelp(SendKey.commandReturn.spoken)
        sendOptions.toolTip = "Send Options"
        sendOptions.target = self
        sendOptions.action = #selector(showSendOptions)
        // The tool row lies in the field: a segment's focus ring cuts the other half in the field's `sheet`.
        sendSplit.surfaceColor = .qSheet
        addSubview(sendSplit)
        sendActionDidChange()

        statusGlyph.imageScaling = .scaleNone
        // An image view registers for files and pictures even when it cannot be edited, and would take a drag meant for
        // the bar from over its glyph.
        statusGlyph.unregisterDraggedTypes()
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
        // Above everything the field holds, which it hides while it shows.
        addSubview(dropOverlay)
        registerForDraggedTypes(AttachmentPasteboard.dropTypes)
        textView.dropTarget = self

        heightConstraint = heightAnchor.constraint(equalToConstant: barHeight)
        heightConstraint.isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
        updatePlaceholder()
        statusDidChange()
    }

    /// Graphite and Increase Contrast change token values (the ring, the edges) without changing the appearance; a
    /// Text size sets the text again, typed text included, and the bar takes its new height.
    @objc private func environmentDidChange(_ note: Notification) {
        if QuireEnvironment.textSize != textSize {
            textSize = QuireEnvironment.textSize
            applyWritingStyle()
            updateHeight(animated: false)
        }
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
        if case let .counting(endsAt, _, _, _) = strip.state { return endsAt }
        if case let .counting(endsAt, _) = status { return endsAt }
        return nil
    }

    private func stripDismissed() {
        guard case let .counting(endsAt, _, _, archived) = strip.state else { return }
        hideStrip()
        status = .counting(endsAt: endsAt, archived: archived)
        window?.makeFirstResponder(textView)
    }

    /// The strip's countdown lead as shown now (tests).
    var stripLead: String { strip.leadText }

    private func hideFieldContents(_ hidden: Bool) {
        scrollView.isHidden = hidden
        placeholder.isHidden = hidden || !text.isEmpty
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Geometry

    private var showsKeycaps: Bool { ReaderColumn.showsKeycaps(readerWidth: bounds.width) }

    /// The width the text wraps at: the field's, less the text's leading pad and the trailing room (the R keycap and the
    /// Send circle at rest, a small pad with the tool row), less a scroller that takes room.
    private var wrapWidth: CGFloat {
        let m = Quire.Layout.QuickReply.self
        let trailing = showsToolRow ? m.focusedTrailing : m.restTrailing
        let frame = NSSize(width: max(0, fieldRect.width - m.textX - trailing), height: lineHeight)
        return NSScrollView.contentSize(forFrameSize: frame, horizontalScrollerClass: nil,
                                        verticalScrollerClass: scrollView.hasVerticalScroller ? NSScroller.self : nil,
                                        borderType: scrollView.borderType, controlSize: .regular, scrollerStyle: scrollView.scrollerStyle).width
    }

    /// Puts the text at the width it wraps at now, before it is measured: the bar's width (a window resized) and focus
    /// (the tool row's narrower trailing pad) change it before the next layout does. True when the width changed.
    @discardableResult
    private func fitTextWidth() -> Bool {
        guard bounds.width > 0 else { return false }
        let width = wrapWidth
        guard abs(textView.frame.width - width) > 0.5 else { return false }
        textView.frame.size.width = width
        return true
    }

    /// Text lines as laid out at the field's width, wrapped lines included, 1 to 5; past five the text scrolls inside
    /// the field.
    private var lineCount: Int {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return 1 }
        fitTextWidth()
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height - writeSpaceInText
        let lines = Int(ceil(max(used, lineHeight) / lineHeight - 0.01))
        return max(1, min(Int(Quire.Layout.QuickReply.maxLines), lines))
    }

    /// Field height: 9 + lines × 21 + 8 at rest (one line), 9 + lines × 21 + 4 + 28 + 4 focused (spec §5.18).
    private var fieldHeight: CGFloat {
        let m = Quire.Layout.QuickReply.self
        guard looksFocused, !isComposerOpen else { return restField }
        return min(m.fieldMax + m.maxLines * lineStep + writeSpace,
                   m.fieldPadTop + writeSpace + CGFloat(lineCount) * lineHeight + m.toolRowGap + m.toolRow + m.toolRowBottom)
    }

    private var fieldRect: NSRect {
        let column = ReaderColumn.frame(readerWidth: bounds.width)
        let m = Quire.Layout.QuickReply.self
        return NSRect(x: column.x, y: m.barPadY, width: column.width, height: max(restField, bounds.height - 2 * m.barPadY))
    }

    private var showsToolRow: Bool { looksFocused && !isComposerOpen && strip.isHidden }

    /// Where the face, the R keycap and the Send circle sit in `field`. All three are centred on the field at rest, so
    /// they stay in line with each other and with its one line at every Text size (spec §4.15): at Default the face's
    /// top is `faceTop` and the circle's inset `restSendInset` from the top (spec §5.18), and the field's step moves
    /// each by half of it. On the device grid, so a half-point step never blurs them.
    func restMarks(in field: NSRect) -> (face: NSRect, keycap: NSRect, send: NSRect) {
        let m = Quire.Layout.QuickReply.self
        let middle = field.minY + restField / 2
        let scale = window?.backingScaleFactor ?? 2
        func onGrid(_ y: CGFloat) -> CGFloat { (y * scale).rounded() / scale }
        let face = NSRect(x: field.minX + m.faceX, y: onGrid(field.minY + m.faceTop + lineStep / 2), width: m.face, height: m.face)
        let send = NSRect(x: field.maxX - m.restSendInset - m.restSend, y: onGrid(middle - m.restSend / 2), width: m.restSend, height: m.restSend)
        let cap = restKeycap.intrinsicContentSize
        let keycap = NSRect(x: send.minX - m.restKeycapGap - cap.width, y: onGrid(middle - cap.height / 2), width: cap.width, height: cap.height)
        return (face, keycap, send)
    }

    /// The field and the marks at rest as laid out now (tests read them).
    var restGeometry: (field: NSRect, face: NSRect, keycap: NSRect, send: NSRect) {
        let field = fieldRect
        let marks = restMarks(in: field)
        return (field, marks.face, marks.keycap, marks.send)
    }

    private func updateHeight(animated: Bool) {
        let m = Quire.Layout.QuickReply.self
        let target = min(m.max + m.maxLines * lineStep + writeSpace, fieldHeight + 2 * m.barPadY)
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
        // A new width (the window resized, the tool row in or out) wraps the text again: the bar takes the lines it now
        // needs, and the caret stays in view. Only while it looks focused: at rest the bar is one line whatever the
        // wrap, and blurring lays out mid-glide, where setting the height at once would cut the glide short.
        let rewrapped = fitTextWidth()
        if rewrapped, looksFocused { updateHeight(animated: false) }
        let lines = looksFocused ? lineCount : 1
        let extra = writeSpace
        scrollView.frame = NSRect(x: field.minX + m.textX, y: field.minY + m.fieldPadTop, width: textWidth,
                                  height: CGFloat(lines) * lineHeight + extra)
        textView.frame.size.width = scrollView.contentSize.width
        scrollView.hasVerticalScroller = looksFocused && lineCount >= Int(m.maxLines)
        if rewrapped, isFocused { textView.scrollRangeToVisible(textView.selectedRange()) }
        let placeholderHeight = ReaderFonts.fieldHeight(placeholder)
        placeholder.frame = NSRect(x: field.minX + m.textX - 2, y: (field.minY + m.fieldPadTop + (lineHeight - placeholderHeight) / 2).rounded(),
                                   width: textWidth + 4, height: placeholderHeight)
        // Unfocused with text, the field shows its first line tail-truncated so the reader does not jump.
        let showsPreview = !looksFocused && !text.isEmpty && strip.isHidden
        // While a composer holds the draft the field only brings it forward: the text view, empty, would take the click
        // and the typing it no longer owns.
        scrollView.isHidden = !strip.isHidden || showsPreview || isComposerOpen
        placeholder.isHidden = !strip.isHidden || (!text.isEmpty && !showsPreview)

        let restVisible = !toolRow && strip.isHidden && !isComposerOpen
        restSend.isHidden = !restVisible
        restKeycap.isHidden = !restVisible || !keycaps
        restSend.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status != .noRecipients
        let marks = restMarks(in: field)
        restSend.frame = restSend.frame(forVisualRect: marks.send)
        restKeycap.frame = marks.keycap

        let rowY = field.minY + m.fieldPadTop + extra + CGFloat(lines) * lineHeight + m.toolRowGap
        let showsStatus = status != .none
        sendSplit.isHidden = !toolRow
        sendOptions.isEnabled = !refusesEdits
        send.keycap = keycaps ? SendKey.commandReturn.legend : nil
        send.isEnabled = status != .noRecipients && !refusesEdits && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.toolTip = sendToolTip
        let tabSize = tabs.intrinsicContentSize
        tabs.frame = tabs.frame(forVisualRect: NSRect(x: field.minX + m.textX, y: rowY, width: tabSize.width, height: m.toolRow))
        var x = field.minX + m.textX + tabSize.width + m.toolGroupGap
        let iconY = rowY + (m.toolRow - m.toolIcon) / 2
        attach.frame = attach.frame(forVisualRect: NSRect(x: x, y: iconY, width: m.toolIcon, height: m.toolIcon))
        x += m.toolIcon + m.toolIconGap
        let composerX = showsStatus ? nil : x
        // Trailing, 8 pt from the edge: Send, its “⌘↩” and its drop-down on one face, centred in the row as the tools are.
        let sendSize = sendSplit.intrinsicContentSize
        let sendVisual = NSRect(x: field.maxX - m.sendInset - sendSize.width, y: rowY + (m.toolRow - sendSize.height) / 2,
                                width: sendSize.width, height: sendSize.height)
        sendSplit.frame = sendSplit.frame(forVisualRect: sendVisual)
        tabs.isHidden = !toolRow || showsStatus
        attach.isHidden = !toolRow || showsStatus
        openInComposer.isHidden = !toolRow || (showsStatus && status == .error)

        // The leading status replaces the tabs and tools; Open in Composer follows it when it applies.
        statusGlyph.isHidden = !toolRow || !showsStatus || { if case .counting = status { return true } else { return false } }()
        statusLabel.isHidden = !toolRow || !showsStatus
        // Only the countdown has an action of its own; an empty one would still take a click and the Tab key.
        statusAction.isHidden = !toolRow || !showsStatus || statusAction.title.isEmpty
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
        dropOverlay.frame = field
        pointerRegionsDidChange()
    }

    // MARK: Pointer

    /// The pointer over the bar (§4.17). The field's face takes the I-beam, its padding, face and R keycap included,
    /// since a click anywhere on it puts the caret in it, with its buttons and the strip left to their own pointer; the
    /// tool row's band around its controls the arrow, as a click there changes nothing. While a composer holds the draft
    /// the whole field takes the hand, since a click brings the composer forward; a failed send's “Open in composer”
    /// takes it too. Around the field the bar lies on the reader's page, whose pointer would show through: the arrow.
    var pointerRegions: [QuirePointerRegion] {
        let field = fieldRect
        // The controls keep their own pointer, wherever the bar's growth has them for now, and the text view its I-beam.
        var holes = childPointerAreas()
        if !scrollView.isHidden { holes.append(scrollView.frame) }
        var regions = QuirePointerRegion.regions(bounds, cursor: .arrow, cutting: holes + [field])
        if isComposerOpen {
            return regions + QuirePointerRegion.regions(field, cursor: .pointingHand, cutting: holes)
        }
        guard strip.isHidden else {
            return regions + QuirePointerRegion.regions(field, cursor: .arrow, cutting: holes)
        }
        if showsToolRow {
            if status == .error, !statusLabel.isHidden {
                regions += QuirePointerRegion.regions(statusLabel.frame, cursor: .pointingHand, cutting: holes)
                holes.append(statusLabel.frame)
            }
            let top = scrollView.frame.maxY + Quire.Layout.QuickReply.toolRowGap
            let toolRow = NSRect(x: field.minX, y: top, width: field.width, height: max(0, field.maxY - top))
            regions += QuirePointerRegion.regions(toolRow, cursor: .arrow, cutting: holes)
            holes.append(toolRow)
        }
        return regions + QuirePointerRegion.regions(field, cursor: .iBeam, cutting: holes)
    }

    override func resetCursorRects() {
        addPointerRects()
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
            let rect = restMarks(in: field).face
            QuireAvatarRenderer.drawAccountFace(face.face, slot: face.inkSlot, in: rect)
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

    // MARK: Dropping (§5.18)

    /// The field takes a drop only while it takes typing: not while a composer holds the reply, nor while Help me write
    /// streams a reply into it (§5.56), nor while the strip counts a send down or says how one ended, nor while hidden.
    var acceptsDrops: Bool {
        onDropAttachments != nil && !isComposerOpen && !refusesEdits && strip.isHidden && !isHiddenOrHasHiddenAncestor
    }

    /// The drop treatment shows (the app's tests read it, and its renders set it).
    var showsDropTarget: Bool {
        get { !dropOverlay.isHidden }
        set { dropOverlay.isHidden = !newValue }
    }

    /// The drop treatment, for the app's tests and renders: where its words are.
    var dropTreatment: AttachmentDropOverlay { dropOverlay }

    /// What a drop of `drag` would attach. A folder, or a file that cannot be read, is left out: the drop moves the reply
    /// out of the bar, which it must not do for nothing.
    private func attachable(_ drag: NSDraggingInfo) -> [AttachmentDropItem] {
        AttachmentPasteboard.attachable(AttachmentPasteboard.dropItems(for: drag))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops, !attachable(sender).isEmpty else { return [] }
        dropOverlay.show(for: sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard showsDropTarget else { return [] }
        // The words move clear of the card as the pointer moves.
        dropOverlay.show(for: sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOverlay.show(for: nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropOverlay.show(for: nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOverlay.show(for: nil)
        let items = attachable(sender)
        guard acceptsDrops, !items.isEmpty else { return false }
        onDropAttachments?(text, mode, items)
        return true
    }

    // MARK: Behavior

    @objc private func sendPressed() {
        send(as: sendAction)
    }

    /// ⇧⌘↩: send and archive the conversation, whatever Send does (§5.23).
    private func sendAndArchivePressed() {
        send(as: .sendAndArchive)
    }

    private func send(as action: SendAction) {
        let typed = text
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, status != .noRecipients, !refusesEdits else { return }
        onSend?(typed, mode, action)
    }

    /// Send's drop-down: hung from Send's face; the choice goes to the owner and a click sends nothing.
    @objc private func showSendOptions() {
        guard !refusesEdits else { return }
        SendActionMenu.popUp(sendOptionsMenu(), from: sendSplit)
    }

    /// The drop-down's menu as it opens now (the app's tests choose from it).
    func sendOptionsMenu() -> NSMenu {
        sendActionMenu.menu(current: sendAction)
    }

    /// ⇧⌘L: Send Later's times hung from the drop-down, while there is a reply to schedule.
    private func showSendLater() {
        guard canSend else {
            NSSound.beep()
            return
        }
        SendActionMenu.popUp(sendLaterMenu(), from: sendSplit)
    }

    /// The menu ⇧⌘L pops (the app's tests choose from it).
    func sendLaterMenu() -> NSMenu {
        sendActionMenu.laterMenu()
    }

    /// A Send Later time (nil: Pick a Time…) for what is typed; the owner schedules it, as it sends on ⌘↩.
    func sendLater(at date: Date?) {
        guard canSend else {
            NSSound.beep()
            return
        }
        onSendLater?(text, mode, date)
    }

    /// There is a reply to send, someone to send it to, and it is the user's: not one Help me write is still writing.
    private var canSend: Bool {
        !refusesEdits && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status != .noRecipients
    }

    /// The tooltips and VoiceOver names of Send and the rest glyph say what they do now; their label stays “Send”.
    private func sendActionDidChange() {
        restSend.toolTip = sendAction.tooltip
        restSend.setAccessibilityLabel(sendAction.title)
        send.setAccessibilityLabel(sendAction.title)
        send.toolTip = sendToolTip
        needsLayout = true
    }

    /// Send's tooltip: what it does now, or why it cannot.
    private var sendToolTip: String {
        status == .noRecipients ? "No one to reply to" : sendAction.tooltip
    }

    /// The Send button's tooltip and VoiceOver name as set now (tests).
    var sendButtonHelp: (toolTip: String?, label: String?) { (send.toolTip, send.accessibilityLabel()) }

    /// Whether Send and its drop-down take a click now (tests).
    var sendControlsEnabled: (send: Bool, options: Bool) { (send.isEnabled, sendOptions.isEnabled) }

    /// Send's split button, its face, keycap and drop-down (tests and debug renders).
    var sendSplitButton: QuireSplitButton { sendSplit }

    // While a reply streams in, the text is not the user's yet: it moves to no composer until the write ends.
    @objc private func openInComposerPressed() {
        guard !refusesEdits else { return }
        onOpenInComposer?(text, mode)
    }

    @objc private func attachPressed() {
        guard !refusesEdits else { return }
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
    private func escape(repeated: Bool) {
        if claimsEscape?() == true { return }
        if let onEscape { onEscape(repeated) } else { blur() }
    }

    /// `writing` at the Text size, for what is typed from now on and for what is there already: the field is plain
    /// text, so one font and one paragraph style cover it all. Not an edit: the undo stack keeps text at the size it
    /// was typed at, and the storage's delegate sets what an undo brings back at the size then.
    private func applyWritingStyle() {
        var writing = QuireFont.attributes(.writing, color: .qInk, textSize: textSize)
        // Quire's role styles truncate a single line (labels); a reply wraps, to five lines and then scrolls (§5.18).
        if let style = (writing[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.lineBreakMode = .byWordWrapping
            writing[.paragraphStyle] = style
        }
        textView.font = writing[.font] as? NSFont
        textView.typingAttributes = writing
        textView.defaultParagraphStyle = writing[.paragraphStyle] as? NSParagraphStyle
        if let storage = textView.textStorage {
            Self.wrapLines(in: storage)
            WritingTextSize.apply(textSize, to: storage)
        }
    }

    /// Text set before the field wrapped (a restored draft) wraps too.
    private static func wrapLines(in storage: NSTextStorage) {
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length), options: []) { value, run, _ in
            guard let style = value as? NSParagraphStyle, style.lineBreakMode != .byWordWrapping,
                  let copy = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            copy.lineBreakMode = .byWordWrapping
            storage.addAttribute(.paragraphStyle, value: copy, range: run)
        }
    }

    /// The writing font in use now (tests read it).
    var writingFont: NSFont? { textView.font }

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
        } else if !looksFocused, !text.isEmpty {
            let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? text
            placeholder.attributedStringValue = ReaderFonts.fieldString(QuireFont.attributedString(first, role: .writing, color: .qInk,
                                                                                                   textSize: textSize))
            return
        } else if mode == .replyAll {
            words = replyAllName.isEmpty ? "Reply all…" : "Reply all to \(replyAllName)…"
        } else {
            words = replyName.isEmpty ? "Reply…" : "Reply to \(replyName)…"
        }
        textView.setAccessibilityPlaceholderValue(words)
        placeholder.attributedStringValue = ReaderFonts.fieldString(QuireFont.attributedString(words, role: .writing, color: .qInk3,
                                                                                               textSize: textSize))
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
        case let .counting(endsAt, archived):
            statusAction.title = "Undo"
            statusContrail.mode = .countdown(duration: max(1, endsAt.timeIntervalSinceNow), remaining: max(0, endsAt.timeIntervalSinceNow))
            updateCountdownStatus(endsAt, archived: archived)
            statusTicker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCountdownStatus(endsAt, archived: archived) }
            }
        }
        statusAction.isHidden = statusAction.title.isEmpty
        needsLayout = true
        needsDisplay = true
    }

    private func updateCountdownStatus(_ endsAt: Date, archived: Bool) {
        let left = max(0, Int(ceil(endsAt.timeIntervalSinceNow)))
        let words = QuickReplyStripView.countdown(secondsLeft: left, archived: archived) + " \u{00b7}"
        statusLabel.attributedStringValue = ReaderFonts.fieldString(QuireFont.attributedString(words, role: .snippet, color: .qInk2))
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
        onUserEdit?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChange?()
    }

    /// The text's right-click menu opens with Help Me Write's group (§5.56), the mouse's way to it. Showing it sends nothing.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        for (index, item) in (writeMenuItems?() ?? []).enumerated() { menu.insertItem(item, at: index) }
        return menu
    }

    /// While Help me write streams into the field, typing waits: the reply and the user's keys never interleave.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        !refusesEdits
    }

    private func textDidChange() {
        if status == .error || status == .noRecipients, text.isEmpty { status = .none }
        updatePlaceholder()
        placeholder.isHidden = !text.isEmpty && looksFocused
        updateHeight(animated: false)
        needsLayout = true
    }
}

extension QuickReplyView: NSTextStorageDelegate {
    /// Every edit, an undo or a redo included, leaves what it touched at the field's Text size (spec §4.15): an undo
    /// of an edit made before a switch would otherwise bring its text back at the old size and on the old line.
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            _ = WritingTextSize.apply(textSize, to: textStorage, in: editedRange)
        }
    }
}

/// The text's clip view, which adds the I-beam over the text for its scroll view (§4.17): none while the text is hidden
/// (AppKit asks a hidden view too, and keeps what it adds), nor under the cheat sheet, which takes the keyboard.
private final class QuickReplyClipView: NSClipView {
    override func resetCursorRects() {
        guard !isHiddenOrHasHiddenAncestor, !isUnderPointerCover else { return }
        guard let text = documentView as? QuickReplyTextView else { return super.resetCursorRects() }
        let marks = text.markAreas()
        guard !marks.isEmpty else { return super.resetCursorRects() }
        // Help me write's marks lie on the text (§5.56): the I-beam leaves them their own pointer.
        addTextPointerRects(over: convert(text.bounds, from: text), cutting: marks.map { convert($0, from: text) })
    }
}

/// Catches the keys the delegate protocol cannot: ⌘↩ and ⇧⌘↩ are not text commands, ⇧⌘R opens the composer, ⇧⌘A
/// attaches there, and Escape must go to the owner rather than cancel completion.
private final class QuickReplyTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    var onCommandShiftReturn: (() -> Void)?
    var onSendLater: (() -> Void)?
    var onOpenInComposer: (() -> Void)?
    var onAttach: (() -> Void)?
    var onEscape: ((_ repeated: Bool) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    /// The areas of Help me write's marks on the text (§5.56), which keep their own pointer.
    var markAreas: () -> [NSRect] = { [] }
    /// The bar, which takes files dragged over the text: a text view registered for files keeps the drag from it, and
    /// would type the file's path.
    weak var dropTarget: NSView?
    /// The key being handled is a repeat (the key held down): `cancelOperation`, which carries no event, tells the owner,
    /// since Esc's repeat must not close a reader window (§6.1).
    private var handlingRepeat = false

    /// ⌘↩, ⇧⌘↩ and ⇧⌘L are taken here, before the main menu sees them: a menu item carrying one (the composer's hidden
    /// Send, Send and Archive and Send Later…) claims the key even while it is hidden or disabled, so `keyDown` would
    /// never get it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, sendKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘↩ sends as Send does, ⇧⌘↩ sends and archives, ⇧⌘L shows Send Later's times (§5.23); false for any other key.
    private func sendKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.rawValue
        if ReaderShortcuts.isSend(keyCode: event.keyCode, rawModifierFlags: flags) {
            onCommandReturn?()
            return true
        }
        if ReaderShortcuts.isSendAndArchive(keyCode: event.keyCode, rawModifierFlags: flags) {
            onCommandShiftReturn?()
            return true
        }
        if ReaderShortcuts.isSendLater(charactersIgnoringModifiers: event.charactersIgnoringModifiers, rawModifierFlags: flags) {
            onSendLater?()
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        handlingRepeat = event.isARepeat
        defer { handlingRepeat = false }
        if sendKey(event) { return }
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
        onEscape?(handlingRepeat)
    }

    /// The I-beam over the text, Help me write's marks cut out of it (§4.17).
    override func resetCursorRects() {
        let marks = markAreas()
        guard !marks.isEmpty else { return super.resetCursorRects() }
        addTextPointerRects(cutting: marks)
    }

    // Files dragged over the text attach through the bar, as attachments dragged from a message do (§5.18).

    private func attaches(_ sender: NSDraggingInfo) -> Bool {
        dropTarget != nil && AttachmentPasteboard.carriesAttachments(sender.draggingPasteboard)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if attaches(sender) { return dropTarget?.draggingEntered(sender) ?? [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if attaches(sender) { return dropTarget?.draggingUpdated(sender) ?? [] }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, attaches(sender) { dropTarget?.draggingExited(sender) }
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        if attaches(sender) { dropTarget?.draggingEnded(sender) }
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if attaches(sender) { return dropTarget?.performDragOperation(sender) ?? false }
        return super.performDragOperation(sender)
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
