import AppKit
import SSDesign

/// Help me write's instruction strip (spec §5.56, ⇧⌘J): one line docked inside the reply, above its text, never floating:
/// a field “Tell it what to write…” and three quiet preset chips that fill it and run it (“Shorter”, “Friendlier”,
/// “Say no politely”). ↩ runs what the field says; Esc stops a write, or closes the strip. With text selected in the reply
/// it says how to rewrite the selection. The session keeps the last instruction for this reply until it is sent.
@MainActor
final class WriteInstructionStrip: NSView, NSTextFieldDelegate {
    static let placeholder = "Tell it what to write\u{2026}"
    static let rewritePlaceholder = "Tell it how to rewrite the selection\u{2026}"
    static let presets = ["Shorter", "Friendlier", "Say no politely"]

    /// ↩ or a chip: the instruction to run (the field's words, a chip's title).
    var onRun: ((String) -> Void)?
    /// Esc in the strip: the session stops a write, or closes the strip.
    var onEscape: (() -> Void)?

    let field = QuireTextField(placeholder: WriteInstructionStrip.placeholder)
    private(set) var chips: [QuireButton] = []

    /// The selection is what it rewrites: the placeholder says so.
    var rewritesSelection = false {
        didSet {
            guard oldValue != rewritesSelection else { return }
            field.placeholder = rewritesSelection ? Self.rewritePlaceholder : Self.placeholder
            field.textField.setAccessibilityPlaceholderValue(field.placeholder)
        }
    }

    var instruction: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.textField.delegate = self
        field.textField.setAccessibilityLabel("Instruction for Help Me Write")
        field.textField.setAccessibilityPlaceholderValue(Self.placeholder)
        addSubview(field)
        for title in Self.presets {
            let chip = QuireButton(title: title, variant: .secondary, size: .small)
            chip.target = self
            chip.action = #selector(chipPressed(_:))
            chip.setAccessibilityHelp("Writes with the instruction \u{201c}\(title)\u{201d}")
            chips.append(chip)
            addSubview(chip)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Help Me Write instructions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WriteInstructionStrip is built in code")
    }

    override var isFlipped: Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The strip's height: one text field.
    static var height: CGFloat { Quire.Layout.TextField.height }

    override func layout() {
        super.layout()
        let s = Quire.Layout.WriteStrip.self
        let height = Self.height
        var trailing = bounds.width
        var shown: [QuireButton] = []
        // Chips leave from the last while the field would be narrower than its minimum.
        var widths = chips.map { $0.intrinsicContentSize.width }
        while !widths.isEmpty {
            let chipsWidth = widths.reduce(0, +) + CGFloat(widths.count - 1) * s.chipGap + s.chipsGap
            if bounds.width - chipsWidth >= s.fieldMinWidth { break }
            widths.removeLast()
        }
        shown = Array(chips.prefix(widths.count))
        for chip in chips { chip.isHidden = !shown.contains { $0 === chip } }
        for chip in shown.reversed() {
            let size = chip.intrinsicContentSize
            let visual = NSRect(x: trailing - size.width, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
            chip.frame = chip.frame(forVisualRect: visual)
            trailing = visual.minX - s.chipGap
        }
        let fieldWidth = max(0, (shown.isEmpty ? bounds.width : trailing + s.chipGap - s.chipsGap))
        field.frame = field.frame(forVisualRect: NSRect(x: 0, y: 0, width: fieldWidth, height: height))
    }

    /// Puts the keyboard in the field, its words selected so typing replaces them.
    func focus() {
        guard let window else { return }
        window.makeFirstResponder(field.textField)
        field.textField.currentEditor()?.selectAll(nil)
    }

    /// Whether the keyboard is in the strip (its field's editor included).
    var holdsFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let owner = editor.delegate as? NSView {
            return owner.isDescendant(of: self)
        }
        return (responder as? NSView)?.isDescendant(of: self) ?? false
    }

    // MARK: Actions

    @objc private func chipPressed(_ sender: QuireButton) {
        field.stringValue = sender.title
        onRun?(sender.title)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onRun?(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
            return true
        default:
            return false
        }
    }
}
