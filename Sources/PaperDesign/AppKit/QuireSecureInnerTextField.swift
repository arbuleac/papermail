import AppKit

/// The secure counterpart of `QuireInnerTextField` (spec §5.25 Secure): bullets with
/// `textField.secureTracking` (2 pt) between them, at rest and while editing. The system draws secure bullets
/// without the text's kerning, so the cell draws them itself at rest and the field editor's text takes the
/// kerning while it edits.
@MainActor
final class QuireSecureInnerTextField: NSSecureTextField, QuireInnerField {
    var onFocusChange: (@MainActor (Bool) -> Void)?

    override class var cellClass: AnyClass? {
        get { QuireSecureTextFieldCell.self }
        set { super.cellClass = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureInnerField()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override func becomeFirstResponder() -> Bool {
        innerFieldWillBecomeFirstResponder()
        let accepted = super.becomeFirstResponder()
        if accepted { trackEditor() }
        innerFieldDidBecomeFirstResponder(accepted)
        return accepted
    }

    override func textDidChange(_ notification: Notification) {
        trackEditor()
        super.textDidChange(notification)
    }

    /// The I-beam over the field, cut out of what lies on it (§4.17): none under the cheat sheet, which takes the
    /// keyboard. AppKit's own lies over the whole visible rect and cannot be cut.
    override func resetCursorRects() {
        if isEnabled, isSelectable { addTextPointerRects() }
    }

    override func textDidEndEditing(_ notification: Notification) {
        innerFieldWillEndEditing()
        super.textDidEndEditing(notification)
        innerFieldDidEndEditing()
    }

    /// Kerns the field editor's text and its typing, so bullets keep their spacing as the user types.
    private func trackEditor() {
        guard let editor = currentEditor() as? NSTextView, let storage = editor.textStorage else { return }
        let tracking = Quire.Layout.TextField.secureTracking
        editor.typingAttributes[.kern] = tracking
        storage.addAttribute(.kern, value: tracking, range: NSRange(location: 0, length: storage.length))
    }
}

/// Draws a secure field's bullets with Quire's tracking while the field is not editing.
final class QuireSecureTextFieldCell: NSSecureTextFieldCell {
    static let bullet = "\u{2022}"

    /// The bullets the cell shows for `value`, as drawn: one per character, kerned.
    static func bullets(for value: String, font: NSFont?, color: NSColor?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: String(repeating: bullet, count: value.count), attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: color ?? NSColor.textColor,
            .kern: Quire.Layout.TextField.secureTracking,
            .paragraphStyle: paragraph,
        ])
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let editing = (controlView as? NSTextField)?.currentEditor() != nil
        guard !editing, !stringValue.isEmpty else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        let text = QuireSecureTextFieldCell.bullets(for: stringValue, font: font, color: textColor)
        text.draw(with: titleRect(forBounds: cellFrame), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}
