import AppKit
import SSDesign

/// Help me write's place in a reply's tool row (spec §5.56): the quick reply's row under its text (§5.18) and the
/// composer's bottom bar (§5.20). One small ghost **Write** button (the Help Me Write glyph and “Write”), and after it one
/// `meta` line that says what Help me write can do or is doing:
///
/// - ready, with a few words of the user's own: “⌘J writes from your notes” (`ink3`), the hint; with text selected,
///   “⌘J rewrites the selection”;
/// - writing: Stop in Write's place, a spinner, “Writing with Claude…” (`ink2`) and the esc keycap;
/// - a reply just written: “Written by Claude · ⌘J Try again · ⇧⌘J Say how · ⌘Z Undo” (`ink2`, the actions links);
/// - a failure: the failed glyph and the reason in `danger`, then Try again and, when the fix is there, Settings….
///
/// The control never draws past the width its host gives it. Where that is short, the line gives way in a fixed order,
/// each step measured, never overlapped: the hint's words shorten, then go, then its keycap, and only then does Write lose
/// its label; a reply's line drops its keycaps, then “Written by Claude”, then Say how; a failure keeps its reason whole
/// longest, its links turning to glyphs first. What does not fit even then is not shown.
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

    /// What ⌘J would do with the user's text, said after Write while it can write.
    enum Hint: Equatable {
        /// A few words of the user's own: ⌘J writes the reply from them.
        case notes
        /// Text selected: ⌘J rewrites just that.
        case selection
    }

    static let hintWords = "writes from your notes"
    /// The hint where the row has no room for the whole: Write's own label says the rest.
    static let shortHintWords = "from notes"
    static let selectionHintWords = "rewrites the selection"
    static let shortSelectionHintWords = "rewrites selection"
    static let tryAgainWords = "Try again"
    static let sayHowWords = "Say how"
    static let settingsWords = "Settings\u{2026}"
    /// The presets the strip offers, also on Write's menu.
    static let presets = WriteInstructionStrip.presets

    var availability: Availability = .off { didSet { if oldValue != availability { apply() } } }
    var phase: Phase = .idle { didSet { if oldValue != phase { apply() } } }
    /// What the hint says, or nil for none (`WriteSession` decides from the user's text and selection).
    var hint: Hint? { didSet { if oldValue != hint { apply() } } }
    /// The user's own text holds enough words to write from, or text is selected: the hint can show.
    var showsHint: Bool { hint != nil }
    /// The write under way rewrites a selection: “Rewriting with Claude…”.
    var isRewriting = false { didSet { if oldValue != isRewriting { apply() } } }

    var onWrite: (() -> Void)?
    var onStop: (() -> Void)?
    var onTryAgain: (() -> Void)?
    var onUndo: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// ⇧⌘J's strip: from the written line's Say how and from Write's menu.
    var onSayHow: (() -> Void)?
    /// A preset from Write's menu (“Shorter”, …), run as the strip's chip would.
    var onPreset: ((String) -> Void)?
    /// What the control shows changed size: the host lays its row out again.
    var onContentChange: (() -> Void)?

    let writeButton = QuireButton(title: "Write", variant: .ghost, size: .small, symbolName: Quire.Icon.helpMeWrite)
    let stopButton = QuireButton(title: "Stop", variant: .ghost, size: .small, symbolName: Quire.Icon.stopWriting)
    private let spinner = QuireSpinnerView(size: .small, color: .qInk2)
    private let glyph = NSImageView()
    /// The line's words (the hint's, “Writing with Claude…”, “Written by Claude”, a failure's reason).
    let label = NSTextField(labelWithString: "")
    private let firstKeycap = QuireKeycap("\u{2318}J")
    private let sayHowKeycap = QuireKeycap("\u{21e7}\u{2318}J")
    private let secondKeycap = QuireKeycap("\u{2318}Z")
    let tryAgainLink = SyncLineActionButton()
    let sayHowLink = SyncLineActionButton()
    let undoLink = SyncLineActionButton()
    let settingsLink = SyncLineActionButton()
    /// A failure's links as glyphs, where the reason needs the room.
    let tryAgainIcon = QuireIconButton(symbolName: Quire.Icon.retry, size: .small, accessibilityLabel: "Try Again")
    let settingsIcon = QuireIconButton(symbolName: Quire.Icon.settings, size: .small, accessibilityLabel: "Open Settings, AI")
    private let dots = (0..<3).map { _ in NSTextField(labelWithString: "\u{00b7}") }

    /// The form the line takes now: what the row's room let it keep (`forms`, richest first).
    private(set) var form = Form()
    /// The line's whole words before any cut: the label is cut to the room left, with an ellipsis, as the form allows.
    private var wholeWords = ""
    private var wordsColor: NSColor = .qInk2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        writeButton.target = self
        writeButton.action = #selector(writePressed)
        writeButton.setAccessibilityLabel("Write with Help Me Write")
        writeButton.menu = writeMenu()
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        stopButton.toolTip = "Stop  esc"
        stopButton.setAccessibilityLabel("Stop writing")
        spinner.delay = 0
        spinner.setAccessibilityElement(false)
        glyph.imageScaling = .scaleNone
        glyph.unregisterDraggedTypes()
        glyph.setAccessibilityElement(false)
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        for (link, title, action) in [(tryAgainLink, Self.tryAgainWords, #selector(tryAgainPressed)),
                                      (sayHowLink, Self.sayHowWords, #selector(sayHowPressed)),
                                      (undoLink, "Undo", #selector(undoPressed)),
                                      (settingsLink, Self.settingsWords, #selector(settingsPressed))] {
            link.title = title
            link.target = self
            link.action = action
        }
        tryAgainLink.toolTip = "Try Again  \u{2318}J"
        sayHowLink.toolTip = "Say How  \u{21e7}\u{2318}J"
        undoLink.toolTip = "Undo Help Me Write  \u{2318}Z"
        tryAgainIcon.target = self
        tryAgainIcon.action = #selector(tryAgainPressed)
        tryAgainIcon.toolTip = "Try Again  \u{2318}J"
        settingsIcon.target = self
        settingsIcon.action = #selector(settingsPressed)
        settingsIcon.toolTip = "Settings \u{203a} AI\u{2026}"
        for keycap in [firstKeycap, sayHowKeycap, secondKeycap] { keycap.setAccessibilityElement(false) }
        for dot in dots { dot.setAccessibilityElement(false) }
        for view in [writeButton, stopButton, spinner, glyph, label, firstKeycap, sayHowKeycap, secondKeycap, tryAgainLink,
                     sayHowLink, undoLink, settingsLink, tryAgainIcon, settingsIcon] + dots as [NSView] {
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

    /// Write's right-click menu: the same write, ⇧⌘J's strip and its presets, so “say how” is found from the button too.
    private func writeMenu() -> NSMenu {
        let menu = NSMenu(title: "Help Me Write")
        let write = NSMenuItem(title: "Write", action: #selector(writePressed), keyEquivalent: "j")
        write.keyEquivalentModifierMask = .command
        let sayHow = NSMenuItem(title: "Say How\u{2026}", action: #selector(sayHowPressed), keyEquivalent: "j")
        sayHow.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(write)
        menu.addItem(sayHow)
        menu.addItem(.separator())
        for (index, preset) in Self.presets.enumerated() {
            let item = NSMenuItem(title: preset, action: #selector(presetChosen(_:)), keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        for item in menu.items { item.target = self }
        return menu
    }

    // MARK: Content

    /// The control shows anything at all: Help me write is on, or a write's line is up (a failure says Help me write is
    /// off, after ⌘J).
    var isShown: Bool {
        if case .off = availability { return phase != .idle }
        return true
    }

    private var writerName: String {
        if case .ready(let writer, _) = availability { return writer }
        return "Claude"
    }

    /// The words of the line now, for VoiceOver and the app's tests: the whole line, whatever the row's room cuts.
    var lineWords: String {
        switch phase {
        case .idle:
            guard let hint = hintNow else { return "" }
            return "\u{2318}J " + (hint == .selection ? Self.selectionHintWords : Self.hintWords)
        case .writing:
            return (isRewriting ? "Rewriting" : "Writing") + " with \(writerName)\u{2026}"
        case .written:
            return "Written by \(writerName) \u{00b7} \u{2318}J Try again \u{00b7} \u{21e7}\u{2318}J Say how \u{00b7} \u{2318}Z Undo"
        case .failed(let reason, let settings):
            return reason + " \u{00b7} Try again" + (settings ? " \u{00b7} Settings\u{2026}" : "")
        }
    }

    /// The words the line shows now, as the row's room left them (tests and renders).
    var shownWords: String {
        let parts: [NSView] = [label, firstKeycap, tryAgainLink, sayHowKeycap, sayHowLink, secondKeycap, undoLink, settingsLink]
        return parts.filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }.map { view -> String in
            if let field = view as? NSTextField { return field.stringValue }
            if let keycap = view as? QuireKeycap { return keycap.legend }
            return (view as? SyncLineActionButton)?.title ?? ""
        }.joined(separator: " ")
    }

    private var hintNow: Hint? {
        guard phase == .idle, case .ready = availability else { return nil }
        return hint
    }

    private func apply() {
        let shown = isShown
        isHidden = !shown
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
            writeButton.toolTip = "Write with \(writer)  \u{2318}J\nSay how  \u{21e7}\u{2318}J\n\(source)"
            writeButton.setAccessibilityHelp("Writes a reply with \(writer), from your notes when you have typed some. "
                                             + "Command Shift J says how.")
        }
        writeButton.setAccessibilityLabel("Write with Help Me Write")
        label.toolTip = nil
        switch phase {
        case .idle:
            let hint = hintNow
            wholeWords = hint == .selection ? Self.selectionHintWords : hint == .notes ? Self.hintWords : ""
            wordsColor = .qInk3
            firstKeycap.legend = "\u{2318}J"
        case .writing:
            wholeWords = (isRewriting ? "Rewriting" : "Writing") + " with \(writerName)\u{2026}"
            wordsColor = .qInk2
            firstKeycap.legend = "esc"
        case .written:
            wholeWords = "Written by \(writerName)"
            wordsColor = .qInk2
            if case .ready(_, let source) = availability { label.toolTip = source }
            firstKeycap.legend = "\u{2318}J"
            tryAgainLink.isAlertLine = false
        case .failed(let reason, _):
            wholeWords = reason
            wordsColor = .qDanger
            label.toolTip = reason
            tryAgainLink.isAlertLine = true
            settingsLink.isAlertLine = true
            glyph.image = QuireSymbol.image(Quire.Icon.failed, size: .custom(Quire.Layout.WriteTool.statusGlyph, weight: .semibold))
            glyph.contentTintColor = .qDanger
            glyph.toolTip = reason
        }
        for dot in dots {
            dot.attributedStringValue = QuireFont.attributedString("\u{00b7}", role: .meta, color: phase == .written ? .qInk3 : wordsColor)
        }
        // VoiceOver reads the whole words, whatever the row's room cut from what shows.
        label.setAccessibilityLabel(wholeWords.isEmpty ? nil : wholeWords)
        if phase == .writing { spinner.startAnimation() } else { spinner.stopAnimation() }
        needsLayout = true
        onContentChange?()
    }

    // MARK: Forms

    /// One way the line can be shown, from whole to bare. `forms` lists a phase's, richest first; layout takes the first
    /// that fits.
    struct Form: Equatable {
        /// Write (or Stop) keeps its label; false: its glyph alone.
        var buttonLabel = true
        /// The idle hint: 0 whole, 1 its short words, 2 its keycap alone, 3 none.
        var hint = 0
        /// The line's words: shown whole, cut to the room (down to `minimumWords`), or not at all.
        var words = Words.whole
        /// The keycaps before the line's actions (⌘J, ⇧⌘J, ⌘Z, esc).
        var keycaps = true
        /// A reply's Say how.
        var sayHow = true
        /// A failure's Try again and Settings… as glyph buttons.
        var iconLinks = false

        enum Words: Equatable { case whole, cut, none }
    }

    /// The narrowest a cut label may get: past it, the words go.
    private static let minimumWords: CGFloat = 48

    /// A phase's forms, richest first.
    private var forms: [Form] {
        switch phase {
        case .idle:
            guard hintNow != nil else {
                return [Form(hint: 3), Form(buttonLabel: false, hint: 3)]
            }
            return [Form(hint: 0), Form(hint: 1), Form(hint: 2), Form(hint: 3), Form(buttonLabel: false, hint: 3)]
        case .writing:
            return [Form(), Form(keycaps: false), Form(words: .cut, keycaps: false), Form(words: .none, keycaps: false),
                    Form(buttonLabel: false, words: .none, keycaps: false)]
        case .written:
            // “Written by Claude” says who wrote the field's text (§5.56): it goes only where even Try again and Undo
            // beside it do not fit.
            return [Form(), Form(keycaps: false), Form(keycaps: false, sayHow: false),
                    Form(words: .none, keycaps: false, sayHow: false)]
        case .failed:
            return [Form(), Form(iconLinks: true), Form(words: .cut, iconLinks: true), Form(words: .none, iconLinks: true)]
        }
    }

    /// The width the control would like: everything whole.
    var fittingWidth: CGFloat {
        guard isShown, let first = forms.first else { return 0 }
        return width(of: first)
    }

    /// The narrowest width at which the line still says what it must: a reply's “Written by Claude · Try again · Undo”,
    /// a failure's whole reason with its links as glyphs. Idle, Write always follows the tools.
    var essentialWidth: CGFloat {
        switch phase {
        case .idle: return 0
        case .writing: return .greatestFiniteMagnitude
        case .written: return width(of: Form(keycaps: false, sayHow: false))
        case .failed: return width(of: Form(iconLinks: true))
        }
    }

    /// Where the quick reply puts the line in its tool row.
    enum Placement: Equatable {
        /// After the tabs and the tools, as Write and its hint always are.
        case afterTools
        /// After the mode tabs, Attach and Open in Composer giving way: Reply · Reply all stay at hand.
        case afterTabs
        /// From the row's start, the tabs and the tools giving way, as the send status does.
        case row
    }

    /// Where the line goes, given the room the row has after its tools and after its tabs: a reply's or a failure's line
    /// keeps the tools while it can say what it must beside them, then the tabs; while a reply streams (its edits wait)
    /// it always takes the row.
    func placement(roomAfterTools: CGFloat, roomAfterTabs: CGFloat) -> Placement {
        switch phase {
        case .idle: return .afterTools
        case .writing: return .row
        case .written, .failed:
            let needs = essentialWidth
            if needs <= roomAfterTools { return .afterTools }
            if needs <= roomAfterTabs { return .afterTabs }
            return .row
        }
    }

    /// How far in from the control's leading edge its first mark draws, so a host that starts the line at a text column
    /// lines the mark up with it: Stop's glyph sits inside its ghost padding.
    var leadingInset: CGFloat {
        switch phase {
        case .idle, .writing: return QuireButtonSize.small.padX
        case .written, .failed: return 0
        }
    }

    private func width(of form: Form) -> CGFloat {
        place(form, height: 22, apply: false)
    }

    // MARK: Geometry

    /// How a label draws its text in from each edge.
    private static let labelInset: CGFloat = 2

    private static func textWidth(_ words: String, color: NSColor = .qInk2) -> CGFloat {
        ceil(QuireFont.attributedString(words, role: .meta, color: color).size().width)
    }

    /// A button's visual width with `title` (empty: its glyph alone).
    private static func buttonWidth(_ title: String, symbol: String) -> CGFloat {
        QuireButton(title: title, variant: .ghost, size: .small, symbolName: symbol).intrinsicContentSize.width
    }

    private static let buttonWidths: [String: CGFloat] = [
        "Write": buttonWidth("Write", symbol: Quire.Icon.helpMeWrite),
        "": buttonWidth("", symbol: Quire.Icon.helpMeWrite),
        "Stop": buttonWidth("Stop", symbol: Quire.Icon.stopWriting),
        "-": buttonWidth("", symbol: Quire.Icon.stopWriting),
    ]

    /// The words a form shows for the label.
    private func words(for form: Form) -> String {
        switch phase {
        case .idle:
            guard let hint = hintNow, form.hint < 2 else { return "" }
            if form.hint == 0 { return wholeWords }
            return hint == .selection ? Self.shortSelectionHintWords : Self.shortHintWords
        default:
            return form.words == .none ? "" : wholeWords
        }
    }

    /// Lays `form` out from the leading edge, each part centred on a row `height` tall, and returns the trailing edge
    /// of what it placed. A label that may be cut is measured at its narrowest here; when applied, it takes the room
    /// left, its words cut to fit with an ellipsis, so it ends where its text does.
    @discardableResult
    private func place(_ form: Form, height: CGFloat, apply: Bool, room: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let t = Quire.Layout.WriteTool.self
        let mid = height / 2
        let inset = Self.labelInset
        let space = Self.textWidth(" ")
        let lineHeight = QuireFont.Role.meta.lineHeight
        var x: CGFloat = 0
        /// Where the last part's face ends: a link's reaches its padding past its words.
        var extent: CGFloat = 0
        var placedAny = false
        let words = words(for: form)
        var visible: [NSView] = []

        /// Places a control `gap` after what came before (its padding inside the row at the start), a label by its text.
        func put(_ view: NSView, gap: CGFloat, width fixed: CGFloat? = nil) {
            let start = placedAny ? x + gap : 0
            placedAny = true
            visible.append(view)
            if let control = view as? QuireControl {
                var size = control.intrinsicContentSize
                if let fixed { size.width = fixed }
                let isLink = view is SyncLineActionButton
                let padX = isLink ? SyncLineActionButton.padX : 0
                // A link draws its words `padX` in from its face: after a mark, the words keep the gap; first, the face does.
                let visualX = start == 0 ? 0 : start - padX
                let visual = NSRect(x: visualX, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height)
                if apply { control.frame = control.frame(forVisualRect: visual) }
                x = visual.maxX - padX
                extent = visual.maxX
            } else if let field = view as? NSTextField {
                let width = (fixed ?? Self.textWidth(field.stringValue)) + 2 * inset
                if apply { field.frame = NSRect(x: start - inset, y: (mid - lineHeight / 2).rounded(), width: width, height: lineHeight) }
                x = start + width - 2 * inset
                extent = x
            } else {
                let size = view === glyph ? NSSize(width: t.statusGlyph, height: t.statusGlyph) : view.intrinsicContentSize
                if apply { view.frame = NSRect(x: start, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height) }
                x = start + size.width
                extent = x
            }
        }

        /// The label: whole, or (a cut form, when applied) cut to what the row leaves after `after` more points.
        func putWords(gap: CGFloat, after: CGFloat) {
            guard !words.isEmpty else { return }
            let whole = Self.textWidth(words, color: wordsColor)
            var shown = words
            var width = whole
            if form.words == .cut {
                let start = (placedAny ? x + gap : 0)
                let available = max(Self.minimumWords, room - start - after)
                if apply, whole > available {
                    shown = Self.cut(words, toFit: available, color: wordsColor)
                    width = Self.textWidth(shown, color: wordsColor)
                } else if !apply {
                    width = min(whole, Self.minimumWords)
                }
            }
            if apply { label.attributedStringValue = QuireFont.attributedString(shown, role: .meta, color: wordsColor) }
            put(label, gap: gap, width: width)
        }

        func dot(_ index: Int, gap: CGFloat) { put(dots[index], gap: gap) }

        let buttonTitle: String
        switch phase {
        case .idle:
            buttonTitle = form.buttonLabel ? "Write" : ""
            if apply { writeButton.title = buttonTitle }
            put(writeButton, gap: 0, width: Self.buttonWidths[buttonTitle])
            if form.hint < 3 {
                if apply { firstKeycap.legend = "\u{2318}J" }
                // Write's ghost padding makes most of the space: the keycap sits `hintGap` from its face.
                put(firstKeycap, gap: t.hintGap)
                putWords(gap: t.keycapGap, after: 0)
            }
        case .writing:
            buttonTitle = form.buttonLabel ? "Stop" : "-"
            if apply { stopButton.title = form.buttonLabel ? "Stop" : "" }
            put(stopButton, gap: 0, width: Self.buttonWidths[buttonTitle])
            put(spinner, gap: t.gap)
            let escWidth = form.keycaps ? t.gap + firstKeycap.intrinsicContentSize.width : 0
            putWords(gap: t.statusGlyphGap, after: escWidth)
            if form.keycaps { put(firstKeycap, gap: t.gap) }
        case .written:
            // “Written by Claude · ⌘J Try again · ⇧⌘J Say how · ⌘Z Undo”.
            var dotIndex = 0
            func link(_ keycap: QuireKeycap?, _ link: SyncLineActionButton) {
                if placedAny {
                    dot(dotIndex, gap: space)
                    dotIndex += 1
                }
                if form.keycaps, let keycap {
                    put(keycap, gap: space)
                    put(link, gap: t.linkGap)
                } else {
                    put(link, gap: space)
                }
            }
            putWords(gap: 0, after: 0)
            link(firstKeycap, tryAgainLink)
            if form.sayHow { link(sayHowKeycap, sayHowLink) }
            link(secondKeycap, undoLink)
        case .failed(_, let offersSettings):
            // “⚠ The Anthropic API key was refused · Try again · Settings…”, or its links as glyphs.
            put(glyph, gap: 0)
            let settingsWidth = offersSettings ? t.keycapGap + settingsIcon.intrinsicContentSize.width : 0
            let iconsWidth = form.iconLinks ? t.gap + tryAgainIcon.intrinsicContentSize.width + settingsWidth : 0
            putWords(gap: t.statusGlyphGap, after: iconsWidth)
            if form.iconLinks {
                put(tryAgainIcon, gap: t.gap)
                if offersSettings { put(settingsIcon, gap: t.keycapGap) }
            } else {
                dot(0, gap: space)
                put(tryAgainLink, gap: space)
                if offersSettings {
                    dot(1, gap: space)
                    put(settingsLink, gap: space)
                }
            }
        }
        if apply {
            let all: [NSView] = [writeButton, stopButton, spinner, glyph, label, firstKeycap, sayHowKeycap, secondKeycap, tryAgainLink,
                                 sayHowLink, undoLink, settingsLink, tryAgainIcon, settingsIcon] + dots
            let shown = Set(visible.map(ObjectIdentifier.init))
            for view in all { view.isHidden = !shown.contains(ObjectIdentifier(view)) }
        }
        return ceil(max(x, extent))
    }

    /// `words` cut at a character to fit `width` points, with an ellipsis: at least its first letter and the ellipsis.
    static func cut(_ words: String, toFit width: CGFloat, color: NSColor = .qInk2) -> String {
        guard textWidth(words, color: color) > width else { return words }
        let characters = Array(words)
        var low = 1
        var high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = String(characters[..<mid]).trimmingCharacters(in: .whitespaces) + "\u{2026}"
            if textWidth(candidate, color: color) <= width { low = mid } else { high = mid - 1 }
        }
        return String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    override func layout() {
        super.layout()
        let available = bounds.width
        let chosen = forms.first { width(of: $0) <= available + 0.5 }
        form = chosen ?? Form()
        guard let chosen else {
            // Not even the barest form fits: nothing is drawn rather than over the host's next control.
            for view in subviews { view.isHidden = true }
            return
        }
        place(chosen, height: bounds.height, apply: true, room: available)
        // A guard, should a measure and a placement ever disagree: nothing shows past the width the host gave.
        for view in subviews where !view.isHidden {
            let visual = (view as? QuireControl).map { $0.alignmentRect(forFrame: $0.frame) }
                ?? (view is NSTextField ? view.frame.insetBy(dx: Self.labelInset, dy: 0) : view.frame)
            if visual.maxX > available + 0.5 { view.isHidden = true }
        }
    }

    // MARK: Actions

    @objc private func writePressed() { onWrite?() }
    @objc private func stopPressed() { onStop?() }
    @objc private func tryAgainPressed() { onTryAgain?() }
    @objc private func undoPressed() { onUndo?() }
    @objc private func settingsPressed() { onOpenSettings?() }
    @objc private func sayHowPressed() { onSayHow?() }

    @objc private func presetChosen(_ item: NSMenuItem) {
        guard Self.presets.indices.contains(item.tag) else { return }
        onPreset?(Self.presets[item.tag])
    }
}

extension WriteToolControl: NSMenuItemValidation {
    /// Write's menu acts only while Help me write can write and nothing is being written.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if case .ready = availability { return phase != .writing }
        return false
    }
}
