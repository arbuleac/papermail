import AppKit
import SSDesign

/// The list header (spec §5.3, §5.6): one 52 pt row on `paper`, the title-bar zone itself, with its bottom
/// hairline at 52. Everything sits on the traffic lights' centre line (y = 26): the masthead (a plain title while
/// the rail shows, the title menu's button in minimal mode), then, only when they apply, the minimal-mode new-mail
/// dot, the Demo tag and the narrowed account's address, then the search field in the free width, then compose.
///
/// The search field keeps its 140 pt minimum while anything can make room for it: first the address (it truncates,
/// and below 40 pt drops out whole, the placeholder then naming the account), then the Demo tag, which steps off the
/// line whole. The masthead text, the chevron and the dot never give way; only when they alone leave less
/// than the minimum does the field narrow, and it never starts before the cluster ends.
@MainActor
final class ListHeaderView: NonDraggingView {
    let masthead = MastheadButton(frame: .zero)
    let demoTag = DemoTagButton(frame: .zero)
    let compose = QuireIconButton(symbolName: Quire.Icon.compose, size: .large, accessibilityLabel: "New Message")
    let search = QuireSearchField(placeholder: "Search")

    private let row = HeaderRow()

    /// Where the masthead text starts: 16, or rail width + 8 while the rail is hidden.
    var mastheadX: CGFloat = Quire.Layout.ListHeader.mastheadX { didSet { if oldValue != mastheadX { needsLayout = true } } }
    var showsDemoTag = false { didSet { if oldValue != showsDemoTag { demoTag.isHidden = !showsDemoTag; needsLayout = true } } }
    var showsNewMailDot = false { didSet { if oldValue != showsNewMailDot { needsLayout = true } } }
    /// The narrowed account's address, shown as “· alex@contoso.test”.
    var address: String? { didSet { if oldValue != address { row.address = address.map { "· " + $0 }; needsLayout = true } } }
    /// The narrowed account's name (“Contoso”). While the line has no room for the address the placeholder names the
    /// account instead (“Search Contoso”, or “Contoso” in a field too narrow for that), so the scope stays on screen
    /// in minimal mode, where nothing else shows it.
    var accountName: String? { didSet { if oldValue != accountName { needsLayout = true } } }
    /// The view's placeholder (“Search”, “Search Starred”, “Search Inbox”, §5.6).
    var searchPlaceholder = "Search" { didSet { if oldValue != searchPlaceholder { needsLayout = true } } }

    /// The address as it is drawn now: its full width, and the part of it the search field leaves (0 hides it).
    private(set) var addressWidths: (natural: CGFloat, shown: CGFloat) = (0, 0)

    /// While the field has the keyboard it widens over the masthead cluster to where the masthead text starts
    /// (§5.6): a query with operators outgrows the free width beside the cluster, and the placeholder still names
    /// the view. Focus leaving gives the cluster back.
    private(set) var isSearchExpanded = false

    /// The field took or gave up the keyboard (after the header has widened or narrowed it).
    var onSearchFocusChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        compose.symbolSize = .custom(Quire.Layout.ListHeader.composeGlyph)
        compose.toolTip = "New Message  C"
        demoTag.isHidden = true
        addSubview(row)
        row.addSubview(masthead)
        row.addSubview(demoTag)
        row.addSubview(search)
        row.addSubview(compose)
        search.onFocusChange = { [weak self] focused in
            self?.setSearchExpanded(focused)
            self?.onSearchFocusChange?(focused)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    /// Widens the field over the cluster, or gives the cluster back, gliding with the field's frame (§4.10, "Search
    /// field width"; a short cross-fade under Reduce Motion). Before the header is on screen it simply lands there.
    func setSearchExpanded(_ expanded: Bool) {
        guard expanded != isSearchExpanded else { return }
        isSearchExpanded = expanded
        guard window != nil else {
            needsLayout = true
            return
        }
        Quire.Motion.run(Quire.Motion.standard, .glide, reduced: .fade, participants: [search, masthead, demoTag]) { _ in
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
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
        row.frame = NSRect(x: 0, y: 0, width: width, height: h.height)

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
            row.dotRect = dot
            cursor = dot.maxX
        } else {
            row.dotRect = nil
        }
        // Search runs from the cluster (+ 12) to compose (− 8). The Demo tag stays on the line only while the field
        // keeps its minimum beside it; off the line, the window title and the sync line still say Demo (§5.43).
        let searchEnd = composeRect.minX - h.searchComposeGap
        var tagShown = false
        if showsDemoTag {
            let size = demoTag.intrinsicContentSize
            let tag = NSRect(x: cursor + h.demoTagGap, y: h.mastheadCenterY - size.height / 2, width: size.width, height: size.height)
            if searchEnd - (tag.maxX + h.searchGap) >= h.searchMinWidth {
                demoTag.frame = demoTag.frame(forVisualRect: tag)
                cursor = tag.maxX
                tagShown = true
            }
        }
        demoTag.isHidden = !tagShown

        // The address takes only what the field's minimum leaves. A lone “· a…” names nothing, so below its own
        // minimum it drops out whole; and it gives way before the Demo tag, so it stays off while the tag is.
        let addressX = cursor + h.addressGap
        let natural = row.addressNaturalWidth
        let room = searchEnd - h.searchMinWidth - h.searchGap - addressX
        var shown: CGFloat = 0
        if natural > 0, showsDemoTag == tagShown {
            if room >= natural {
                shown = natural
            } else if room >= h.addressMinWidth {
                shown = room
            }
        }
        addressWidths = (natural, shown)
        let lineHeight = QuireFont.Role.snippet.lineHeight
        row.addressRect = NSRect(x: addressX, y: (h.mastheadCenterY - lineHeight / 2).rounded(), width: shown, height: lineHeight)

        // Never under the cluster: what the masthead, chevron and dot leave is the field's, even below its minimum.
        // Focused, the field covers the cluster from where the masthead text starts, and the cluster fades under it.
        let searchStart = isSearchExpanded ? mastheadX : (shown > 0 ? addressX + shown + h.searchGap : cursor + h.searchGap)
        let searchWidth = max(0, searchEnd - searchStart)
        search.frame = search.frame(forVisualRect: NSRect(x: searchStart, y: h.searchTop, width: searchWidth, height: h.searchHeight))
        let clusterAlpha: CGFloat = isSearchExpanded ? 0 : 1
        if masthead.alphaValue != clusterAlpha { masthead.alphaValue = clusterAlpha }
        if demoTag.alphaValue != clusterAlpha { demoTag.alphaValue = clusterAlpha }
        // With the address off the line, or covered by the widened field, the placeholder names the account; when
        // “Search Contoso” would be cut, the name alone, since the magnifier already says search and a cut name may no
        // longer tell two accounts apart.
        var placeholder = searchPlaceholder
        if address != nil, shown == 0 || isSearchExpanded, let accountName {
            let scoped = "Search " + accountName
            placeholder = search.fitsPlaceholder(scoped) ? scoped : accountName
        }
        if search.placeholder != placeholder { search.placeholder = placeholder }
        search.allowsKeycap = placeholder != accountName
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
        // The row draws the new-mail dot (`accent`, which Graphite changes) and the address itself.
        row.needsDisplay = true
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

/// The header's one row: the title-bar zone, with the minimal-mode dot and the narrowed address drawn in it.
@MainActor
private final class HeaderRow: TitleBarZoneView {
    var dotRect: NSRect? { didSet { if oldValue != dotRect { needsDisplay = true } } }
    var addressRect: NSRect = .zero { didSet { if oldValue != addressRect { needsDisplay = true } } }
    var address: String? { didSet { if oldValue != address { needsDisplay = true } } }

    private func addressText(_ address: String) -> NSAttributedString {
        QuireFont.attributedString(address, role: .snippet, color: .qInk3)
    }

    /// The address's untruncated width; 0 without one.
    var addressNaturalWidth: CGFloat {
        guard let address else { return 0 }
        return ceil(addressText(address).size().width)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let dotRect { QuireDraw.fillCircle(dotRect, .qAccent) }
        if let address, addressRect.width >= 1 {
            addressText(address).draw(with: addressRect, options: QuireFont.drawingOptions, context: nil)
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
