import AppKit

/// The borderless `NSTextField` inside Quire's field containers (spec §5.25: “an NSTextField with isBezeled =
/// false inside a layer-backed container that paints face, edge and ring”). It draws only text, never a ring,
/// and tells its container when editing starts and ends so the container can draw focus. While it edits, the
/// shared field editor's caret is `accent`.
@MainActor
final class QuireInnerTextField: NSTextField, QuireInnerField {
    var onFocusChange: (@MainActor (Bool) -> Void)?

    /// Set while the container changes something AppKit applies by ending and restarting the editing session (the
    /// placeholder, for one). That restart is no focus change: it reports none and keeps the editing setup.
    var isRestartingEditing = false

    /// What a borderless text field cell insets its text by on each side; containers subtract it so the text
    /// starts exactly at their padding.
    static let cellInset: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureInnerField()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override func becomeFirstResponder() -> Bool {
        innerFieldWillBecomeFirstResponder()
        let accepted = super.becomeFirstResponder()
        innerFieldDidBecomeFirstResponder(accepted)
        return accepted
    }

    /// No I-beam under the cheat sheet, which takes the keyboard (§4.17).
    override func resetCursorRects() {
        if !isUnderPointerCover { super.resetCursorRects() }
    }

    override func textDidEndEditing(_ notification: Notification) {
        guard !isRestartingEditing else { return super.textDidEndEditing(notification) }
        innerFieldWillEndEditing()
        super.textDidEndEditing(notification)
        innerFieldDidEndEditing()
    }
}
