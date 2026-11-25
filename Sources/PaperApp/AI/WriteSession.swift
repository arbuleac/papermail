import AppKit
import PaperCore
import PaperDesign
import os

/// Help me write in one field, at the caret (spec §5.56): the quick reply's field or a composer's body, whatever it
/// writes (a reply, a new message, the message above a forward). Everything it shows is in the text itself
/// (`WriteInlineLayer`): the ghost “⌘J to write a reply” after the caret, “⌘J to write from your notes” once the user
/// pauses at the end of them, the pill “Rewrite ⌘J” under a settled selection, ⇧⌘J's prompt line under the caret's line,
/// the pencil after the last word while a draft streams, and the afterline under the draft.
///
/// One rule for ⌘J (and the ghost, the pill, the context menu): it writes at once where there is something to write
/// from, and opens the prompt line where there is nothing. Something to write from is a selection, the user's notes, a
/// draft just written (Try again), a reply's conversation or a forward's forwarded message; an empty new message has
/// none of them, so ⌘J asks what to write there and sends nothing. A write streams into the field in pencil, replacing
/// the user's notes (or the selection), then lands in ink as one undoable step, “Undo Help Me Write”, which brings the
/// notes back, and with them the empty Subject of a new message the draft gave a subject to. Right after, ⌘J tries
/// again from the same notes; once the user edits the draft, ⌘J writes from what the field holds now.
///
/// Nothing is read, built or sent before the user acts (spec §3b): what shows comes from this Mac's facts alone
/// (`HelpMeWrite.availability`), and the write itself is the one place in the app that makes a write's `AIUserAction`,
/// after it has checked that there is something to write from. The ghost's and the pill's timers are local; showing any
/// mark, opening the prompt line or the context menu sends nothing. There is no permission sheet here: permission is
/// given in Settings › AI when a provider is chosen; without it, ⌘J says so under the caret's line and sends nothing.
///
/// The quick reply's owner and each composer keep one session for as long as the field lives. `end()` stops its write
/// first: the writer's field is the text view's identity, and a write must never outlive the message it fills.
@MainActor
final class WriteSession {
    let center: HelpMeWrite
    /// The field's adapter, which holds its owner weakly: the owner keeps the session, the session keeps the adapter.
    let field: WriteField
    /// The marks in the text.
    let layer: WriteInlineLayer

    /// What the session is doing, as the text shows it.
    private(set) var phase: WritePhase = .idle {
        didSet {
            // What failed is asked again only from under its own line: once that line goes, so does the ask.
            if !phase.isFailed { lastFailure = nil }
            guard oldValue != phase else { return }
            render()
        }
    }

    /// Whether Help me write can write here now, from this Mac's facts (read again on `refresh()`).
    private(set) var availability: WriteAvailability = .off

    /// Where the prompt line hangs while it shows.
    private var promptAnchor: WriteInlineLayer.Anchor?
    var isPromptShown: Bool { promptAnchor != nil }

    /// Where a failure's afterline hangs: under the caret's line as ⌘J was pressed.
    private var failureAnchor: WriteInlineLayer.Anchor = .caret(0)

    /// The last reply written here, while it stands as written: Try again replaces it from the same notes.
    private struct Draft {
        var ask: WriteAsk
        /// Where the notes (or the selection) were, which the reply replaced.
        var range: NSRange
        var isRewrite: Bool
        /// The reply as it landed.
        var reply: String
        /// Where the landed part ends in the field: the afterline and the prompt line hang under its line. A rewrite
        /// whose neighbour words changed length lands its part somewhere else than `range` says.
        var partEnd: Int
        /// The field's whole text with the reply in it.
        var textAfter: String
        /// The field's whole text before the reply (the notes): ⌘Z brings it back, ⌘⇧Z the reply, and neither is the
        /// user's edit. Any other text is.
        var textBefore: String
        /// The selection before ⌘J (the caret, usually), which ⌘Z puts back with the notes.
        var selection: [NSValue]
        /// Who wrote it, for the afterline.
        var writer: String
        var source: String?
        /// What was written, as its request named it: a forward without its forwarded message is a new message.
        var kind: WriteKind
        /// The instruction a new message was first written from, when it had no notes: its whole brief. A follow-up
        /// (Shorter, a chip, new words) keeps it as the notes of what it asks, and after ⌘Z back to the empty body ⌘J
        /// offers it again in the prompt line.
        var brief: String?
    }

    private var lastDraft: Draft?

    /// A write under way: what it asks, so a draft that lands becomes `lastDraft` and one that fails can be asked again.
    private struct Running {
        var ask: WriteAsk
        var isRewrite: Bool
        var kind: WriteKind
        /// A subject was asked for with the draft.
        var wantsSubject: Bool
        var brief: String?
        /// A rewrite that sent the draft around its selection: where its gaps and windows are in the field, so the
        /// words the writer accepts for them land with the part.
        var seams: SeamRanges?
    }

    private var running: Running?

    /// The gaps and windows beside a selection whose rewrite sent the draft around it (`WriteAsk.Around`), in the
    /// field's text as it was asked, with each window's words and style.
    struct SeamRanges {
        var gapBefore: NSRange
        var before: NSRange
        var beforeText: String
        var gapAfter: NSRange
        var after: NSRange
        var afterText: String
        /// Each window's own style, read as the write starts: once the part streams in, the field's text there is the
        /// stream's, in pencil, until the edit puts it back at landing.
        var beforeAttributes: [NSAttributedString.Key: Any] = [:]
        var afterAttributes: [NSAttributedString.Key: Any] = [:]

        /// Nil for a rewrite that sent the selection alone, or for anything else.
        init?(core: NSRange, around: WriteAsk.Around?) {
            guard let around else { return nil }
            let beforeText = around.before as NSString
            let afterText = around.after as NSString
            guard around.beforeGap >= 0, around.beforeWindow >= 0, around.afterGap >= 0, around.afterWindow >= 0,
                  around.beforeGap + around.beforeWindow <= beforeText.length,
                  around.afterGap + around.afterWindow <= afterText.length,
                  core.location >= around.beforeGap + around.beforeWindow else { return nil }
            gapBefore = NSRange(location: core.location - around.beforeGap, length: around.beforeGap)
            before = NSRange(location: gapBefore.location - around.beforeWindow, length: around.beforeWindow)
            self.beforeText = beforeText.substring(with: NSRange(location: beforeText.length - around.beforeGap - around.beforeWindow,
                                                                 length: around.beforeWindow))
            gapAfter = NSRange(location: NSMaxRange(core), length: around.afterGap)
            after = NSRange(location: NSMaxRange(gapAfter), length: around.afterWindow)
            self.afterText = afterText.substring(with: NSRange(location: around.afterGap, length: around.afterWindow))
        }

        /// The windows' styles, read from `field` before anything streams into it.
        @MainActor mutating func readStyle(of field: WriteField) {
            if before.length > 0 { beforeAttributes = field.seamAttributes(at: before.location) }
            if after.length > 0 { afterAttributes = field.seamAttributes(at: after.location) }
        }

        /// What lands beside the part for `join`, the words the writer accepted: each changed window in its own style.
        func edits(for join: WriteJoin?) -> WriteStreamEdit.Seams {
            func side(_ range: NSRange, _ text: String, _ words: String?, _ attributes: [NSAttributedString.Key: Any])
                -> WriteStreamEdit.Seams.Side? {
                guard let words, range.length > 0 else { return nil }
                return .init(range: range, original: text, replacement: words, attributes: attributes)
            }
            return WriteStreamEdit.Seams(gapBefore: gapBefore, gapAfter: gapAfter,
                                         before: side(before, beforeText, join?.before, beforeAttributes),
                                         after: side(after, afterText, join?.after, afterAttributes))
        }
    }

    /// What the last write that did not go through was asked, kept while its reason shows under the caret's line: Try
    /// again asks the same again (§5.56), the same notes and the same instruction.
    private enum Failure {
        /// It could not start (Help Me Write off, not turned on, needing setup): the instruction it came with.
        case notStarted(instruction: String?)
        /// It was asked and failed. `text` is the field's whole text as it was asked, which must still stand.
        case asked(ask: WriteAsk, range: NSRange, isRewrite: Bool, brief: String?, text: String)
    }

    private var lastFailure: Failure?
    /// The subject the write under way proposes for its message, held here and never shown while the body streams: it
    /// is set only as the draft lands, in the draft's one undo step, so Stop, a failure, a close or an autosave
    /// mid-write leave the Subject as it was.
    private var proposedSubject: String?
    /// The new words for the words beside a rewritten selection, as the writer accepted them: held, never shown while
    /// the part streams, and landed with it in its one step.
    private var proposedJoin: WriteJoin?
    private var configuration: AIProviderConfiguration?
    private var edit: WriteStreamEdit?
    private var writeTask: Task<Void, Never>?
    /// Bumped by every write and every stop, so events meant for an earlier write are dropped.
    private var generation = 0
    /// The whole reply so far, and whether the field has caught up with it.
    private var written = ""
    private var flushScheduled = false
    /// Set while the session itself changes the text (a reply landing, Try again's undo), which is not the user's edit.
    private var isChangingText = false
    private var responderObservation: NSKeyValueObservation?
    private var availabilityObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?

    /// The notes ghost waits for a pause in the typing (`layout.writeCaret.ghostPause`); a selection made from the keyboard
    /// settles before its pill shows (`selectionSettle`). Both timers are this Mac's alone.
    private var ghostTimer: Timer?
    private var notesGhostReady = false
    private var pillTimer: Timer?
    private var selectionSettled = true

    /// Renders launched from a terminal stand for the key window, which they may never be (debug snapshots).
    var assumesKeyWindow = false {
        didSet {
            layer.windowKeyOverride = assumesKeyWindow ? true : nil
            render()
        }
    }

    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "ai")
    private static let signposter = OSSignposter(subsystem: AppIdentity.bundleIdentifier, category: "ai")
    /// Every session with a write streaming, by window: Edit › Undo waits while one streams there (§6.1).
    private static var streaming: [ObjectIdentifier: Int] = [:]

    #if DEBUG
    /// The debug-only live check reads what a write sends, to report it; nothing else sets it, and it is never logged.
    static var requestObserver: ((AIWriteRequest) -> Void)?
    #endif

    init(center: HelpMeWrite, field: WriteField) {
        self.center = center
        self.field = field
        layer = field.writeLayer
        layer.ghost.onPress = { [weak self] in self?.writeFromMark() }
        layer.pill.onPress = { [weak self] in self?.writeFromMark() }
        layer.pencil.onPress = { [weak self] in self?.stop() }
        layer.afterline.onAction = { [weak self] action in self?.afterlineAction(action) }
        layer.prompt.onRun = { [weak self] instruction in self?.runFromPrompt(instruction) }
        layer.prompt.onEscape = { [weak self] in _ = self?.promptEscape() }
        layer.prompt.onFocusChange = { [weak self] in self?.layer.prompt.needsDisplay = true }
        layer.onReservedSpaceChange = { [weak field] in field?.reservedSpaceDidChange() }
        layer.onScroll = { [weak self] in self?.textDidScroll() }
        // A new text size: the ghost, the pencil and the prompt line set their words in the text's new style at once.
        layer.onEnvironmentChange = { [weak self] in self?.render() }
        availabilityObserver = NotificationCenter.default.addObserver(forName: HelpMeWrite.availabilityDidChange, object: center,
                                                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    deinit {
        if let availabilityObserver { NotificationCenter.default.removeObserver(availabilityObserver) }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        ghostTimer?.invalidate()
        pillTimer?.invalidate()
    }

    var isWriting: Bool { phase == .writing }

    /// Whether a Help me write reply is streaming into a field of `window`: its undo stack waits until it ends.
    static func isStreaming(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return (streaming[ObjectIdentifier(window)] ?? 0) > 0
    }

    private var textView: NSTextView { field.writeTextView }

    // MARK: What the text shows

    /// Reads the provider's state again from this Mac (the field took the keyboard, Settings changed) and shows it: for
    /// what this field writes, since a provider turned on for replies is not ready for anything else.
    func refresh() {
        let kind = field.writeKind
        availability = center.availability(for: kind)
        layer.prompt.writer = availability.writer
        layer.prompt.presets = WriteWords.presets(for: kind)
        watchTheKeyboard()
        render()
    }

    /// What the field can be written from changed without the user's doing (a forward's forwarded message arrived, or
    /// will not): the ghost follows, and the line that said it was still loading goes.
    func fieldDidChange() {
        if phase == .notice(WriteWords.forwardLoading) { phase = .idle }
        refresh()
    }

    /// The marks the text shows now, from the phase, the caret, the selection and the provider's state.
    private func render() {
        layer.textAttributes = field.writeAttributes(at: NSRange(location: textView.selectedRange().location, length: 0))
        var state = WriteInlineLayer.State()
        if isWriting {
            state.pencil = edit.map(\.textEnd)
        } else if let promptAnchor {
            state.block = .prompt(promptAnchor, chips: canWriteAtOnce)
        } else if phase == .written, let lastDraft, textView.string == lastDraft.textAfter {
            state.block = .afterline(.end(lastDraft.partEnd),
                                     .written(writer: lastDraft.writer, rewrite: lastDraft.isRewrite, source: lastDraft.source))
        } else if case .failed(let reason, let settings) = phase {
            state.block = .afterline(failureAnchor, .failed(reason: reason, offersSettings: settings))
        } else if case .notice(let words) = phase {
            state.block = .afterline(failureAnchor, .notice(words))
        }
        if !isWriting, canShowMarks {
            // Read once a keystroke: a composer finds its signature by walking the body's attributes.
            let own = field.ownTextRange
            if !isPromptShown, selectionSettled, let selection = rewritableSelection, NSMaxRange(selection) <= NSMaxRange(own) {
                state.pill = selection
            }
            if state.block == nil { state.ghost = ghost(own: own) }
        }
        layer.apply(state)
    }

    /// The text has the keyboard in a key window, a provider is ready and no marked text (an input method's) is open:
    /// the ghost and the pill may show.
    private var canShowMarks: Bool {
        guard availability.isReady, let window = textView.window, window.firstResponder === textView, !textView.hasMarkedText(),
              !textView.isHiddenOrHasHiddenAncestor else { return false }
        return assumesKeyWindow || window.isKeyWindow
    }

    /// The ghost after the caret (§5.56): on an empty field at once, in the words of what ⌘J does there; at the end of
    /// a paragraph of the user's notes once they pause; never mid-line, never in the signature, and none where only a
    /// selection can be rewritten.
    private func ghost(own: NSRange) -> WriteInlineLayer.Ghost? {
        let selection = textView.selectedRange()
        guard selection.length == 0, field.selectionOnlyReason == nil else { return nil }
        let text = textView.string as NSString
        let at = selection.location
        guard at >= own.location, at <= NSMaxRange(own) else { return nil }
        // At the end of a paragraph: the next letter is a line break, or the user's text ends there.
        guard at == NSMaxRange(own) || (at < text.length && WriteTextGeometry.isLineEnd(text.character(at: at))) else { return nil }
        // Never the whole notes copied or counted on each key: the first letter, then the first few words, are enough.
        guard NSMaxRange(own) <= text.length else { return nil }
        let kind = field.writeKind
        if text.rangeOfCharacter(from: Self.words(writing: kind), options: [], range: own).location == NSNotFound {
            if let offset = field.placeholderWidth {
                return WriteInlineLayer.Ghost(location: at, words: WriteWords.ghostAfterPlaceholder, offset: offset)
            }
            return WriteInlineLayer.Ghost(location: at, words: WriteWords.emptyGhost(for: kind))
        }
        guard notesGhostReady, Self.hasWords(Int(Quire.Layout.WriteCaret.hintMinWords), in: text, range: own) else { return nil }
        return WriteInlineLayer.Ghost(location: at, words: WriteWords.ghostNotes, fades: true)
    }

    /// The selection ⌘J would rewrite, less its leading and trailing blanks: nil with nothing selected, or a selection of
    /// spaces and line breaks only, which ⌘J treats as no selection (it writes from the notes or the thread).
    private var rewritableSelection: NSRange? {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length > 0, NSMaxRange(selection) <= text.length else { return nil }
        let core = Self.trimmedCore(of: selection, in: text)
        guard Self.holdsWords(text.substring(with: core), writing: field.writeKind) else { return nil }
        return core
    }

    /// Whether `text` holds something written, in a field writing `kind`: anything but blanks, and in a new message or
    /// a forward anything but a picture (its attachment character, `WriteAsk.pictureCharacter`) or an invisible mark
    /// (`AIRedactor.invisibleCharacters`: a byte-order mark left by a paste, a right-to-left mark) too, which hold no
    /// words. That is the body as `WriteKind.hasNothingToWriteFrom` and the request's cleaning read it, scalar by
    /// scalar, so the ghost, the plan, the ask and where the draft goes agree with what would be sent: there a body of
    /// pictures and marks alone is empty to ⌘J, its ghost the empty body's, and a selection of them alone is none. A
    /// reply's field reads a picture and a mark as it always did.
    static func holdsWords(_ text: String, writing kind: WriteKind) -> Bool {
        kind == .reply ? text.contains { !$0.isWhitespace } : text.unicodeScalars.contains { written.contains($0) }
    }

    /// `holdsWords` as a set, for a search in the text without copying it.
    static func words(writing kind: WriteKind) -> CharacterSet {
        kind == .reply ? notBlank : written
    }

    private static let notBlank = CharacterSet.whitespacesAndNewlines.inverted
    private static let written = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: WriteAsk.pictureCharacter))
        .union(AIRedactor.invisibleCharacters).inverted

    /// The selection moved (a click, the arrows, a drag let go): the ghost goes until the next pause, the pill follows the
    /// selection once it has settled, and the open prompt's placeholder follows what ⌘J would rewrite.
    func selectionDidChange() {
        guard !isWriting, !isChangingText else { return }
        restartGhostPause()
        pillTimer?.invalidate()
        pillTimer = nil
        if rewritableSelection != nil, NSApp.currentEvent?.type == .keyDown {
            // ⇧→ held or repeated: the pill waits until the selection stops moving.
            selectionSettled = false
            let timer = Timer(timeInterval: Quire.Motion.writeSelectionSettle, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.selectionSettled = true
                    self?.render()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pillTimer = timer
        } else {
            selectionSettled = true
        }
        if isPromptShown { layer.prompt.rewritesSelection = rewritableSelection != nil }
        render()
    }

    private var ownText: String {
        let text = textView.string as NSString
        let own = field.ownTextRange
        guard NSMaxRange(own) <= text.length else { return "" }
        return text.substring(with: own)
    }

    /// Words: runs holding a letter or a digit.
    static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    /// Whether `range` of `text` holds at least `count` words (`wordCount`'s words), reading no further than they reach.
    static func hasWords(_ count: Int, in text: NSString, range: NSRange) -> Bool {
        guard count > 0 else { return true }
        let blank = CharacterSet.whitespacesAndNewlines
        let wordy = CharacterSet.letters.union(.decimalDigits)
        var found = 0
        var inRun = false
        var runHasWord = false
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let unit = text.character(at: index)
            let isBlank = UnicodeScalar(unit).map { blank.contains($0) } ?? false
            if isBlank {
                if inRun, runHasWord { found += 1; if found >= count { return true } }
                inRun = false
                runHasWord = false
            } else {
                inRun = true
                // A surrogate half is part of a letter outside the BMP: it counts as one.
                if UnicodeScalar(unit).map({ wordy.contains($0) }) ?? true { runHasWord = true }
            }
            index += 1
        }
        if inRun, runHasWord { found += 1 }
        return found >= count
    }

    /// The user changed the text (typing, a paste, an undo): the afterline about the last reply or a failure goes, and
    /// Try again with it; the notes ghost waits for the next pause.
    func userDidEdit() {
        guard !isChangingText else { return }
        if phase.showsLine { phase = .idle }
        // ⌘Z back to the notes and ⌘⇧Z back to the reply keep Try again: a redone reply is tried again from its notes.
        if phase != .writing, let lastDraft, textView.string != lastDraft.textAfter, textView.string != lastDraft.textBefore {
            self.lastDraft = nil
        }
        restartGhostPause()
        render()
    }

    /// The notes ghost goes now and comes back once the user has paused (`ghostPause`).
    private func restartGhostPause() {
        notesGhostReady = false
        ghostTimer?.invalidate()
        let timer = Timer(timeInterval: Quire.Motion.writeGhostPause, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notesGhostReady = true
                self.render()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ghostTimer = timer
    }

    private func textDidScroll() {
        guard notesGhostReady, layer.state.ghost != nil else { return }
        restartGhostPause()
        render()
    }

    /// The text's own I-beam is cut out of the marks (§4.17): each keeps its own pointer.
    var pointerHoles: [NSRect] { layer.pointerHoles }

    // MARK: What ⌘J does now

    enum Plan: Equatable {
        /// Rewrite the selection.
        case rewriteSelection
        /// Write again from the same notes: the last draft stands as written.
        case tryAgain
        /// Say why nothing but a selection can be rewritten here (`WriteField.selectionOnlyReason`).
        case selectionOnly
        /// Write from the user's notes.
        case fromNotes
        /// Write from what the field answers or forwards alone: a reply's conversation, a forward's message.
        case fromContext
        /// Ask what to write: there is nothing to write from, so the prompt line opens and nothing is sent.
        case askWhat
    }

    var plan: Plan {
        if rewritableSelection != nil, !isWriting { return .rewriteSelection }
        if standingDraft != nil { return .tryAgain }
        if field.selectionOnlyReason != nil { return .selectionOnly }
        let own = ownText
        let kind = field.writeKind
        if kind.hasNothingToWriteFrom(WriteAsk(draft: .notes(own))) { return .askWhat }
        return Self.holdsWords(own, writing: kind) ? .fromNotes : .fromContext
    }

    /// The last draft, while it stands in the field as it was written: ⌘J tries again from what it was written from.
    private var standingDraft: Draft? {
        guard let lastDraft, textView.string == lastDraft.textAfter else { return nil }
        return lastDraft
    }

    /// Whether ⌘J would write at once here, with no instruction: there is a selection, a draft just written, notes, or
    /// what the field answers or forwards. The prompt line's chips show exactly then, since each is a whole instruction
    /// that runs by itself.
    private var canWriteAtOnce: Bool {
        switch plan {
        case .rewriteSelection, .tryAgain, .fromNotes, .fromContext: return true
        case .selectionOnly, .askWhat: return false
        }
    }

    /// Edit › Help Me Write's title for what it does now (§5.35). “Write Message…” ends in an ellipsis because it asks
    /// for more: on an empty new message ⌘J opens the prompt line.
    func menuTitle(withInstructions: Bool) -> String {
        let noun = WriteWords.noun(for: field.writeKind)
        switch (plan, withInstructions) {
        case (.rewriteSelection, false): return "Rewrite Selection"
        case (.rewriteSelection, true): return "Rewrite Selection with Instructions\u{2026}"
        case (.selectionOnly, false): return MainMenu.helpMeWriteTitle
        case (.selectionOnly, true): return MainMenu.helpMeWriteWithInstructionsTitle
        case (.tryAgain, false): return "Try Again"
        case (.fromNotes, false): return "Write \(noun) from Notes"
        case (.fromContext, false): return "Write \(noun)"
        case (.askWhat, false): return "Write \(noun)\u{2026}"
        case (_, true): return "Write \(noun) with Instructions\u{2026}"
        }
    }

    // MARK: The context menu

    /// The text's right-click menu's Help Me Write group (§5.56), at its top while a provider is on: what ⌘J does here,
    /// then Say How…, then a separator. Showing it sends nothing; choosing an item does what its key does.
    func contextMenuItems() -> [NSMenuItem] {
        guard availability != .off, !isWriting else { return [] }
        let write = WriteMenuAction.item(menuTitle(withInstructions: false), key: "j", modifiers: .command) { [weak self] in
            self?.writeFromMark()
        }
        let sayHow = WriteMenuAction.item("Say How\u{2026}", key: "j", modifiers: [.command, .shift]) { [weak self] in
            self?.sayHowFromMark()
        }
        return [write, sayHow, .separator()]
    }

    // MARK: Writing

    /// The ghost, the pill, the afterline's Try again or the context menu: the keyboard goes to the text first, so a
    /// selection there counts.
    private func writeFromMark() {
        if textView.window?.firstResponder !== textView, !layer.promptHoldsFocus { field.focusText() }
        write()
    }

    /// ⌘J: Try again, a selection's rewrite, or a draft from the notes, with the prompt line's instruction while it shows.
    /// Where there is nothing to write from it opens the prompt line instead (`run`).
    func write() {
        if isPromptShown {
            runFromPrompt(layer.prompt.instruction.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        run(instruction: nil)
    }

    /// The prompt line's ↩ or a chip: the line closes, its words kept for the next ⇧⌘J, and the write runs with them.
    /// With nothing to write from (an empty new message and no words here) nothing is sent and the line stays open, the
    /// keyboard in it, for the words it still needs: no beep, no failure line.
    private func runFromPrompt(_ instruction: String) {
        guard !isWriting else { return }
        refresh()
        // Only while Help Me Write can write: otherwise the line closes and the reason shows, as on a reply.
        if availability.isReady, center.configuration != nil, hasNothingToWriteFrom(instruction: instruction) {
            if !layer.promptHoldsFocus { layer.prompt.focus() }
            return
        }
        closePrompt(focusText: true)
        run(instruction: instruction)
    }

    /// What a write with `instruction` would be asked now, from what the field holds: the user's own text as its notes,
    /// or an empty draft (in a new message or a forward, also where that text is pictures and nothing else), and where
    /// the draft goes (`wholeDraftRange`). Reads this Mac only.
    private func freshAsk(instruction: String) -> (ask: WriteAsk, range: NSRange) {
        let text = textView.string as NSString
        let own = field.ownTextRange
        let notes = NSMaxRange(own) <= text.length ? text.substring(with: own) : ""
        let typed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return (WriteAsk(instruction: instruction, draft: Self.holdsWords(typed, writing: field.writeKind) ? .notes(typed) : .empty),
                wholeDraftRange)
    }

    /// Where a draft of the whole message goes: the user's own text, which it replaces. In a new message or a forward
    /// whose own text holds pictures and no words, only the blanks before the first picture: the draft goes above the
    /// pictures, an empty line between them, and every picture stays where it was (§5.56). Over notes beside pictures
    /// the draft takes the whole own text and brings its pictures back after it (`picturesKept(after:attributes:)`).
    /// A reply's field is written over whole, as it always was.
    private var wholeDraftRange: NSRange {
        let own = field.ownTextRange
        let kind = field.writeKind
        let text = textView.string as NSString
        guard kind != .reply, NSMaxRange(own) <= text.length,
              text.rangeOfCharacter(from: Self.words(writing: kind), options: [], range: own).location == NSNotFound else { return own }
        let picture = text.range(of: WriteAsk.pictureCharacter, options: .literal, range: own)
        guard picture.location != NSNotFound else { return own }
        return NSRange(location: own.location, length: picture.location - own.location)
    }

    /// What a whole draft of a new message or a forward written over `range` (`wholeDraftRange`) brings after it, in
    /// `attributes`, so it never takes a picture away: the model never sees one (`WriteAsk.withoutPictures`), and a draft
    /// that dropped it would say nothing of it. Above pictures alone, an empty line: they stay where they are. Over notes
    /// beside pictures, an empty line, then each picture the notes held, in order and as it was (its attachment, its
    /// style): two that stood apart with only blanks between keep those blanks, and two with words between go on lines
    /// of their own. The draft takes the words' place; its one undo step puts `range` back exactly as it was. Empty
    /// where there is no picture.
    private func picturesKept(after range: NSRange, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return NSAttributedString() }
        let text = storage.string as NSString
        let gap = NSAttributedString(string: "\n\n", attributes: attributes)
        if NSMaxRange(range) < text.length, text.character(at: NSMaxRange(range)) == 0xFFFC { return gap }
        let kind = field.writeKind
        let kept = NSMutableAttributedString()
        var previous: NSRange?
        var from = range.location
        while from < NSMaxRange(range) {
            let picture = text.range(of: WriteAsk.pictureCharacter, options: .literal,
                                     range: NSRange(location: from, length: NSMaxRange(range) - from))
            guard picture.location != NSNotFound else { break }
            if let previous {
                let between = NSRange(location: NSMaxRange(previous), length: picture.location - NSMaxRange(previous))
                if Self.holdsWords(text.substring(with: between), writing: kind) {
                    kept.append(NSAttributedString(string: "\n", attributes: attributes))
                } else {
                    kept.append(storage.attributedSubstring(from: between))
                }
            }
            kept.append(storage.attributedSubstring(from: picture))
            previous = picture
            from = NSMaxRange(picture)
        }
        guard kept.length > 0 else { return NSAttributedString() }
        kept.insert(gap, at: 0)
        return kept
    }

    /// Whether a write with `instruction` would have nothing to write from (`WriteKind.hasNothingToWriteFrom`): no
    /// selection, no draft just written, and an ask that says nothing where the field itself answers nothing.
    private func hasNothingToWriteFrom(instruction: String) -> Bool {
        guard rewritableSelection == nil, standingDraft == nil else { return false }
        return field.writeKind.hasNothingToWriteFrom(freshAsk(instruction: instruction).ask)
    }

    /// Runs a write with `instruction` (the prompt line's ↩, a chip, Shorter; nil: ⌘J's own, the last draft's on Try again).
    ///
    /// In order: why it cannot write at all (off, not turned on, needing setup), under the caret's line; Try again after
    /// a failure, which asks the same again; a selection's rewrite; Try again of a draft just written; why only a
    /// selection can be rewritten here; then, where there is nothing to write from, the prompt line and nothing sent;
    /// else the write.
    func run(instruction: String?) {
        guard !isWriting else { return }
        // ⌘J or Try again under a failure's line asks what failed again; anything said since is a new ask.
        let failed = instruction == nil && phase.isFailed ? lastFailure : nil
        lastFailure = nil
        var instruction = instruction
        if case .notStarted(let kept)? = failed { instruction = kept }
        refresh()
        failureAnchor = .caret(textView.selectedRange().location)
        guard let configuration = center.configuration else {
            lastFailure = failed ?? .notStarted(instruction: instruction)
            phase = .failed(reason: HelpMeWrite.offWords, offersSettings: true)
            announceFailure(HelpMeWrite.offWords)
            return
        }
        if case .unavailable(let reason) = availability {
            lastFailure = failed ?? .notStarted(instruction: instruction)
            phase = .failed(reason: reason, offersSettings: true)
            announceFailure(reason)
            return
        }
        self.configuration = configuration
        let text = textView.string as NSString

        // The same ask only while the field stands as it was asked: its text, and what is selected in it. A selection
        // made or let go since says what to work on now.
        if case .asked(let ask, let range, let isRewrite, let brief, let before)? = failed, textView.string == before,
           NSMaxRange(range) <= text.length, rewritableSelection == (isRewrite ? range : nil) {
            start(ask: ask, range: range, isRewrite: isRewrite, previous: nil, configuration: configuration, retry: true, brief: brief)
            return
        }
        if let range = rewritableSelection {
            // The selection's own leading and trailing space and line breaks stay where they are (a triple-clicked
            // paragraph keeps its line break): the reply, trimmed, replaces what lies between them. A selection of blanks
            // alone is none: ⌘J then writes from the notes. The user's own text around it is read now, as they asked,
            // and never before.
            let ask = WriteAsk(instruction: instruction ?? "", draft: .selection(text.substring(with: range)),
                               around: around(range, in: text))
            start(ask: ask, range: range, isRewrite: true, previous: nil, configuration: configuration)
            return
        }
        let selectionOnly = field.selectionOnlyReason
        if let draft = standingDraft, draft.isRewrite || selectionOnly == nil {
            tryAgain(draft, instruction: instruction, configuration: configuration)
            return
        }
        if let selectionOnly {
            notify(selectionOnly)
            return
        }
        let fresh = freshAsk(instruction: instruction ?? "")
        if field.writeKind.hasNothingToWriteFrom(fresh.ask) {
            // Nothing to write from: ⌘J asks what to write, and sends nothing.
            askWhatToWrite()
            return
        }
        start(ask: fresh.ask, range: fresh.range, isRewrite: false, previous: nil, configuration: configuration,
              brief: Self.brief(of: fresh.ask))
    }

    /// The user's own text around the selection `core` (the DRAFT form of a rewrite, §5.56), with the gaps and the
    /// windows of words beside it that the rewrite may change (`WriteSeamWindows`); nil where that text may not be the
    /// user's own (a body the composer did not write) or the selection reaches outside it (into or below the
    /// signature), so the selection goes alone. Read only here, at the user's ⌘J, the pill, Rewrite Selection or the
    /// prompt line's ↩ or chip.
    func around(_ core: NSRange, in text: NSString) -> WriteAsk.Around? {
        guard field.textAroundSelectionIsOwn else { return nil }
        let own = field.ownTextRange
        guard own.location <= core.location, NSMaxRange(core) <= NSMaxRange(own), NSMaxRange(own) <= text.length else { return nil }
        let windows = WriteSeamWindows.find(in: text, core: core, own: own, blocked: { [field] in field.blocksSeam(at: $0) })
        return WriteAsk.Around(before: text.substring(with: NSRange(location: own.location, length: core.location - own.location)),
                               after: text.substring(with: NSRange(location: NSMaxRange(core), length: NSMaxRange(own) - NSMaxRange(core))),
                               beforeGap: windows.beforeGap, beforeWindow: windows.beforeWindow,
                               afterGap: windows.afterGap, afterWindow: windows.afterWindow)
    }

    /// The instruction a draft is written from when it is all there is: its brief.
    private static func brief(of ask: WriteAsk) -> String? {
        guard case .empty = ask.draft else { return nil }
        let words = ask.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// The prompt line, opened by ⌘J where there is nothing to write from. After ⌘Z took a draft back to the empty
    /// body, the brief it was written from waits in the line, selected: ↩ writes it again, typing replaces it.
    private func askWhatToWrite() {
        if let lastDraft, textView.string == lastDraft.textBefore, let brief = lastDraft.brief { layer.prompt.instruction = brief }
        showPrompt()
    }

    /// A reason no write runs here now, under the caret's line (a failure's afterline, with no Settings…): nothing was
    /// asked, so nothing is sent, and Try again under it asks what ⌘J would ask now.
    private func refuse(_ reason: String) {
        failureAnchor = .caret(textView.selectedRange().location)
        lastFailure = nil
        phase = .failed(reason: reason, offersSettings: false)
        announceFailure(reason)
    }

    /// Why ⌘J cannot write here as things stand, where nothing failed (`WriteField.selectionOnlyReason`: a forward
    /// still loading, a body where only a selection can be rewritten): a quiet notice under the caret's line, with no
    /// action, which goes as a failure's line goes. Nothing is sent; ⌘J under it runs the rule again.
    private func notify(_ words: String) {
        failureAnchor = .caret(textView.selectedRange().location)
        lastFailure = nil
        phase = .notice(words)
        QuireAccessibility.announce(words, from: textView)
    }

    /// Writes again from the notes the last draft came from, never from the draft: its step is undone first, so the new
    /// draft's one step goes back to the notes (and a new message's Subject back to empty, to be proposed again), and the
    /// old draft stays in sight, in pencil, until the new one starts.
    ///
    /// What the write is made from is read before that undo: where the field can give none, or the ask is longer than
    /// is sent, the draft and its subject stay as they are.
    private func tryAgain(_ draft: Draft, instruction: String?, configuration: AIProviderConfiguration) {
        var ask = draft.ask
        var brief = draft.brief
        if let instruction {
            let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            if draft.kind == .newMessage, case .empty = ask.draft, let standing = Self.brief(of: ask) {
                // A new message written from an instruction alone: that instruction is its whole brief. New words are a
                // follow-up on it, so the brief becomes the notes of what is asked now; no words, or the same ones, ask
                // the same again.
                if !words.isEmpty, words != standing {
                    ask = WriteAsk(instruction: instruction, draft: .notes(standing))
                    brief = standing
                }
            } else {
                ask.instruction = instruction
            }
        }
        if !draft.isRewrite, let reason = field.selectionOnlyReason {
            notify(reason)
            return
        }
        guard let context = field.writeContext() else {
            NSSound.beep()
            return
        }
        // Past the cap nothing is sent (`start` refuses it by the same test), and that is known before the undo: the
        // reason shows under the draft, which stands with its subject, and ⌘J under it tries the draft again as asked.
        if let refusal = context.kind.lengthRefusal(of: ask) {
            refuse(refusal.lineMessage(for: configuration.kind))
            return
        }
        if let undo = textView.undoManager, undo.canUndo, undo.undoActionName == WriteStreamEdit.actionName {
            isChangingText = true
            undo.undo()
            // The caret from before the first ⌘J, never the notes selected: Esc during this write puts it back so.
            if textView.string == draft.textBefore { textView.selectedRanges = draft.selection }
            isChangingText = false
        }
        let range = draft.isRewrite ? draft.range : wholeDraftRange
        guard NSMaxRange(range) <= (textView.string as NSString).length, textView.string != draft.textAfter else {
            // The undo did not bring the notes back (the stack changed under it): the field as it is is the notes.
            lastDraft = nil
            run(instruction: instruction)
            return
        }
        start(ask: ask, range: range, isRewrite: draft.isRewrite, previous: draft.reply, configuration: configuration, retry: true,
              brief: brief)
    }

    private func start(ask: WriteAsk, range: NSRange, isRewrite: Bool, previous: String?, configuration: AIProviderConfiguration,
                       retry: Bool = false, brief: String? = nil) {
        // A whole draft where only a selection can be rewritten (a forward still loading, a body that may hold quoted
        // mail) never starts, whatever asked for it.
        if !isRewrite, let reason = field.selectionOnlyReason {
            notify(reason)
            return
        }
        // Read now, after Try again's undo: the Subject that undo emptied is asked for again.
        guard let context = field.writeContext() else {
            NSSound.beep()
            return
        }
        let kind = context.kind
        // Nothing to write from never sends: checked here, before the user's action is made, whatever path led here.
        guard !kind.hasNothingToWriteFrom(ask) else { return }
        // The draft replaces the whole selection or the notes, so all of it must be sent, and a new message's
        // instruction can be its whole brief: past the cap, nothing is.
        if let refusal = kind.lengthRefusal(of: ask) {
            let reason = refusal.lineMessage(for: configuration.kind)
            lastFailure = .asked(ask: ask, range: range, isRewrite: isRewrite, brief: brief, text: textView.string)
            phase = .failed(reason: reason, offersSettings: false)
            announceFailure(reason)
            return
        }
        let wantsSubject = context.wantsSubject(for: ask)
        // Only a new message can be written from an instruction alone; elsewhere it is no brief to keep.
        let brief = kind == .newMessage ? brief : nil
        let fieldID = AIFieldID(textView)
        generation += 1
        let mine = generation
        written = ""
        flushScheduled = false
        proposedSubject = nil
        proposedJoin = nil
        lastDraft = nil
        var seams = isRewrite ? SeamRanges(core: range, around: ask.around) : nil
        seams?.readStyle(of: field)
        running = Running(ask: ask, isRewrite: isRewrite, kind: kind, wantsSubject: wantsSubject, brief: brief, seams: seams)
        // A whole draft in a new message or a forward never takes a picture away: what it keeps follows it.
        let attributes = field.writeAttributes(at: range)
        let trailing = isRewrite || kind == .reply ? NSAttributedString() : picturesKept(after: range, attributes: attributes)
        edit = WriteStreamEdit(textView: textView, range: range, attributes: attributes, showing: previous, trailing: trailing)
        field.streamDidUpdate()
        field.refusesEdits = true
        field.setHeldOpen(true)
        markStreaming(true, in: textView.window)
        phase = .writing
        QuireAccessibility.announce((isRewrite ? "Rewriting with " : "Writing with ") + center.writerName(for: configuration.kind),
                                    from: textView)

        let writer = center.writer
        // The one place a write's user action is made: the user pressed ⌘J, the ghost, the pill, a menu item, the prompt
        // line's ↩ or a chip, Try again or Shorter.
        let action = AIUserAction(userPressed: .write)
        // `subject` says one was asked for with the draft, never that one was set.
        // `around` says whether a rewrite sent the draft around its selection, never what it held.
        center.writeDetails[fieldID] = AnalyticsSignal.WriteDetails(ask, retry: retry,
                                                                    source: field is ComposerWriteField ? .composer : .quickReply,
                                                                    kind: field.analyticsKind, subject: wantsSubject)
        writeTask = Task { [weak self] in
            // Read, redacted and built off the main thread, only now that the user asked (§5.56: nothing before).
            let built = await Task.detached(priority: .userInitiated) { context.request(for: ask, configuration: configuration) }.value
            guard let self, self.generation == mine, !Task.isCancelled else { return }
            guard let request = built else {
                // Nothing may be sent for this ask (the builder's own test of what was checked above): no write started.
                self.center.writeDetails[fieldID] = nil
                self.writeEndedElsewhere()
                return
            }
            #if DEBUG
            Self.requestObserver?(request)
            #endif
            let stream = writer.write(request, using: configuration, in: fieldID, action: action)
            do {
                for try await event in stream {
                    guard self.generation == mine else { return }
                    switch event {
                    case .text(let more):
                        self.written += more
                        self.scheduleFlush()
                    case .replaceAll(let all):
                        // A CLI's whole message (Codex sends nothing before it): shown at once.
                        self.written = all
                        self.flush()
                    case .usage:
                        break
                    case .subject(let subject):
                        // Held until the draft lands: a Stop can still follow it.
                        self.proposedSubject = subject
                    case .join(let join):
                        // Held until the part lands, and landed with it: a Stop can still follow it.
                        self.proposedJoin = join
                    case .finished(.done), .finished(.maxTokens):
                        self.finish()
                        return
                    case .finished(.cancelled):
                        // Not this session's Stop, which changes `generation` first: the writer was stopped from outside
                        // (quit, Leave Demo, the environment going away). The field goes back as it was all the same.
                        self.writeEndedElsewhere()
                        return
                    case .finished(.refused):
                        // The writer throws a refusal; should one ever arrive as an event, it reads as one.
                        self.fail(.refused)
                        return
                    }
                }
                // The stream ended with no word of how: as a stop from outside.
                guard self.generation == mine else { return }
                self.writeEndedElsewhere()
            } catch {
                guard self.generation == mine else { return }
                self.fail(AIError.from(error))
            }
        }
    }

    /// The selection less its leading and trailing whitespace and line breaks; the selection itself when that is all it
    /// holds.
    static func trimmedCore(of selection: NSRange, in text: NSString) -> NSRange {
        let blank = CharacterSet.whitespacesAndNewlines
        var start = selection.location
        var end = NSMaxRange(selection)
        while start < end, let scalar = UnicodeScalar(text.character(at: start)), blank.contains(scalar) { start += 1 }
        while end > start, let scalar = UnicodeScalar(text.character(at: end - 1)), blank.contains(scalar) { end -= 1 }
        return start < end ? NSRange(location: start, length: end - start) : selection
    }

    // MARK: Stopping

    /// Esc in the text (claimed before anything else answers it, §6.1): a write stops and the notes come back exactly;
    /// else the prompt line closes; else the afterline goes, the draft kept. False when none applies, so Esc goes on as it
    /// would.
    @discardableResult
    func escape() -> Bool {
        if isWriting {
            stop()
            return true
        }
        if isPromptShown {
            closePrompt(focusText: true)
            return true
        }
        if phase.showsLine {
            phase = .idle
            return true
        }
        return false
    }

    /// Esc in the prompt line: a write stops; else the line closes and the keyboard goes back to the text.
    @discardableResult
    func promptEscape() -> Bool {
        if isWriting {
            stop()
        } else {
            closePrompt(focusText: true)
        }
        return true
    }

    /// Stop, the pencil or Esc while writing: the field comes back as it was, at once.
    func stop() {
        guard isWriting else { return }
        let keyboardWasHere = keyboardIsHere
        stopWriting()
        phase = .idle
        field.setHeldOpen(isPromptShown)
        if keyboardWasHere, !layer.promptHoldsFocus { field.focusText() }
        QuireAccessibility.announce("Stopped", from: textView)
    }

    /// The reply goes away (another conversation, text set from outside, sent, the window closing): a write stops with the
    /// field put back, the prompt line closes, and Try again and the prompt's instruction are forgotten.
    func end() {
        stopWriting()
        lastDraft = nil
        lastFailure = nil
        layer.prompt.instruction = ""
        promptAnchor = nil
        phase = .idle
        field.setHeldOpen(false)
        render()
    }

    private func stopWriting() {
        generation += 1
        writeTask?.cancel()
        writeTask = nil
        running = nil
        proposedSubject = nil
        proposedJoin = nil
        center.writer.stop(AIFieldID(textView))
        if let edit, !edit.isFinished {
            edit.rollback()
            field.streamDidUpdate()
        }
        endStream()
    }

    private func endStream() {
        if edit != nil { markStreaming(false, in: edit?.textView.window) }
        edit = nil
        field.refusesEdits = false
        flushScheduled = false
    }

    /// The write ended without this session stopping it: the field as it was, editable.
    private func writeEndedElsewhere() {
        let keyboardWasHere = keyboardIsHere
        stopWriting()
        phase = .idle
        field.setHeldOpen(isPromptShown)
        if keyboardWasHere, !layer.promptHoldsFocus { field.focusText() }
    }

    // MARK: The prompt line (⇧⌘J)

    /// ⇧⌘J: the prompt line opens under the caret's line (a selection's last line; a draft's, right after one), the
    /// keyboard in it, its last instruction kept and selected. Opening it sends nothing.
    func showPrompt() {
        guard !isWriting else { return }
        // Where only a selection can be rewritten, there is nothing to say how to write without one.
        if !isPromptShown, rewritableSelection == nil, standingDraft?.isRewrite != true, let reason = field.selectionOnlyReason {
            notify(reason)
            return
        }
        if !isPromptShown {
            if let selection = rewritableSelection {
                promptAnchor = .end(NSMaxRange(selection))
            } else if phase == .written, let lastDraft, textView.string == lastDraft.textAfter {
                promptAnchor = .end(lastDraft.partEnd)
            } else {
                promptAnchor = .caret(textView.selectedRange().location)
            }
            // One block at a time: the prompt takes the afterline's place; Try again stays a ⌘J away.
            if phase.showsLine { phase = .idle }
            field.setHeldOpen(true)
            render()
            QuireAccessibility.announce("Help Me Write instructions", from: layer.prompt)
        }
        layer.prompt.rewritesSelection = rewritableSelection != nil
        layer.prompt.focus()
    }

    /// The afterline's Say how or the context menu: the prompt line, as ⇧⌘J opens it.
    private func sayHowFromMark() {
        guard !isWriting else { return }
        if !isPromptShown, textView.window?.firstResponder !== textView { field.focusText() }
        showPrompt()
    }

    func closePrompt(focusText: Bool) {
        guard isPromptShown else { return }
        let hadFocus = layer.promptHoldsFocus
        promptAnchor = nil
        field.setHeldOpen(isWriting)
        render()
        if focusText || hadFocus { field.focusText() }
    }

    // MARK: The afterline

    private func afterlineAction(_ action: WriteAfterline.Action) {
        switch action {
        case .tryAgain: writeFromMark()
        case .shorter:
            guard !isWriting else { return }
            if textView.window?.firstResponder !== textView { field.focusText() }
            layer.prompt.instruction = WriteWords.shorter
            run(instruction: WriteWords.shorter)
        case .sayHow: sayHowFromMark()
        case .undo: undoDraft()
        case .settings: openSettings()
        }
    }

    // MARK: Streaming into the field

    /// At most one text-view update per frame, however fast the deltas come (§5.56; ARCHITECTURE's budget).
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        // A frame's flush belongs to the write that asked for it: one still pending as that write lands must not write
        // into the next (Try again pressed within the frame would see its old draft, kept in pencil, cleared).
        let mine = generation
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine else { return }
                self.flush()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func flush() {
        flushScheduled = false
        guard let edit, !edit.isFinished else { return }
        let signpost = Self.signposter.beginInterval("ai.flush")
        edit.show(written)
        field.streamDidUpdate()
        // The pencil follows the last word, at most once a frame with the text.
        render()
        Self.signposter.endInterval("ai.flush", signpost)
        // The text was replaced around the stream by something that did not stop it first: the write ends here and
        // writes nothing more (`WriteStreamEdit.wasDisturbed`).
        if edit.wasDisturbed {
            stopWriting()
            phase = .idle
            field.setHeldOpen(isPromptShown)
        }
    }

    /// The draft is complete: one undoable change in ink, the caret after it, and the afterline under it. A subject that
    /// came with a new message's draft is set in that same step, if the message still takes one.
    private func finish() {
        guard let edit, let running else { return }
        let keyboardWasHere = keyboardIsHere
        if edit.wasDisturbed {
            stopWriting()
            phase = .idle
            return
        }
        field.refusesEdits = false
        markStreaming(false, in: textView.window)
        self.edit = nil
        self.running = nil
        let subject = running.wantsSubject && !running.isRewrite ? proposedSubject : nil
        proposedSubject = nil
        let join = proposedJoin
        proposedJoin = nil
        let reply = written.trimmingCharacters(in: .whitespacesAndNewlines)
        // A rewrite that sent the draft around it lands the words beside it the writer accepted, in the same step.
        let seams = running.isRewrite ? running.seams?.edits(for: join) : nil
        var setSubject = false
        isChangingText = true
        let committed = edit.commit(reply, seams: seams) { [field] undo in
            guard let subject else { return }
            setSubject = field.commitSubject(subject, undo: undo)
        }
        isChangingText = false
        field.streamDidUpdate()
        written = ""
        field.setHeldOpen(isPromptShown)
        guard committed else {
            // Text replaced around the stream at the last moment is the user's now: nothing is said about the reply.
            if edit.wasDisturbed {
                phase = .idle
            } else {
                let reason = AIError.emptyReply.lineMessage(for: configuration?.kind)
                failureAnchor = .caret(textView.selectedRange().location)
                lastFailure = .asked(ask: running.ask, range: edit.originalRange, isRewrite: running.isRewrite, brief: running.brief,
                                     text: edit.textBefore)
                phase = .failed(reason: reason, offersSettings: false)
                announceFailure(reason)
            }
            return
        }
        let writer = configuration.map { center.writerName(for: $0.kind) } ?? "Claude"
        lastDraft = Draft(ask: running.ask, range: edit.originalRange, isRewrite: running.isRewrite, reply: reply,
                          partEnd: edit.landedPartEnd ?? edit.originalRange.location + (reply as NSString).length,
                          textAfter: textView.string, textBefore: edit.textBefore, selection: edit.originalSelection,
                          writer: writer, source: configuration.map { center.sourceLine(for: $0) }, kind: running.kind,
                          brief: running.brief)
        // The caret waits after the reply; the keyboard goes to it from the text or the prompt, never from elsewhere.
        if keyboardWasHere { field.focusText() }
        phase = .written
        render()
        QuireAccessibility.announce(WriteWords.landed(running.kind, by: writer, rewrite: running.isRewrite, withSubject: setSubject,
                                                      joined: edit.landedJoin),
                                    from: textView)
        Self.logger.debug("Help Me Write committed \(reply.count, privacy: .public) characters")
    }

    /// The write failed: the field as it was, and the afterline says why in words (never the request or the reply).
    /// What was asked is kept while that line shows, for Try again.
    private func fail(_ error: AIError) {
        let keyboardWasHere = keyboardIsHere
        let asked: Failure? = running.flatMap { running in
            edit.map { .asked(ask: running.ask, range: $0.originalRange, isRewrite: running.isRewrite, brief: running.brief,
                              text: $0.textBefore) }
        }
        // What was being written, as its request named it: the writer's refusal is about that.
        let kind = running?.kind ?? field.writeKind
        stopWriting()
        field.setHeldOpen(isPromptShown)
        // The writer's own refusal reads as the text's does: never turned on, or on for replies only.
        let reason = error == .consentRequired
            ? configuration.map { center.consentReason(for: $0.kind, writing: kind) } ?? HelpMeWrite.turnOnWords
            : error.lineMessage(for: configuration?.kind)
        lastFailure = asked
        phase = .failed(reason: reason, offersSettings: error.needsSettings || error == .consentRequired)
        if keyboardWasHere, !layer.promptHoldsFocus { field.focusText() }
        announceFailure(reason)
    }

    private func announceFailure(_ reason: String) {
        QuireAccessibility.announce("Couldn\u{2019}t write. " + reason, from: textView)
    }

    /// The afterline's Undo: the reply's one step, as ⌘Z would take it back.
    private func undoDraft() {
        field.focusText()
        guard let undo = textView.undoManager, undo.canUndo, undo.undoActionName == WriteStreamEdit.actionName else {
            NSSound.beep()
            return
        }
        undo.undo()
    }

    private func openSettings() {
        phase = .idle
        center.openSettings()
    }

    // MARK: The keyboard

    /// Whether the keyboard is in the text, the prompt line or nowhere, with the field on screen. A write that ends moves
    /// the keyboard only then: what the user went on to type elsewhere (a search, J and K in the list) must not land in
    /// the reply.
    private var keyboardIsHere: Bool {
        guard let window = textView.window, !textView.isHiddenOrHasHiddenAncestor else { return false }
        return isHere(window.firstResponder) || window.firstResponder === window || window.firstResponder == nil
    }

    private func isHere(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder === textView || layer.prompt.holdsFocus { return true }
        return (responder as? NSView)?.isDescendant(of: layer.prompt) ?? false
    }

    /// The user moving away (the keyboard leaving the text and the prompt line) ends the afterline and closes the prompt
    /// line unless a write runs (§5.56; its instruction stays for the next ⇧⌘J); the ghost and the pill go with the
    /// keyboard. The keyboard coming back to the text by a click closes the prompt line too: it hung under a caret that
    /// has moved.
    private func watchTheKeyboard() {
        guard let window = textView.window else { return }
        if responderObservation == nil || observedWindow !== window {
            responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
                MainActor.assumeIsolated { self?.firstResponderDidChange(in: window) }
            }
            for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
            windowObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.render() }
                }
            }
            observedWindow = window
        }
    }

    private func firstResponderDidChange(in window: NSWindow) {
        guard textView.window === window else { return }
        let responder = window.firstResponder
        if responder === textView, isPromptShown, !isWriting, !layer.prompt.holdsFocus {
            promptAnchor = nil
            field.setHeldOpen(false)
        } else if let responder, responder !== window, !isHere(responder) {
            if phase.showsLine { phase = .idle }
            if isPromptShown, !isWriting {
                promptAnchor = nil
                field.setHeldOpen(false)
            }
        }
        if responder !== textView { notesGhostReady = false }
        render()
    }

    private func markStreaming(_ on: Bool, in window: NSWindow?) {
        guard let window else { return }
        let key = ObjectIdentifier(window)
        let count = (Self.streaming[key] ?? 0) + (on ? 1 : -1)
        Self.streaming[key] = count > 0 ? count : nil
    }

    #if DEBUG
    /// Renders and tests: the notes ghost as after a pause, without waiting for it.
    func showNotesGhostNow() {
        ghostTimer?.invalidate()
        notesGhostReady = true
        render()
    }
    #endif
}

/// A context-menu item that runs a closure: the text's menu belongs to the text view, and Help me write's items act on
/// the session that made them.
@MainActor
final class WriteMenuAction: NSObject {
    private let run: () -> Void

    private init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func runFromMenu(_ sender: Any?) {
        run()
    }

    /// An item titled `title` showing `key` with `modifiers`, which runs `run`; the item keeps its target.
    static func item(_ title: String, key: String, modifiers: NSEvent.ModifierFlags, run: @escaping () -> Void) -> NSMenuItem {
        let target = WriteMenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(runFromMenu(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        item.representedObject = target
        return item
    }
}
