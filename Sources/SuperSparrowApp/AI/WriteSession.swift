import AppKit
import SSCore
import SSDesign
import os

/// Help me write on one reply, in place (spec §5.56): the quick reply's field or a reply composer's body, with its Write
/// control in the tool row and its instruction strip docked above the text. No card: ⌘J (or Write) starts at once and
/// the reply streams into the field in pencil, replacing the user's notes (or the selection), then lands in ink as one
/// undoable step, “Undo Help Me Write”, which brings the notes back. Right after, ⌘J tries again from the same notes; once
/// the user edits the draft, ⌘J writes from what the field holds now. ⇧⌘J opens the strip to say how.
///
/// Nothing about the conversation is read, built or sent before the user's Write (spec §3b): the control's state comes
/// from this Mac's facts alone (`HelpMeWrite.availability`), and the write itself is the one place in the app that makes a
/// write's `AIUserAction`. There is no permission sheet here: permission is given in Settings › AI when a provider is
/// chosen; without it, ⌘J says so in the tool row and sends nothing.
///
/// The quick reply's owner and each reply composer keep one session for as long as the reply lives. `end()` stops its
/// write first: the writer's field is the text view's identity, and a write must never outlive the reply it fills.
@MainActor
final class WriteSession {
    let center: HelpMeWrite
    /// The field's adapter, which holds its owner weakly: the owner keeps the session, the session keeps the adapter.
    let field: WriteField

    /// What the session is doing, as the Write control shows it.
    private(set) var phase: WriteToolControl.Phase = .idle {
        didSet {
            guard oldValue != phase else { return }
            field.writeControl.phase = phase
        }
    }

    /// The strip is docked above the text.
    private(set) var isStripShown = false

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
        let control = field.writeControl
        control.onWrite = { [weak self] in self?.writeFromControl() }
        control.onStop = { [weak self] in self?.stop() }
        control.onTryAgain = { [weak self] in self?.writeFromControl() }
        control.onUndo = { [weak self] in self?.undoDraft() }
        control.onOpenSettings = { [weak self] in self?.openSettings() }
        control.onSayHow = { [weak self] in self?.sayHowFromControl() }
        control.onPreset = { [weak self] preset in self?.runPresetFromControl(preset) }
        let strip = field.instructionStrip
        strip.onRun = { [weak self] instruction in self?.run(instruction: instruction) }
        strip.onEscape = { [weak self] in _ = self?.stripEscape() }
        availabilityObserver = NotificationCenter.default.addObserver(forName: HelpMeWrite.availabilityDidChange, object: center,
                                                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    deinit {
        if let availabilityObserver { NotificationCenter.default.removeObserver(availabilityObserver) }
    }

    var isWriting: Bool { phase == .writing }

    /// Whether a Help me write reply is streaming into a field of `window`: its undo stack waits until it ends.
    static func isStreaming(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return (streaming[ObjectIdentifier(window)] ?? 0) > 0
    }

    private var textView: NSTextView { field.writeTextView }

    // MARK: What the control shows

    /// Reads the provider's state again from this Mac (the field took the keyboard, Settings changed) and the hint.
    func refresh() {
        field.writeControl.availability = center.availability()
        updateHint()
        watchTheKeyboard()
    }

    /// The hint says what ⌘J does with the user's text (§5.56): with text selected, it rewrites the selection; once the
    /// user's own text holds a few words, it writes from them, their notes.
    private func updateHint() {
        if rewritableSelection != nil {
            field.writeControl.hint = .selection
        } else if Self.wordCount(in: ownText) >= Int(Quire.Layout.WriteTool.hintMinWords) {
            field.writeControl.hint = .notes
        } else {
            field.writeControl.hint = nil
        }
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

    /// The selection moved: the hint, and the open strip's placeholder, follow what ⌘J would rewrite.
    func selectionDidChange() {
        guard !isWriting, !isChangingText else { return }
        updateHint()
        if isStripShown { field.instructionStrip.rewritesSelection = rewritableSelection != nil }
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

    /// The user changed the text (typing, a paste, an undo): a line about the last reply or a failure goes, and Try again
    /// with it.
    func userDidEdit() {
        guard !isChangingText else { return }
        if phase == .written || isFailed { phase = .idle }
        // ⌘Z back to the notes and ⌘⇧Z back to the reply keep Try again: a redone reply is tried again from its notes.
        if phase != .writing, let lastDraft, textView.string != lastDraft.textAfter, textView.string != lastDraft.textBefore {
            self.lastDraft = nil
        }
        updateHint()
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

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

    // MARK: Writing

    /// The Write button or a line's Try again: the keyboard goes to the text first, so a selection there counts.
    private func writeFromControl() {
        if textView.window?.firstResponder !== textView, !field.instructionStrip.holdsFocus { field.focusText() }
        write()
    }

    /// ⌘J: Try again, a selection's rewrite, or a reply from the notes, with the strip's instruction while it shows.
    func write() {
        run(instruction: isStripShown ? field.instructionStrip.instruction.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
    }

    /// Runs a write with `instruction` (the strip's ↩ or a chip; nil: ⌘J's own, the last draft's on Try again).
    func run(instruction: String?) {
        guard !isWriting else { return }
        refresh()
        guard let configuration = center.configuration else {
            phase = .failed(reason: HelpMeWrite.offWords, offersSettings: true)
            announceFailure(HelpMeWrite.offWords)
            return
        }
        if case .unavailable(let reason) = field.writeControl.availability {
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
        field.writeControl.isRewriting = isRewrite
        phase = .writing
        QuireAccessibility.announce((isRewrite ? "Rewriting with " : "Writing with ") + center.writerName(for: configuration.kind),
                                    from: field.writeControl)

        let writer = center.writer
        let signature = context.appendsSignature
        // The one place a write's user action is made: the user pressed Write, ⌘J, ⇧⌘J's ↩, a chip or Try again.
        let action = AIUserAction(userPressed: .write)
        writeTask = Task { [weak self] in
            // Read and redacted off the main thread, only now that Write was pressed (§5.56: nothing before).
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
    /// else the strip closes. False when neither applies, so Esc goes on as it would.
    @discardableResult
    func escape() -> Bool {
        if isWriting {
            stop()
            return true
        }
        if isStripShown {
            closeStrip(focusText: true)
            return true
        }
        return false
    }

    /// Esc in the strip: a write stops; else the strip closes and the keyboard goes back to the text.
    @discardableResult
    func stripEscape() -> Bool {
        if isWriting {
            stop()
        } else {
            closeStrip(focusText: true)
        }
        return true
    }

    /// Stop or Esc while writing: the field comes back as it was, at once.
    func stop() {
        guard isWriting else { return }
        let keyboardWasHere = keyboardIsHere
        stopWriting()
        phase = .idle
        field.setHeldOpen(isStripShown)
        if keyboardWasHere, !field.instructionStrip.holdsFocus { field.focusText() }
        QuireAccessibility.announce("Stopped", from: field.writeControl)
    }

    /// The reply goes away (another conversation, text set from outside, sent, the window closing): a write stops with the
    /// field put back, the strip closes, and Try again and the strip's instruction are forgotten.
    func end() {
        stopWriting()
        phase = .idle
        lastDraft = nil
        field.instructionStrip.instruction = ""
        if isStripShown { setStrip(false) }
        field.setHeldOpen(false)
        updateHint()
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
        field.setHeldOpen(isStripShown)
        if keyboardWasHere, !field.instructionStrip.holdsFocus { field.focusText() }
    }

    // MARK: The instruction strip (⇧⌘J)

    /// ⇧⌘J: the strip docks above the text with the keyboard in it, its last instruction kept (and selected).
    func showStrip() {
        if !isStripShown { setStrip(true) }
        field.instructionStrip.rewritesSelection = rewritableSelection != nil
        field.instructionStrip.focus()
    }

    /// The written line's Say how, or Write's menu: the strip, as ⇧⌘J opens it.
    private func sayHowFromControl() {
        guard !isWriting else { return }
        if !isStripShown, textView.window?.firstResponder !== textView { field.focusText() }
        showStrip()
    }

    /// A preset from Write's menu: run as the strip's chip runs it, the strip showing what was asked.
    private func runPresetFromControl(_ preset: String) {
        guard !isWriting else { return }
        if textView.window?.firstResponder !== textView, !field.instructionStrip.holdsFocus { field.focusText() }
        field.instructionStrip.instruction = preset
        run(instruction: preset)
    }

    func closeStrip(focusText: Bool) {
        guard isStripShown else { return }
        let hadFocus = field.instructionStrip.holdsFocus
        setStrip(false)
        if focusText || hadFocus { field.focusText() }
    }

    private func setStrip(_ shown: Bool) {
        isStripShown = shown
        field.setHeldOpen(shown || isWriting)
        field.setStripShown(shown)
        if shown { QuireAccessibility.announce("Help Me Write instructions", from: field.instructionStrip) }
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
        Self.signposter.endInterval("ai.flush", signpost)
        // The text was replaced around the stream by something that did not stop it first: the write ends here and
        // writes nothing more (`WriteStreamEdit.wasDisturbed`).
        if edit.wasDisturbed {
            stopWriting()
            phase = .idle
            field.setHeldOpen(isStripShown)
        }
    }

    /// The reply is complete: one undoable change in ink, the caret after it, and the line that offers Try again and Undo.
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
        field.setHeldOpen(isStripShown)
        guard committed else {
            // Text replaced around the stream at the last moment is the user's now: nothing is said about the reply.
            if edit.wasDisturbed {
                phase = .idle
            } else {
                let reason = AIError.emptyReply.lineMessage(for: configuration?.kind)
                phase = .failed(reason: reason, offersSettings: false)
                announceFailure(reason)
            }
            return
        }
        lastDraft = Draft(ask: running.ask, range: edit.originalRange, isRewrite: running.isRewrite, reply: reply,
                          textAfter: textView.string, textBefore: edit.textBefore, selection: edit.originalSelection)
        phase = .written
        // The caret waits after the reply; the keyboard goes to it from the strip or the text, never from elsewhere.
        if keyboardWasHere { field.focusText() }
        updateHint()
        let writer = configuration.map { center.writerName(for: $0.kind) } ?? "Claude"
        QuireAccessibility.announce(running.isRewrite ? "Selection rewritten by \(writer)" : "Reply written by \(writer)",
                                    from: field.writeControl)
        Self.logger.debug("Help Me Write committed \(reply.count, privacy: .public) characters")
    }

    /// The write failed: the field as it was, and the tool row says why in words (never the request or the reply).
    private func fail(_ error: AIError) {
        let keyboardWasHere = keyboardIsHere
        stopWriting()
        field.setHeldOpen(isStripShown)
        let reason = error == .consentRequired ? HelpMeWrite.turnOnWords : error.lineMessage(for: configuration?.kind)
        phase = .failed(reason: reason, offersSettings: error.needsSettings || error == .consentRequired)
        if keyboardWasHere, !field.instructionStrip.holdsFocus { field.focusText() }
        announceFailure(reason)
    }

    private func announceFailure(_ reason: String) {
        QuireAccessibility.announce("Couldn\u{2019}t write. " + reason, from: field.writeControl)
    }

    /// The line's Undo: the reply's one step, as ⌘Z would take it back.
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

    /// Whether the keyboard is in the text, the strip, the Write control or nowhere, with the field on screen. A write
    /// that ends moves the keyboard only then: what the user went on to type elsewhere (a search, J and K in the list) must
    /// not land in the reply.
    private var keyboardIsHere: Bool {
        guard let window = textView.window, !textView.isHiddenOrHasHiddenAncestor else { return false }
        return isHere(window.firstResponder) || window.firstResponder === window || window.firstResponder == nil
    }

    private func isHere(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder === textView || field.instructionStrip.holdsFocus { return true }
        return (responder as? NSView)?.isDescendant(of: field.writeControl) ?? false
    }

    /// The user moving away (the keyboard leaving the text, the strip and the control) ends the line about the last reply
    /// or a failure, and closes the strip unless a write runs (§5.56); its instruction stays for the next ⇧⌘J.
    private func watchTheKeyboard() {
        guard responderObservation == nil, let window = textView.window else { return }
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, let responder = window.firstResponder, responder !== window else { return }
                guard !self.isHere(responder), self.textView.window === window else { return }
                if self.phase == .written || self.isFailed { self.phase = .idle }
                if self.isStripShown, !self.isWriting { self.setStrip(false) }
            }
        }
    }

    private func markStreaming(_ on: Bool, in window: NSWindow?) {
        guard let window else { return }
        let key = ObjectIdentifier(window)
        let count = (Self.streaming[key] ?? 0) + (on ? 1 : -1)
        Self.streaming[key] = count > 0 ? count : nil
    }
}
