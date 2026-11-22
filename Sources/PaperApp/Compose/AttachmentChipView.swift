import AppKit
import PaperCore
import PaperDesign

/// One attachment in the composer's strip (spec §5.22): the reader's chip (§5.17) with a remove button where the reader
/// has Download. 44 pt, as wide as its words need up to 264 pt, radius 8, an inset `rule` hairline on `sheet`. From the
/// leading edge: 8 · the file mark (28 pt, §5.57) · 10 · the name (`label` `ink`, middle-truncated, its extension kept)
/// over the meta (`meta` `ink3`: “PDF · 240 KB”, the reader's words) · 6 · remove (a 16 pt `fill` disc with a 9 pt
/// `xmark` `ink3`, `ink` on hover, 24 pt hit) · 4.
///
/// Loading keeps the meta with a contrail along the bottom inside edge; an error gives the mark up to the reader's error
/// tile, turns the name `danger` and puts the short problem in the meta, the whole of it in the tooltip. The strip draws
/// the focus ring around the focused chip and moves it with ← →.
@MainActor
final class AttachmentChipView: NSView {
    let attachment: ComposeAttachment
    var onRemove: ((UUID) -> Void)?

    private let removeButton = ChipRemoveButton()
    private var contrail: QuireContrailView?
    private let mark: FileMark

    init(attachment: ComposeAttachment) {
        self.attachment = attachment
        mark = attachment.fileMark
        super.init(frame: .zero)
        removeButton.target = self
        removeButton.action = #selector(removeTapped(_:))
        removeButton.setAccessibilityLabel("Remove \(attachment.filename)")
        removeButton.toolTip = "Remove"
        addSubview(removeButton)
        switch attachment.state {
        case .failed(_, let detail):
            toolTip = detail
        case .loading:
            toolTip = attachment.filename
            let contrail = QuireContrailView(mode: .indeterminate, color: .qAccent)
            addSubview(contrail)
            self.contrail = contrail
        case .ready:
            toolTip = attachment.filename
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        var label = "\(attachment.filename), \(metaText)"
        if case .failed(_, let detail) = attachment.state { label = "\(attachment.filename), \(detail)" }
        if attachment.state == .loading { label += ", loading" }
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentChipView is built in code")
    }

    override var isFlipped: Bool { true }

    private var c: Quire.Layout.Composer.Type { Quire.Layout.Composer.self }
    private var chip: Quire.Layout.AttachmentChip.Type { Quire.Layout.AttachmentChip.self }

    /// The reader's meta words (spec §5.17): the kind and the size, “PDF · 240 KB”; a failure's short problem instead.
    var metaText: String {
        if case .failed(let short, _) = attachment.state { return short }
        let size = RenderPayloadBuilder.sizeString(bytes: attachment.sizeBytes)
        return mark.kind.isEmpty ? size : mark.kind + " · " + size
    }

    private var nameString: NSAttributedString {
        let color: NSColor = attachment.state.isFailed ? .qDanger : .qInk
        let string = NSMutableAttributedString(attributedString: QuireFont.attributedString(attachment.filename, role: .label, color: color))
        if let style = (string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.lineBreakMode = .byTruncatingMiddle
            string.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: string.length))
        }
        return string
    }

    private var metaString: NSAttributedString {
        let string = NSMutableAttributedString(attributedString: QuireFont.attributedString(metaText, role: .meta,
                                                                                            color: attachment.state.isFailed ? .qDanger : .qInk3))
        if let style = (string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.lineBreakMode = .byTruncatingTail
            string.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: string.length))
        }
        return string
    }

    /// Where the mark (or the error tile) sits: the chip's leading padding, centred on its height.
    var markRect: NSRect {
        NSRect(x: c.stripChipPadLeft, y: ((bounds.height - chip.tile) / 2).rounded(), width: chip.tile, height: chip.tile)
    }

    override var intrinsicContentSize: NSSize {
        let fixed = c.stripChipPadLeft + chip.tile + c.stripChipMarkGap + c.stripChipInnerGap + Quire.Layout.Button.minHit
            + c.stripChipPadRight
        let words = max(ceil(nameString.size().width), ceil(metaString.size().width))
        return NSSize(width: min(c.stripChipMaxWidth, fixed + words), height: c.stripChip)
    }

    override func layout() {
        super.layout()
        let hit = Quire.Layout.Button.minHit
        removeButton.frame = NSRect(x: bounds.width - c.stripChipPadRight - hit, y: ((bounds.height - hit) / 2).rounded(), width: hit, height: hit)
        let line = Quire.Layout.Progress.contrail
        let head = Quire.Layout.Progress.contrailHead
        contrail?.frame = NSRect(x: 0, y: bounds.height - line - (head - line) / 2, width: bounds.width, height: head)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = c.stripChipRadius
        QuireDraw.fill(bounds, radius: radius, .qSheet)
        QuireDraw.strokeInside(bounds, radius: radius, width: QuireHairline.width(for: self), .qRule)
        let tile = markRect
        if attachment.state.isFailed {
            QuireDraw.fill(tile, radius: chip.tileRadius, .qFill)
            QuireSymbol.draw(Quire.Icon.warning, size: .custom(chip.tileGlyph), color: .qDanger, centredIn: tile)
        } else {
            QuireFileMark(mark).draw(in: tile)
        }

        let label = QuireFont.Role.label
        let meta = QuireFont.Role.meta
        let textX = tile.maxX + c.stripChipMarkGap
        let textWidth = max(0, removeButton.frame.minX - c.stripChipInnerGap - textX)
        let top = ((bounds.height - label.lineHeight - meta.lineHeight) / 2).rounded()
        nameString.draw(with: NSRect(x: textX, y: top, width: textWidth, height: label.lineHeight), options: QuireFont.drawingOptions,
                        context: nil)
        metaString.draw(with: NSRect(x: textX, y: top + label.lineHeight, width: textWidth, height: meta.lineHeight),
                        options: QuireFont.drawingOptions, context: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func removeTapped(_ sender: Any?) {
        onRemove?(attachment.id)
    }
}

/// The chip's remove control: a 16 pt `fill` disc with a 9 pt `xmark` in `ink3` (`ink` on hover), 24 pt hit, the
/// pointing hand over all of it (§4.17).
@MainActor
private final class ChipRemoveButton: NSControl, QuirePointerTarget {
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    var pointerRegions: [QuirePointerRegion] { [.control(bounds, acts: isEnabled)] }

    override func resetCursorRects() {
        addPointerRects()
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = Quire.Layout.Composer.self
        let disc = NSRect(x: (bounds.midX - c.removeVisual / 2).rounded(), y: (bounds.midY - c.removeVisual / 2).rounded(),
                          width: c.removeVisual, height: c.removeVisual)
        QuireDraw.fillCircle(disc, .qFill)
        QuireSymbol.draw(Quire.Icon.remove, size: .custom(c.removeGlyph), color: isHovered ? .qInk : .qInk3, centredIn: disc)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
        return true
    }
}
