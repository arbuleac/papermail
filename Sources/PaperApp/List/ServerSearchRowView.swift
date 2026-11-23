import AppKit
import PaperCore
import PaperDesign

/// The end of a search (spec §5.10): once every local result is listed, a fixed 28 pt row, the list tail's height and
/// type, offers to search the server and then says how it went. A centred cluster: the 12 pt `magnifyingglass` in
/// `ink3`, 6 pt, then “Search Gmail for more” as a `metaStrong` `accent` link; while it runs “Searching Gmail…” in
/// `meta` `ink3`, the magnifier giving way to a 12 pt spinner once the spinner's delay has passed; then “Found 12 more on
/// Gmail” or “Nothing more on Gmail”; a failure the danger triangle and “Couldn't search Gmail” in `danger`, then a
/// “Try again” link 6 pt on, as the failed tail sets “Retry”. While the search field has the keyboard the offer ends
/// with a “↩” keycap 6 pt after the link, since ↩ in the field runs it. Never selectable; j/k never land on it; the
/// link joins the Tab order and ↩ or Space runs it.
final class ServerSearchRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ServerSearchRow")

    var row: ServerSearchRow? {
        didSet { if oldValue != row { rowDidChange(from: oldValue) } }
    }

    /// Runs the search: the offer's link and “Try again”.
    var onRun: (() -> Void)?

    /// The search field has the keyboard, so ↩ there runs the offer: its keycap shows after the link.
    var showsReturnKeycap = false {
        didSet { if oldValue != showsReturnKeycap { updateKeycap() } }
    }

    private typealias Footer = Quire.Layout.ListFooter

    private let spinner = QuireSpinnerView(size: .small, color: .qInk3)
    /// The offer's words, or “Try again” after a failure.
    let link = SyncLineActionButton(frame: .zero)
    /// “↩” after the offer while the search field has the keyboard.
    let keycap = QuireKeycap("↩")

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = ServerSearchRowView.identifier
        wantsLayer = true
        // As the rows: redrawn at a new width, not scaled to it.
        layerContentsRedrawPolicy = .duringViewResize
        spinner.onReveal = { [weak self] in self?.needsDisplay = true }
        addSubview(spinner)
        link.target = self
        link.action = #selector(linkPressed(_:))
        link.isHidden = true
        addSubview(link)
        keycap.isHidden = true
        keycap.setAccessibilityElement(false)
        addSubview(keycap)
    }

    private func updateKeycap() {
        keycap.isHidden = !(showsReturnKeycap && row?.phase == .offer)
        needsLayout = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func rowDidChange(from old: ServerSearchRow?) {
        if row?.phase == .searching {
            if old?.phase != .searching { spinner.startAnimation() }
        } else {
            spinner.stopAnimation()
        }
        let linkTitle = row.flatMap { $0.phase == .offer ? $0.title : $0.actionTitle }
        if linkTitle == nil, let window, window.firstResponder === link {
            // ↩ on the focused link started the search and the link goes: the keyboard returns to the list rather
            // than staying on a hidden control.
            window.makeFirstResponder(superview)
        }
        link.isHidden = linkTitle == nil
        link.title = linkTitle ?? ""
        link.setAccessibilityLabel(linkTitle)
        link.toolTip = row?.phase == .offer ? ServerSearchRow.menuTitle(for: row?.target) + "  ↩ in the search field" : nil
        updateKeycap()
        needsLayout = true
        needsDisplay = true
    }

    @objc private func linkPressed(_ sender: Any?) {
        onRun?()
    }

    // MARK: Content

    /// The words drawn as text: none for the offer, whose words are the link.
    private var words: NSAttributedString? {
        guard let row, row.phase != .offer else { return nil }
        if case .failed = row.phase {
            // The words carry the error's colour with the glyph, like the failed tail (§5.10).
            return QuireFont.attributedString(row.title, role: .meta, color: .qDanger)
        }
        return QuireFont.attributedString(row.title, role: .meta, color: .qInk3)
    }

    private var isFailed: Bool {
        if case .failed? = row?.phase { return true }
        return false
    }

    private var wordsWidth: CGFloat { words.map { ceil($0.size().width) } ?? 0 }

    private var linkWidth: CGFloat { link.isHidden ? 0 : link.intrinsicContentSize.width }

    private var keycapWidth: CGFloat { keycap.isHidden ? 0 : Footer.gap + keycap.intrinsicContentSize.width }

    private var clusterWidth: CGFloat {
        var width = Footer.spinner + Footer.gap
        if row?.phase == .offer { return width + linkWidth + keycapWidth }
        width += wordsWidth
        if isFailed { width += Footer.gap + linkWidth }
        return width
    }

    private var clusterX: CGFloat { max(0, ((bounds.width - clusterWidth) / 2).rounded()) }

    override func layout() {
        super.layout()
        let size = Footer.spinner
        let x = clusterX
        spinner.frame = NSRect(x: x, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
        guard !link.isHidden else { return }
        let linkX = row?.phase == .offer ? x + size + Footer.gap : x + size + Footer.gap + wordsWidth + Footer.gap
        let linkSize = link.intrinsicContentSize
        link.frame = link.frame(forVisualRect: NSRect(x: linkX, y: ((bounds.height - linkSize.height) / 2).rounded(),
                                                      width: linkSize.width, height: linkSize.height))
        // The table cuts the link's area out of the row's arrow, so it is asked again when the link moves.
        link.pointerRegionsDidChange()
        guard !keycap.isHidden else { return }
        let capSize = keycap.intrinsicContentSize
        keycap.frame = NSRect(x: linkX + linkSize.width + Footer.gap, y: ((bounds.height - capSize.height) / 2).rounded(),
                              width: capSize.width, height: capSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        bounds.fill()
        guard row != nil else { return }
        let size = Footer.spinner
        let x = clusterX
        let glyphRect = NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
        if isFailed {
            QuireSymbol.draw(Quire.Icon.failed, size: .row, color: .qDanger, centredIn: glyphRect)
        } else if !spinner.isRevealed {
            // The search field's own rule: the magnifier until the spinner's delay has passed (§5.6).
            QuireSymbol.draw(Quire.Icon.search, size: .row, color: .qInk3, centredIn: glyphRect)
        }
        guard let words else { return }
        let lineHeight = QuireFont.Role.meta.lineHeight
        words.draw(with: NSRect(x: x + size + Footer.gap, y: ((bounds.height - lineHeight) / 2).rounded(),
                                width: wordsWidth + 1, height: lineHeight),
                   options: QuireFont.drawingOptions, context: nil)
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { row != nil }
    /// A group while it holds a link, so VoiceOver reaches it; static text never has children.
    override func accessibilityRole() -> NSAccessibility.Role? { link.isHidden ? .staticText : .group }
    override func accessibilityLabel() -> String? { row?.accessibilityLabel }
}
