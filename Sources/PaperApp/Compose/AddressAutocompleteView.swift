import AppKit
import PaperCore
import PaperDesign

/// The recipient autocomplete (spec §5.21): an app-drawn `raised` popover (`e2`, radius 8, padding 4, 320 pt)
/// over the composer, because it must track the caret. Rows are 40 pt: a 24 pt avatar, 10 pt, the name in
/// `body` `ink` with the typed letters in `bodyStrong`, over the address in `meta` `ink3`.
///
/// The highlighted row is a selection, drawn like the list's: `selWash` with the 3 pt `selRule` margin rule on
/// its leading edge, inks unchanged, and a trailing “↩” keycap. It opens, closes and moves instantly.
@MainActor
final class AddressAutocompleteView: NSView, QuirePointerCover {
    var onAccept: ((EmailAddress) -> Void)?

    private(set) var suggestions: [EmailAddress] = []
    private var typed = ""
    private var highlightIndex = 0
    private let sheet = QuireSheetView(frame: .zero)
    private let rows = RowsView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        sheet.fillColor = .qRaised
        sheet.elevation = Quire.Elevation.e2
        sheet.cornerRadius = Quire.Layout.Autocomplete.radius
        sheet.showsEdge = false
        addSubview(sheet)
        rows.owner = self
        sheet.contentView.addSubview(rows)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Suggestions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AddressAutocompleteView is built in code")
    }

    override var isFlipped: Bool { true }

    var highlighted: EmailAddress? {
        suggestions.indices.contains(highlightIndex) ? suggestions[highlightIndex] : nil
    }

    func show(_ suggestions: [EmailAddress], typed: String) {
        let previous = highlighted
        self.suggestions = suggestions
        self.typed = typed
        highlightIndex = previous.flatMap { suggestions.firstIndex(of: $0) } ?? 0
        rows.needsDisplay = true
        invalidateIntrinsicContentSize()
        pointerRegionsDidChange()
        if highlighted != previous { announceHighlight() }
    }

    func moveHighlight(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let previous = highlightIndex
        highlightIndex = min(max(0, highlightIndex + delta), suggestions.count - 1)
        rows.needsDisplay = true
        if highlightIndex != previous { announceHighlight() }
    }

    /// Focus stays in the recipient being typed, so VoiceOver hears the highlighted suggestion this way.
    private func announceHighlight() {
        guard let suggestion = highlighted else { return }
        let text = [suggestion.name, suggestion.address].compactMap { $0 }.joined(separator: ", ")
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    override var fittingSize: NSSize {
        let a = Quire.Layout.Autocomplete.self
        return NSSize(width: a.width, height: 2 * a.pad + CGFloat(suggestions.count) * a.row)
    }

    /// Places the popover: `frame` is the sheet's own rect, from `ComposePopoverPlacement`.
    func setFrameFromPopover(_ rect: NSRect) {
        frame = rect
        sheet.frame = bounds
        rows.frame = sheet.contentView.bounds
        pointerRegionsDidChange()
    }

    // MARK: Pointer

    /// The pointing hand over each suggestion, which a click accepts, and the arrow over the padding around them (§4.17).
    /// The popover lies on the body, the other recipient rows, the subject and their buttons, whose pointers would
    /// otherwise show through it: as a `QuirePointerCover` they leave its frame to it.
    var pointerRegions: [QuirePointerRegion] {
        let rowRects = suggestions.indices.map { convert(rowRect($0), from: rows) }
        return rowRects.map { QuirePointerRegion.control($0, acts: true) }
            + QuirePointerRegion.regions(bounds, cursor: .arrow, cutting: rowRects)
    }

    override func resetCursorRects() {
        addPointerRects()
    }

    // As a cover, the views under it leave its frame to it: they are asked again when it comes, goes, moves or hides.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointerCoverDidChange()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let old = frame.origin
        super.setFrameOrigin(newOrigin)
        if frame.origin != old { pointerCoverDidChange() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        if frame.size != old { pointerCoverDidChange() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        pointerCoverDidChange()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        pointerCoverDidChange()
    }

    // MARK: Rows

    fileprivate func rowRect(_ index: Int) -> NSRect {
        let a = Quire.Layout.Autocomplete.self
        return NSRect(x: a.pad, y: a.pad + CGFloat(index) * a.row, width: bounds.width - 2 * a.pad, height: a.row)
    }

    fileprivate func hover(at point: NSPoint) {
        guard let index = suggestions.indices.first(where: { rowRect($0).contains(point) }), index != highlightIndex else { return }
        highlightIndex = index
        rows.needsDisplay = true
    }

    fileprivate func click(at point: NSPoint) {
        guard let index = suggestions.indices.first(where: { rowRect($0).contains(point) }) else { return }
        onAccept?(suggestions[index])
    }

    fileprivate func drawRows() {
        let a = Quire.Layout.Autocomplete.self
        for (index, suggestion) in suggestions.enumerated() {
            let row = rowRect(index)
            if index == highlightIndex {
                NSGraphicsContext.saveGraphicsState()
                QuireDraw.roundedRect(row, radius: a.rowRadius).addClip()
                NSColor.qSelWash.setFill()
                row.fill()
                NSColor.qSelRule.setFill()
                NSRect(x: row.minX, y: row.minY, width: a.highlightRule, height: row.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let avatar = NSRect(x: row.minX + a.rowPadX, y: row.midY - a.avatar / 2, width: a.avatar, height: a.avatar)
            QuireAvatarRenderer.drawFace(
                initials: QuireAvatarRenderer.initials(displayName: suggestion.name, address: suggestion.address),
                tint: QuireAvatarRenderer.tint(forAddress: suggestion.address), in: avatar)
            let textX = avatar.maxX + a.avatarGap
            var trailing = row.maxX - a.rowPadX
            if index == highlightIndex {
                let size = QuireKeycap.size(for: "↩", style: .standard)
                let keycap = NSRect(x: row.maxX - a.keycapTrailing - size.width, y: (row.midY - size.height / 2).rounded(),
                                    width: size.width, height: size.height)
                QuireKeycap.draw("↩", style: .standard, in: keycap)
                trailing = keycap.minX - 8
            }
            let nameRole = QuireFont.Role.body
            let metaRole = QuireFont.Role.meta
            let top = (row.midY - (nameRole.lineHeight + metaRole.lineHeight) / 2).rounded()
            let width = max(0, trailing - textX)
            nameString(for: suggestion).draw(with: NSRect(x: textX, y: top, width: width, height: nameRole.lineHeight),
                                             options: QuireFont.drawingOptions, context: nil)
            let hasName = !(suggestion.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            if hasName {
                QuireFont.attributedString(suggestion.address, role: metaRole, color: .qInk3)
                    .draw(with: NSRect(x: textX, y: top + nameRole.lineHeight, width: width, height: metaRole.lineHeight),
                          options: QuireFont.drawingOptions, context: nil)
            }
        }
    }

    /// The name with every word that starts with the typed letters marked in `bodyStrong`.
    private func nameString(for suggestion: EmailAddress) -> NSAttributedString {
        let name = (suggestion.name ?? "").trimmingCharacters(in: .whitespaces)
        let text = name.isEmpty ? suggestion.address : name
        let string = NSMutableAttributedString(attributedString: QuireFont.attributedString(text, role: .body, color: .qInk))
        let needle = typed.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return string }
        let strong = QuireFont.font(.bodyStrong)
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let found = ns.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            guard found.location != NSNotFound else { break }
            let atWordStart = found.location == 0
                || !(CharacterSet.alphanumerics.contains(UnicodeScalar(ns.character(at: found.location - 1)) ?? " "))
            if atWordStart { string.addAttribute(.font, value: strong, range: found) }
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: ns.length - next)
        }
        return string
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        suggestions.enumerated().map { index, suggestion in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.row)
            element.setAccessibilityLabel([suggestion.name, suggestion.address].compactMap { $0 }.joined(separator: ", "))
            element.setAccessibilitySelected(index == highlightIndex)
            element.setAccessibilityParent(self)
            if let window { element.setAccessibilityFrame(window.convertToScreen(convert(rowRect(index), to: nil))) }
            return element
        }
    }
}

/// Draws the rows; hover moves the highlight, a click accepts.
@MainActor
private final class RowsView: NSView {
    weak var owner: AddressAutocompleteView?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        owner?.hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        owner?.click(at: convert(event.locationInWindow, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawRows()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Clicks must not take focus from the recipient being typed.
    override var acceptsFirstResponder: Bool { false }
}
