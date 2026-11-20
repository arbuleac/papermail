import AppKit
import SSCore
import SSDesign

/// Edit › Help Me Write… (⌘J) on the quick reply (spec §5.55): the card above the field, writing the reply to the
/// conversation's target message.
extension ConversationViewController {
    @objc func helpMeWrite(_ sender: Any?) {
        guard canHelpMeWrite, let center = HelpMeWrite.current else {
            NSSound.beep()
            return
        }
        let session = WriteSession(center: center, field: QuickReplyWriteField(reader: self))
        session.onClose = { [weak self, weak session] in
            if let self, self.writeSession === session { self.writeSession = nil }
        }
        writeSession = session
        session.open()
    }

    /// ⌘J applies while the keyboard is in a quick reply that can be written in: one conversation shown, the bar there and
    /// not given to a composer or a send's strip, and no card open on it.
    var canHelpMeWrite: Bool {
        guard isViewLoaded, case .one = selection, HelpMeWrite.current != nil, writeSession == nil else { return false }
        let bar = quickReplyBar
        guard !bar.isHiddenOrHasHiddenAncestor, !bar.isComposerOpen, bar.stripState == nil,
              let window = view.window, window.firstResponder === bar.writingTextView, bar.writingTextView.isEditable else { return false }
        return replyTarget(in: currentMessages) != nil
    }

    /// Closes Help me write's card, putting the field back first if a reply was streaming into it.
    func closeWriteCard() {
        writeSession?.close()
        writeSession = nil
    }
}

/// The quick reply as Help me write's field: its whole text is the user's notes, the card floats above the bar (there is
/// no room under a field docked to the window's bottom), and the reply answers the reader's target message.
@MainActor
final class QuickReplyWriteField: WriteField {
    private weak var reader: ConversationViewController?

    init(reader: ConversationViewController) {
        self.reader = reader
    }

    private var bar: QuickReplyView? { reader?.quickReplyBar }

    var writeTextView: NSTextView { bar?.writingTextView ?? NSTextView() }

    var cardHost: NSView { reader?.view ?? NSView() }

    var ownTextRange: NSRange {
        NSRange(location: 0, length: (writeTextView.string as NSString).length)
    }

    func writeAttributes(at range: NSRange) -> [NSAttributedString.Key: Any] {
        writeTextView.typingAttributes
    }

    func cardFrame(size: NSSize, anchoredTo range: NSRange) -> NSRect {
        guard let bar else { return NSRect(origin: .zero, size: size) }
        let host = cardHost
        let c = Quire.Layout.WriteCard.self
        // The bar takes its new height (held open, or a line more of the reply) in this pass, before it is measured.
        host.layoutSubtreeIfNeeded()
        // Above the bar, its leading edge at the reply's text less the card's padding, so the instruction field starts
        // over the text it writes.
        let barRect = WriteCardGeometry.topDown(bar.convert(bar.bounds, to: host), in: host)
        let text = writeTextView.convert(writeTextView.bounds, to: host)
        let startX = text.width > 0 ? text.minX : barRect.minX + Quire.Layout.QuickReply.textX
        let frame = ComposePopoverPlacement.linkPopover(firstLine: barRect, lastLine: barRect, selectionStartX: startX, size: size,
                                                        bounds: host.bounds, pad: c.pad, offsetY: c.offsetY, edgeMin: c.edgeMin)
        return WriteCardGeometry.topDown(frame, in: host)
    }

    var refusesEdits: Bool {
        get { bar?.refusesEdits ?? false }
        set { bar?.refusesEdits = newValue }
    }

    func cardDidChange(isOpen: Bool) {
        bar?.isHeldOpen = isOpen
    }

    func streamDidUpdate() {
        bar?.textDidChangeByWriting()
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

/// Where the card goes: rects in a top-down space over the host, as `ComposePopoverPlacement` reads them, whichever way
/// the host is flipped (the reader's root is not, the composer's content is).
@MainActor
enum WriteCardGeometry {
    /// `rect` in `host`'s coordinates, in the top-down space over its bounds; applied twice, it gives `rect` back.
    static func topDown(_ rect: NSRect, in host: NSView) -> NSRect {
        guard !host.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The caret at `range`'s start (or the first line of the selection), in the host's top-down space; nil when the text
    /// is not laid out on screen.
    static func caretRect(in textView: NSTextView, at range: NSRange, host: NSView) -> NSRect? {
        guard let window = textView.window else { return nil }
        let length = (textView.string as NSString).length
        let safe = NSRange(location: min(range.location, length), length: 0)
        let screen = textView.firstRect(forCharacterRange: safe, actualRange: nil)
        guard screen != .zero else { return nil }
        let inWindow = window.convertFromScreen(screen)
        return topDown(host.convert(inWindow, from: nil), in: host)
    }

    /// The lines of `range` in the host's top-down space: the first and the last, for anchoring under or above them.
    static func lineRects(in textView: NSTextView, range: NSRange, host: NSView) -> (first: NSRect, last: NSRect)? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        layoutManager.ensureLayout(for: container)
        let length = (textView.string as NSString).length
        let location = min(range.location, length)
        let safe = NSRange(location: location, length: min(range.length, length - location))
        var rects: [NSRect] = []
        if safe.length == 0 {
            if let caret = caretRect(in: textView, at: safe, host: host) { rects = [caret] }
        } else {
            let origin = textView.textContainerOrigin
            let glyphs = layoutManager.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { rect, _ in
                let inView = rect.offsetBy(dx: origin.x, dy: origin.y)
                rects.append(topDown(host.convert(inView, from: textView), in: host))
            }
        }
        guard let first = rects.first, let last = rects.last else { return nil }
        return (first, last)
    }
}
