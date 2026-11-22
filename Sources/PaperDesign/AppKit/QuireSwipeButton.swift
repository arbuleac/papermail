import AppKit

/// The button a swipe uncovers behind a list row (spec §5.7, Swipe): the whole area the row's content slid off, its full
/// height, in the action's fill, with the action's icon above its label, both white (`onSwipe`) and centred.
///
/// The list sizes it to what the swipe has uncovered at every step, so it draws whatever width it is given. The label
/// shows only where it fits whole with `layout.swipe.padX` either side, fading in over the last `padX` before that and
/// never cut; below that the icon shows alone, centred, and it fades out in the same way, leaving the fill. Everything is
/// drawn in `draw(_:)` from live tokens, so a theme, appearance, Increase Contrast or Graphite change redraws it in the
/// new values.
///
/// A click released on it, or VoiceOver's press, calls `onPress`. It takes no keyboard focus: E, U and the row's
/// VoiceOver actions are the way to do the same without a trackpad.
@MainActor
public final class QuireSwipeButton: NSControl, QuirePointerTarget {
    private typealias Metrics = Quire.Layout.Swipe

    public var kind: QuireSwipeAction {
        didSet { if oldValue != kind { needsDisplay = true } }
    }

    /// The command's words (“Archive”, “Mark as Read”, “Mark as Unread”), shown under the icon and read by VoiceOver.
    public var title: String {
        didSet { if oldValue != title { needsDisplay = true } }
    }

    /// The list's Text size (spec §4.15): the label is set in `label` at it, like the row it sits behind.
    public var textSize: QuireFont.TextSize {
        didSet { if oldValue != textSize { needsDisplay = true } }
    }

    /// What a click or VoiceOver's press does; nil leaves the button inert (and shows the arrow over it).
    public var onPress: (() -> Void)? {
        didSet { if (oldValue == nil) != (onPress == nil) { pointerRegionsDidChange() } }
    }

    public init(kind: QuireSwipeAction, title: String, textSize: QuireFont.TextSize = .default) {
        self.kind = kind
        self.title = title
        self.textSize = textSize
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    public required init?(coder: NSCoder) {
        nil
    }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { false }

    // MARK: Layout

    /// Where the icon and the label go in a button of `size`, and how much of each shows (0 none, 1 all of it).
    public struct Layout: Equatable {
        /// The icon's box, `layout.swipe.glyph` square; the symbol is centred on it at its own size.
        public var icon: NSRect
        public var iconAlpha: CGFloat
        /// The label's line box, as wide as the label set whole.
        public var label: NSRect
        public var labelAlpha: CGFloat
    }

    /// The width the button opens to when a swipe is let go of short of a full swipe: the label set whole with `padX`
    /// either side, never under `layout.swipe.minWidth`.
    public static func openWidth(title: String, textSize: QuireFont.TextSize) -> CGFloat {
        max(Metrics.minWidth, labelWidth(title, textSize: textSize) + 2 * Metrics.padX)
    }

    /// The icon over the label, the pair centred in `size`. As the label fades in, the icon rises from the centre to
    /// its place above it, so nothing jumps while the fingers move.
    public static func layout(title: String, textSize: QuireFont.TextSize, size: NSSize) -> Layout {
        let glyph = Metrics.glyph
        let pad = Metrics.padX
        let width = labelWidth(title, textSize: textSize)
        let lineHeight = QuireFont.Role.label.lineHeight(at: textSize)
        func ramp(_ content: CGFloat) -> CGFloat { min(1, max(0, (size.width - content - pad) / pad)) }
        let iconAlpha = ramp(glyph)
        let labelAlpha = ramp(width)
        let stack = glyph + labelAlpha * (Metrics.glyphGap + lineHeight)
        let top = (size.height - stack) / 2
        let icon = NSRect(x: ((size.width - glyph) / 2).rounded(), y: top.rounded(), width: glyph, height: glyph)
        let label = NSRect(x: ((size.width - width) / 2).rounded(), y: (top + glyph + Metrics.glyphGap).rounded(),
                           width: width, height: lineHeight)
        return Layout(icon: icon, iconAlpha: iconAlpha, label: label, labelAlpha: labelAlpha)
    }

    public var currentLayout: Layout {
        Self.layout(title: title, textSize: textSize, size: bounds.size)
    }

    private static func labelString(_ title: String, textSize: QuireFont.TextSize, color: NSColor = .qOnSwipe) -> NSAttributedString {
        QuireFont.attributedString(title, role: .label, color: color, textSize: textSize)
    }

    private static func labelWidth(_ title: String, textSize: QuireFont.TextSize) -> CGFloat {
        QuireDraw.width(labelString(title, textSize: textSize))
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        kind.fill.setFill()
        bounds.fill()
        let layout = currentLayout
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if layout.iconAlpha > 0 {
            context.saveGState()
            context.setAlpha(layout.iconAlpha)
            QuireDraw.symbol(kind.symbolName, size: Self.symbolSize, color: kind.contentColor, centredIn: layout.icon)
            context.restoreGState()
        }
        if layout.labelAlpha > 0 {
            context.saveGState()
            context.setAlpha(layout.labelAlpha)
            // The box is the label's own width plus a point, so it is never truncated.
            QuireDraw.draw(Self.labelString(title, textSize: textSize, color: kind.contentColor), x: layout.label.minX,
                           top: layout.label.minY, maxWidth: layout.label.width + 1, lineHeight: layout.label.height)
            context.restoreGState()
        }
    }

    /// `layout.swipe.glyph` at a medium weight, so the white symbol holds up on the fill as the label beside it does.
    public static let symbolSize = QuireSymbolSize.custom(Metrics.glyph, weight: .medium)

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func environmentDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    // MARK: Clicking

    /// Tracks the press itself: the action runs when the button is let go of over it, as a button's does, and the table
    /// behind never sees the click, so it selects nothing.
    public override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        var inside = true
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
        }
        if inside { onPress?() }
    }

    // MARK: Pointer

    /// The pointing hand over the whole button, which a click acts on (spec §4.17).
    public var pointerRegions: [QuirePointerRegion] { [.control(bounds, acts: onPress != nil)] }

    public override func resetCursorRects() {
        addPointerRects()
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityLabel() -> String? { title }

    public override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }
}
