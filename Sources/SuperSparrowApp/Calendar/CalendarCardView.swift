import AppKit
import SSCore
import SSDesign

/// What a calendar card says (spec §5.54, “Event details” and the week's invitation card): a kicker with the account's
/// dot or a glyph, a title, when, a few lines, and small buttons.
struct CalendarCardModel {
    struct Line {
        var glyph: (name: String, color: NSColor)?
        var text: String
        var role: QuireFont.Role
        var color: NSColor
    }

    struct Action {
        var title: String
        var variant: QuireButton.Variant
        var symbol: String?
        /// For an answer: chosen.
        var isChosen = false
        var handler: () -> Void
    }

    var dot: NSColor?
    var kickerGlyph: (name: String, color: NSColor)?
    var kicker: String
    var title: String
    var titleIsPlaceholder = false
    var when: String?
    var lines: [Line] = []
    var actions: [Action] = []
    /// What VoiceOver names the card by.
    var accessibilityName: String
}

/// A card that floats beside an event: 240 pt, `raised`, radius 8, `e2`, a hairline edge (`ruleStrong` in Increase
/// Contrast), padding 12 14 14 (spec §5.54). Its words are drawn; its actions are Quire buttons, which take Tab in
/// turn. It lies on the reader or the timeline as a pointer cover (§4.17): the arrow over it, the hand on its buttons.
@MainActor
class CalendarCardView: NSView, QuirePointerCover {
    typealias Pane = Quire.Layout.CalendarPane

    private let sheet = QuireSheetView(frame: .zero)
    private let words = CalendarCardWords()
    private(set) var buttons: [QuireButton] = []
    private(set) var model: CalendarCardModel

    init(model: CalendarCardModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Pane.detailsWidth, height: 100))
        sheet.fillColor = .qRaised
        sheet.elevation = Quire.Elevation.e2
        sheet.cornerRadius = Pane.detailsRadius
        sheet.showsEdge = true
        addSubview(sheet)
        sheet.contentView.addSubview(words)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        apply(model)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    func apply(_ model: CalendarCardModel) {
        self.model = model
        words.model = model
        for button in buttons { button.removeFromSuperview() }
        buttons = model.actions.enumerated().map { index, action in
            let button = QuireButton(title: action.title, variant: action.variant, size: .small, symbolName: action.symbol,
                                     target: self, action: #selector(actionClicked(_:)))
            button.tag = index
            if action.isChosen {
                button.symbolName = Quire.Icon.answered
                button.setAccessibilityValue(NSNumber(value: true))
            }
            sheet.contentView.addSubview(button)
            return button
        }
        for (index, button) in buttons.enumerated() {
            button.nextKeyView = buttons[(index + 1) % buttons.count]
        }
        setAccessibilityLabel(model.accessibilityName)
        setFrameSize(NSSize(width: Pane.detailsWidth, height: preferredHeight))
        needsLayout = true
        words.needsDisplay = true
    }

    /// The card's height for its words and its buttons, wrapped to the width.
    var preferredHeight: CGFloat {
        let wordsHeight = words.height(forWidth: Pane.detailsWidth - 2 * Pane.detailsPadX)
        let rows = actionRows(width: Pane.detailsWidth - 2 * Pane.detailsPadX)
        let actionsHeight = rows.isEmpty ? 0
            : Pane.detailsActionsTop + CGFloat(rows.count) * Quire.Layout.Button.Small.height
                + CGFloat(rows.count - 1) * Pane.detailsActionGap
        return ceil(Pane.detailsPadTop + wordsHeight + actionsHeight + Pane.detailsPadBottom)
    }

    /// The buttons in rows, 4 pt apart, wrapping at the width.
    private func actionRows(width: CGFloat) -> [[QuireButton]] {
        var rows: [[QuireButton]] = []
        var row: [QuireButton] = []
        var used: CGFloat = 0
        for button in buttons {
            let w = button.intrinsicContentSize.width
            if !row.isEmpty, used + Pane.detailsActionGap + w > width {
                rows.append(row)
                row = []
                used = 0
            }
            used += (row.isEmpty ? 0 : Pane.detailsActionGap) + w
            row.append(button)
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    override func layout() {
        super.layout()
        sheet.frame = bounds
        let inner = bounds.width - 2 * Pane.detailsPadX
        let wordsHeight = words.height(forWidth: inner)
        words.frame = NSRect(x: Pane.detailsPadX, y: Pane.detailsPadTop, width: inner, height: wordsHeight)
        var y = Pane.detailsPadTop + wordsHeight + Pane.detailsActionsTop
        for row in actionRows(width: inner) {
            var x = Pane.detailsPadX
            for button in row {
                let size = button.intrinsicContentSize
                button.frame = button.frame(forVisualRect: NSRect(x: x, y: y, width: size.width, height: size.height))
                x += size.width + Pane.detailsActionGap
            }
            y += Quire.Layout.Button.Small.height + Pane.detailsActionGap
        }
        pointerRegionsDidChange()
    }

    @objc private func actionClicked(_ sender: QuireButton) {
        guard model.actions.indices.contains(sender.tag) else { return }
        model.actions[sender.tag].handler()
    }

    // MARK: Pointer

    var pointerRegions: [QuirePointerRegion] {
        QuirePointerRegion.regions(bounds, cursor: .arrow, cutting: childPointerAreas())
    }

    override func resetCursorRects() {
        addPointerRects()
    }

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

    /// A click on the card itself (not a button) stays on it, rather than reaching the reader under it.
    override func mouseDown(with event: NSEvent) {}

    override func accessibilityChildren() -> [Any]? { [words] + buttons }
}

/// The card's words, drawn: the kicker, the title (at most three lines), when, and the lines under it.
@MainActor
final class CalendarCardWords: NSView {
    typealias Pane = Quire.Layout.CalendarPane

    var model: CalendarCardModel? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    private var kickerHeight: CGFloat { QuireFont.Role.runningHead.lineHeight }

    private func title(_ model: CalendarCardModel) -> NSAttributedString {
        CalendarType.wrapping(model.title, role: .title, color: model.titleIsPlaceholder ? .qInk3 : .qInk)
    }

    private func height(of text: NSAttributedString, width: CGFloat, maxLines: Int, role: QuireFont.Role) -> CGFloat {
        let box = NSSize(width: width, height: CGFloat(maxLines) * role.lineHeight)
        let used = text.boundingRect(with: box, options: QuireFont.drawingOptions, context: nil).height
        return min(box.height, max(role.lineHeight, ceil(used / role.lineHeight) * role.lineHeight))
    }

    private func lineText(_ line: CalendarCardModel.Line) -> NSAttributedString {
        CalendarType.wrapping(line.text, role: line.role, color: line.color,
                              firstLineIndent: line.glyph == nil ? 0 : Pane.eventGlyph + Pane.eventGlyphGap)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let model else { return 0 }
        var height = kickerHeight + Pane.detailsTitleTop + self.height(of: title(model), width: width, maxLines: 3, role: .title)
        if let when = model.when {
            height += Pane.detailsWhenTop + self.height(of: CalendarType.wrapping(when, role: .body, color: .qInk), width: width,
                                                        maxLines: 2, role: .body)
        }
        for line in model.lines {
            height += Pane.detailsPlaceTop + self.height(of: lineText(line), width: width, maxLines: 4, role: line.role)
        }
        return ceil(height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        var x: CGFloat = 0
        let kickerRole = QuireFont.Role.runningHead
        if let dot = model.dot {
            let side = Quire.Layout.ReaderHeader.kickerDot
            QuireDraw.fillCircle(NSRect(x: 0, y: (kickerHeight - side) / 2, width: side, height: side), dot)
            x = side + Quire.Layout.ReaderHeader.kickerDotGap
        } else if let glyph = model.kickerGlyph {
            QuireSymbol.draw(glyph.name, size: .custom(Pane.eventGlyph), color: glyph.color,
                             centredIn: NSRect(x: 0, y: 0, width: Pane.eventGlyph, height: kickerHeight))
            x = Pane.eventGlyph + Pane.eventGlyphGap
        }
        QuireFont.attributedString(model.kicker, role: kickerRole, color: .qInk3)
            .draw(with: NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: kickerHeight),
                  options: QuireFont.drawingOptions, context: nil)
        var y = kickerHeight + Pane.detailsTitleTop
        let title = title(model)
        let titleHeight = height(of: title, width: bounds.width, maxLines: 3, role: .title)
        title.draw(with: NSRect(x: 0, y: y, width: bounds.width, height: titleHeight), options: QuireFont.drawingOptions, context: nil)
        y += titleHeight
        if let when = model.when {
            y += Pane.detailsWhenTop
            let text = CalendarType.wrapping(when, role: .body, color: .qInk)
            let h = height(of: text, width: bounds.width, maxLines: 2, role: .body)
            text.draw(with: NSRect(x: 0, y: y, width: bounds.width, height: h), options: QuireFont.drawingOptions, context: nil)
            y += h
        }
        for line in model.lines {
            y += Pane.detailsPlaceTop
            let text = lineText(line)
            let h = height(of: text, width: bounds.width, maxLines: 4, role: line.role)
            if let glyph = line.glyph {
                QuireSymbol.draw(glyph.name, size: .custom(Pane.eventGlyph), color: glyph.color,
                                 centredIn: NSRect(x: 0, y: y, width: Pane.eventGlyph, height: line.role.lineHeight))
            }
            text.draw(with: NSRect(x: 0, y: y, width: bounds.width, height: h), options: QuireFont.drawingOptions, context: nil)
            y += h
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override func accessibilityValue() -> Any? {
        guard let model else { return nil }
        return ([model.kicker, model.title, model.when].compactMap { $0 } + model.lines.map(\.text)).joined(separator: ", ")
    }
}
