import AppKit
import SSCore
import SSDesign

/// Edit › Help Me Write… (⌘J) in a reply composer (spec §5.55): the card under the caret, writing the reply to the
/// message this composer answers.
extension ComposeWindowController {
    @objc func helpMeWrite(_ sender: Any?) {
        guard canHelpMeWrite, let center = HelpMeWrite.current else {
            NSSound.beep()
            return
        }
        let session = WriteSession(center: center, field: ComposerWriteField(composer: self))
        session.onClose = { [weak self, weak session] in
            if let self, self.writeSession === session { self.writeSession = nil }
        }
        writeSession = session
        session.open()
    }

    /// ⌘J applies while the keyboard is in the body of a reply or reply all that can be written in, with no card open.
    /// New messages and forwards answer no one, so it never applies there.
    var canHelpMeWrite: Bool {
        guard repliesTo != nil, HelpMeWrite.current != nil, writeSession == nil, !isSending, let window else { return false }
        return window.firstResponder === bodyEditor && bodyEditor.isEditable
    }

    /// Closes Help me write's card, putting the body back first if a reply was streaming into it.
    func closeWriteCard() {
        writeSession?.close()
        writeSession = nil
    }
}

/// A reply composer's body as Help me write's field: the user's own text is the body above the signature (the quoted
/// original is never in the text), the card sits under the caret or the reply being written, and the reply answers the
/// message the composer replies to.
@MainActor
final class ComposerWriteField: WriteField {
    private weak var composer: ComposeWindowController?

    init(composer: ComposeWindowController) {
        self.composer = composer
    }

    private var editor: ComposeTextView? { composer?.bodyEditor }

    var writeTextView: NSTextView { editor ?? NSTextView() }

    var cardHost: NSView { composer?.content ?? NSView() }

    var ownTextRange: NSRange {
        guard let editor else { return NSRange(location: 0, length: 0) }
        let body = editor.attributedString()
        let text = body.string as NSString
        let end = ComposeSignature.range(in: body).map { ComposeSignature.separatorStart(before: $0, in: text) } ?? text.length
        return NSRange(location: 0, length: end)
    }

    /// The selection keeps its own style (bold stays bold); a reply in place of the notes is set as typed text is.
    func writeAttributes(at range: NSRange) -> [NSAttributedString.Key: Any] {
        guard let editor else { return [:] }
        if range.length > 0, range == editor.selectedRange() { return editor.typingAttributes }
        return ComposeTextView.defaultTypingAttributes(at: editor.textSize)
    }

    func cardFrame(size: NSSize, anchoredTo range: NSRange) -> NSRect {
        let host = cardHost
        let c = Quire.Layout.WriteCard.self
        guard let editor, let lines = WriteCardGeometry.lineRects(in: editor, range: range, host: host) else {
            return NSRect(x: Quire.Layout.Composer.valueX - c.pad, y: Quire.Layout.Composer.fieldRow * 4, width: size.width, height: size.height)
        }
        // Under the last line, its leading edge at the selection's start (at a caret, the text's) less the card's padding, so
        // the instruction field starts over the text it writes; above the first line without room.
        let textStart = host.convert(NSPoint(x: editor.textContainerOrigin.x, y: 0), from: editor).x
        let startX = range.length > 0 ? lines.first.minX : textStart
        let frame = ComposePopoverPlacement.linkPopover(firstLine: lines.first, lastLine: lines.last, selectionStartX: startX,
                                                        size: size, bounds: WriteCardGeometry.topDown(host.bounds, in: host),
                                                        pad: c.pad, offsetY: c.offsetY, edgeMin: c.edgeMin)
        return WriteCardGeometry.topDown(frame, in: host)
    }

    var refusesEdits: Bool {
        get { composer?.refusesBodyEdits ?? false }
        set { composer?.refusesBodyEdits = newValue }
    }

    func cardDidChange(isOpen: Bool) {}

    func streamDidUpdate() {
        editor?.textDidChangeByWriting()
    }

    func writeContext() -> WriteContextInputs? {
        guard let composer, let editor, let original = composer.repliesTo else { return nil }
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
