import AppKit

/// A keyboard shortcut hint (spec §5.36): a small raised cap with the key's legend.
///
/// Legends are written the way the spec lists them: modifiers in Apple order (⌃⌥⇧⌘), Return “↩”, Delete
/// “⌫”, Escape “esc”, Space “space”. SF Pro carries the modifier glyphs, so the `kbd` role sets them all.
/// Other components draw keycaps with the static `draw` so a button, an empty-state hint and a slip action
/// share one implementation.
@MainActor
public final class QuireKeycap: NSView {
    public var legend: String {
        didSet { if oldValue != legend { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    public var style: Style {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    /// On a slip: the action this cap belongs to is hovered or pressed, so the legend switches from `onSlip2`
    /// to `onSlip` (`onSlip2` falls below 4.5:1 on `slip + slipPressed`, §4.1).
    public var isHighlighted = false {
        didSet { if oldValue != isHighlighted { needsDisplay = true } }
    }

    public init(_ legend: String, style: Style = .standard) {
        self.legend = legend
        self.style = style
        super.init(frame: NSRect(origin: .zero, size: QuireKeycap.size(for: legend, style: style)))
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireKeycap is built in code") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize { QuireKeycap.size(for: legend, style: style) }

    public override func draw(_ dirtyRect: NSRect) {
        QuireKeycap.draw(legend, style: style, highlighted: isHighlighted, in: bounds)
    }

    @objc private func environmentDidChange(_ note: Notification) {
        needsDisplay = true
    }

    // MARK: Shared drawing

    private struct SizeKey: Hashable {
        let legend: String
        let style: Style
    }

    /// What a style's legend needs to draw, built once per style: the paragraph style and baseline offset
    /// cost a layout manager each, and buttons ask for the cap's size on every pointer move (`hitTest`).
    private struct LegendStyle: @unchecked Sendable {
        let font: NSFont
        let paragraph: NSParagraphStyle
        let baselineOffset: CGFloat
    }

    nonisolated private static let sizes = LockedCache<SizeKey, NSSize>()
    nonisolated private static let legendStyles = LockedCache<Style, LegendStyle>()

    nonisolated private static func legendStyle(_ style: Style) -> LegendStyle {
        legendStyles.value(for: style) {
            let font = style.font
            let lineHeight = QuireFont.Role.kbd.lineHeight
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byClipping
            return LegendStyle(font: font, paragraph: paragraph, baselineOffset: QuireFont.baselineOffset(for: font, lineHeight: lineHeight))
        }
    }

    /// The cap's size: at least as wide as it is tall, the legend padded by `kbd.padX` on each side.
    nonisolated public static func size(for legend: String, style: Style) -> NSSize {
        sizes.value(for: SizeKey(legend: legend, style: style)) {
            let text = NSAttributedString(string: legend, attributes: [.font: legendStyle(style).font])
            let width = max(style.height, ceil(text.size().width) + 2 * Quire.Layout.Kbd.padX)
            return NSSize(width: width, height: style.height)
        }
    }

    /// Draws a keycap filling `rect` in the current graphics context; colours resolve now.
    public static func draw(_ legend: String, style: Style, highlighted: Bool = false, in rect: NSRect) {
        let radius = style.cornerRadius
        let legendColor: NSColor
        switch style {
        case .onSlip:
            QuireDraw.strokeInside(rect, radius: radius, width: 1, .qOnSlipEdge)
            legendColor = highlighted ? .qOnSlip : .qOnSlip2
        case .standard, .inField, .large:
            // `raised` with a 1 pt edge and a second 1 pt line inside the bottom edge for key depth; Increase
            // Contrast draws both in `ruleStrong`.
            let edge: NSColor = QuireDraw.isIncreasedContrast ? .qRuleStrong : .qRule
            QuireDraw.fill(rect, radius: radius, .qRaised)
            QuireDraw.strokeInside(rect, radius: radius, width: 1, edge)
            NSGraphicsContext.saveGraphicsState()
            QuireDraw.roundedRect(rect, radius: radius).addClip()
            edge.setFill()
            NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 1).fill()
            NSGraphicsContext.restoreGraphicsState()
            legendColor = .qInk2
        }
        let lineHeight = QuireFont.Role.kbd.lineHeight
        let legendStyle = legendStyle(style)
        let text = NSAttributedString(string: legend, attributes: [
            .font: legendStyle.font,
            .foregroundColor: legendColor,
            .paragraphStyle: legendStyle.paragraph,
            .baselineOffset: legendStyle.baselineOffset,
        ])
        let top = rect.minY + ((rect.height - lineHeight) / 2).rounded(.down)
        text.draw(with: NSRect(x: rect.minX, y: top, width: rect.width, height: lineHeight),
                  options: [.usesLineFragmentOrigin], context: nil)
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    public override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? legend }
}
