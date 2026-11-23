import AppKit
import PaperCore
import PaperDesign

/// Help me write on the quick reply (spec §5.56): Edit › Help Me Write (⌘J) writes in place, Edit › Help Me Write with
/// Instructions… (⇧⌘J) opens the prompt line under the caret's line; everything it shows is in the text, none of it in
/// the tool row.
extension ConversationViewController {
    @objc func helpMeWrite(_ sender: Any?) {
        guard canHelpMeWrite, let session = quickReplyWriteSession else {
            NSSound.beep()
            return
        }
        session.write()
    }

    @objc func helpMeWriteWithInstructions(_ sender: Any?) {
        guard canHelpMeWrite, let session = quickReplyWriteSession else {
            NSSound.beep()
            return
        }
        session.showPrompt()
    }

    /// The quick reply's session, made the first time Help me write is reached there (the environment's center must be
    /// on screen by then).
    var quickReplyWriteSession: WriteSession? {
        if let writeSession { return writeSession }
        guard isViewLoaded, let center = HelpMeWrite.current else { return nil }
        let session = WriteSession(center: center, field: QuickReplyWriteField(reader: self))
        writeSession = session
        quickReplyBar.writeMenuItems = { [weak session] in session?.contextMenuItems() ?? [] }
        return session
    }

    /// ⌘J and ⇧⌘J apply while the keyboard is in a quick reply that can be written in (its text or its prompt line): one
    /// conversation shown, the bar there and not given to a composer or a send's strip, and no write running there.
    var canHelpMeWrite: Bool {
        guard isViewLoaded, case .one = selection, HelpMeWrite.current != nil, writeSession?.isWriting != true else { return false }
        let bar = quickReplyBar
        guard !bar.isHiddenOrHasHiddenAncestor, !bar.isComposerOpen, bar.stripState == nil, bar.writingTextView.isEditable,
              let window = view.window else { return false }
        let inField = window.firstResponder === bar.writingTextView || (writeSession?.layer.promptHoldsFocus ?? false)
        return inField && replyTarget(in: currentMessages) != nil
    }

    /// The menu items' titles for what ⌘J and ⇧⌘J do now (§5.35).
    func validateHelpMeWrite(_ item: NSMenuItem) -> Bool {
        let instructions = item.action == #selector(helpMeWriteWithInstructions(_:))
        guard canHelpMeWrite, let session = quickReplyWriteSession else {
            item.title = instructions ? MainMenu.helpMeWriteWithInstructionsTitle : MainMenu.helpMeWriteTitle
            return false
        }
        item.title = session.menuTitle(withInstructions: instructions)
        return true
    }

    /// Ends Help me write on the quick reply: a reply streaming in is put back first, the prompt line closes, and Try again
    /// and the prompt's instruction are forgotten (another conversation, text set from outside, a send).
    func endHelpMeWrite() {
        writeSession?.end()
    }

    /// A reply is streaming into the quick reply: what the field holds is not the user's to send yet.
    var isWritingReply: Bool { writeSession?.isWriting == true }
}

/// The quick reply as Help me write's field: its whole text is the user's notes, its marks are its text's (the pill floats
/// on the bar, out of the text's clip), its blocks grow the field, and the reply answers the reader's target message.
@MainActor
final class QuickReplyWriteField: WriteField {
    private weak var reader: ConversationViewController?

    init(reader: ConversationViewController) {
        self.reader = reader
    }

    private var bar: QuickReplyView? { reader?.quickReplyBar }

    var writeTextView: NSTextView { bar?.writingTextView ?? NSTextView() }

    var writeKind: WriteKind { .reply }

    var analyticsKind: AnalyticsSignal.ComposeKind { bar?.mode == .replyAll ? .replyAll : .reply }

    var ownTextRange: NSRange {
        NSRange(location: 0, length: (writeTextView.string as NSString).length)
    }

    func writeAttributes(at range: NSRange) -> [NSAttributedString.Key: Any] {
        writeTextView.typingAttributes
    }

    var refusesEdits: Bool {
        get { bar?.refusesEdits ?? false }
        set { bar?.refusesEdits = newValue }
    }

    func streamDidUpdate() {
        bar?.textDidChangeByWriting()
    }

    var writeLayer: WriteInlineLayer { bar?.writeLayer ?? WriteInlineLayer(textView: NSTextView()) }

    var placeholderWidth: CGFloat? { bar?.placeholderGhostOffset }

    func reservedSpaceDidChange() {
        bar?.writeSpaceDidChange()
    }

    func setHeldOpen(_ held: Bool) {
        bar?.isHeldOpen = held
    }

    func focusText() {
        bar?.focus()
    }

    func writeContext() -> WriteContextInputs? {
        guard let reader, let target = reader.replyTarget(in: reader.currentMessages) else { return nil }
        let messages = reader.currentMessages
        // What the context reads stays whole for the write: a Keep mail clean-up reads the marks inside its write.
        reader.client.keepBodies(of: messages.map(\.id))
        let account = reader.accountsByID[target.id.accountID]
        let signature = ComposeSignature.export(html: account?.signature)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return WriteContextInputs(store: reader.client.store, messages: messages, target: target.id,
                                  accounts: Array(reader.accountsByID.values), appendsSignature: !signature.isEmpty)
    }
}
