import AppKit

/// Text from Help Me Write going into a text view (spec §5.55, Writing): it replaces `range` (the selection, or the
/// user's own text) as it streams, with undo registration off and no edit reported, so typing, the draft and the undo
/// stack never see the stream; then either one undoable change, “Help Me Write”, from what was there to the reply, or
/// the text exactly as it was.
///
/// The stream writes the storage directly: the field refuses the user's own edits meanwhile (its owner's
/// `shouldChangeText` delegate answer), so the two never interleave.
@MainActor
final class WriteStreamEdit {
    static let actionName = "Help Me Write"

    let textView: NSTextView
    /// Where the reply goes, as it was before the write.
    let originalRange: NSRange
    let original: NSAttributedString
    private let originalSelection: [NSValue]
    private let attributes: [NSAttributedString.Key: Any]
    /// The text the stream has put in so far, and where it sits.
    private(set) var shown = ""
    private(set) var range: NSRange
    private(set) var isFinished = false
    /// The text changed under the stream without it (a reset its owner missed): the edit let it be and ended, rather than
    /// write at a range the storage no longer holds.
    private(set) var wasDisturbed = false
    /// The undo manager whose registration this edit turned off, so the same one is turned back on.
    private var silencedUndo: UndoManager?

    init(textView: NSTextView, range: NSRange, attributes: [NSAttributedString.Key: Any]) {
        self.textView = textView
        let length = textView.textStorage?.length ?? 0
        let location = min(max(0, range.location), length)
        let safe = NSRange(location: location, length: min(range.length, length - location))
        originalRange = safe
        original = textView.textStorage?.attributedSubstring(from: safe) ?? NSAttributedString()
        originalSelection = textView.selectedRanges
        self.attributes = attributes
        self.range = safe
    }

    /// Puts `text`, the whole reply so far, in the field: only what was added since the last call when the reply grew,
    /// all of it when it was replaced (a CLI's authoritative whole text).
    func show(_ text: String) {
        guard !isFinished, text != shown, let storage = textView.textStorage else { return }
        guard holdsItsRange(in: storage) else { return }
        silenceUndo()
        let now = text as NSString
        let before = shown as NSString
        storage.beginEditing()
        if before.length > 0, now.length > before.length, now.substring(to: before.length) == shown {
            let added = NSAttributedString(string: now.substring(from: before.length), attributes: attributes)
            storage.insert(added, at: NSMaxRange(range))
        } else {
            storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
        }
        storage.endEditing()
        shown = text
        range = NSRange(location: originalRange.location, length: now.length)
        let end = NSRange(location: NSMaxRange(range), length: 0)
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
    }

    /// The reply, as one undoable change from what was there before the write: Edit › Undo reads “Undo Help Me Write”
    /// and brings back exactly that. The caret ends after the reply. False when the field refused the change.
    @discardableResult
    func commit(_ text: String) -> Bool {
        guard !isFinished else { return false }
        restoreOriginal()
        isFinished = true
        let inserted = NSAttributedString(string: text, attributes: attributes)
        guard !wasDisturbed else { return false }
        guard let storage = textView.textStorage, inserted.length > 0,
              textView.shouldChangeText(in: originalRange, replacementString: text) else {
            textView.selectedRanges = originalSelection
            return false
        }
        // Its own undo step: typing just before or after must not fold into it.
        textView.breakUndoCoalescing()
        storage.replaceCharacters(in: originalRange, with: inserted)
        textView.didChangeText()
        textView.undoManager?.setActionName(Self.actionName)
        textView.breakUndoCoalescing()
        let end = NSRange(location: originalRange.location + inserted.length, length: 0)
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
        return true
    }

    /// The field exactly as it was before the write, selection included, with nothing on the undo stack.
    func rollback() {
        guard !isFinished else { return }
        restoreOriginal()
        isFinished = true
        if !wasDisturbed { textView.selectedRanges = originalSelection }
    }

    private func restoreOriginal() {
        if let storage = textView.textStorage, shown != "" || range != originalRange, holdsItsRange(in: storage) {
            silenceUndo()
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: original)
            storage.endEditing()
            range = originalRange
        }
        shown = ""
        if let silencedUndo {
            silencedUndo.enableUndoRegistration()
            self.silencedUndo = nil
        }
    }

    /// Whether the storage still holds the stream's range, as it does unless the text was replaced around the stream.
    /// When it does not, the edit ends here: undo comes back on, and nothing more is written or put back.
    private func holdsItsRange(in storage: NSTextStorage) -> Bool {
        guard NSMaxRange(range) > storage.length else { return true }
        wasDisturbed = true
        isFinished = true
        shown = ""
        if let silencedUndo {
            silencedUndo.enableUndoRegistration()
            self.silencedUndo = nil
        }
        return false
    }

    private func silenceUndo() {
        guard silencedUndo == nil, let undo = textView.undoManager else { return }
        undo.disableUndoRegistration()
        silencedUndo = undo
    }
}
