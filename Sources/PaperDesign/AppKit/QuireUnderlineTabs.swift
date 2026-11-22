import AppKit

/// The quick reply's mode tabs, Reply · Reply all (spec §5.18), drawn as underline tabs rather than a bezelled
/// segmented control: labels in `label` (12 pt Medium) after a 12 pt glyph, centred in the 28 pt tool row, the
/// selected one `labelStrong` in `ink` over a 2 pt `ink` underline as wide as the label, its top at y = 24;
/// `ink3` when the window is not key (§3.4). Rest labels are `ink2`, hover and press `ink`; disabled labels are
/// `inkDisabled` with no underline. Focus rings the selected label (radius `r.sm`), and ← → then move the
/// choice. The hit area of a tab is its label ± 6 pt, the full row height.
///
/// Each tab's slot is as wide as its Semibold label, so choosing a tab never shifts the others.
@MainActor
public final class QuireUnderlineTabs: QuireControl {
    public var items: [Item] {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true; pointerRegionsDidChange() }
    }

    public var selectedIndex: Int {
        didSet { if oldValue != selectedIndex { needsDisplay = true; pointerRegionsDidChange() } }
    }

    /// The tab a forced `displayState` applies to: the selected tab for `.focused`, the first other tab for
    /// hover and pressed, unless set.
    public var displayStateIndex: Int? {
        didSet { needsDisplay = true }
    }

    /// Called with the new index when the user chooses a tab.
    public var onChange: (@MainActor (Int) -> Void)?

    private var hoveredIndex: Int?
    private var pressedIndex: Int?
    private var moveArea: NSTrackingArea?
    private var tabElements: [QuireTabAccessibilityElement] = []

    public init(items: [Item], selectedIndex: Int = 0) {
        self.items = items
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
    }

    public convenience init(titles: [String], selectedIndex: Int = 0) {
        self.init(items: titles.map { Item($0) }, selectedIndex: selectedIndex)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireUnderlineTabs is built in code") }

    // MARK: Geometry

    private static var glyphSize: QuireSymbolSize { .custom(Quire.Layout.IconSize.row) }

    /// The tool row the tabs sit in.
    private static var rowHeight: CGFloat { Quire.Layout.QuickReply.toolRow }

    /// The label box's top: centred in the row.
    private static var labelTop: CGFloat { (rowHeight - QuireFont.Role.label.lineHeight) / 2 }

    private func glyphWidth(_ item: Item) -> CGFloat {
        guard let name = item.symbolName else { return 0 }
        return QuireDraw.symbolSize(name, size: QuireUnderlineTabs.glyphSize).width + Quire.Layout.Button.glyphGap
    }

    private func slotWidth(_ item: Item) -> CGFloat {
        glyphWidth(item) + QuireDraw.width(QuireDraw.line(item.title, .labelStrong, .black))
    }

    public override var intrinsicContentSize: NSSize {
        let widths = items.map(slotWidth)
        let gaps = CGFloat(max(0, items.count - 1)) * Quire.Layout.QuickReply.modeGap
        return NSSize(width: widths.reduce(0, +) + gaps, height: QuireUnderlineTabs.rowHeight)
    }

    /// Tab `index`'s slot: glyph plus Semibold label width, full row height.
    func slotRect(forTab index: Int) -> NSRect {
        let body = bodyRect
        var x = body.minX
        for i in 0..<index { x += slotWidth(items[i]) + Quire.Layout.QuickReply.modeGap }
        return NSRect(x: x, y: body.minY, width: slotWidth(items[index]), height: body.height)
    }

    /// The label's own box (glyph excluded) as drawn in its current weight, centred in the slot.
    func labelRect(forTab index: Int) -> NSRect {
        let slot = slotRect(forTab: index)
        let item = items[index]
        let role: QuireFont.Role = index == selectedIndex ? .labelStrong : .label
        let width = QuireDraw.width(QuireDraw.line(item.title, role, .black))
        let glyph = glyphWidth(item)
        let x = (slot.minX + (slot.width - glyph - width) / 2 + glyph).rounded()
        return NSRect(x: x, y: slot.minY + QuireUnderlineTabs.labelTop, width: width, height: QuireFont.Role.label.lineHeight)
    }

    /// Where a tab takes clicks: its slot ± 6 pt, the full row.
    func hitRect(forTab index: Int) -> NSRect {
        slotRect(forTab: index).insetBy(dx: -Quire.Layout.QuickReply.modeHitPad, dy: 0)
    }

    private func tabIndex(at point: NSPoint) -> Int? {
        items.indices.first { hitRect(forTab: $0).contains(point) }
    }

    // MARK: State per tab

    private func forcedIndex(for state: QuireDisplayState) -> Int {
        if let displayStateIndex { return displayStateIndex }
        if state == .focused { return selectedIndex }
        return items.indices.first { $0 != selectedIndex } ?? selectedIndex
    }

    private func state(ofTab index: Int) -> QuireDisplayState {
        if let forced = displayState {
            return forcedIndex(for: forced) == index && forced != .focused ? forced : .rest
        }
        guard isEnabled, items[index].isEnabled else { return .rest }
        if pressedIndex == index { return .pressed }
        return hoveredIndex == index ? .hover : .rest
    }

    private var focusedTab: Int? {
        if let forced = displayState { return forced == .focused ? forcedIndex(for: .focused) : nil }
        return showsFocusRing ? selectedIndex : nil
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        for index in items.indices {
            let item = items[index]
            let selected = index == selectedIndex
            let enabled = isEnabled && item.isEnabled
            let color: NSColor = !enabled ? .qInkDisabled : (selected || state(ofTab: index) != .rest ? .qInk : .qInk2)
            let label = labelRect(forTab: index)
            if let name = item.symbolName {
                let size = QuireDraw.symbolSize(name, size: QuireUnderlineTabs.glyphSize)
                let rect = NSRect(x: label.minX - Quire.Layout.Button.glyphGap - size.width, y: label.minY, width: size.width, height: label.height)
                QuireDraw.symbol(name, size: QuireUnderlineTabs.glyphSize, color: color, centredIn: rect)
            }
            let role: QuireFont.Role = selected && enabled ? .labelStrong : .label
            QuireDraw.draw(QuireDraw.line(item.title, role, color), x: label.minX, top: label.minY, maxWidth: label.width + 1,
                           lineHeight: label.height)
            if selected, enabled {
                (isWindowKey ? NSColor.qInk : NSColor.qInk3).setFill()
                NSRect(x: label.minX, y: bodyRect.minY + Quire.Layout.QuickReply.modeUnderlineY, width: label.width,
                       height: Quire.Border.TabUnderline.width).fill()
            }
        }
        if let index = focusedTab, items.indices.contains(index) {
            // The ring's inner edge sits 5 pt beside and 3 pt above and below the label, radius r.sm.
            let label = labelRect(forTab: index)
            let gap = QuireFocusRing.gap
            let box = label.insetBy(dx: -(5 - gap), dy: -(3 - gap))
            QuireFocusRing.draw(around: box, cornerRadius: Quire.Radius.sm - gap, gap: gap)
        }
    }

    // MARK: Pointer

    /// Each tab's own hit area within the control's (§4.17): the hand over a tab a click would choose, the arrow over the
    /// chosen one and over one that is disabled, which a click leaves as they are. The arrow between the tabs too: a
    /// container cuts the whole hit rect out of its own region, and the quick reply's lies on the reader's page, whose
    /// pointer would show through a gap.
    public override var pointerRegions: [QuirePointerRegion] {
        let area = hitRect
        var taken: [NSRect] = []
        var regions: [QuirePointerRegion] = []
        for index in items.indices {
            // Where two tabs' areas meet, the first takes the click (`tabIndex(at:)`), so it keeps the pointer.
            let tab = hitRect(forTab: index).intersection(area)
            let acts = isEnabled && items[index].isEnabled && index != selectedIndex
            regions += QuirePointerRegion.regions(tab, cursor: acts ? .pointingHand : .arrow, cutting: taken)
            taken.append(tab)
        }
        return regions + QuirePointerRegion.regions(area, cursor: .arrow, cutting: taken)
    }

    public override func updateTrackingAreas() {
        if let moveArea { removeTrackingArea(moveArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(area)
        moveArea = area
        super.updateTrackingAreas()
    }

    public override func mouseMoved(with event: NSEvent) {
        updateHover(convert(event.locationInWindow, from: nil))
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover(convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredIndex = nil
        needsDisplay = true
    }

    private func updateHover(_ point: NSPoint) {
        let index = tabIndex(at: point)
        if index != hoveredIndex { hoveredIndex = index; needsDisplay = true }
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled, let index = tabIndex(at: convert(event.locationInWindow, from: nil)), items[index].isEnabled else { return }
        pressedIndex = index
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let pressed = pressedIndex else { return }
        let inside = hitRect(forTab: pressed).contains(convert(event.locationInWindow, from: nil))
        hoveredIndex = inside ? pressed : nil
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        guard let pressed = pressedIndex else { return }
        pressedIndex = nil
        needsDisplay = true
        if hitRect(forTab: pressed).contains(convert(event.locationInWindow, from: nil)) { choose(pressed) }
    }

    // MARK: Choosing

    /// Selects tab `index` as the user would: when it is enabled and not already selected, then sends the action.
    func choose(_ index: Int) {
        guard isEnabled, items.indices.contains(index), items[index].isEnabled, index != selectedIndex else { return }
        selectedIndex = index
        onChange?(index)
        sendAction(action, to: target)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    public override func keyDown(with event: NSEvent) {
        if isEnabled, let key = event.specialKey, key == .leftArrow || key == .rightArrow {
            let step = key == .leftArrow ? -1 : 1
            var index = selectedIndex
            for _ in items.indices {
                index += step
                guard items.indices.contains(index) else { return }
                if items[index].isEnabled { choose(index); return }
            }
            return
        }
        super.keyDown(with: event)
    }

    /// Space does nothing on a tab group: arrows choose.
    public override func activate() {}

    // MARK: Accessibility

    public override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }

    public override func accessibilityChildren() -> [Any]? {
        if tabElements.count != items.count {
            tabElements = items.indices.map { QuireTabAccessibilityElement(tabs: self, index: $0) }
        }
        return tabElements
    }

    public override func accessibilityTabs() -> [Any]? { accessibilityChildren() }
}
