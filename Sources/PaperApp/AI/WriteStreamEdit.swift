import AppKit
import PaperCore
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
    /// Written after the reply as part of it, as given: in a new message or a forward, the empty line between a draft and
    /// the pictures it goes above, or that and the pictures of the notes it replaces, so a draft never takes a picture
    /// away (`WriteSession.picturesKept(after:attributes:)`). Empty for every other write.
    let trailing: NSAttributedString
    private var trailingLength: Int { trailing.length }

    /// Where the landed part ends in the field, after `commit`: the caret's place, and the line the afterline and the
    /// prompt line hang under. A rewrite whose neighbour words changed length moves it.
    private(set) var landedPartEnd: Int?
    /// The landed rewrite changed words beside its selection (`Seams`), for what VoiceOver says.
    private(set) var landedJoin = false

    /// The words beside a rewritten selection that may land with it, in one step (spec §5.56): its gaps and windows as
    /// the field held them when the rewrite was asked (`WriteSeamWindows`), and the new words the writer accepted for a
    /// window. Nothing outside these ranges and the selection is ever in the landing's range.
    struct Seams {
        struct Side {
            /// The window, in the field before the write.
            var range: NSRange
            /// Its text then: the storage must still hold exactly this for it to change.
            var original: String
            /// Its new words (empty takes the window away); nil leaves it as it is.
            var replacement: String?
            /// The window's own style, which its new words take.
            var attributes: [NSAttributedString.Key: Any]
        }

        /// The blanks between the before window and the selection, and between the selection and the after window.
        var gapBefore: NSRange
        var gapAfter: NSRange
        var before: Side?
        var after: Side?
    }

    /// The marks a part may begin with that take no blank before them, and after-words that take none before them.
    static let jointPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", "\u{2026}"]

    /// `previous`, when given, is shown in pencil in place of `range` until the first words arrive: Try again keeps the
    /// draft it replaces in sight rather than flashing the notes back. Without it, what `range` holds (the notes, the
    /// selection) turns to pencil where it is until then, its own style kept: it is what the reply will take the place of,
    /// and the pencil mark waits after it (§5.56).
    init(textView: NSTextView, range: NSRange, attributes: [NSAttributedString.Key: Any], showing previous: String? = nil,
         trailing: NSAttributedString = NSAttributedString()) {
        self.textView = textView
        self.trailing = trailing
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
            storage.replaceCharacters(in: safe, with: penciled(previous))
            storage.endEditing()
            self.range = NSRange(location: safe.location, length: (previous as NSString).length + trailingLength)
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

    /// Where the text the stream has put in ends, before `trailing`: the pencil mark waits there.
    var textEnd: Int {
        wroteStorage ? NSMaxRange(range) - trailingLength : NSMaxRange(range)
    }

    /// `text` in pencil, then `trailing` as given.
    private func penciled(_ text: String) -> NSAttributedString {
        let whole = NSMutableAttributedString(string: text, attributes: pencilAttributes)
        whole.append(trailing)
        return whole
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
            storage.insert(added, at: NSMaxRange(range) - trailingLength)
        } else {
            storage.replaceCharacters(in: range, with: penciled(text))
        }
        holdsPrevious = false
        wroteStorage = true
        storage.endEditing()
        shown = text
        range = NSRange(location: originalRange.location, length: now.length + trailingLength)
        let end = NSRange(location: NSMaxRange(range) - trailingLength, length: 0)
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
    ///
    /// With `seams` (a rewrite that sent the draft around its selection), the words beside it the writer accepted, and
    /// the blank a punctuation joint drops, land in the same step: one wider range, one replacement, one undo step, the
    /// caret after the part. A side the storage no longer holds as it was asked is left as it is. Without any change
    /// beside the part, the step is exactly the one without `seams`.
    @discardableResult
    func commit(_ text: String, seams: Seams? = nil, alongside: ((UndoManager?) -> Void)? = nil) -> Bool {
        guard !isFinished else { return false }
        restoreOriginal()
        isFinished = true
        if let seams, !wasDisturbed, trailing.length == 0, !text.isEmpty, let joint = joint(for: text, seams: seams) {
            return commit(text, joint: joint, alongside: alongside)
        }
        let inserted = NSMutableAttributedString(string: text, attributes: attributes)
        inserted.append(trailing)
        let replacement = inserted.string
        guard !wasDisturbed else { return false }
        // The owner's answer first (it refuses while it holds edits), so a refused change leaves no step behind.
        let allowed = textView.isEditable
            && (textView.delegate?.textView?(textView, shouldChangeTextIn: originalRange, replacementString: replacement) ?? true)
        guard let storage = textView.textStorage, !text.isEmpty, allowed else {
            textView.selectedRanges = originalSelection
            return false
        }
        // Its own undo step: typing just before or after must not fold into it.
        textView.breakUndoCoalescing()
        // The caret after the reply's last word, before `trailing`.
        let end = NSRange(location: originalRange.location + inserted.length - trailingLength, length: 0)
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        // An undo group runs last what was registered first: the caret goes back after the text view's own undo of the
        // change (registered as it is asked whether it may change), which selects the text it puts back. The second
        // registration runs first on undo and does nothing then; its redo runs last on redo, after the text view selects
        // the reply, and puts the caret after it.
        Self.registerSelection(on: undo, of: textView, undoTo: originalSelection, redoTo: nil)
        guard textView.shouldChangeText(in: originalRange, replacementString: replacement) else {
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
        landedPartEnd = end.location
        return true
    }

    /// What a rewrite with seams lands: the range it replaces, which never leaves the windows, the gaps and the
    /// selection, and what goes there.
    struct Joint {
        var range: NSRange
        var replacement: NSAttributedString
        var partEnd: Int
        /// A window's words changed (not only a blank dropped).
        var changesWords: Bool
    }

    /// The joint for `text` over `seams`, read from the storage as it stands (restored to before the write); nil when
    /// nothing beside the part changes, so the step is the plain one.
    private func joint(for text: String, seams: Seams) -> Joint? {
        guard let storage = textView.textStorage else { return nil }
        let string = storage.string as NSString
        let core = originalRange
        // The pieces must sit where they were asked, side by side, around the selection.
        guard NSMaxRange(seams.gapBefore) == core.location, seams.gapAfter.location == NSMaxRange(core),
              NSMaxRange(seams.gapAfter) <= string.length, isBlanks(seams.gapBefore, in: string),
              isBlanks(seams.gapAfter, in: string) else { return nil }
        /// A side changes only where the storage still holds its words exactly, beside its gap, with no link or picture.
        func changing(_ side: Seams.Side?, endsAt: Int?, startsAt: Int?) -> (range: NSRange, words: String, attributes: [NSAttributedString.Key: Any])? {
            guard let side, let words = side.replacement, side.range.length > 0, NSMaxRange(side.range) <= string.length else { return nil }
            if let endsAt, NSMaxRange(side.range) != endsAt { return nil }
            if let startsAt, side.range.location != startsAt { return nil }
            guard string.substring(with: side.range) == side.original else { return nil }
            var marked = false
            storage.enumerateAttributes(in: side.range, options: []) { attributes, _, stop in
                if attributes[.link] != nil || attributes[.attachment] != nil {
                    marked = true
                    stop.pointee = true
                }
            }
            return marked ? nil : (side.range, words, side.attributes)
        }
        var before = changing(seams.before, endsAt: seams.gapBefore.location, startsAt: nil)
        var after = changing(seams.after, endsAt: nil, startsAt: NSMaxRange(seams.gapAfter))
        let startsWithMark = text.first.map { Self.jointPunctuation.contains($0) } ?? false
        let dropsGapBefore = seams.gapBefore.length > 0 && (before?.words.isEmpty == true || startsWithMark)
        let dropsGapAfter = seams.gapAfter.length > 0 && after.map { $0.words.isEmpty || $0.words.first.map(Self.jointPunctuation.contains) == true } == true
        guard before != nil || after != nil || dropsGapBefore || dropsGapAfter else { return nil }
        // New words that come right up to the part keep the blank that parted the window's words from it.
        if let words = before?.words, let original = seams.before?.original, seams.gapBefore.length == 0, !startsWithMark {
            before?.words = Self.keepingBlank(words, original: original, partedByGap: false, after: false)
        }
        if let words = after?.words, let original = seams.after?.original, seams.gapAfter.length == 0 || dropsGapAfter {
            after?.words = Self.keepingBlank(words, original: original, partedByGap: seams.gapAfter.length > 0, after: true)
        }

        let start = before?.range.location ?? (dropsGapBefore ? seams.gapBefore.location : core.location)
        let end = after.map { NSMaxRange($0.range) } ?? (dropsGapAfter ? NSMaxRange(seams.gapAfter) : NSMaxRange(core))
        let replacement = NSMutableAttributedString()
        if let before { replacement.append(NSAttributedString(string: before.words, attributes: before.attributes)) }
        if before != nil, !dropsGapBefore { replacement.append(storage.attributedSubstring(from: seams.gapBefore)) }
        let partStart = replacement.length
        replacement.append(NSAttributedString(string: text, attributes: attributes))
        if after != nil, !dropsGapAfter { replacement.append(storage.attributedSubstring(from: seams.gapAfter)) }
        if let after { replacement.append(NSAttributedString(string: after.words, attributes: after.attributes)) }
        return Joint(range: NSRange(location: start, length: end - start), replacement: replacement,
                     partEnd: start + partStart + (text as NSString).length, changesWords: before != nil || after != nil)
    }

    /// `words`, new words for a window that meet the part with no gap between them (none was there, or the joint
    /// drops it), with the blank kept that parted the window's first word (`after`) or last word from the part: in its
    /// gap (`partedByGap`) or in the window's own punctuation beside the part (“, so the March”). Its punctuation may
    /// go, but words never glue onto the part: “too.” and “So the March” land as “too. So the March”, never
    /// “too.So the March”; “Please call” before “John”, where “Please call (” was, as “Please call John”.
    static func keepingBlank(_ words: String, original: String, partedByGap: Bool, after: Bool) -> String {
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        if after {
            guard let first = words.firstIndex(where: isWord) else { return words }
            let originalEdge = original.prefix { !isWord($0) }
            guard partedByGap || originalEdge.contains(where: \.isWhitespace), !words[..<first].contains(where: \.isWhitespace) else {
                return words
            }
            return String(words[..<first]) + " " + words[first...]
        }
        guard let last = words.lastIndex(where: isWord) else { return words }
        let edge = words.index(after: last)
        let originalEdge = original.reversed().prefix { !isWord($0) }
        guard partedByGap || originalEdge.contains(where: \.isWhitespace), !words[edge...].contains(where: \.isWhitespace) else {
            return words
        }
        return String(words[..<edge]) + " " + words[edge...]
    }

    /// The rewrite and its joint as one undoable change, “Help Me Write”, as the plain commit makes it: the owner asked
    /// first, the caret registered on both sides of the text view's own step, the caret after the part.
    private func commit(_ text: String, joint: Joint, alongside: ((UndoManager?) -> Void)?) -> Bool {
        let replacement = joint.replacement.string
        let allowed = textView.isEditable
            && (textView.delegate?.textView?(textView, shouldChangeTextIn: joint.range, replacementString: replacement) ?? true)
        guard let storage = textView.textStorage, allowed else {
            textView.selectedRanges = originalSelection
            return false
        }
        textView.breakUndoCoalescing()
        let end = NSRange(location: joint.partEnd, length: 0)
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        Self.registerSelection(on: undo, of: textView, undoTo: originalSelection, redoTo: nil)
        guard textView.shouldChangeText(in: joint.range, replacementString: replacement) else {
            undo?.endUndoGrouping()
            textView.selectedRanges = originalSelection
            return false
        }
        storage.replaceCharacters(in: joint.range, with: joint.replacement)
        textView.didChangeText()
        alongside?(undo)
        Self.registerSelection(on: undo, of: textView, undoTo: nil, redoTo: [NSValue(range: end)])
        undo?.setActionName(Self.actionName)
        undo?.endUndoGrouping()
        textView.breakUndoCoalescing()
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
        landedPartEnd = joint.partEnd
        landedJoin = joint.changesWords
        return true
    }

    private func isBlanks(_ range: NSRange, in string: NSString) -> Bool {
        (range.location..<NSMaxRange(range)).allSatisfy { WriteSeamWindows.isGapBlank(string.character(at: $0)) }
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
