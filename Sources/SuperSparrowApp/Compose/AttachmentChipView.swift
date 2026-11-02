import AppKit
import SSDesign

/// One attachment in the composer's strip (spec §5.22): 30 pt, at most 240 pt wide, radius 6, an inset `rule`
/// hairline on `sheet`. From the leading edge: 8 · type glyph 14 pt `ink2` · 6 · name (`label` `ink`,
/// middle-truncated first) · 6 · size (`meta` `ink3`) · 6 · remove (a 16 pt `fill` disc with a 9 pt `xmark`
/// `ink3`, `ink` on hover, 24 pt hit) · 4.
///
/// Loading shows the size as “3.1 of 4.8 MB” (or the declared size while unknown) with a contrail along the
/// bottom inside edge; an error turns the glyph to the warning triangle and the name `danger`, the problem in
/// the tooltip. The strip draws the focus ring around the focused chip and moves it with ← →.
@MainActor
final class AttachmentChipView: NSView {
    let attachment: ComposeAttachment
    var onRemove: ((UUID) -> Void)?

    private let removeButton = ChipRemoveButton()
    private var contrail: QuireContrailView?

    init(attachment: ComposeAttachment) {
        self.attachment = attachment
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
        var label = "\(attachment.filename), \(ComposeAttachment.formattedSize(attachment.sizeBytes))"
        if case .failed(_, let detail) = attachment.state { label += ", \(detail)" }
        if attachment.state == .loading { label += ", loading" }
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentChipView is built in code")
    }

    override var isFlipped: Bool { true }

    private var c: Quire.Layout.Composer.Type { Quire.Layout.Composer.self }

    private var nameString: NSAttributedString {
        let color: NSColor = attachment.state.isFailed ? .qDanger : .qInk
        let string = NSMutableAttributedString(attributedString: QuireFont.attributedString(attachment.filename, role: .label, color: color))
        if let style = (string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.lineBreakMode = .byTruncatingMiddle
            string.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: string.length))
        }
        return string
    }

    private var sizeString: NSAttributedString {
        let size = ComposeAttachment.formattedSize(attachment.sizeBytes)
        let text: String
        switch attachment.state {
        case .ready: text = size
        case .loading: text = size
        case .failed(let short, _): text = short
        }
        return QuireFont.attributedString(text, role: .meta, color: .qInk3)
    }

    private var glyphWidth: CGFloat {
        QuireSymbol.cachedImage(glyphName, size: .custom(c.stripGlyph))?.size.width ?? c.stripGlyph
    }

    private var glyphName: String { attachment.state.isFailed ? Quire.Icon.warning : attachment.symbolName }

    override var intrinsicContentSize: NSSize {
        let fixed = c.stripChipPadLeft + glyphWidth + c.stripChipInnerGap + c.stripChipInnerGap + c.stripChipInnerGap
            + Quire.Layout.Button.minHit + c.stripChipPadRight
        let width = fixed + ceil(nameString.size().width) + ceil(sizeString.size().width)
        return NSSize(width: min(c.stripChipMaxWidth, width), height: c.stripChip)
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
        let glyphColor: NSColor = attachment.state.isFailed ? .qDanger : .qInk2
        let glyphRect = NSRect(x: c.stripChipPadLeft, y: 0, width: glyphWidth, height: bounds.height)
        QuireSymbol.draw(glyphName, size: .custom(c.stripGlyph), color: glyphColor, centredIn: glyphRect)

        let size = sizeString
        let sizeWidth = ceil(size.size().width)
        let sizeX = removeButton.frame.minX - c.stripChipInnerGap - sizeWidth
        let nameX = glyphRect.maxX + c.stripChipInnerGap
        let nameWidth = max(0, sizeX - c.stripChipInnerGap - nameX)
        let label = QuireFont.Role.label
        let meta = QuireFont.Role.meta
        nameString.draw(with: NSRect(x: nameX, y: ((bounds.height - label.lineHeight) / 2).rounded(), width: nameWidth,
                                     height: label.lineHeight), options: QuireFont.drawingOptions, context: nil)
        size.draw(with: NSRect(x: sizeX, y: ((bounds.height - meta.lineHeight) / 2).rounded(), width: sizeWidth + 1,
                               height: meta.lineHeight), options: QuireFont.drawingOptions, context: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func removeTapped(_ sender: Any?) {
        onRemove?(attachment.id)
    }
}

/// The chip's remove control: a 16 pt `fill` disc with a 9 pt `xmark` in `ink3` (`ink` on hover), 24 pt hit.
@MainActor
private final class ChipRemoveButton: NSControl {
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
