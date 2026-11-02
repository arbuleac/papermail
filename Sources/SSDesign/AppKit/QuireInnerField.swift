import AppKit

/// What the borderless fields inside Quire's containers share, the plain one and the secure one: no bezel,
/// no ring, one line, tail truncation at rest and scrolling only while editing (a scrollable cell never
/// truncates, spec §4.4), the `accent` caret, and a callback when editing starts and ends.
@MainActor
protocol QuireInnerField: NSTextField {
    var onFocusChange: (@MainActor (Bool) -> Void)? { get set }
}

extension QuireInnerField {
    var isEditing: Bool { currentEditor() != nil }

    func configureInnerField() {
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        cell?.wraps = false
        setScrolls(false)
    }

    func setScrolls(_ scrolls: Bool) {
        // The line break mode first: setting it can reset the cell's scrolling.
        lineBreakMode = scrolls ? .byClipping : .byTruncatingTail
        cell?.truncatesLastVisibleLine = !scrolls
        cell?.isScrollable = scrolls
        needsDisplay = true
    }

    /// Call before `super.becomeFirstResponder()`: the field editor copies the cell's scrolling when it starts.
    func innerFieldWillBecomeFirstResponder() {
        if !isEditing { setScrolls(true) }
    }

    /// Call with what `super.becomeFirstResponder()` returned.
    func innerFieldDidBecomeFirstResponder(_ accepted: Bool) {
        guard accepted else {
            if !isEditing { setScrolls(false) }
            return
        }
        (currentEditor() as? NSTextView)?.insertionPointColor = .qAccent
        onFocusChange?(true)
    }

    /// Call before `super.textDidEndEditing(_:)`.
    func innerFieldWillEndEditing() {
        (currentEditor() as? NSTextView)?.insertionPointColor = .textInsertionPointColor
    }

    /// Call after `super.textDidEndEditing(_:)`.
    func innerFieldDidEndEditing() {
        setScrolls(false)
        onFocusChange?(false)
    }
}
