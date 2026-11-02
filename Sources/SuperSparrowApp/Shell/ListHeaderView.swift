import AppKit
import SSDesign

/// The list header (spec §5.3–§5.6): 92 pt on `paper`, its bottom hairline on the horizon.
///
/// Row 1 is the 52 pt title-bar zone: the masthead centred on the traffic lights' line (y = 26), then, only when
/// they apply, the minimal-mode new-mail dot, the Demo tag and the narrowed account's address, and the compose
/// button at the trailing edge. Row 2 (40 pt) holds the filter tabs at x = 16 (Inbox only) and the search field
/// trailing; without tabs the search spans the row. Row 2 never drags the window.
@MainActor
final class ListHeaderView: NonDraggingView {
    let masthead = MastheadButton(frame: .zero)
    let demoTag = DemoTagButton(frame: .zero)
    let compose = QuireIconButton(symbolName: Quire.Icon.compose, size: .large, accessibilityLabel: "New Message")
    let tabs = QuireUnderlineTabs(titles: ["All", "Focused", "Other"], style: .filter)
    let search = QuireSearchField(placeholder: "Search")

    private let rowOne = HeaderRowOne()
    private let rowTwo = NonDraggingView()

    /// Where the masthead text starts: 16, or rail width + 8 while the rail is hidden.
    var mastheadX: CGFloat = Quire.Layout.ListHeader.mastheadX { didSet { if oldValue != mastheadX { needsLayout = true } } }
    var showsTabs = true { didSet { if oldValue != showsTabs { needsLayout = true; updateTabsVisibility() } } }
    var showsDemoTag = false { didSet { if oldValue != showsDemoTag { demoTag.isHidden = !showsDemoTag; needsLayout = true } } }
    var showsNewMailDot = false { didSet { if oldValue != showsNewMailDot { needsLayout = true } } }
    /// The narrowed account's address, shown as “· alex@contoso.test”.
    var address: String? { didSet { if oldValue != address { rowOne.address = address.map { "· " + $0 }; needsLayout = true } } }

    /// The search field covers the row: while it has focus, and while it keeps a query.
    private(set) var isSearchExpanded = false
    private var isAnimatingSearch = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        compose.symbolSize = .custom(Quire.Layout.ListHeader.composeGlyph)
        compose.toolTip = "New Message  C"
        demoTag.isHidden = true
        search.wantsLayer = true
        addSubview(rowOne)
        addSubview(rowTwo)
        rowOne.addSubview(masthead)
        rowOne.addSubview(demoTag)
        rowOne.addSubview(compose)
        rowTwo.addSubview(tabs)
        rowTwo.addSubview(search)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isOpaque: Bool { true }

    // MARK: Layout

    /// Frames are set by hand; a new size lays the contents out again.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = Quire.Layout.ListHeader.self
        let width = bounds.width
        rowOne.frame = NSRect(x: 0, y: 0, width: width, height: h.row1)
        rowTwo.frame = NSRect(x: 0, y: h.row1, width: width, height: h.row2)

        let composeRect = NSRect(x: width - h.composeTrailing - h.composeSize, y: h.composeTop, width: h.composeSize, height: h.composeSize)
        compose.frame = compose.frame(forVisualRect: composeRect)

        let mastheadSize = masthead.intrinsicContentSize
        let mastheadRect = NSRect(x: mastheadX - h.mastheadHitPad, y: (h.mastheadCenterY - mastheadSize.height / 2).rounded(),
                                  width: mastheadSize.width, height: mastheadSize.height)
        masthead.frame = masthead.frame(forVisualRect: mastheadRect)
        var cursor = mastheadRect.maxX - h.mastheadHitPad
        if showsNewMailDot {
            let dot = NSRect(x: cursor + h.minimalDotGap, y: h.mastheadCenterY - h.minimalDotSize / 2,
                             width: h.minimalDotSize, height: h.minimalDotSize)
            rowOne.dotRect = dot
            cursor = dot.maxX
        } else {
            rowOne.dotRect = nil
        }
        if showsDemoTag {
            let size = demoTag.intrinsicContentSize
            let tag = NSRect(x: cursor + h.demoTagGap, y: h.mastheadCenterY - size.height / 2, width: size.width, height: size.height)
            demoTag.frame = demoTag.frame(forVisualRect: tag)
            cursor = tag.maxX
        }
        let lineHeight = QuireFont.Role.snippet.lineHeight
        let addressX = cursor + h.addressGap
        rowOne.addressRect = NSRect(x: addressX, y: (h.mastheadCenterY - lineHeight / 2).rounded(),
                                    width: max(0, composeRect.minX - 8 - addressX), height: lineHeight)

        let tabsSize = tabs.intrinsicContentSize
        tabs.frame = tabs.frame(forVisualRect: NSRect(x: h.tabsX, y: 0, width: tabsSize.width, height: h.row2))
        if !isAnimatingSearch { search.frame = search.frame(forVisualRect: searchRect(expanded: isSearchExpanded)) }
    }

    /// The field's visual rect in row 2: 168 × 26 at rest, trailing 12, top 59; the full row (inset 12) when
    /// expanded or when the view has no tabs.
    private func searchRect(expanded: Bool) -> NSRect {
        let h = Quire.Layout.ListHeader.self
        let top = h.searchTop - h.row1
        if expanded || !showsTabs {
            let inset = Quire.Layout.Search.expandedInset
            return NSRect(x: inset, y: top, width: max(0, bounds.width - 2 * inset), height: h.searchHeight)
        }
        return NSRect(x: bounds.width - h.searchTrailing - h.searchWidth, y: top, width: h.searchWidth, height: h.searchHeight)
    }

    // MARK: Search expansion

    /// Grows the field over the tabs or returns it to 168 pt (`dur.standard`, `ease.glide`; a cross-fade under
    /// Reduce Motion). Only the field animates; the list does not move.
    func setSearchExpanded(_ expanded: Bool, animated: Bool = true) {
        guard expanded != isSearchExpanded else { return }
        isSearchExpanded = expanded
        let target = search.frame(forVisualRect: searchRect(expanded: expanded))
        if !expanded { updateTabsVisibility() }
        guard animated, window != nil, showsTabs else {
            search.frame = target
            updateTabsVisibility()
            return
        }
        isAnimatingSearch = true
        Quire.Motion.run(Quire.Motion.standard, .glide, reduced: .fade, participants: [search], animations: { plan in
            if plan.isReduced {
                self.search.frame = target
                self.search.alphaValue = 0
                self.search.animator().alphaValue = 1
            } else {
                self.search.animator().frame = target
            }
        }, completion: { [weak self] in
            guard let self else { return }
            self.isAnimatingSearch = false
            self.search.alphaValue = 1
            self.search.frame = self.search.frame(forVisualRect: self.searchRect(expanded: self.isSearchExpanded))
            self.updateTabsVisibility()
        })
    }

    /// Tabs show in Inbox while the field rests; an expanded field covers them, so they leave the key loop too.
    private func updateTabsVisibility() {
        tabs.isHidden = !showsTabs || (isSearchExpanded && !isAnimatingSearch)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        // Views do not clip to their bounds by default, so the fill is limited to them by hand.
        dirtyRect.intersection(bounds).fill()
        QuireHairline.fill(along: bounds, orientation: .horizontal, width: QuireHairline.width(for: self), color: .qRule,
                           atMaxEdge: true, flipped: true)
    }

    @objc private func environmentDidChange(_ note: Notification) {
        needsDisplay = true
        needsLayout = true
        // Row 1 draws the new-mail dot (`accent`, which Graphite changes) and the address itself.
        rowOne.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

/// Row 1 of the header: the title-bar zone, with the minimal-mode dot and the narrowed address drawn in it.
@MainActor
private final class HeaderRowOne: TitleBarZoneView {
    var dotRect: NSRect? { didSet { if oldValue != dotRect { needsDisplay = true } } }
    var addressRect: NSRect = .zero { didSet { if oldValue != addressRect { needsDisplay = true } } }
    var address: String? { didSet { if oldValue != address { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        if let dotRect { QuireDraw.fillCircle(dotRect, .qAccent) }
        if let address, addressRect.width > 0 {
            let text = QuireFont.attributedString(address, role: .snippet, color: .qInk3)
            text.draw(with: addressRect, options: QuireFont.drawingOptions, context: nil)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { address != nil || dotRect != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? {
        [dotRect != nil ? "New mail in another account" : nil, address].compactMap { $0 }.joined(separator: ", ")
    }
}
