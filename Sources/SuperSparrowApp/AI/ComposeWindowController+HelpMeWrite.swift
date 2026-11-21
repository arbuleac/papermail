import AppKit
import SSCore
import SSDesign

/// Help me write in a reply composer (spec §5.56): ⌘J writes in place in the body, ⇧⌘J opens the prompt line under the
/// caret's line; everything it shows is in the body's text, at the caret, none of it in the bottom bar.
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

    /// The body's session, for a reply or reply all: new messages and forwards answer no one, so they have none.
    var bodyWriteSession: WriteSession? {
        if let writeSession { return writeSession }
        guard repliesTo != nil, let center = HelpMeWrite.current else { return nil }
        let session = WriteSession(center: center, field: ComposerWriteField(composer: self))
        writeSession = session
        bodyEditor.markAreas = { [weak session] in session?.layer.pointerHoles ?? [] }
        return session
    }

    /// ⌘J and ⇧⌘J apply while the keyboard is in the body (or its prompt line) of a reply that can be written in, and no
    /// write runs there. New messages and forwards answer no one, so they never apply there.
    var canHelpMeWrite: Bool {
        guard repliesTo != nil, HelpMeWrite.current != nil, writeSession?.isWriting != true, !isSending, let window else {
            return false
        }
        let inBody = window.firstResponder === bodyEditor || (writeSession?.layer.promptHoldsFocus ?? false)
        return inBody && bodyEditor.isEditable
    }

    /// The menu items' titles for what ⌘J and ⇧⌘J do now; on a new message or a forward, why they do nothing (§5.35).
    func validateHelpMeWrite(_ item: NSMenuItem) -> Bool {
        let instructions = item.action == #selector(helpMeWriteWithInstructions(_:))
        item.toolTip = repliesTo == nil ? "Help Me Write works on replies" : nil
        guard canHelpMeWrite, let session = bodyWriteSession else {
            item.title = instructions ? MainMenu.helpMeWriteWithInstructionsTitle : MainMenu.helpMeWriteTitle
            return false
        }
        item.title = session.menuTitle(withInstructions: instructions)
        return true
    }

    /// Ends Help me write on the body: a reply streaming in is put back first, the prompt line closes, Try again is
    /// forgotten.
    func endHelpMeWrite() {
        writeSession?.end()
    }
}

/// A reply composer's body as Help me write's field: the user's own text is the body above the signature (the quoted
/// original is never in the text), its marks are the body's own (the pill floats on the body's page, under the
/// selection), and the reply answers the message the composer replies to.
@MainActor
final class ComposerWriteField: WriteField {
    private weak var composer: ComposeWindowController?

    init(composer: ComposeWindowController) {
        self.composer = composer
    }

    private var editor: ComposeTextView? { composer?.bodyEditor }

    var writeTextView: NSTextView { editor ?? NSTextView() }

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

    func writeContext() -> WriteContextInputs? {
        // A send under way, or one waiting for dropped attachments (§5.20), has taken the body as it stands: a reply
        // streaming in now would go with it half-written.
        guard let composer, !composer.isSending, !composer.isWaitingToSend, let editor, let original = composer.repliesTo else {
            return nil
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
        return WriteContextInputs(store: store, messages: messages, target: original, accounts: composer.accounts,
                                  appendsSignature: ComposeSignature.range(in: editor.attributedString()) != nil)
    }
}
