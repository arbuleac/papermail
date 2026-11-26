import AppKit
import PaperCore
import PaperDesign

/// An event's notes in its details (spec §5.54): the text read at sync time (`EventNotesReader`), selectable, its https
/// and tel links `accent` and always underlined, their address as their tooltip. Nothing else is ever a link here: link
/// and data detection, substitutions and Quick Look's previews are off and cannot be turned on from Edit ›
/// Substitutions, and the menu holds Copy, Copy Link and Open Link alone (no Services, Look Up or Search With Google).
/// A click on a link goes to `onLink`, which opens it through the window's opener.
@MainActor
final class EventNotesTextView: NSTextView {
    /// A link clicked or chosen from the menu: the window's opener decides.
    var onLink: ((URL) -> Void)?
    private(set) var notes: EventNotes?
    /// Clamped to this many lines while not expanded; 0 shows every line.
    var maxLines = 0 {
        didSet { if oldValue != maxLines { needsLayout = true } }
    }

    convenience init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        usesFindBar = false
        isIncrementalSearchingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        smartInsertDeleteEnabled = false
        textContainerInset = .zero
        // Clamped to its first lines: what lies below is not drawn over Show more.
        clipsToBounds = true
        delegate = self
        setAccessibilityLabel("Notes")
    }

    /// The notes drawn in the card's tokens, links on their stored ranges alone.
    func show(_ notes: EventNotes) {
        self.notes = notes
        let text = NSMutableAttributedString(attributedString: QuireFont.attributedString(notes.text, role: .snippet, color: .qInk2))
        EventDetailsText.wrap(text)
        let length = (notes.text as NSString).length
        for link in notes.links {
            guard link.location >= 0, link.length > 0, link.location + link.length <= length,
                  let url = EventLinkPolicy.checked(link.url) else { continue }
            let range = NSRange(location: link.location, length: link.length)
            text.addAttribute(.link, value: url, range: range)
            text.addAttribute(.toolTip, value: link.url, range: range)
        }
        textStorage?.setAttributedString(text)
        linkTextAttributes = [.foregroundColor: NSColor.qAccent, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .cursor: NSCursor.pointingHand]
        needsLayout = true
    }

    /// The height of the text at `width`, every line or the first `maxLines`.
    func height(forWidth width: CGFloat, lines: Int) -> CGFloat {
        guard let container = textContainer, let manager = layoutManager else { return 0 }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let full = ceil(manager.usedRect(for: container).height)
        guard lines > 0 else { return full }
        // The bottom of the `lines`th line as laid out, so the clamp cuts between two lines, never through one.
        var count = 0
        var bottom: CGFloat = 0
        var index = 0
        let glyphs = manager.numberOfGlyphs
        while index < glyphs, count < lines {
            var range = NSRange()
            let fragment = manager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: &range)
            bottom = fragment.maxY
            count += 1
            index = NSMaxRange(range)
        }
        return min(full, ceil(bottom))
    }

    /// Whether the text runs past `lines` lines at `width`.
    func isClamped(atWidth width: CGFloat, lines: Int) -> Bool {
        height(forWidth: width, lines: 0) > height(forWidth: width, lines: lines) + 1
    }

    // MARK: What a click can do

    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return }
        onLink?(url)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        let point = convert(event.locationInWindow, from: nil)
        if let url = link(at: point) {
            let copyLink = menu.addItem(withTitle: "Copy Link", action: #selector(copyLink(_:)), keyEquivalent: "")
            copyLink.representedObject = url
            copyLink.target = self
            let open = menu.addItem(withTitle: "Open Link", action: #selector(openLink(_:)), keyEquivalent: "")
            open.representedObject = url
            open.target = self
        }
        return menu
    }

    /// The stored link under `point`, as written.
    func link(at point: NSPoint) -> URL? {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length else { return nil }
        return storage.attribute(.link, at: index, effectiveRange: nil) as? URL
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(url.absoluteString, forType: .string)
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onLink?(url)
    }

    // Nothing the system offers on text may turn on detection, replace words or preview a link.
    override func toggleAutomaticLinkDetection(_ sender: Any?) {}
    override func toggleAutomaticDataDetection(_ sender: Any?) {}
    override func toggleAutomaticTextReplacement(_ sender: Any?) {}
    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {}
    override func toggleContinuousSpellChecking(_ sender: Any?) {}
    override func quickLook(with event: NSEvent) {}
    override func quickLookPreviewItems(_ sender: Any?) {}
    override func showFindIndicator(for charRange: NSRange) {}

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(toggleAutomaticLinkDetection(_:)), #selector(toggleAutomaticDataDetection(_:)),
             #selector(toggleAutomaticTextReplacement(_:)), #selector(toggleAutomaticSpellingCorrection(_:)),
             #selector(toggleContinuousSpellChecking(_:)), #selector(quickLookPreviewItems(_:)):
            (item as? NSMenuItem)?.state = .off
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }

    override func pressureChange(with event: NSEvent) {}

    /// The hand over each link in sight and the I-beam around them, each cut out of what lies on it (§4.17), which
    /// AppKit's own I-beam could not be: an edge cover over lines scrolled past the middle's edge shows its arrow alone.
    override func resetCursorRects() {
        guard let manager = layoutManager, let container = textContainer, let notes, !isHiddenOrHasHiddenAncestor else { return }
        guard !visibleRect.isEmpty else { return }
        var hands: [NSRect] = []
        for link in notes.links {
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: link.location, length: link.length), actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in
                // A link clamped out of sight has no rect to add (the intersection is null).
                let visible = rect.intersection(self.visibleRect)
                guard !visible.isNull, !visible.isEmpty else { return }
                hands.append(visible)
            }
        }
        addTextPointerRects(cutting: hands)
        let covered = pointerCoverAreas()
        for hand in hands {
            for piece in QuirePointerRegion.regions(hand, cursor: .pointingHand, cutting: covered) {
                addCursorRect(piece.rect, cursor: piece.cursor)
            }
        }
    }
}

extension EventNotesTextView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return true }
        onLink?(url)
        return true
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        self.menu(for: event)
    }
}
