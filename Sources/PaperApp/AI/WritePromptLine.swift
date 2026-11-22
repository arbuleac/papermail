import AppKit
import PaperDesign

/// The prompt line (§5.56, ⇧⌘J “Say how”): opened in the reply's text, under the caret's line (the selection's last line;
/// a draft's, right after one), in a space the text below moves down to make, never over the text. A capsule as wide as
/// the text column (at most `promptMaxWidth`): `pencil.line` in `accent`, the field in the writing font (“Tell Claude what
/// to write…”, “…how to rewrite it…” with a selection) and the quiet ↩ keycap; `chipsGap` under it, the presets as quiet
/// text chips (Shorter · Friendlier · Say no politely), washed under the pointer or the keyboard. ↩ runs the field, a
/// chip runs its words, Esc closes the line and gives the keyboard back to the text, Tab or ↓ moves to the chips.
@MainActor
final class WritePromptLine: NSView, NSTextFieldDelegate {
    /// ↩ or a chip: the instruction to run (the field's words, a chip's).
    var onRun: ((String) -> Void)?
    /// Esc in the line: the session stops a write, or closes the line.
    var onEscape: (() -> Void)?
    /// The keyboard came into the line or left it: its ring follows.
    var onFocusChange: (() -> Void)?

    let field = PromptField(frame: .zero)
    private(set) var chips: [Chip] = []

    /// The writer named in the placeholder (“Claude”).
    var writer = "Claude" { didSet { if oldValue != writer { updatePlaceholder() } } }

    /// The selection is what it rewrites: the placeholder says so.
    var rewritesSelection = false {
        didSet { if oldValue != rewritesSelection { updatePlaceholder() } }
    }

    /// The reply's writing style: the field types in it.
    var textAttributes: [NSAttributedString.Key: Any] = [:] {
        didSet {
            guard !NSDictionary(dictionary: oldValue).isEqual(to: textAttributes) else { return }
            if let font = textAttributes[.font] as? NSFont, field.font != font { field.font = font }
            updatePlaceholder()
            needsLayout = true
        }
    }

    var instruction: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// Forces the key window's look (renders launched from a terminal, which may never be key).
    var windowKeyOverride: Bool? {
        didSet { needsDisplay = true; chips.forEach { $0.windowKeyOverride = windowKeyOverride } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.delegate = self
        field.onFocusChange = { [weak self] in
            self?.needsDisplay = true
            self?.onFocusChange?()
        }
        field.setAccessibilityLabel("Instruction for Help Me Write")
        addSubview(field)
        for title in WriteWords.presets {
            let chip = Chip(frame: .zero)
            chip.title = title
            chip.takesKeyboard = true
            chip.onPress = { [weak self] in self?.run(chip: title) }
            chip.onKey = { [weak self, weak chip] key in
                guard let self, let chip else { return false }
                return self.chipKey(key, on: chip)
            }
            chip.setAccessibilityHelp("Writes with the instruction \u{201c}\(title)\u{201d}")
            chips.append(chip)
            addSubview(chip)
        }
        // Tab from the field reaches the chips and comes back round to it, inside the line.
        field.nextKeyView = chips.first
        for (index, chip) in chips.enumerated() { chip.nextKeyView = index + 1 < chips.count ? chips[index + 1] : field }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Help Me Write instructions")
        updatePlaceholder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("built in code")
    }

    override var isFlipped: Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    /// A click on the capsule outside its field (the pencil, the ↩, the padding) puts the keyboard in the field, as a
    /// search field's does; one in the line's gaps (between the chips, under the capsule) does nothing. Neither goes on to
    /// the text view the line lies in, whose click would move the caret into the text under the line and close it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if capsuleRect.contains(point), !fieldHoldsFocus { window?.makeFirstResponder(field) }
    }

    /// Frames are set by hand: a new size lays the capsule and the chips out again.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// The line's height in the text's flow, its gaps above and below included (the reserved block's).
    nonisolated static var blockHeight: CGFloat {
        let c = Quire.Layout.WriteCaret.self
        return c.blockGapTop + c.promptHeight + c.chipsGap + c.chipHeight + c.blockGapBottom
    }

    var placeholder: String { WriteWords.promptPlaceholder(writer: writer, rewrites: rewritesSelection) }

    private func updatePlaceholder() {
        var attributes = textAttributes
        attributes[.foregroundColor] = NSColor.qInk3
        attributes[.paragraphStyle] = nil
        attributes[.baselineOffset] = nil
        if attributes[.font] == nil { attributes[.font] = QuireFont.font(.writing) }
        let new = NSAttributedString(string: placeholder, attributes: attributes)
        guard field.placeholderAttributedString?.isEqual(to: new) != true else { return }
        // AppKit applies a new placeholder by ending the field's editing: the keyboard, and where it was, come back.
        let editing = fieldHoldsFocus ? field.currentEditor()?.selectedRange : nil
        field.placeholderAttributedString = new
        field.setAccessibilityPlaceholderValue(placeholder)
        if let editing, !fieldHoldsFocus, let window {
            window.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = editing
        }
    }

    // MARK: Geometry

    /// The capsule, in the line's coordinates: its leading edge on the text column's.
    var capsuleRect: NSRect {
        let c = Quire.Layout.WriteCaret.self
        return NSRect(x: 0, y: 0, width: max(0, min(bounds.width, c.promptMaxWidth)), height: c.promptHeight)
    }

    /// Where the field's words start: the chips' words line up under them.
    private var textX: CGFloat {
        let c = Quire.Layout.WriteCaret.self
        return capsuleRect.minX + c.promptPadX + ceil(WriteGlyph.size(Quire.Icon.helpMeWrite, size: c.promptGlyph).width) + c.promptGlyphGap
    }

    override func layout() {
        super.layout()
        let c = Quire.Layout.WriteCaret.self
        let capsule = capsuleRect
        let keycap = WriteQuietKeycap.size("\u{21a9}")
        let fieldHeight = ceil(field.cell?.cellSize.height ?? 18)
        // A borderless field's cell sets its text 2 pt in: the field starts that far before the words.
        let fieldX = textX - 2
        field.frame = NSRect(x: fieldX, y: (capsule.midY - fieldHeight / 2).rounded(),
                             width: max(0, capsule.maxX - c.promptPadX - keycap.width - c.promptGlyphGap - fieldX), height: fieldHeight)
        var x = textX - c.chipPadX
        let y = capsule.maxY + c.chipsGap
        let dot = ceil(Chip.dotWidth)
        for (index, chip) in chips.enumerated() {
            let width = chip.intrinsicContentSize.width
            // A chip that does not fit the column is not shown rather than drawn past it.
            chip.isHidden = x + width > bounds.width + 0.5
            chip.frame = chip.frame(forVisualRect: NSRect(x: x, y: y, width: width, height: c.chipHeight))
            x += width
            if index + 1 < chips.count { x += c.chipGap + dot + c.chipGap }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = Quire.Layout.WriteCaret.self
        let capsule = capsuleRect
        let radius = capsule.height / 2
        QuireDraw.fill(capsule, radius: radius, .qRaised)
        let strong = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        QuireDraw.strokeInside(capsule, radius: radius, width: strong ? 1 : QuireHairline.width(for: self), strong ? .qRuleStrong : .qRule)
        let glyph = WriteGlyph.size(Quire.Icon.helpMeWrite, size: c.promptGlyph)
        WriteGlyph.draw(Quire.Icon.helpMeWrite, size: c.promptGlyph, color: .qAccent,
                        centredIn: NSRect(x: capsule.minX + c.promptPadX, y: capsule.minY, width: ceil(glyph.width), height: capsule.height))
        let size = WriteQuietKeycap.size("\u{21a9}")
        WriteQuietKeycap.draw("\u{21a9}", in: NSRect(x: capsule.maxX - c.promptPadX - size.width, y: (capsule.midY - size.height / 2).rounded(),
                                                     width: size.width, height: size.height),
                              ink: .qInk3, hairline: QuireHairline.width(for: self))
        if fieldHoldsFocus, windowKeyOverride ?? window?.isKeyWindow ?? false {
            // The ring on the capsule's own edge, inside it: the text's column is the capsule's, and the quick reply's
            // clip would cut a ring drawn outside.
            QuireFocusRing.drawInset(in: capsule, cornerRadius: radius)
        }
        // The dots between the chips.
        let lineHeight = QuireFont.Role.meta.lineHeight
        for (index, chip) in chips.enumerated() where index + 1 < chips.count && !chips[index + 1].isHidden {
            let face = chip.alignmentRect(forFrame: chip.frame)
            Chip.dot.draw(with: NSRect(x: face.maxX + c.chipGap, y: (face.midY - lineHeight / 2).rounded(), width: Chip.dotWidth + 1,
                                       height: lineHeight), options: QuireFont.drawingOptions, context: nil)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePlaceholder()
        needsDisplay = true
    }

    // MARK: Keyboard

    /// Puts the keyboard in the field, its words selected so typing replaces them.
    func focus() {
        guard let window else { return }
        // A field not laid out yet (as wide as nothing) cannot start editing: the keyboard would land on the window.
        needsLayout = true
        layoutSubtreeIfNeeded()
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Whether the keyboard is in the field (its editor included).
    var fieldHoldsFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSTextView, editor.isFieldEditor { return (editor.delegate as? NSView) === field }
        return responder === field
    }

    /// Whether the keyboard is anywhere in the line: the field or a chip.
    var holdsFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if fieldHoldsFocus { return true }
        return (responder as? NSView)?.isDescendant(of: self) ?? false
    }

    private func run(chip title: String) {
        field.stringValue = title
        onRun?(title)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onRun?(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            guard let first = chips.first(where: { !$0.isHidden }) else { return false }
            window?.makeFirstResponder(first)
            return true
        default:
            return false
        }
    }

    /// A key on a focused chip: ↩ runs it (Space does, as on every control), ← → move along the chips, ↑ goes back to the
    /// field, Esc closes the line.
    private func chipKey(_ event: NSEvent, on chip: Chip) -> Bool {
        let shown = chips.filter { !$0.isHidden }
        guard let index = shown.firstIndex(where: { $0 === chip }) else { return false }
        switch event.keyCode {
        case 36, 76:
            chip.onPress?()
        case 53:
            onEscape?()
        case 123:
            if index > 0 { window?.makeFirstResponder(shown[index - 1]) }
        case 124:
            if index + 1 < shown.count { window?.makeFirstResponder(shown[index + 1]) }
        case 126:
            window?.makeFirstResponder(field)
        default:
            return false
        }
        return true
    }

    // MARK: Parts

    /// The prompt's field: borderless on the capsule, in the reply's writing font, its caret `accent`.
    final class PromptField: NSTextField {
        var onFocusChange: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            textColor = .qInk
            usesSingleLineMode = true
            cell?.isScrollable = true
            cell?.wraps = false
            lineBreakMode = .byClipping
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("built in code")
        }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted {
                (currentEditor() as? NSTextView)?.insertionPointColor = .qAccent
                leaveTheFieldEditorsPointerToTheField()
                onFocusChange?()
            }
            return accepted
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            onFocusChange?()
        }

        override func resetCursorRects() {
            addTextPointerRects()
        }
    }

    /// A preset as a quiet text chip: its words in `meta` `ink2`, a washed capsule under the pointer or the keyboard.
    final class Chip: WriteInlineControl {
        var title = "" {
            didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(title) }
        }
        /// A key the chip answers itself (↩, the arrows, Esc).
        var onKey: ((NSEvent) -> Bool)?

        static let dot = QuireFont.attributedString("\u{00b7}", role: .meta, color: .qInk3)
        static var dotWidth: CGFloat { ceil(dot.size().width) }

        private func label(_ color: NSColor) -> NSAttributedString {
            QuireFont.attributedString(title, role: .meta, color: color)
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: ceil(label(.qInk2).size().width) + 2 * Quire.Layout.WriteCaret.chipPadX, height: Quire.Layout.WriteCaret.chipHeight)
        }

        override func keyDown(with event: NSEvent) {
            if onKey?(event) == true { return }
            super.keyDown(with: event)
        }

        override func draw(_ dirtyRect: NSRect) {
            let face = bodyRect
            let state = interactionState
            let washed = state != .rest || hasKeyboardFocus && isWindowKey
            if washed { QuireDraw.fill(face, radius: face.height / 2, state == .pressed ? .qPressed : .qHover) }
            let text = label(washed ? .qInk : .qInk2)
            let lineHeight = QuireFont.Role.meta.lineHeight
            text.draw(with: NSRect(x: face.minX + Quire.Layout.WriteCaret.chipPadX, y: (face.midY - lineHeight / 2).rounded(),
                                   width: face.width, height: lineHeight), options: QuireFont.drawingOptions, context: nil)
            if showsFocusRing { QuireFocusRing.draw(around: face, cornerRadius: face.height / 2) }
        }
    }
}

extension WritePromptLine.Chip: ShellKeyHandling {
    /// ↩ and Esc on a focused chip are the line's, before the window's single keys (§6).
    func handlesKey(_ event: NSEvent) -> Bool { [36, 76, 53, 123, 124, 126].contains(event.keyCode) }
}
