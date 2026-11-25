import AppKit
import PaperCore
import PaperDesign

/// Help me write in a composer (spec §5.56), whatever it writes (a reply, a new message, the message above a forward):
/// ⌘J writes in place in the body where there is something to write from and asks what to write where there is not,
/// ⇧⌘J opens the prompt line under the caret's line; everything it shows is in the body's text, at the caret, none of
/// it in the bottom bar.
extension ComposeWindowController {
    @objc func helpMeWrite(_ sender: Any?) {
        guard canHelpMeWrite, let session = bodyWriteSession else {
            NSSound.beep()
            return
        }
        session.write()
    }

    @objc func helpMeWriteWithInstructions(_ sender: Any?) {
        guard canHelpMeWrite, let session = bodyWriteSession else {
            NSSound.beep()
            return
        }
        session.showPrompt()
    }

    /// The body's session, made the first time Help me write is reached there (a key, a selection, the window coming
    /// forward). Making it reads this Mac only (`HelpMeWrite.availability(for:)`): nothing of the message is read, and
    /// nothing is sent, until the user asks for a write.
    var bodyWriteSession: WriteSession? {
        if let writeSession { return writeSession }
        guard let center = HelpMeWrite.current else { return nil }
        let session = WriteSession(center: center, field: ComposerWriteField(composer: self))
        writeSession = session
        bodyEditor.markAreas = { [weak session] in session?.layer.pointerHoles ?? [] }
        return session
    }

    /// ⌘J and ⇧⌘J apply while the keyboard is in the body (or its prompt line) of a message that can be written in, and
    /// no write runs there: never from To, Cc, Bcc or Subject. Nor under a sheet (“Send without a subject?”), whose
    /// Send Anyway would take the body as a write fills it.
    var canHelpMeWrite: Bool {
        guard HelpMeWrite.current != nil, writeSession?.isWriting != true, !isSending, let window, window.attachedSheet == nil else {
            return false
        }
        let inBody = window.firstResponder === bodyEditor || (writeSession?.layer.promptHoldsFocus ?? false)
        return inBody && bodyEditor.isEditable
    }

    /// The menu items' titles for what ⌘J and ⇧⌘J do now (§5.35).
    func validateHelpMeWrite(_ item: NSMenuItem) -> Bool {
        let instructions = item.action == #selector(helpMeWriteWithInstructions(_:))
        item.toolTip = nil
        guard canHelpMeWrite, let session = bodyWriteSession else {
            item.title = instructions ? MainMenu.helpMeWriteWithInstructionsTitle : MainMenu.helpMeWriteTitle
            return false
        }
        item.title = session.menuTitle(withInstructions: instructions)
        return true
    }

    /// Ends Help me write on the body: a draft streaming in is put back first, the prompt line closes, Try again is
    /// forgotten.
    func endHelpMeWrite() {
        writeSession?.end()
    }
}

/// A composer's body as Help me write's field: the user's own text is the body above the signature (the quoted
/// original is never in the text), and its marks are the body's own (the pill floats on the body's page, under the
/// selection). What is written there follows what the composer was opened as: a reply answers the message it replies
/// to, read from the store as the quick reply's is; a new message and a forward are written from what the window
/// itself holds, handed over as plain values (`ComposeWriteInputs`).
@MainActor
final class ComposerWriteField: WriteField {
    private weak var composer: ComposeWindowController?
    /// What the composer was opened as, which it never changes: kept here so the kind of write outlives the window.
    private let mode: ComposeMode

    init(composer: ComposeWindowController) {
        self.composer = composer
        mode = composer.mode
    }

    private var editor: ComposeTextView? { composer?.bodyEditor }

    var writeTextView: NSTextView { editor ?? NSTextView() }

    /// A forward is one while it holds its forwarded message, or is still fetching it. Once that is known not to come
    /// (the original gone, its body not loaded, a draft kept without it) there is nothing here but what the user gives,
    /// so it is written, worded and offered as a new message is (§5.56). The window gone, it is what it was opened as.
    var writeKind: WriteKind {
        switch mode {
        case .new: return .newMessage
        case .reply: return .reply
        case .forward:
            guard let composer else { return .forward }
            return composer.hasForwardedMessage || composer.isLoadingForwardedMessage ? .forward : .newMessage
        }
    }

    /// From the mode, so a kept reply or forward opened again counts as what it is, never as `draft`.
    var analyticsKind: AnalyticsSignal.ComposeKind { AnalyticsSignal.ComposeKind(mode) }

    var ownTextRange: NSRange {
        guard let editor else { return NSRange(location: 0, length: 0) }
        let body = editor.attributedString()
        let text = body.string as NSString
        let end = ComposeSignature.range(in: body).map { ComposeSignature.separatorStart(before: $0, in: text) } ?? text.length
        return NSRange(location: 0, length: end)
    }

    /// The selection keeps its own style (bold stays bold), also when the reply goes between its own leading and trailing
    /// space and line breaks (a triple-clicked paragraph): read from the text where the reply goes, which typing attributes
    /// may not have caught up with (a style applied to the selection after it was made), less the marks typing never
    /// carries. A reply in place of the notes is set as typed text is.
    func writeAttributes(at range: NSRange) -> [NSAttributedString.Key: Any] {
        guard let editor else { return [:] }
        let selection = editor.selectedRange()
        guard range.length > 0, selection.length > 0, NSIntersectionRange(range, selection) == range,
              let storage = editor.textStorage, range.location < storage.length else {
            return ComposeTextView.defaultTypingAttributes(at: editor.textSize)
        }
        return ComposeTextView.typingSafe(storage.attributes(at: range.location, effectiveRange: nil))
    }

    var refusesEdits: Bool {
        get { composer?.refusesBodyEdits ?? false }
        set { composer?.refusesBodyEdits = newValue }
    }

    func streamDidUpdate() {
        editor?.textDidChangeByWriting()
    }

    var writeLayer: WriteInlineLayer {
        composer?.bodyWriteLayer ?? WriteInlineLayer(textView: NSTextView())
    }

    var placeholderWidth: CGFloat? { nil }

    /// A block under the body's last line hangs below its text: the body grows by it, and the quoted original moves down.
    /// A block inside the text (under a line the signature or more notes follow) moves those lines down without hanging
    /// below anything: the body grows by it all the same, or they would run past the editor, over the quoted original and
    /// out of reach of a click.
    func reservedSpaceDidChange() {
        guard let composer, let editor else { return }
        editor.reservedBottom = composer.bodyWriteLayer.overflow
        editor.invalidateIntrinsicContentSize()
        guard composer.bodyWriteLayer.revealsBlock else { return }
        // A block that just opened shows whole once the window has laid the grown body out: a reply that ends at the
        // window's bottom edge would otherwise leave its afterline below it.
        DispatchQueue.main.async { [weak editor, weak composer] in
            MainActor.assumeIsolated {
                editor?.window?.contentView?.layoutSubtreeIfNeeded()
                composer?.bodyWriteLayer.revealBlockIfNeeded()
            }
        }
    }

    func setHeldOpen(_ held: Bool) {}

    func focusText() {
        guard let editor else { return }
        editor.window?.makeFirstResponder(editor)
    }

    /// Where the composer cannot tell the user's words from quoted mail (a provider's draft continued here, a Send
    /// Later message rebuilt from the outbox), a whole draft would send that mail as notes and replace it: only a
    /// selection is rewritten there. A forward waits for its forwarded message, which is what it is written from.
    var selectionOnlyReason: String? {
        guard let composer else { return nil }
        if composer.bodyIsOfUnknownOrigin { return WriteWords.selectionOnly }
        if composer.isLoadingForwardedMessage { return WriteWords.forwardLoading }
        return nil
    }

    /// A provider's draft continued here, or a message rebuilt from the outbox, holds quoted mail and a signature in one
    /// unmarked text: nothing around a selection is read there (§5.56). The window gone, nothing is.
    var textAroundSelectionIsOwn: Bool { !(composer?.bodyIsOfUnknownOrigin ?? true) }

    func blocksSeam(at index: Int) -> Bool {
        guard let storage = editor?.textStorage, index >= 0, index < storage.length else { return true }
        return storage.attribute(.link, at: index, effectiveRange: nil) != nil
            || storage.attribute(.attachment, at: index, effectiveRange: nil) != nil
    }

    func seamAttributes(in range: NSRange) -> [NSAttributedString.Key: Any]? {
        guard let storage = editor?.textStorage, range.location >= 0, range.length > 0, NSMaxRange(range) <= storage.length else {
            return nil
        }
        var run = NSRange(location: NSNotFound, length: 0)
        let attributes = storage.attributes(at: range.location, longestEffectiveRange: &run, in: range)
        return run == range ? ComposeTextView.typingSafe(attributes) : nil
    }

    func commitSubject(_ subject: String, undo: UndoManager?) -> Bool {
        composer?.commitWrittenSubject(subject, undo: undo) ?? false
    }

    func writeContext() -> WriteContextInputs? {
        // A send under way, or one waiting for dropped attachments (§5.20), has taken the body as it stands: a draft
        // streaming in now would go with it half-written. So would one started under a sheet whose answer sends
        // (“Send without a subject?”).
        guard let composer, !composer.isSending, !composer.isWaitingToSend, composer.window?.attachedSheet == nil,
              let editor else { return nil }
        let appendsSignature = ComposeSignature.range(in: editor.attributedString()) != nil
        guard let original = composer.repliesTo else {
            // A new message or a forward: what this window holds, and nothing read from the store. Of the recipients
            // only To is handed over, and a subject is asked for only where the composer would take one.
            return .composed(ComposeWriteInputs(subject: composer.subjectText, to: composer.toRecipients, account: composer.account,
                                                appendsSignature: appendsSignature,
                                                wantsSubject: composer.takesWrittenSubject && !composer.bodyIsUntouchedPrefill,
                                                redactsOwnText: composer.bodyIsUntouchedPrefill,
                                                forwarded: composer.forwardedMessage))
        }
        let store = composer.client.store
        var messages: [MessageMetadata] = []
        if let conversation = (try? store.message(original))?.conversationID {
            messages = RenderPayloadBuilder.visibleMessages((try? store.messages(in: conversation)) ?? [])
        }
        if messages.isEmpty, let message = try? store.message(original) { messages = [message] }
        guard !messages.isEmpty else { return nil }
        // What the context reads stays whole for the write: a Keep mail clean-up reads the marks inside its write.
        composer.client.keepBodies(of: messages.map(\.id))
        return .reply(ReplyWriteInputs(store: store, messages: messages, target: original, accounts: composer.accounts,
                                       appendsSignature: appendsSignature))
    }
}
