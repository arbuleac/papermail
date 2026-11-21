import AppKit
import SSCore
import SSDesign
import os

/// Help me write on one reply, at the caret (spec §5.56): the quick reply's field or a reply composer's body. Everything
/// it shows is in the text itself (`WriteInlineLayer`): the ghost “⌘J to write a reply” after the caret, “⌘J to write from
/// your notes” once the user pauses at the end of them, the pill “Rewrite ⌘J” under a settled selection, ⇧⌘J's prompt
/// line under the caret's line, the pencil after the last word while a reply streams, and the afterline under the draft.
/// ⌘J (or the ghost, the pill, the context menu) starts at once: the reply streams into the field in pencil, replacing the
/// user's notes (or the selection), then lands in ink as one undoable step, “Undo Help Me Write”, which brings the notes
/// back. Right after, ⌘J tries again from the same notes; once the user edits the draft, ⌘J writes from what the field
/// holds now.
///
/// Nothing about the conversation is read, built or sent before the user acts (spec §3b): what shows comes from this
/// Mac's facts alone (`HelpMeWrite.availability`), and the write itself is the one place in the app that makes a write's
/// `AIUserAction`. The ghost's and the pill's timers are local; showing any mark, opening the prompt line or the context
/// menu sends nothing. There is no permission sheet here: permission is given in Settings › AI when a provider is
/// chosen; without it, ⌘J says so under the caret's line and sends nothing.
///
/// The quick reply's owner and each reply composer keep one session for as long as the reply lives. `end()` stops its
/// write first: the writer's field is the text view's identity, and a write must never outlive the reply it fills.
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
    }

    private var lastDraft: Draft?
    /// The write under way: what it asks, so a reply that lands becomes `lastDraft`.
    private var running: (ask: WriteAsk, isRewrite: Bool)?
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

    private static let logger = Logger(subsystem: "io.supersparrow.mac", category: "ai")
    private static let signposter = OSSignposter(subsystem: "io.supersparrow.mac", category: "ai")
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

    /// Reads the provider's state again from this Mac (the field took the keyboard, Settings changed) and shows it.
    func refresh() {
        availability = center.availability()
        layer.prompt.writer = availability.writer
        watchTheKeyboard()
        render()
    }

    /// The marks the text shows now, from the phase, the caret, the selection and the provider's state.
    private func render() {
        layer.textAttributes = field.writeAttributes(at: NSRange(location: textView.selectedRange().location, length: 0))
        var state = WriteInlineLayer.State()
        if isWriting {
            state.pencil = edit.map { NSMaxRange($0.range) }
        } else if let promptAnchor {
            state.block = .prompt(promptAnchor)
        } else if phase == .written, let lastDraft, textView.string == lastDraft.textAfter {
            let end = lastDraft.range.location + (lastDraft.reply as NSString).length
            state.block = .afterline(.end(end), .written(writer: lastDraft.writer, rewrite: lastDraft.isRewrite, source: lastDraft.source))
        } else if case .failed(let reason, let settings) = phase {
            state.block = .afterline(failureAnchor, .failed(reason: reason, offersSettings: settings))
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

    /// The ghost after the caret (§5.56): on an empty reply at once; at the end of a paragraph of the user's notes once
    /// they pause; never mid-line, never in the signature.
    private func ghost(own: NSRange) -> WriteInlineLayer.Ghost? {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        let text = textView.string as NSString
        let at = selection.location
        guard at >= own.location, at <= NSMaxRange(own) else { return nil }
        // At the end of a paragraph: the next letter is a line break, or the user's text ends there.
        guard at == NSMaxRange(own) || (at < text.length && WriteTextGeometry.isLineEnd(text.character(at: at))) else { return nil }
        // Never the whole notes copied or counted on each key: the first letter, then the first few words, are enough.
        guard NSMaxRange(own) <= text.length else { return nil }
        if text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: [], range: own).location == NSNotFound {
            if let offset = field.placeholderWidth {
                return WriteInlineLayer.Ghost(location: at, words: WriteWords.ghostAfterPlaceholder, offset: offset)
            }
            return WriteInlineLayer.Ghost(location: at, words: WriteWords.ghostReply)
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
        guard text.substring(with: core).contains(where: { !$0.isWhitespace }) else { return nil }
        return core
    }

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
        if phase == .written || phase.isFailed { phase = .idle }
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
        /// Write again from the same notes: the last reply stands as written.
        case tryAgain
        /// Write the reply from the user's notes.
        case fromNotes
        /// Write the reply from the conversation alone.
        case reply
    }

    var plan: Plan {
        if rewritableSelection != nil, !isWriting { return .rewriteSelection }
        if let lastDraft, textView.string == lastDraft.textAfter { return .tryAgain }
        return ownText.contains { !$0.isWhitespace } ? .fromNotes : .reply
    }

    /// Edit › Help Me Write's title for what it does now (§5.35).
    func menuTitle(withInstructions: Bool) -> String {
        switch (plan, withInstructions) {
        case (.rewriteSelection, false): return "Rewrite Selection"
        case (.rewriteSelection, true): return "Rewrite Selection with Instructions\u{2026}"
        case (.tryAgain, false): return "Try Again"
        case (.fromNotes, false): return "Write Reply from Notes"
        case (.reply, false): return "Write Reply"
        case (_, true): return "Write Reply with Instructions\u{2026}"
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

    /// ⌘J: Try again, a selection's rewrite, or a reply from the notes, with the prompt line's instruction while it shows.
    func write() {
        if isPromptShown {
            runFromPrompt(layer.prompt.instruction.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        run(instruction: nil)
    }

    /// The prompt line's ↩ or a chip: the line closes, its words kept for the next ⇧⌘J, and the write runs with them.
    private func runFromPrompt(_ instruction: String) {
        guard !isWriting else { return }
        closePrompt(focusText: true)
        run(instruction: instruction)
    }

    /// Runs a write with `instruction` (the prompt line's ↩, a chip, Shorter; nil: ⌘J's own, the last draft's on Try again).
    func run(instruction: String?) {
        guard !isWriting else { return }
        refresh()
        failureAnchor = .caret(textView.selectedRange().location)
        guard let configuration = center.configuration else {
            phase = .failed(reason: HelpMeWrite.offWords, offersSettings: true)
            announceFailure(HelpMeWrite.offWords)
            return
        }
        if case .unavailable(let reason) = availability {
            phase = .failed(reason: reason, offersSettings: true)
            announceFailure(reason)
            return
        }
        self.configuration = configuration
        let text = textView.string as NSString

        if let range = rewritableSelection {
            // The selection's own leading and trailing space and line breaks stay where they are (a triple-clicked
            // paragraph keeps its line break): the reply, trimmed, replaces what lies between them. A selection of blanks
            // alone is none: ⌘J then writes from the notes.
            let ask = WriteAsk(instruction: instruction ?? "", draft: .selection(text.substring(with: range)))
            start(ask: ask, range: range, isRewrite: true, previous: nil, configuration: configuration)
            return
        }
        if let draft = lastDraft, textView.string == draft.textAfter {
            tryAgain(draft, instruction: instruction, configuration: configuration)
            return
        }
        let own = field.ownTextRange
        let notes = NSMaxRange(own) <= text.length ? text.substring(with: own) : ""
        let typed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = WriteAsk(instruction: instruction ?? "", draft: typed.isEmpty ? .empty : .notes(typed))
        start(ask: ask, range: own, isRewrite: false, previous: nil, configuration: configuration)
    }

    /// Writes again from the notes the last reply came from, never from the reply: its step is undone first, so the new
    /// reply's one step goes back to the notes, and the old reply stays in sight, in pencil, until the new one starts.
    private func tryAgain(_ draft: Draft, instruction: String?, configuration: AIProviderConfiguration) {
        var ask = draft.ask
        if let instruction { ask.instruction = instruction }
        if let undo = textView.undoManager, undo.canUndo, undo.undoActionName == WriteStreamEdit.actionName {
            isChangingText = true
            undo.undo()
            // The caret from before the first ⌘J, never the notes selected: Esc during this write puts it back so.
            if textView.string == draft.textBefore { textView.selectedRanges = draft.selection }
            isChangingText = false
        }
        let range = draft.isRewrite ? draft.range : field.ownTextRange
        guard NSMaxRange(range) <= (textView.string as NSString).length, textView.string != draft.textAfter else {
            // The undo did not bring the notes back (the stack changed under it): the field as it is is the notes.
            lastDraft = nil
            run(instruction: instruction)
            return
        }
        start(ask: ask, range: range, isRewrite: draft.isRewrite, previous: draft.reply, configuration: configuration)
    }

    private func start(ask: WriteAsk, range: NSRange, isRewrite: Bool, previous: String?, configuration: AIProviderConfiguration) {
        guard let context = field.writeContext() else {
            NSSound.beep()
            return
        }
        // The reply replaces the whole selection or the notes, so all of it must be sent: past the cap, nothing is.
        switch ask.draft {
        case .selection(let part) where ReplyContextBuilder.exceedsAskLimit(part),
             .notes(let part) where ReplyContextBuilder.exceedsAskLimit(part):
            let reason = AIError.tooLong(selection: isRewrite).lineMessage(for: configuration.kind)
            phase = .failed(reason: reason, offersSettings: false)
            announceFailure(reason)
            return
        default:
            break
        }
        let fieldID = AIFieldID(textView)
        generation += 1
        let mine = generation
        written = ""
        lastDraft = nil
        running = (ask, isRewrite)
        edit = WriteStreamEdit(textView: textView, range: range, attributes: field.writeAttributes(at: range), showing: previous)
        field.streamDidUpdate()
        field.refusesEdits = true
        field.setHeldOpen(true)
        markStreaming(true, in: textView.window)
        phase = .writing
        QuireAccessibility.announce((isRewrite ? "Rewriting with " : "Writing with ") + center.writerName(for: configuration.kind),
                                    from: textView)

        let writer = center.writer
        let signature = context.appendsSignature
        // The one place a write's user action is made: the user pressed ⌘J, the ghost, the pill, a menu item, the prompt
        // line's ↩ or a chip, Try again or Shorter.
        let action = AIUserAction(userPressed: .write)
        writeTask = Task { [weak self] in
            // Read and redacted off the main thread, only now that the user asked (§5.56: nothing before).
            let built = await Task.detached(priority: .userInitiated) { context.build(ask: ask) }.value
            guard let self, self.generation == mine, !Task.isCancelled else { return }
            let request = WritePrompt.request(for: built, appendsSignature: signature, configuration: configuration)
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
        if phase == .written || phase.isFailed {
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
        if !isPromptShown {
            if let selection = rewritableSelection {
                promptAnchor = .end(NSMaxRange(selection))
            } else if phase == .written, let lastDraft, textView.string == lastDraft.textAfter {
                promptAnchor = .end(lastDraft.range.location + (lastDraft.reply as NSString).length)
            } else {
                promptAnchor = .caret(textView.selectedRange().location)
            }
            // One block at a time: the prompt takes the afterline's place; Try again stays a ⌘J away.
            if phase == .written || phase.isFailed { phase = .idle }
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
            layer.prompt.instruction = WriteWords.presets[0]
            run(instruction: WriteWords.presets[0])
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
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
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

    /// The reply is complete: one undoable change in ink, the caret after it, and the afterline under it.
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
        let reply = written.trimmingCharacters(in: .whitespacesAndNewlines)
        isChangingText = true
        let committed = edit.commit(reply)
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
                phase = .failed(reason: reason, offersSettings: false)
                announceFailure(reason)
            }
            return
        }
        let writer = configuration.map { center.writerName(for: $0.kind) } ?? "Claude"
        lastDraft = Draft(ask: running.ask, range: edit.originalRange, isRewrite: running.isRewrite, reply: reply,
                          textAfter: textView.string, textBefore: edit.textBefore, selection: edit.originalSelection,
                          writer: writer, source: configuration.map { center.sourceLine(for: $0) })
        // The caret waits after the reply; the keyboard goes to it from the text or the prompt, never from elsewhere.
        if keyboardWasHere { field.focusText() }
        phase = .written
        render()
        QuireAccessibility.announce(running.isRewrite ? "Selection rewritten by \(writer)" : "Reply written by \(writer)",
                                    from: textView)
        Self.logger.debug("Help Me Write committed \(reply.count, privacy: .public) characters")
    }

    /// The write failed: the field as it was, and the afterline says why in words (never the request or the reply).
    private func fail(_ error: AIError) {
        let keyboardWasHere = keyboardIsHere
        stopWriting()
        field.setHeldOpen(isPromptShown)
        let reason = error == .consentRequired ? HelpMeWrite.turnOnWords : error.lineMessage(for: configuration?.kind)
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
            if phase == .written || phase.isFailed { phase = .idle }
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
