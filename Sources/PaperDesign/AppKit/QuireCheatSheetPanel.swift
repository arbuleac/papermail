import AppKit

/// The keyboard cheat sheet's panel (spec §5.32): 816 pt wide, `raised`, radius 12, `e3`, padding 24, with
/// the `ruleStrong` edge in Increase Contrast. A fixed 28 pt title row (“Keyboard Shortcuts” in `title` and a
/// 24 pt `xmark` icon button 16 pt from the top-trailing corner), then 16 pt below it the sections in bands
/// of three 240 pt columns, 24 pt apart, 20 pt between bands: each section opens with a 22 pt `runningHead`
/// `ink3` title, then 28 pt rows of large keycaps (24 pt, 4 pt apart) in a 96 pt key column and the label in
/// `snippet` `ink`, tail-truncated. Sequences read “G then I” with “then” in `meta` `ink3`, 6 pt either side.
/// 20 pt under the last band, one 28 pt line lists the search operators: “Search” in `runningHead` `ink3` in the
/// key column, then the operators as typed in `snippet` `ink`, 8 pt apart.
///
/// The content is `Quire.cheatSheet` and `Quire.cheatSheetSearch`, generated from `cheatSheetContent` and
/// `cheatSheetSearch`. At its natural height (736 pt) the panel shows everything; given less, as in the default
/// 800 pt window since the calendar's rows, the bands and the search line scroll under the fixed title row. `QuireCheatSheetOverlay`
/// places it over the window with the scrim and runs its motion and keys.
@MainActor
public final class QuireCheatSheetPanel: NSView, QuirePointerTarget {
    public static let title = "Keyboard Shortcuts"

    public let sections: [QuireCheatSheetSection]
    /// The search operators on the line under the bands; none, no line.
    public let searchTerms: [String]
    /// The close button. `onClose` runs when it is clicked.
    public let closeButton: QuireIconButton
    public var onClose: (@MainActor () -> Void)?

    private let sheet = QuireSheetView(frame: .zero)
    private let titleView = TitleView(frame: .zero)
    let scrollView = NSScrollView(frame: .zero)
    private let bands: BandsView

    public init(sections: [QuireCheatSheetSection] = Quire.cheatSheet, searchTerms: [String] = Quire.cheatSheetSearch) {
        self.sections = sections
        self.searchTerms = searchTerms
        bands = BandsView(sections: sections, searchTerms: searchTerms)
        closeButton = QuireIconButton(symbolName: Quire.Icon.dismiss, size: .medium, accessibilityLabel: "Close")
        super.init(frame: NSRect(x: 0, y: 0, width: Quire.Layout.CheatSheet.width,
                                 height: QuireCheatSheetPanel.naturalHeight(for: sections, searchTerms: searchTerms)))
        wantsLayer = true
        clipsToBounds = false
        sheet.fillColor = .qRaised
        sheet.elevation = Quire.Elevation.e3
        sheet.cornerRadius = Quire.Layout.CheatSheet.radius
        // No edge at rest; the sheet draws the `ruleStrong` outline in Increase Contrast on its own.
        sheet.showsEdge = false
        sheet.frame = bounds
        sheet.autoresizingMask = [.width, .height]
        addSubview(sheet)
        closeButton.toolTip = "Close  esc"
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = bands
        sheet.contentView.addSubview(scrollView)
        sheet.contentView.addSubview(titleView)
        sheet.contentView.addSubview(closeButton)
        needsLayout = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireCheatSheetPanel is built in code") }

    public override var isFlipped: Bool { true }

    // MARK: Metrics

    /// The sections in bands of three (`cheatSheet.columns`), in order.
    static func bands(of sections: [QuireCheatSheetSection]) -> [[QuireCheatSheetSection]] {
        let columns = max(1, Int(Quire.Layout.CheatSheet.columns))
        return stride(from: 0, to: sections.count, by: columns).map { Array(sections[$0..<min(sections.count, $0 + columns)]) }
    }

    /// A band's height: the section title and its longest section's rows.
    static func bandHeight(_ band: [QuireCheatSheetSection]) -> CGFloat {
        let c = Quire.Layout.CheatSheet.self
        return c.sectionTitle + CGFloat(band.map(\.rows.count).max() ?? 0) * c.row
    }

    /// The scrolling content: every band, `sectionGap` apart, then the search line `sectionGap` below them.
    static func bandsHeight(for sections: [QuireCheatSheetSection], searchTerms: [String] = Quire.cheatSheetSearch) -> CGFloat {
        let c = Quire.Layout.CheatSheet.self
        let all = bands(of: sections)
        let line = searchTerms.isEmpty ? 0 : c.sectionGap + c.row
        return all.map(bandHeight).reduce(0, +) + CGFloat(max(0, all.count - 1)) * c.sectionGap + line
    }

    /// The panel's whole height: 24 + 28 + 16 + bands + search line + 24 (736 pt for the generated content).
    public static func naturalHeight(for sections: [QuireCheatSheetSection] = Quire.cheatSheet,
                                     searchTerms: [String] = Quire.cheatSheetSearch) -> CGFloat {
        let c = Quire.Layout.CheatSheet.self
        return 2 * c.pad + c.titleRow + c.headerGap + bandsHeight(for: sections, searchTerms: searchTerms)
    }

    /// Where the bands start, under the fixed title row.
    private static var bandsTop: CGFloat {
        let c = Quire.Layout.CheatSheet.self
        return c.pad + c.titleRow + c.headerGap
    }

    /// True when the panel is shorter than its content and the bands scroll.
    public var scrolls: Bool { bounds.height < QuireCheatSheetPanel.naturalHeight(for: sections, searchTerms: searchTerms) - 0.5 }

    public override func layout() {
        super.layout()
        let c = Quire.Layout.CheatSheet.self
        titleView.frame = NSRect(x: c.pad, y: c.pad, width: bounds.width - 2 * c.pad - c.close, height: c.titleRow)
        let side = closeButton.size.side
        closeButton.frame = closeButton.frame(forVisualRect: NSRect(x: bounds.width - c.closeInset - side, y: c.closeInset, width: side, height: side))
        let top = QuireCheatSheetPanel.bandsTop
        // The bands scroll down to the panel's edge, their bottom padding inside the scrolled content: where the panel is
        // a little short of its content, the padding scrolls away first, so the last row of keycaps still draws whole
        // and only what lies below it (the search line) waits for a scroll, rather than a row cut at the padding's edge.
        scrollView.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        bands.frame = NSRect(x: 0, y: 0, width: bounds.width,
                             height: QuireCheatSheetPanel.bandsHeight(for: sections, searchTerms: searchTerms) + c.pad)
        pointerRegionsDidChange()
    }

    /// The arrow over the panel around its close button (§4.17): a click on it does nothing, and the scrim around it,
    /// which a click dismisses, shows the hand.
    public var pointerRegions: [QuirePointerRegion] {
        QuirePointerRegion.regions(bounds, cursor: .arrow, cutting: childPointerAreas())
    }

    public override func resetCursorRects() {
        addPointerRects()
    }

    /// Scrolls the bands by `lines` rows (arrow keys) or pages (Page Up / Down), when they scroll.
    public func scrollBands(byRows rows: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, bands.frame.height - clip.bounds.height)
        let y = min(maxY, max(0, clip.bounds.origin.y + rows * Quire.Layout.CheatSheet.row))
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    public func scrollBands(byPages pages: CGFloat) {
        scrollBands(byRows: pages * max(1, (scrollView.contentView.bounds.height / Quire.Layout.CheatSheet.row).rounded(.down) - 1))
    }

    @objc private func closeClicked(_ sender: Any?) {
        onClose?()
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }
    public override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? QuireCheatSheetPanel.title }

    // MARK: Parts

    /// The title, in `title` `ink`, vertically centred in its 28 pt row.
    fileprivate final class TitleView: NSView {
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let lineHeight = QuireFont.Role.title.lineHeight
            QuireDraw.draw(QuireDraw.line(QuireCheatSheetPanel.title, .title, .qInk), x: 0, top: ((bounds.height - lineHeight) / 2).rounded(),
                           maxWidth: bounds.width, lineHeight: lineHeight)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        override func accessibilityLabel() -> String? { QuireCheatSheetPanel.title }
    }

    /// Every band, drawn in one pass: section titles, keycaps, connecting words and labels, then the search line.
    fileprivate final class BandsView: NSView {
        let sections: [QuireCheatSheetSection]
        let searchTerms: [String]

        init(sections: [QuireCheatSheetSection], searchTerms: [String]) {
            self.sections = sections
            self.searchTerms = searchTerms
            super.init(frame: .zero)
            NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                                   name: QuireEnvironment.didChangeNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("built in code") }

        @objc private func environmentDidChange(_ note: Notification) {
            needsDisplay = true
        }

        override var isFlipped: Bool { true }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let c = Quire.Layout.CheatSheet.self
            var top: CGFloat = 0
            for band in QuireCheatSheetPanel.bands(of: sections) {
                for (column, section) in band.enumerated() {
                    let x = c.pad + CGFloat(column) * (c.columnWidth + c.columnGap)
                    // The running head sits on the bottom of its 22 pt box, as the specimen aligns it.
                    let headLine = QuireFont.Role.runningHead.lineHeight
                    QuireDraw.draw(QuireDraw.line(section.title, .runningHead, .qInk3), x: x, top: top + c.sectionTitle - headLine,
                                   maxWidth: c.columnWidth, lineHeight: headLine)
                    var rowTop = top + c.sectionTitle
                    for row in section.rows {
                        QuireCheatSheetPanel.drawRow(row, x: x, top: rowTop)
                        rowTop += c.row
                    }
                }
                top += QuireCheatSheetPanel.bandHeight(band) + c.sectionGap
            }
            if !searchTerms.isEmpty { QuireCheatSheetPanel.drawSearchLine(searchTerms, top: top) }
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
        override func accessibilityLabel() -> String? {
            let search = searchTerms.isEmpty ? [] : [Quire.cheatSheetSearchTitle + ": " + searchTerms.joined(separator: ", ")]
            return (sections.map { section in
                section.title + ": " + section.rows.map { "\($0.keys), \($0.label)" }.joined(separator: "; ")
            } + search).joined(separator: ". ")
        }
    }

    /// The search line: its title in the key column, then the operators as typed, `searchTermGap` apart, in the
    /// panel's width less its padding. They are words to type, not keys to press, so they are text, not keycaps.
    static func drawSearchLine(_ terms: [String], top: CGFloat) {
        let c = Quire.Layout.CheatSheet.self
        let headLine = QuireFont.Role.runningHead.lineHeight
        QuireDraw.draw(QuireDraw.line(Quire.cheatSheetSearchTitle, .runningHead, .qInk3), x: c.pad,
                       top: top + ((c.row - headLine) / 2).rounded(), maxWidth: c.keyColumn, lineHeight: headLine)
        let lineHeight = QuireFont.Role.snippet.lineHeight
        let end = c.width - c.pad
        var x = c.pad + c.keyColumn
        for term in terms where x < end {
            let line = QuireDraw.line(term, .snippet, .qInk)
            QuireDraw.draw(line, x: x, top: top + ((c.row - lineHeight) / 2).rounded(), maxWidth: end - x, lineHeight: lineHeight)
            x += QuireDraw.width(line) + c.searchTermGap
        }
    }

    /// One row: the keys in the 96 pt key column, then the label in the rest of the 240 pt column.
    static func drawRow(_ row: QuireCheatSheetRow, x: CGFloat, top: CGFloat) {
        let c = Quire.Layout.CheatSheet.self
        var cursor = x
        var previousWasKeycap = false
        for part in row.parts {
            if part.isKeycap {
                if previousWasKeycap { cursor += c.keycapGap }
                let size = QuireKeycap.size(for: part.text, style: .large)
                QuireKeycap.draw(part.text, style: .large, in: NSRect(x: cursor, y: top + ((c.row - size.height) / 2).rounded(),
                                                                      width: size.width, height: size.height))
                cursor += size.width
                previousWasKeycap = true
            } else {
                let word = QuireDraw.line(part.text, .meta, .qInk3)
                let gap = Quire.Space.s3
                let lineHeight = QuireFont.Role.meta.lineHeight
                cursor += gap
                QuireDraw.draw(word, x: cursor, top: top + ((c.row - lineHeight) / 2).rounded(), maxWidth: QuireDraw.width(word) + 1,
                               lineHeight: lineHeight)
                cursor += QuireDraw.width(word) + gap
                previousWasKeycap = false
            }
        }
        let labelX = x + c.keyColumn
        let lineHeight = QuireFont.Role.snippet.lineHeight
        QuireDraw.draw(QuireDraw.line(row.label, .snippet, .qInk), x: labelX, top: top + ((c.row - lineHeight) / 2).rounded(),
                       maxWidth: c.columnWidth - c.keyColumn, lineHeight: lineHeight)
    }
}
