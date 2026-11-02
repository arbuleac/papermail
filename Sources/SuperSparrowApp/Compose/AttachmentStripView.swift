import AppKit
import SSDesign

/// The attachment strip (spec §5.22): a 48 pt band of `sheet` under a top hairline, above the format row and
/// the bottom bar, shown only while there are attachments. Chips are centred, 8 pt apart, from x = 16, and
/// scroll horizontally. Inline parts of a quoted original are never listed.
///
/// The strip is one stop in the Tab loop; ← → move focus between chips and ⌫ removes the focused one.
@MainActor
final class AttachmentStripView: NSView {
    var onRemove: ((UUID) -> Void)?

    var attachments: [ComposeAttachment] = [] {
        didSet { rebuildChips() }
    }

    var hasChips: Bool { !chips.isEmpty }

    private let scrollView = NSScrollView()
    private let document = StripDocumentView()
    private var chips: [AttachmentChipView] = []
    private var focusedIndex = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = document
        document.strip = self
        addSubview(scrollView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Attachments")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentStripView is built in code")
    }

    override var isFlipped: Bool { true }

    private func rebuildChips() {
        chips.forEach { $0.removeFromSuperview() }
        chips = attachments.filter { !$0.isInline }.map { attachment in
            let chip = AttachmentChipView(attachment: attachment)
            chip.onRemove = { [weak self] id in self?.onRemove?(id) }
            return chip
        }
        chips.forEach(document.addSubview)
        focusedIndex = min(focusedIndex, max(0, chips.count - 1))
        needsLayout = true
        document.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let c = Quire.Layout.Composer.self
        scrollView.frame = NSRect(x: 0, y: 1, width: bounds.width, height: max(0, bounds.height - 1))
        var x = c.stripPadX
        let height = scrollView.frame.height
        for chip in chips {
            let size = chip.intrinsicContentSize
            chip.frame = NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + c.stripChipSpacing
        }
        let contentWidth = chips.isEmpty ? 0 : x - c.stripChipSpacing + c.stripPadX
        document.frame = NSRect(x: 0, y: 0, width: max(contentWidth, scrollView.contentSize.width), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qSheet.setFill()
        // Views no longer clip to their bounds (macOS 14), and the dirty rect can reach past them.
        dirtyRect.intersection(bounds).fill()
        QuireHairline.fill(along: NSRect(x: 0, y: 0, width: bounds.width, height: 1), orientation: .horizontal,
                           width: QuireHairline.width(for: self), color: .qRule, atMaxEdge: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { !chips.isEmpty }
    override var canBecomeKeyView: Bool { !chips.isEmpty && !isHidden }

    override func becomeFirstResponder() -> Bool {
        document.needsDisplay = true
        revealFocusedChip()
        return true
    }

    override func resignFirstResponder() -> Bool {
        document.needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard !chips.isEmpty, let special = event.specialKey,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch special {
        case .leftArrow:
            focusedIndex = max(0, focusedIndex - 1)
        case .rightArrow:
            focusedIndex = min(chips.count - 1, focusedIndex + 1)
        case .delete, .deleteForward:
            onRemove?(chips[focusedIndex].attachment.id)
            return
        default:
            super.keyDown(with: event)
            return
        }
        document.needsDisplay = true
        revealFocusedChip()
    }

    private func revealFocusedChip() {
        guard chips.indices.contains(focusedIndex) else { return }
        document.scrollToVisible(chips[focusedIndex].frame.insetBy(dx: -Quire.Layout.Composer.stripPadX, dy: 0))
    }

    fileprivate var focusedChipFrame: NSRect? {
        guard window?.firstResponder === self, window?.isKeyWindow == true, chips.indices.contains(focusedIndex) else { return nil }
        return chips[focusedIndex].frame
    }
}

/// Hosts the chips and draws the focus ring around the focused one (outside it, where the chip cannot draw).
@MainActor
private final class StripDocumentView: NSView {
    weak var strip: AttachmentStripView?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let frame = strip?.focusedChipFrame else { return }
        QuireFocusRing.draw(around: frame, cornerRadius: Quire.Layout.Composer.stripChipRadius, gap: QuireFocusRing.gap)
    }
}
