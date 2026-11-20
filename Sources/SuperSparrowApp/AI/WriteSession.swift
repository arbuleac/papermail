import AppKit
import SSCore
import SSDesign
import os

/// One Help me write card on one field, from ⌘J to its close (spec §5.56): it shows the state, asks for consent the
/// first time a provider is used, builds what is sent only once Write is pressed, streams the reply into the field at
/// most once a frame, and ends in one undoable change or the field exactly as it was.
///
/// The quick reply's owner and a reply composer each keep at most one. Closing it always stops its write first: the
/// writer's field is the text view's identity, and a write must never outlive the card that shows it.
@MainActor
final class WriteSession {
    let center: HelpMeWrite
    /// The field's adapter, which holds its owner weakly: the owner keeps the session, the session keeps the adapter.
    private(set) var field: WriteField?
    let card = WriteCardView()
    /// Called once the card has gone, whichever way it closed.
    var onClose: (() -> Void)?

    private(set) var isOpen = false
    /// The configuration the card was opened with, and the one a write runs with.
    private var configuration: AIProviderConfiguration?
    private var isRewrite = false
    private var edit: WriteStreamEdit?
    private var writeTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    /// Bumped by every write and every stop, so events meant for an earlier write are dropped.
    private var generation = 0
    /// The whole reply so far, and whether the field has caught up with it.
    private var written = ""
    private var flushScheduled = false
    private var clickMonitor: Any?
    private var fieldID: AIFieldID?

    private static let logger = Logger(subsystem: "io.supersparrow.mac", category: "ai")
    /// Every session with a write streaming, by window: Edit › Undo waits while one streams there (§6.1).
    private static var streaming: [ObjectIdentifier: Int] = [:]

    init(center: HelpMeWrite, field: WriteField) {
        self.center = center
        self.field = field
        card.onWrite = { [weak self] in self?.write() }
        card.onStop = { [weak self] in self?.stop() }
        card.onEscape = { [weak self] in _ = self?.escape() }
        card.onOpenSettings = { [weak self] in
            self?.close()
            self?.center.openSettings()
        }
    }

    /// The card's state now (the app's tests read it).
    var state: WriteCardView.State { card.state }
    var isWriting: Bool { card.state == .writing }

    /// Whether a Help me write reply is streaming into a field of `window`: its undo stack waits until it ends.
    static func isStreaming(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return (streaming[ObjectIdentifier(window)] ?? 0) > 0
    }

    /// The keyboard to the card's field, or back to the text when the card has none (Off, needs setup).
    private func focusCard() {
        guard !card.takeFocus(), let textView = field?.writeTextView, textView.window?.firstResponder !== textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// Whether the keyboard is still the card's or its field's (or no one's), with the field on screen. A write that ends
    /// moves the keyboard only then: a click elsewhere leaves a write running (§5.56), and what the user goes on to type
    /// there (a search, J and K in the list) must not land in the card or the reply.
    private var keyboardIsHere: Bool {
        guard let textView = field?.writeTextView, let window = textView.window, !textView.isHiddenOrHasHiddenAncestor else {
            return false
        }
        let responder = window.firstResponder
        return card.holdsFocus || responder === textView || responder === window || responder == nil
    }

    // MARK: Opening and closing

    /// Shows the card under the caret: Off without a provider, else ready to write, then needs-setup if the provider's
    /// health says so (a quick check that sends no mail: a key is stored, the CLI is found and signed in).
    func open() {
        guard !isOpen, let field else { return }
        isOpen = true
        let textView = field.writeTextView
        fieldID = AIFieldID(textView)
        isRewrite = textView.selectedRange().length > 0
        configuration = center.configuration
        if let configuration {
            card.configure(state: .idle, isRewrite: isRewrite, sourceLine: center.sourceLine(for: configuration))
            checkHealth(configuration)
        } else {
            card.configure(state: .off, isRewrite: false, sourceLine: "")
        }
        field.cardDidChange(isOpen: true)
        card.present(in: field.cardHost, frame: frame(anchoredTo: textView.selectedRange()))
        focusCard()
        installClickMonitor()
        QuireAccessibility.announce(card.accessibilityWords, from: card)
    }

    /// Closes the card; a write still running is stopped and the field put back as it was. Focus that was in the card
    /// goes back to the field.
    func close() {
        guard isOpen else { return }
        isOpen = false
        let hadFocus = card.holdsFocus
        stopWriting()
        healthTask?.cancel()
        healthTask = nil
        removeClickMonitor()
        card.dismiss()
        field?.cardDidChange(isOpen: false)
        if hadFocus, let textView = field?.writeTextView, !textView.isHiddenOrHasHiddenAncestor {
            textView.window?.makeFirstResponder(textView)
        }
        onClose?()
    }

    /// Esc, from the card or the field (claimed before anything else answers it, §6.1): a write stops and the field comes
    /// back as it was, with the card open and the instruction kept; otherwise the card closes. False when no card is open.
    @discardableResult
    func escape() -> Bool {
        guard isOpen else { return false }
        if isWriting { stop() } else { close() }
        return true
    }

    private func frame(anchoredTo range: NSRange) -> NSRect {
        guard let field else { return .zero }
        return field.cardFrame(size: card.preferredSize, anchoredTo: range).integral
    }

    /// The card's frame again: its size changed with the state, or the text under it moved.
    private func reposition(anchoredTo range: NSRange? = nil) {
        guard isOpen, let field else { return }
        let anchor = range ?? edit?.range ?? field.writeTextView.selectedRange()
        card.frame = frame(anchoredTo: anchor)
        card.needsLayout = true
    }

    /// The field moved or grew (the quick reply's bar takes its height): the card follows it.
    func fieldDidMove() {
        reposition()
    }

    private func show(_ state: WriteCardView.State) {
        card.configure(state: state, isRewrite: isRewrite, sourceLine: configuration.map(center.sourceLine(for:)) ?? "")
        reposition()
    }

    private func checkHealth(_ configuration: AIProviderConfiguration) {
        let writer = center.writer
        healthTask = Task { [weak self] in
            let health = await writer.health(of: configuration)
            guard let self, !Task.isCancelled, self.isOpen, self.card.state == .idle, !health.isReady else { return }
            // The answer can come while the user types an instruction: the field goes, and the keyboard stays on the card
            // (Esc closes it, ↩ opens Settings) rather than jumping to the reply with the rest of what was typed.
            let typing = self.card.holdsFocus
            self.show(.needsSetup(reason: health.words))
            if typing { self.card.holdKeyboard() } else { self.focusCard() }
        }
    }

    /// A click anywhere in the window outside the card closes it and sends nothing; while it writes, the card stays.
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, !self.isWriting, let window = self.card.window, event.window === window else { return }
                let point = self.card.convert(event.locationInWindow, from: nil)
                if !self.card.bounds.contains(point) { self.close() }
            }
            return event
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: Writing

    /// Write (↩, the button, Try Again): consent first, the first time this provider is used; then the write.
    func write() {
        guard isOpen, !isWriting, let field else { return }
        // Settings may have changed since the card opened: the provider the user chose now is the one asked.
        guard let configuration = center.configuration else {
            self.configuration = nil
            show(.off)
            focusCard()
            return
        }
        self.configuration = configuration
        guard center.hasConsent(for: configuration.kind) else {
            askConsent(for: configuration.kind, window: field.writeTextView.window)
            return
        }
        start(configuration)
    }

    /// The consent sheet (§5.33): Allow records the answer and writes; Cancel (the default, and Esc) sends nothing and
    /// leaves the card as it was.
    private func askConsent(for kind: AIProviderKind, window: NSWindow?) {
        center.presentAlert(center.consentAlert(for: kind), window) { [weak self] choice in
            guard let self, self.isOpen else { return }
            if choice == 1 {
                self.center.recordConsent(for: kind)
                self.write()
            } else {
                self.focusCard()
            }
        }
    }

    private func start(_ configuration: AIProviderConfiguration) {
        guard let field, let fieldID, let context = field.writeContext() else {
            NSSound.beep()
            return
        }
        let textView = field.writeTextView
        let selection = textView.selectedRange()
        let own = field.ownTextRange
        let ask: WriteAsk
        let range: NSRange
        let text = textView.string as NSString
        if selection.length > 0, NSMaxRange(selection) <= text.length {
            isRewrite = true
            // The selection's own leading and trailing space and line breaks stay where they are (a triple-clicked
            // paragraph keeps its line break): the reply, trimmed, replaces what lies between them.
            range = Self.trimmedCore(of: selection, in: text)
            ask = WriteAsk(instruction: card.instruction, draft: .selection(text.substring(with: range)))
        } else {
            isRewrite = false
            range = own
            let notes = NSMaxRange(own) <= text.length ? text.substring(with: own) : ""
            let typed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            ask = WriteAsk(instruction: card.instruction, draft: typed.isEmpty ? .empty : .notes(typed))
        }
        // The reply replaces the whole selection or the notes, so all of it must be sent: past the cap, nothing is.
        if case .selection(let part) = ask.draft, ReplyContextBuilder.exceedsAskLimit(part) {
            show(.failed(reason: AIError.tooLong(selection: true).message(for: configuration.kind), offersSettings: false))
            focusCard()
            return
        }
        if case .notes(let part) = ask.draft, ReplyContextBuilder.exceedsAskLimit(part) {
            show(.failed(reason: AIError.tooLong(selection: false).message(for: configuration.kind), offersSettings: false))
            focusCard()
            return
        }
        generation += 1
        let mine = generation
        written = ""
        edit = WriteStreamEdit(textView: textView, range: range, attributes: field.writeAttributes(at: range))
        field.refusesEdits = true
        markStreaming(true, in: textView.window)
        show(.writing)
        focusCard()
        QuireAccessibility.announce(WriteCardView.writingWords, from: card)

        let writer = center.writer
        let signature = context.appendsSignature
        writeTask = Task { [weak self] in
            // Read and redacted off the main thread, only now that Write was pressed (§5.56: nothing before).
            let built = await Task.detached(priority: .userInitiated) { context.build(ask: ask) }.value
            guard let self, self.generation == mine, !Task.isCancelled else { return }
            let request = WritePrompt.request(for: built, appendsSignature: signature, configuration: configuration)
            let stream = writer.write(request, using: configuration, in: fieldID)
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
                        // Not this card's Stop, which changes `generation` first: the writer was stopped from outside
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

    /// The write ended without this card stopping it: the field as it was, editable, and the card ready to try again.
    private func writeEndedElsewhere() {
        let keyboardWasHere = keyboardIsHere
        generation += 1
        writeTask = nil
        if let edit, !edit.isFinished {
            edit.rollback()
            field?.streamDidUpdate()
        }
        endStream()
        guard isOpen else { return }
        show(.idle)
        if keyboardWasHere { focusCard() }
    }

    /// Stop or Esc while writing: the field comes back as it was, at once; the card stays with the instruction kept.
    func stop() {
        guard isWriting else { return }
        let keyboardWasHere = keyboardIsHere
        stopWriting()
        show(.idle)
        if keyboardWasHere { focusCard() }
    }

    private func stopWriting() {
        generation += 1
        writeTask?.cancel()
        writeTask = nil
        if let fieldID { center.writer.stop(fieldID) }
        if let edit, !edit.isFinished {
            edit.rollback()
            field?.streamDidUpdate()
        }
        endStream()
    }

    private func endStream() {
        if edit != nil { markStreaming(false, in: edit?.textView.window) }
        edit = nil
        field?.refusesEdits = false
        flushScheduled = false
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
        field?.streamDidUpdate()
        Self.signposter.endInterval("ai.flush", signpost)
        // The text was replaced around the stream by something that did not stop it first: the write ends here and
        // writes nothing more (`WriteStreamEdit.wasDisturbed`).
        if edit.wasDisturbed {
            stopWriting()
            if isOpen { show(.idle) }
            return
        }
        reposition()
    }

    private static let signposter = OSSignposter(subsystem: "io.supersparrow.mac", category: "ai")

    /// The reply is complete: one undoable change, the card closes and the caret waits after the reply (with the keyboard,
    /// when the keyboard was still with the card or the field).
    private func finish() {
        guard let edit, let field else { return }
        let keyboardWasHere = keyboardIsHere
        if edit.wasDisturbed {
            stopWriting()
            if isOpen { show(.idle) }
            return
        }
        let textView = edit.textView
        field.refusesEdits = false
        markStreaming(false, in: textView.window)
        self.edit = nil
        let reply = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = edit.commit(reply)
        field.streamDidUpdate()
        written = ""
        guard committed else {
            // Text replaced around the stream at the last moment is the user's now: nothing is said about the reply.
            if edit.wasDisturbed { show(.idle) } else {
                show(.failed(reason: AIError.emptyReply.message(for: configuration?.kind), offersSettings: false))
            }
            if keyboardWasHere { focusCard() }
            return
        }
        isOpen = false
        healthTask?.cancel()
        removeClickMonitor()
        card.dismiss()
        field.cardDidChange(isOpen: false)
        // The caret waits after the reply; the keyboard goes to it only from the card or the field.
        if keyboardWasHere { textView.window?.makeFirstResponder(textView) }
        Self.logger.debug("Help Me Write committed \(reply.count, privacy: .public) characters")
        onClose?()
    }

    /// The write failed: the field as it was, and the card says why in words (never the request or the reply).
    private func fail(_ error: AIError) {
        let keyboardWasHere = keyboardIsHere
        if let edit, !edit.isFinished {
            edit.rollback()
            field?.streamDidUpdate()
        }
        endStream()
        guard isOpen else { return }
        if error == .consentRequired, let kind = configuration?.kind {
            show(.idle)
            askConsent(for: kind, window: field?.writeTextView.window)
            return
        }
        let reason = error.message(for: configuration?.kind)
        show(.failed(reason: reason, offersSettings: error.needsSettings))
        if keyboardWasHere { focusCard() }
        QuireAccessibility.announce(WriteCardView.failureWords + ". " + reason, from: card)
    }

    private func markStreaming(_ on: Bool, in window: NSWindow?) {
        guard let window else { return }
        let key = ObjectIdentifier(window)
        let count = (Self.streaming[key] ?? 0) + (on ? 1 : -1)
        Self.streaming[key] = count > 0 ? count : nil
    }
}
