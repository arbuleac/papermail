import AppKit

/// The borderless `NSTextField` inside Quire's field containers (spec §5.25: “an NSTextField with isBezeled =
/// false inside a layer-backed container that paints face, edge and ring”). It draws only text, never a ring,
/// and tells its container when editing starts and ends so the container can draw focus. While it edits, the
/// shared field editor's caret is `accent`.
@MainActor
final class QuireInnerTextField: NSTextField {
    var onFocusChange: (@MainActor (Bool) -> Void)?

    /// What a borderless text field cell insets its text by on each side; containers subtract it so the text
    /// starts exactly at their padding.
    static let cellInset: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    var isEditing: Bool { currentEditor() != nil }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            (currentEditor() as? NSTextView)?.insertionPointColor = .qAccent
            onFocusChange?(true)
        }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        (currentEditor() as? NSTextView)?.insertionPointColor = .textInsertionPointColor
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}
