import AppKit
import PaperDesign

/// One field row of the composer (spec §5.20): `paper`, the label right-aligned in a 56 pt column from x = 16
/// (`snippet` `ink3`), the value from x = 84, optional trailing accessories (the To row's Cc and Bcc buttons),
/// and a hairline at the bottom from x = 16 to 16 pt before the trailing edge.
///
/// Rows are borderless, so a focused row draws the **inset ring**: 2 pt (3 pt in Increase Contrast) `focus`
/// from x = 78 to 16 pt before the trailing edge (6 pt before the accessories while they show), its outer edge
/// 3 pt inside the row's top and bottom, radius 5. Never animated, not drawn while the window is not key, and
/// not drawn while a selected token carries the ring instead.
@MainActor
final class ComposeFieldRow: NSView {
    enum Kind {
        /// 36 pt, or taller while a recipient field wraps.
        case field
        /// 42 pt.
        case subject
    }

    let title: String
    let kind: Kind
    let control: NSView
    private(set) var accessories: [NSView]
    /// Whether the control has keyboard focus; asked when drawing the ring.
    var isFocused: () -> Bool = { false }
    /// When true the ring is drawn by something inside the row (a selected token), not around it.
    var focusIsInside: () -> Bool = { false }
    /// Overrides the row's height (recipient rows that wrap); nil uses the kind's height.
    var heightProvider: (() -> CGFloat)?

    init(title: String, kind: Kind = .field, control: NSView, accessories: [NSView] = []) {
        self.title = title
        self.kind = kind
        self.control = control
        self.accessories = accessories
        super.init(frame: .zero)
        addSubview(control)
        accessories.forEach(addSubview)
        setAccessibilityElement(false)
        if let field = control as? NSControl { field.setAccessibilityLabel(title) }
        control.setAccessibilityLabel(title)
        // VoiceOver lands on the text being typed, so it names the row too: “To”, not just “Recipients”.
        (control as? AddressTokenField)?.input.setAccessibilityLabel(title)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeFieldRow is built in code")
    }

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat {
        if let heightProvider { return heightProvider() }
        switch kind {
        case .field: return Quire.Layout.Composer.fieldRow
        case .subject: return Quire.Layout.Composer.subjectRow
        }
    }

    /// The accessories that show (the Cc and Bcc buttons until used).
    private var visibleAccessories: [NSView] { accessories.filter { !$0.isHidden } }

    func accessoriesDidChange() {
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Geometry

    /// The ring's trailing edge: 16 pt before the window's edge, or 6 pt before the first accessory.
    private var ringTrailing: CGFloat {
        let c = Quire.Layout.Composer.self
        if let first = visibleAccessories.map(visualMinX).min() { return first - c.focusRingButtonGap }
        return bounds.width - c.fieldTrailing
    }

    private func visualMinX(_ view: NSView) -> CGFloat {
        view.alignmentRect(forFrame: view.frame).minX
    }

    var ringRect: NSRect {
        let c = Quire.Layout.Composer.self
        return NSRect(x: c.focusRingX, y: c.focusRingInsetY, width: max(0, ringTrailing - c.focusRingX),
                      height: max(0, bounds.height - 2 * c.focusRingInsetY))
    }

    override func layout() {
        super.layout()
        let c = Quire.Layout.Composer.self
        // Accessories trail at 16 pt, `ccBccGap` apart, centred on the row's first line.
        var x = bounds.width - c.fieldTrailing
        let firstLineMidY = c.fieldRow / 2
        for accessory in visibleAccessories.reversed() {
            let size = accessory.intrinsicContentSize
            let visual = NSRect(x: x - size.width, y: (firstLineMidY - size.height / 2).rounded(), width: size.width, height: size.height)
            accessory.frame = accessory.frame(forAlignmentRect: visual)
            x = visual.minX - c.ccBccGap
        }
        layoutControl()
    }

    private func layoutControl() {
        let c = Quire.Layout.Composer.self
        let ring = ringRect
        switch control {
        case let field as AddressTokenField:
            // The field spans the ring's inside so a selected token's ring is never clipped; its tokens start on
            // the value axis.
            field.frame = NSRect(x: c.focusRingX, y: c.focusRingInsetY, width: ring.width, height: ring.height)
        case let popup as QuirePopUpButton:
            // The ink dot sits on the value axis: the borderless face starts its left padding before it.
            let size = popup.intrinsicContentSize
            let width = min(size.width, ring.maxX - (c.valueX - Quire.Layout.Popup.padLeft))
            let visual = NSRect(x: c.valueX - Quire.Layout.Popup.padLeft, y: ((bounds.height - size.height) / 2).rounded(),
                                width: width, height: size.height)
            popup.frame = popup.frame(forAlignmentRect: visual)
        default:
            let height = control.intrinsicContentSize.height
            let right = ring.maxX - 6
            control.frame = NSRect(x: c.valueX - 2, y: ((bounds.height - height) / 2).rounded(), width: max(0, right - c.valueX + 2),
                                   height: height)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let c = Quire.Layout.Composer.self
        NSColor.qPaper.setFill()
        // Views no longer clip to their bounds (macOS 14), and the dirty rect can reach past them.
        dirtyRect.intersection(bounds).fill()

        let role = QuireFont.Role.snippet
        let label = QuireFont.attributedString(title, role: role, color: .qInk3)
        let width = ceil(label.size().width)
        let firstLineMidY = (kind == .subject ? bounds.height : c.fieldRow) / 2
        let labelRect = NSRect(x: c.labelX + c.labelColumn - width, y: (firstLineMidY - role.lineHeight / 2).rounded(),
                               width: width + 1, height: role.lineHeight)
        label.draw(with: labelRect, options: QuireFont.drawingOptions, context: nil)

        let hairline = NSRect(x: c.labelX, y: bounds.height - 1, width: max(0, bounds.width - c.labelX - c.fieldTrailing), height: 1)
        QuireHairline.fill(along: hairline, orientation: .horizontal, width: QuireHairline.width(for: self), color: .qRule)

        if (window?.isKeyWindow ?? false), isFocused(), !focusIsInside() {
            QuireFocusRing.drawInset(in: ringRect, cornerRadius: c.focusRingRadius)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func environmentDidChange(_ note: Notification) {
        needsDisplay = true
    }
}
