import AppKit
import SSDesign

/// Help me write's place in a reply's tool row (spec §5.56): the quick reply's row under its text (§5.18) and the
/// composer's bottom bar (§5.20). One small ghost **Write** button (the Help Me Write glyph and “Write”, the glyph alone
/// where the row is tight), and after it one `meta` line that says what Help me write can do or is doing:
///
/// - ready, with a few words of the user's own: “⌘J writes from your notes” (`ink3`), the hint;
/// - writing: Stop in Write's place, a spinner, “Writing with Claude…” (`ink2`) and the esc keycap;
/// - a reply just written: “Written by Claude · ⌘J Try again · ⌘Z Undo” (`ink2`, the two actions links);
/// - a failure: the failed glyph and the reason in `danger`, then Try again and, when the fix is there, Settings….
///
/// With a provider that needs setup the button shows disabled and its tooltip says why; with Help me write off the
/// control shows nothing. The control shows; `WriteSession` and its host decide.
@MainActor
final class WriteToolControl: NSView {
    /// Whether Help me write can write from this field now, as far as this Mac knows (`HelpMeWrite.availability`).
    enum Availability: Equatable {
        /// No provider chosen: the control is absent.
        case off
        /// A provider is chosen but cannot write: the reason, shown as the disabled button's tooltip and, on ⌘J, inline.
        case unavailable(reason: String)
        /// Ready: the writer's name for the words (“Claude”), and its source line for the tooltips.
        case ready(writer: String, source: String)
    }

    /// What the session is doing in this field.
    enum Phase: Equatable {
        case idle
        case writing
        /// A reply just landed; the line stays until the user types, sends or moves away.
        case written
        case failed(reason: String, offersSettings: Bool)
    }

    static let hintWords = "writes from your notes"
    /// The hint where the row has no room for the whole: Write's own label says the rest.
    static let shortHintWords = "from your notes"
    static let tryAgainWords = "Try again"
    static let settingsWords = "Settings\u{2026}"

    var availability: Availability = .off { didSet { if oldValue != availability { apply() } } }
    var phase: Phase = .idle { didSet { if oldValue != phase { apply() } } }
    /// The user's own text holds enough words to write from (`layout.writeTool.hintMinWords`).
    var showsHint = false { didSet { if oldValue != showsHint { apply() } } }
    /// The write under way rewrites a selection: “Rewriting with Claude…”.
    var isRewriting = false { didSet { if oldValue != isRewriting { apply() } } }

    var onWrite: (() -> Void)?
    var onStop: (() -> Void)?
    var onTryAgain: (() -> Void)?
    var onUndo: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// What the control shows changed size: the host lays its row out again.
    var onContentChange: (() -> Void)?

    let writeButton = QuireButton(title: "Write", variant: .ghost, size: .small, symbolName: Quire.Icon.helpMeWrite)
    let stopButton = QuireButton(title: "Stop", variant: .ghost, size: .small, symbolName: Quire.Icon.stopWriting)
    private let spinner = QuireSpinnerView(size: .small, color: .qInk2)
    private let glyph = NSImageView()
    /// The line's words (the hint's, “Writing with Claude…”, “Written by Claude ·”, a failure's reason).
    let label = NSTextField(labelWithString: "")
    private let firstKeycap = QuireKeycap("\u{2318}J")
    private let secondKeycap = QuireKeycap("\u{2318}Z")
    let tryAgainLink = SyncLineActionButton()
    let undoLink = SyncLineActionButton()
    let settingsLink = SyncLineActionButton()
    private let firstDot = NSTextField(labelWithString: "\u{00b7}")
    private let secondDot = NSTextField(labelWithString: "\u{00b7}")
    /// How much the row's lack of room took from the idle line: 0 nothing; 1 the hint's “writes”; 2 also Write's label.
    private var tightness = 0
    private var isCompact: Bool { tightness >= 2 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        writeButton.target = self
        writeButton.action = #selector(writePressed)
        writeButton.setAccessibilityLabel("Write with Help Me Write")
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        stopButton.toolTip = "Stop  esc"
        stopButton.setAccessibilityLabel("Stop writing")
        spinner.delay = 0
        spinner.setAccessibilityElement(false)
        glyph.imageScaling = .scaleNone
        glyph.unregisterDraggedTypes()
        glyph.setAccessibilityElement(false)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        for (link, title, action) in [(tryAgainLink, Self.tryAgainWords, #selector(tryAgainPressed)),
                                      (undoLink, "Undo", #selector(undoPressed)),
                                      (settingsLink, Self.settingsWords, #selector(settingsPressed))] {
            link.title = title
            link.target = self
            link.action = action
        }
        for keycap in [firstKeycap, secondKeycap] { keycap.setAccessibilityElement(false) }
        for dot in [firstDot, secondDot] { dot.setAccessibilityElement(false) }
        for view in [writeButton, stopButton, spinner, glyph, label, firstKeycap, secondKeycap, firstDot, secondDot,
                     tryAgainLink, undoLink, settingsLink] as [NSView] {
            addSubview(view)
        }
        setAccessibilityElement(false)
        apply()
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WriteToolControl is built in code")
    }

    override var isFlipped: Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func environmentDidChange(_ note: Notification) {
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    // MARK: Content

    /// The control shows anything at all: Help me write is on, or a write's line is up (a failure says Help me write is
    /// off, after ⌘J).
    var isShown: Bool {
        if case .off = availability { return phase != .idle }
        return true
    }

    /// Whether the line replaces the row's own leading controls (the quick reply's tabs and tools): while writing, after
    /// a reply, after a failure.
    var takesTheRow: Bool { phase != .idle }

    private var writerName: String {
        if case .ready(let writer, _) = availability { return writer }
        return "Claude"
    }

    /// The words of the line now, for VoiceOver and the app's tests.
    var lineWords: String {
        switch phase {
        case .idle:
            return showsHintNow ? "\u{2318}J " + Self.hintWords : ""
        case .writing:
            return (isRewriting ? "Rewriting" : "Writing") + " with \(writerName)\u{2026}"
        case .written:
            return "Written by \(writerName) \u{00b7} \u{2318}J Try again \u{00b7} \u{2318}Z Undo"
        case .failed(let reason, let settings):
            return reason + " \u{00b7} Try again" + (settings ? " \u{00b7} Settings\u{2026}" : "")
        }
    }

    private var showsHintNow: Bool {
        guard phase == .idle, showsHint, case .ready = availability else { return false }
        return true
    }

    private func apply() {
        let shown = isShown
        isHidden = !shown
        let writing = phase == .writing
        let idle = phase == .idle
        writeButton.isHidden = !shown || !idle
        stopButton.isHidden = !writing
        switch availability {
        case .off:
            writeButton.isEnabled = false
            writeButton.toolTip = nil
        case .unavailable(let reason):
            writeButton.isEnabled = false
            writeButton.toolTip = reason
            writeButton.setAccessibilityHelp(reason)
        case .ready(let writer, let source):
            writeButton.isEnabled = true
            writeButton.toolTip = "Write with \(writer)  \u{2318}J\n\(source)"
            writeButton.setAccessibilityHelp("Writes a reply with \(writer), from your notes when you have typed some.")
        }
        writeButton.title = isCompact ? "" : "Write"
        writeButton.setAccessibilityLabel("Write with Help Me Write")
        spinner.isHidden = !writing
        if writing { spinner.startAnimation() } else { spinner.stopAnimation() }

        var words = ""
        var color: NSColor = .qInk2
        var glyphName: String?
        firstKeycap.isHidden = true
        secondKeycap.isHidden = true
        firstDot.isHidden = true
        secondDot.isHidden = true
        tryAgainLink.isHidden = true
        undoLink.isHidden = true
        settingsLink.isHidden = true
        label.toolTip = nil
        switch phase {
        case .idle:
            if showsHintNow {
                firstKeycap.legend = "\u{2318}J"
                firstKeycap.isHidden = false
                words = tightness >= 1 ? Self.shortHintWords : Self.hintWords
                color = .qInk3
            }
        case .writing:
            words = (isRewriting ? "Rewriting" : "Writing") + " with \(writerName)\u{2026}"
            firstKeycap.legend = "esc"
            firstKeycap.isHidden = false
        case .written:
            words = "Written by \(writerName)"
            if case .ready(_, let source) = availability { label.toolTip = source }
            firstDot.isHidden = false
            firstKeycap.legend = "\u{2318}J"
            firstKeycap.isHidden = false
            tryAgainLink.isHidden = false
            tryAgainLink.isAlertLine = false
            secondDot.isHidden = false
            secondKeycap.isHidden = false
            undoLink.isHidden = false
        case .failed(let reason, let offersSettings):
            words = reason
            label.toolTip = reason
            color = .qDanger
            glyphName = Quire.Icon.failed
            firstDot.isHidden = false
            tryAgainLink.isHidden = false
            tryAgainLink.isAlertLine = true
            settingsLink.isHidden = !offersSettings
            settingsLink.isAlertLine = true
            secondDot.isHidden = !offersSettings
        }
        label.attributedStringValue = QuireFont.attributedString(words, role: .meta, color: color)
        label.isHidden = words.isEmpty
        if let glyphName {
            glyph.image = QuireSymbol.image(glyphName, size: .custom(Quire.Layout.WriteTool.statusGlyph, weight: .semibold))
            glyph.contentTintColor = .qDanger
        }
        glyph.isHidden = glyphName == nil
        for dot in [firstDot, secondDot] {
            dot.attributedStringValue = QuireFont.attributedString("\u{00b7}", role: .meta, color: phase == .written ? .qInk3 : color)
        }
        needsLayout = true
        onContentChange?()
    }

    // MARK: Geometry

    /// How a label draws its text in from each edge.
    private static let labelInset: CGFloat = 2

    private func textWidth(_ field: NSTextField) -> CGFloat {
        ceil(field.attributedStringValue.size().width) + 2 * Self.labelInset
    }

    /// The width the control would like: Write with its label and its line whole.
    var fittingWidth: CGFloat {
        guard isShown else { return 0 }
        return layoutItems(height: 22, apply: false) + (isCompact ? Self.labelWidth : 0) + (tightness >= 1 && showsHintNow ? hintSaving : 0)
    }

    /// What the short hint saves over the whole one.
    private var hintSaving: CGFloat {
        func width(_ words: String) -> CGFloat { ceil(QuireFont.attributedString(words, role: .meta, color: .qInk3).size().width) }
        return width(Self.hintWords) - width(Self.shortHintWords)
    }

    /// What “Write” adds to the button beside its glyph.
    private static let labelWidth: CGFloat = {
        let full = QuireButton(title: "Write", variant: .ghost, size: .small, symbolName: Quire.Icon.helpMeWrite)
        let bare = QuireButton(title: "", variant: .ghost, size: .small, symbolName: Quire.Icon.helpMeWrite)
        return full.intrinsicContentSize.width - bare.intrinsicContentSize.width
    }()

    /// Lays its parts out from the leading edge, each centred on a row `height` tall. Returns the trailing edge of what it
    /// placed, whole (the label may then be cut to the bounds).
    @discardableResult
    private func layoutItems(height: CGFloat, apply: Bool) -> CGFloat {
        let t = Quire.Layout.WriteTool.self
        let mid = height / 2
        let inset = Self.labelInset
        let space = ceil(QuireFont.attributedString(" ", role: .meta, color: .qInk3).size().width)
        let lineHeight = QuireFont.Role.meta.lineHeight
        var x: CGFloat = 0
        /// Places `view` `gap` after what came before; a label is placed by its text, its frame `inset` wider each side.
        func put(_ view: NSView, gap: CGFloat) {
            guard !view.isHidden else { return }
            let start = x == 0 ? 0 : x + gap
            if let control = view as? QuireControl {
                let size = control.intrinsicContentSize
                let padX = (view as? SyncLineActionButton) != nil ? SyncLineActionButton.padX : 0
                let visual = NSRect(x: start - padX, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height)
                if apply { control.frame = control.frame(forVisualRect: visual) }
                x = visual.maxX - padX
            } else if let field = view as? NSTextField {
                let width = textWidth(field)
                if apply { field.frame = NSRect(x: start - inset, y: (mid - lineHeight / 2).rounded(), width: width, height: lineHeight) }
                x = start - inset + width - inset
            } else {
                let size = view === glyph ? NSSize(width: t.statusGlyph, height: t.statusGlyph) : view.intrinsicContentSize
                if apply { view.frame = NSRect(x: start, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height) }
                x = start + size.width
            }
        }
        put(writeButton, gap: 0)
        put(stopButton, gap: 0)
        put(spinner, gap: t.gap)
        put(glyph, gap: t.gap)
        let afterMark = spinner.isHidden && glyph.isHidden ? t.gap : t.statusGlyphGap
        switch phase {
        case .idle:
            // “⌘J writes from your notes”: the keycap leads the words.
            put(firstKeycap, gap: t.gap)
            put(label, gap: t.keycapGap)
        case .writing:
            // “Writing with Claude…  esc”.
            put(label, gap: afterMark)
            put(firstKeycap, gap: t.gap)
        case .written:
            // “Written by Claude · ⌘J Try again · ⌘Z Undo”.
            put(label, gap: afterMark)
            put(firstDot, gap: space)
            put(firstKeycap, gap: space)
            put(tryAgainLink, gap: t.linkGap)
            put(secondDot, gap: space)
            put(secondKeycap, gap: space)
            put(undoLink, gap: t.linkGap)
        case .failed:
            // “The Anthropic API key was refused · Try again · Settings…”.
            put(label, gap: afterMark)
            put(firstDot, gap: space)
            put(tryAgainLink, gap: space)
            put(secondDot, gap: space)
            put(settingsLink, gap: space)
        }
        return ceil(x)
    }

    override func layout() {
        super.layout()
        let available = bounds.width
        // Tight: the hint drops “writes” first (“Write ⌘J from your notes”), then the button its label, then the line
        // truncates.
        var level = 0
        if phase == .idle {
            let whole = fittingWidth
            let shortened = whole - (showsHintNow ? hintSaving : 0)
            if shortened > available {
                level = 2
            } else if whole > available {
                level = 1
            }
        }
        if level != tightness {
            tightness = level
            apply()
        }
        let used = layoutItems(height: bounds.height, apply: true)
        if used > available, !label.isHidden {
            // The label gives up what the row lacks; the links after it move back with it.
            let excess = used - available
            label.frame.size.width = max(0, label.frame.width - excess)
            for view in [firstDot, firstKeycap, tryAgainLink, secondDot, secondKeycap, undoLink, settingsLink] as [NSView]
            where !view.isHidden && view.frame.minX > label.frame.minX {
                view.frame.origin.x -= excess
            }
        }
    }

    // MARK: Actions

    @objc private func writePressed() { onWrite?() }
    @objc private func stopPressed() { onStop?() }
    @objc private func tryAgainPressed() { onTryAgain?() }
    @objc private func undoPressed() { onUndo?() }
    @objc private func settingsPressed() { onOpenSettings?() }
}
