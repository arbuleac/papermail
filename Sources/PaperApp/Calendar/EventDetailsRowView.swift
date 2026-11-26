import AppKit
import PaperCore
import PaperDesign

/// One labelled row of an event's details (spec §5.54): the label in its column, the value's lines beside it (words
/// selectable, links as link buttons), and a copy button trailing on the first line.
@MainActor
final class EventDetailsRowView: NSView {
    typealias Pane = Quire.Layout.CalendarPane

    let row: EventDetailsModel.Row
    private let label: NSTextField
    private var lines: [[NSView]] = []
    private(set) var controls: [NSView] = []
    private(set) var copyButton: QuireIconButton?

    var onLink: ((URL, AnalyticsSignal.EventAction) -> Void)?
    var onControl: ((String) -> Void)?
    var onCopy: ((EventDetailsModel.CopyItem, String, QuireIconButton) -> Void)?

    init(row: EventDetailsModel.Row) {
        self.row = row
        label = EventDetailsText.label(row.label, role: .snippet, color: .qInk3)
        super.init(frame: .zero)
        addSubview(label)
        var copy: QuireIconButton?
        if let item = row.copy?.item {
            let button = QuireIconButton(symbolName: Quire.Icon.copy, size: .small, accessibilityLabel: item.accessibilityLabel,
                                         target: self, action: #selector(copyClicked(_:)))
            button.toolTip = item.tooltip
            button.onStyle = .accent
            button.onSymbolName = Quire.Icon.answered
            copy = button
        }
        for (lineIndex, line) in row.lines.enumerated() {
            var views: [NSView] = []
            for (pieceIndex, piece) in line.enumerated() {
                if piece.link != nil || piece.control != nil {
                    let button = QuireButton(title: piece.text, variant: .link, size: .small, target: self, action: #selector(pieceClicked(_:)))
                    button.tag = lineIndex * 100 + pieceIndex
                    button.toolTip = piece.tooltip
                    if let tooltip = piece.tooltip, piece.link?.scheme == "tel" { button.setAccessibilityLabel(tooltip) }
                    views.append(button)
                    controls.append(button)
                } else {
                    let field = EventDetailsText.label(piece.text, role: .snippet, color: piece.color, selectable: true,
                                                       maxLines: row.maxLines)
                    field.toolTip = piece.tooltip
                    views.append(field)
                }
            }
            views.forEach(addSubview)
            lines.append(views)
            // The copy button trails the first line: Tab and VoiceOver reach it after that line, before the next ones,
            // as it is seen (the Phone link, its Copy, then More phone numbers).
            if lineIndex == 0, let copy {
                addSubview(copy)
                copyButton = copy
                controls.append(copy)
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(row.label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    private var valueX: CGFloat { Quire.Layout.Invitation.labelColumn }

    private func valueWidth(_ width: CGFloat, line: Int) -> CGFloat {
        let full = width - valueX
        return line == 0 && copyButton != nil ? full - Pane.detailsCopyButton - Pane.detailsCopyGap : full
    }

    /// The row's height at `width`: every line, 2 pt apart, at least the copy button's.
    func height(forWidth width: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        for (index, views) in lines.enumerated() {
            if index > 0 { height += Quire.Layout.Invitation.rowGap }
            height += lineHeight(views, width: valueWidth(width, line: index))
        }
        if copyButton != nil { height = max(height, Pane.detailsCopyButton) }
        return ceil(max(height, QuireFont.Role.snippet.lineHeight))
    }

    private func lineHeight(_ views: [NSView], width: CGFloat) -> CGFloat {
        if views.count == 1, let field = views.first as? NSTextField { return EventDetailsText.height(of: field, width: width) }
        return views.map { view -> CGFloat in
            if let button = view as? QuireButton { return button.intrinsicContentSize.height }
            if let field = view as? NSTextField { return EventDetailsText.height(of: field, width: width) }
            return 0
        }.max() ?? 0
    }

    override func layout() {
        super.layout()
        let lineHeight = QuireFont.Role.snippet.lineHeight
        // The first text line centred on the copy button when there is one.
        let firstLineTop: CGFloat = copyButton != nil ? (Pane.detailsCopyButton - lineHeight) / 2 : 0
        label.frame = NSRect(x: 0, y: firstLineTop, width: valueX - 4, height: lineHeight)
        var y = firstLineTop
        for (index, views) in lines.enumerated() {
            if index > 0 { y += Quire.Layout.Invitation.rowGap }
            let width = valueWidth(bounds.width, line: index)
            var x = valueX
            if views.count == 1, let field = views.first as? NSTextField {
                let h = EventDetailsText.height(of: field, width: width)
                field.frame = NSRect(x: x, y: y, width: width, height: h)
                y += h
                continue
            }
            var tallest: CGFloat = 0
            for view in views {
                let remaining = max(0, valueX + width - x)
                if let button = view as? QuireButton {
                    let size = button.intrinsicContentSize
                    let w = min(size.width, max(0, remaining - EventDetailsText.wordsInset))
                    // A link's words start where a field's would at the same x (a field draws its words its cell's
                    // inset in): the row's words stay in one column, links or not.
                    let wordsX = x + EventDetailsText.wordsInset
                    let visual = NSRect(x: wordsX - Quire.Layout.Button.linkPadX, y: y + (lineHeight - size.height) / 2, width: w,
                                        height: size.height)
                    button.frame = button.frame(forVisualRect: visual)
                    // The next piece is a field, which draws its words its inset in: so they follow the link's words
                    // with no more than the space they begin with.
                    x += w - 2 * Quire.Layout.Button.linkPadX
                    tallest = max(tallest, lineHeight)
                } else if let field = view as? NSTextField {
                    let w = min(ceil(field.attributedStringValue.size().width) + 8, remaining)
                    field.frame = NSRect(x: x, y: y, width: w, height: lineHeight)
                    x += w
                    tallest = max(tallest, lineHeight)
                }
            }
            y += tallest
        }
        if let copyButton {
            let side = Pane.detailsCopyButton
            copyButton.frame = NSRect(x: bounds.width - side, y: 0, width: side, height: side)
        }
    }

    @objc private func pieceClicked(_ sender: QuireButton) {
        let line = sender.tag / 100, index = sender.tag % 100
        guard row.lines.indices.contains(line), row.lines[line].indices.contains(index) else { return }
        let piece = row.lines[line][index]
        if let control = piece.control {
            onControl?(control)
        } else if let url = piece.link {
            onLink?(url, piece.action ?? .notesLink)
        }
    }

    @objc private func copyClicked(_ sender: QuireIconButton) {
        guard let copy = row.copy else { return }
        onCopy?(copy.item, copy.value, sender)
    }

    override func accessibilityChildren() -> [Any]? {
        var views: [NSView] = []
        for (index, line) in lines.enumerated() {
            views += line
            if index == 0, let copyButton { views.append(copyButton) }
        }
        return views
    }
}

/// The card's text fields: Quire roles, wrapping, selectable where they are values.
@MainActor
enum EventDetailsText {
    /// How far in from its frame a label draws its first word (its cell's inset, as `QuireInnerTextField`'s).
    static let wordsInset: CGFloat = 2

    static func label(_ text: String, role: QuireFont.Role, color: NSColor, selectable: Bool = false, maxLines: Int = 0,
                      italic: Bool = false, struck: Bool = false, tabular: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = selectable
        field.drawsBackground = false
        field.isBordered = false
        field.maximumNumberOfLines = maxLines
        field.lineBreakMode = .byWordWrapping
        field.cell?.truncatesLastVisibleLine = true
        field.attributedStringValue = attributed(text, role: role, color: color, italic: italic, struck: struck, tabular: tabular)
        field.setAccessibilityRole(.staticText)
        return field
    }

    static func attributed(_ text: String, role: QuireFont.Role, color: NSColor, italic: Bool = false, struck: Bool = false,
                           tabular: Bool = false) -> NSAttributedString {
        let string = NSMutableAttributedString(attributedString: QuireFont.attributedString(text, role: role, color: color))
        let whole = NSRange(location: 0, length: string.length)
        EventDetailsText.wrap(string)
        if italic, let font = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, string.length > 0 {
            string.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: whole)
        }
        if tabular, string.length > 0, let font = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]])
            if let tabularFont = NSFont(descriptor: descriptor, size: font.pointSize) {
                string.addAttribute(.font, value: tabularFont, range: whole)
            }
        }
        if struck { string.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: whole) }
        return string
    }

    /// The card's words wrap (a role's own style may truncate a line, as a list row's does); a word longer than the line
    /// breaks where it must.
    static func wrap(_ string: NSMutableAttributedString) {
        guard string.length > 0 else { return }
        let whole = NSRange(location: 0, length: string.length)
        let base = (string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle) ?? .default
        let style = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        string.addAttribute(.paragraphStyle, value: style, range: whole)
    }

    /// The field's height at `width`, its line count capped as it is.
    static func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        guard let cell = field.cell else { return 0 }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return ceil(size.height)
    }
}
