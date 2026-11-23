import AppKit
import PaperDesign

/// Text from Help Me Write going into a text view (spec §5.56, Writing): it replaces `range` (the selection, or the
/// user's own text) as it streams, drawn in pencil (`layout.writeCaret.pencilInk`, `ink2`), with undo registration off and
/// no edit reported, so typing, the draft and the undo stack never see the stream; then either one undoable change,
/// “Help Me Write”, from what was there to the reply in the field's own ink, or the text exactly as it was.
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
    /// The selection before the write (the caret, usually): a stop puts it back, and so does undoing the reply.
    let originalSelection: [NSValue]
    /// The field's whole text before the write.
    let textBefore: String
    private let attributes: [NSAttributedString.Key: Any]
    /// `attributes` in pencil: what streams in is not the user's text yet.
    private let pencilAttributes: [NSAttributedString.Key: Any]
    /// The text the stream has put in so far, and where it sits.
    private(set) var shown = ""
    private(set) var range: NSRange
    private(set) var isFinished = false
    /// The text changed under the stream without it (a reset its owner missed): the edit let it be and ended, rather than
    /// write at a range the storage no longer holds.
    private(set) var wasDisturbed = false
    /// The undo manager whose registration this edit turned off, so the same one is turned back on.
    private var silencedUndo: UndoManager?

    /// `previous`, when given, is shown in pencil in place of `range` until the first words arrive: Try again keeps the
    /// draft it replaces in sight rather than flashing the notes back. Without it, what `range` holds (the notes, the
    /// selection) turns to pencil where it is until then, its own style kept: it is what the reply will take the place of,
    /// and the pencil mark waits after it (§5.56).
    init(textView: NSTextView, range: NSRange, attributes: [NSAttributedString.Key: Any], showing previous: String? = nil) {
        self.textView = textView
        let length = textView.textStorage?.length ?? 0
        let location = min(max(0, range.location), length)
        let safe = NSRange(location: location, length: min(range.length, length - location))
        originalRange = safe
        original = textView.textStorage?.attributedSubstring(from: safe) ?? NSAttributedString()
        originalSelection = textView.selectedRanges
        textBefore = textView.string
        self.attributes = attributes
        var pencil = attributes
        pencil[.foregroundColor] = WriteStreamEdit.pencilInk
        pencilAttributes = pencil
        self.range = safe
        if let previous, !previous.isEmpty, let storage = textView.textStorage {
            silenceUndo()
            storage.beginEditing()
            storage.replaceCharacters(in: safe, with: NSAttributedString(string: previous, attributes: pencilAttributes))
            storage.endEditing()
            self.range = NSRange(location: safe.location, length: (previous as NSString).length)
            holdsPrevious = true
            wroteStorage = true
        } else if safe.length > 0, let manager = textView.layoutManager {
            // Drawn in pencil, not written: the storage and the undo stack stay as they are until the first words come
            // (undo registration turned off now, in the same event as the user's typing, would leave that typing's undo
            // group open for good).
            manager.addTemporaryAttribute(.foregroundColor, value: WriteStreamEdit.pencilInk, forCharacterRange: safe)
            penciledInPlace = true
        }
    }

    /// Pencil: the colour token `layout.writeCaret.pencilInk` names (`ink2`).
    static var pencilInk: NSColor {
        (QuireColorToken(rawValue: Quire.Layout.WriteCaret.pencilInk) ?? .ink2).color
    }

    /// The previous draft is in the field, in pencil, until the first words replace it.
    private var holdsPrevious = false
    /// The storage holds something of the stream's (or the previous draft), so a rollback has text to put back.
    private var wroteStorage = false
    /// What the reply will replace is drawn in pencil where it is (a layout manager's temporary colour), until the first
    /// words take its place or the edit ends.
    private var penciledInPlace = false

    private func clearPencilInPlace() {
        guard penciledInPlace else { return }
        penciledInPlace = false
        textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: originalRange)
    }

    /// Puts `text`, the whole reply so far, in the field: only what was added since the last call when the reply grew,
    /// all of it when it was replaced (a CLI's authoritative whole text).
    func show(_ text: String) {
        guard !isFinished, text != shown || holdsPrevious, let storage = textView.textStorage else { return }
        guard holdsItsRange(in: storage) else { return }
        clearPencilInPlace()
        silenceUndo()
        let now = text as NSString
        let before = shown as NSString
        storage.beginEditing()
        if !holdsPrevious, before.length > 0, now.length > before.length, now.substring(to: before.length) == shown {
            let added = NSAttributedString(string: now.substring(from: before.length), attributes: pencilAttributes)
            storage.insert(added, at: NSMaxRange(range))
        } else {
            storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: pencilAttributes))
        }
        holdsPrevious = false
        wroteStorage = true
        storage.endEditing()
        shown = text
        range = NSRange(location: originalRange.location, length: now.length)
        let end = NSRange(location: NSMaxRange(range), length: 0)
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
    }

    /// The reply, as one undoable change from what was there before the write: Edit › Undo reads “Undo Help Me Write”
    /// and brings back exactly that, with the caret where it was before the write (never the notes selected, which ⌘J
    /// would then rewrite as a selection); Redo puts the reply back with the caret after it. The caret ends after the
    /// reply. False when the field refused the change.
    ///
    /// `alongside` runs once the change is in, inside the same undo group and before it is named: what lands with the
    /// draft (a new message's subject) registers its own inverse on the manager it is handed, so one Undo takes both
    /// back. It never runs for a change that did not go in.
    @discardableResult
    func commit(_ text: String, alongside: ((UndoManager?) -> Void)? = nil) -> Bool {
        guard !isFinished else { return false }
        restoreOriginal()
        isFinished = true
        let inserted = NSAttributedString(string: text, attributes: attributes)
        guard !wasDisturbed else { return false }
        // The owner's answer first (it refuses while it holds edits), so a refused change leaves no step behind.
        let allowed = textView.isEditable
            && (textView.delegate?.textView?(textView, shouldChangeTextIn: originalRange, replacementString: text) ?? true)
        guard let storage = textView.textStorage, inserted.length > 0, allowed else {
            textView.selectedRanges = originalSelection
            return false
        }
        // Its own undo step: typing just before or after must not fold into it.
        textView.breakUndoCoalescing()
        let end = NSRange(location: originalRange.location + inserted.length, length: 0)
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        // An undo group runs last what was registered first: the caret goes back after the text view's own undo of the
        // change (registered as it is asked whether it may change), which selects the text it puts back. The second
        // registration runs first on undo and does nothing then; its redo runs last on redo, after the text view selects
        // the reply, and puts the caret after it.
        Self.registerSelection(on: undo, of: textView, undoTo: originalSelection, redoTo: nil)
        guard textView.shouldChangeText(in: originalRange, replacementString: text) else {
            undo?.endUndoGrouping()
            textView.selectedRanges = originalSelection
            return false
        }
        storage.replaceCharacters(in: originalRange, with: inserted)
        textView.didChangeText()
        alongside?(undo)
        Self.registerSelection(on: undo, of: textView, undoTo: nil, redoTo: [NSValue(range: end)])
        undo?.setActionName(Self.actionName)
        undo?.endUndoGrouping()
        textView.breakUndoCoalescing()
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
        return true
    }

    /// Registers on `undo` a step that sets `textView`'s selection to `undoTo` (nothing when nil) and registers its
    /// inverse, which sets `redoTo`: one of the pair runs on each undo and redo of the reply's group.
    private static func registerSelection(on undo: UndoManager?, of textView: NSTextView, undoTo: [NSValue]?, redoTo: [NSValue]?) {
        guard let undo else { return }
        undo.registerUndo(withTarget: textView) { [weak undo] view in
            MainActor.assumeIsolated {
                if let undoTo, let length = view.textStorage?.length,
                   undoTo.allSatisfy({ NSMaxRange($0.rangeValue) <= length }) {
                    view.selectedRanges = undoTo
                }
                registerSelection(on: undo, of: view, undoTo: redoTo, redoTo: undoTo)
            }
        }
    }

    /// The field exactly as it was before the write, selection included, with nothing on the undo stack.
    func rollback() {
        guard !isFinished else { return }
        restoreOriginal()
        isFinished = true
        if !wasDisturbed { textView.selectedRanges = originalSelection }
    }

    private func restoreOriginal() {
        clearPencilInPlace()
        if let storage = textView.textStorage, wroteStorage || shown != "" || range != originalRange, holdsItsRange(in: storage) {
            silenceUndo()
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: original)
            storage.endEditing()
            range = originalRange
        }
        wroteStorage = false
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
