import AppKit

/// A Quire popup button (spec §5.27): 24 pt, radius 6, `raised` with a 1 pt `ruleStrong` inset edge, padding
/// 0 6 0 9, the value in `body` `ink` and a trailing `chevron.up.chevron.down` 12 pt `ink2`. The menu itself is a
/// system `NSMenu` with a checkmark on the current value.
///
/// States: hover `raised + hover`; pressed while the menu is open, `raised + pressed`; focus rings it outside a
/// 1 pt gap; disabled is `fill`, `inkDisabled`, no edge. The borderless variant (the composer's From) shows no
/// face or edge until hovered, and is as wide as its chosen value, so the chevron sits right after it. An account dot or swatch in the label sits on a 2 pt `raised` halo that the
/// face's wash is clipped around, so the ink always meets `raised` (§4.2).
@MainActor
public final class QuirePopUpButton: QuireControl {
    /// The system menu the button pops. Its items' targets and actions are the button's.
    public let itemMenu = NSMenu()

    public var titles: [String] {
        get { itemMenu.items.map(\.title) }
        set { rebuildMenu(newValue) }
    }

    public var selectedIndex: Int = 0 {
        didSet {
            if oldValue != selectedIndex { updateCheckmarks(); invalidateIntrinsicContentSize(); needsDisplay = true }
        }
    }

    public var isBorderless = false {
        didSet { if oldValue != isBorderless { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    public var inkMark: InkMark? {
        didSet { if oldValue != inkMark { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    /// Called with the chosen index when the user picks an item.
    public var onChange: (@MainActor (Int) -> Void)?

    /// The menu is showing; the face draws pressed.
    public private(set) var isMenuOpen = false

    public init(titles: [String], selectedIndex: Int = 0, isBorderless: Bool = false) {
        self.isBorderless = isBorderless
        super.init(frame: .zero)
        itemMenu.autoenablesItems = false
        rebuildMenu(titles)
        self.selectedIndex = min(max(0, selectedIndex), max(0, titles.count - 1))
        updateCheckmarks()
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuirePopUpButton is built in code") }

    /// The selected item's title.
    public var title: String {
        guard itemMenu.items.indices.contains(selectedIndex) else { return "" }
        return itemMenu.items[selectedIndex].title
    }

    private func rebuildMenu(_ titles: [String]) {
        itemMenu.removeAllItems()
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(itemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            itemMenu.addItem(item)
        }
        updateCheckmarks()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func updateCheckmarks() {
        for (index, item) in itemMenu.items.enumerated() { item.state = index == selectedIndex ? .on : .off }
    }

    @objc private func itemChosen(_ sender: NSMenuItem) {
        let changed = sender.tag != selectedIndex
        selectedIndex = sender.tag
        guard changed else { return }
        onChange?(selectedIndex)
        sendAction(action, to: target)
    }

    // MARK: Geometry

    private static var chevronSize: QuireSymbolSize { .custom(Quire.Layout.Popup.chevron) }

    private var markWidth: CGFloat { inkMark.map { $0.diameter + Quire.Layout.Popup.gap } ?? 0 }

    /// A bordered popup is as wide as its widest item, so its face never changes size. The borderless one has no face
    /// at rest, only its value and chevron, so it hugs the chosen value: the chevron follows the words, never left out
    /// where a longer item would end.
    public override var intrinsicContentSize: NSSize {
        let p = Quire.Layout.Popup.self
        let measured = isBorderless ? [title] : itemMenu.items.map(\.title)
        let widest = measured.map { QuireDraw.width(QuireDraw.line($0, .body, .black)) }.max() ?? 0
        let chevron = QuireDraw.symbolSize(Quire.Icon.popup, size: QuirePopUpButton.chevronSize).width
        return NSSize(width: ceil(p.padLeft + markWidth + widest + p.gap + chevron + p.padRight), height: p.height)
    }

    /// Hosts lay their rows out by hand from the intrinsic size: a borderless popup that changes width with its value asks
    /// its row to place it again.
    public override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    private func markRect(in face: NSRect) -> NSRect? {
        guard let inkMark else { return nil }
        let d = inkMark.diameter
        return NSRect(x: face.minX + Quire.Layout.Popup.padLeft, y: face.midY - d / 2, width: d, height: d)
    }

    // MARK: Drawing

    private var faceState: QuireDisplayState {
        isMenuOpen ? .pressed : interactionState
    }

    public override func draw(_ dirtyRect: NSRect) {
        let p = Quire.Layout.Popup.self
        let face = faceRect
        let radius = p.radius
        let state = faceState
        let mark = markRect(in: face)
        let wash: NSColor? = state == .pressed ? .qPressed : state == .hover ? .qHover : nil

        if !isEnabled {
            if !isBorderless { QuireDraw.fill(face, radius: radius, .qFill) }
        } else if !isBorderless || wash != nil {
            QuireDraw.fill(face, radius: radius, .qRaised)
            if let wash {
                // The wash stops at the ink's halo, so the ink always meets `raised`.
                NSGraphicsContext.saveGraphicsState()
                let clip = QuireDraw.roundedRect(face, radius: radius)
                if let mark {
                    let halo = mark.insetBy(dx: -p.inkHalo, dy: -p.inkHalo)
                    clip.append(NSBezierPath(ovalIn: halo))
                    clip.windingRule = .evenOdd
                }
                clip.addClip()
                wash.setFill()
                face.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if !isBorderless { QuireDraw.strokeInside(face, radius: radius, width: Quire.Border.Strong.width, .qRuleStrong) }
        }

        if let mark, let inkMark {
            QuireDraw.fillCircle(mark, .qAccount(inkMark.slot))
        }
        let chevronWidth = QuireDraw.symbolSize(Quire.Icon.popup, size: QuirePopUpButton.chevronSize).width
        let chevronRect = NSRect(x: face.maxX - p.padRight - chevronWidth, y: face.minY, width: chevronWidth, height: face.height)
        QuireDraw.symbol(Quire.Icon.popup, size: QuirePopUpButton.chevronSize, color: isEnabled ? .qInk2 : .qInkDisabled,
                         centredIn: chevronRect)
        let lineHeight = QuireFont.Role.body.lineHeight
        let x = face.minX + p.padLeft + markWidth
        QuireDraw.draw(QuireDraw.line(title, .body, isEnabled ? .qInk : .qInkDisabled), x: x,
                       top: (face.midY - lineHeight / 2).rounded(), maxWidth: chevronRect.minX - p.gap - x, lineHeight: lineHeight)
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: radius, gap: QuireFocusRing.gap)
        }
    }

    // MARK: Opening

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        openMenu()
    }

    public override func activate() {
        openMenu()
    }

    public override func keyDown(with event: NSEvent) {
        if isEnabled, let key = event.specialKey, key == .downArrow || key == .upArrow {
            openMenu()
            return
        }
        super.keyDown(with: event)
    }

    /// Pops the system menu with the current item under the pointer, aligned to the value's text.
    public func openMenu() {
        guard isEnabled, !itemMenu.items.isEmpty else { return }
        isMenuOpen = true
        stateDidChange()
        displayIfNeeded()
        let face = faceRect
        let origin = NSPoint(x: face.minX + Quire.Layout.Popup.padLeft + markWidth, y: face.maxY)
        itemMenu.popUp(positioning: itemMenu.item(at: selectedIndex), at: origin, in: self)
        isMenuOpen = false
        stateDidChange()
    }

    // MARK: Accessibility

    public override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    public override func accessibilityValue() -> Any? { title }
}
