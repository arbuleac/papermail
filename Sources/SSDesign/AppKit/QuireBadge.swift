import AppKit

/// Count, dot and attention badges (spec §5.28). Numerals are the `badge` role: SF Pro Rounded 11 Semibold
/// with tabular digits, so a changing count never jitters. Badges never animate when counts change.
///
/// Where a badge overlaps a tile it draws a 2 pt cut-out ring in the surface colour (`cutoutColor`, `spine`
/// on the rail). The frame keeps room for that ring on every side (as `alignmentRectInsets`), so turning the
/// cut-out on or off never moves the badge.
@MainActor
public final class QuireBadge: NSView {
    public var kind: Kind {
        didSet { if oldValue != kind { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    /// The surface the badge cuts into; nil draws no cut-out.
    public var cutoutColor: NSColor? {
        didSet { needsDisplay = true }
    }

    public init(_ kind: Kind, cutoutColor: NSColor? = nil) {
        self.kind = kind
        self.cutoutColor = cutoutColor
        super.init(frame: .zero)
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireBadge is built in code") }

    public override var isFlipped: Bool { true }

    public override var alignmentRectInsets: NSEdgeInsets {
        let c = Quire.Layout.Badge.cutout
        return NSEdgeInsets(top: c, left: c, bottom: c, right: c)
    }

    // MARK: Text

    /// The text a count badge shows. Unread counts cap at “99+” (`badge.cap`); message counts are exact, in the
    /// locale's grouping (§4.13).
    public static func text(for kind: Kind) -> String? {
        switch kind {
        case .unread(let count):
            let cap = Int(Quire.Layout.Badge.cap)
            return count > cap ? "\(cap)+" : QuireDraw.grouped(max(0, count))
        case .messageCount(let count):
            return QuireDraw.grouped(max(0, count))
        case .dot, .attention:
            return nil
        }
    }

    private static func label(for kind: Kind) -> NSAttributedString? {
        guard let text = text(for: kind) else { return nil }
        let color: NSColor
        if case .unread = kind { color = .qOnAccent } else { color = .qInk2 }
        return QuireDraw.line(text, .badge, color)
    }

    /// The badge's visual size, without the cut-out ring: what a row lays out (§8.2).
    public static func size(for kind: Kind) -> NSSize {
        let b = Quire.Layout.Badge.self
        switch kind {
        case .dot: return NSSize(width: b.dot, height: b.dot)
        case .attention: return NSSize(width: b.attention, height: b.attention)
        case .unread, .messageCount:
            let minWidth = kind.isMessageCount ? b.rowMinWidth : b.minWidth
            let textWidth = label(for: kind).map { QuireDraw.width($0) } ?? 0
            return NSSize(width: max(minWidth, textWidth + 2 * b.padX), height: b.height)
        }
    }

    /// Draws a badge filling `rect` (its visual rect) in the current context, with the 2 pt cut-out ring in
    /// `cutoutColor` outside it when given. Rows call this from their own `draw(_:)`; the view does too.
    public static func draw(_ kind: Kind, in rect: NSRect, cutoutColor: NSColor? = nil) {
        let radius = rect.height / 2
        if let cutoutColor {
            let c = Quire.Layout.Badge.cutout
            QuireDraw.fill(rect.insetBy(dx: -c, dy: -c), radius: radius + c, cutoutColor)
        }
        switch kind {
        case .dot:
            QuireDraw.fillCircle(rect, .qAccent)
        case .attention:
            QuireDraw.fillCircle(rect, .qDangerFill)
            QuireDraw.symbol(Quire.Icon.attention, size: .custom(Quire.Layout.Badge.attentionGlyph, weight: .semibold),
                             color: .qOnDanger, centredIn: rect)
        case .unread, .messageCount:
            QuireDraw.fill(rect, radius: radius, kind.isMessageCount ? .qFill : .qAccentFill)
            guard let label = label(for: kind) else { return }
            let lineHeight = QuireFont.Role.badge.lineHeight
            let width = QuireDraw.width(label)
            QuireDraw.draw(label, x: (rect.midX - width / 2).rounded(), top: (rect.midY - lineHeight / 2).rounded(),
                           maxWidth: width + 1, lineHeight: lineHeight)
        }
    }

    public override var intrinsicContentSize: NSSize { QuireBadge.size(for: kind) }

    private var badgeRect: NSRect {
        let i = alignmentRectInsets
        return NSRect(x: bounds.minX + i.left, y: bounds.minY + i.top,
                      width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        QuireBadge.draw(kind, in: badgeRect, cutoutColor: cutoutColor)
    }

    @objc private func environmentDidChange(_ note: Notification) {
        needsDisplay = true
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    public override func accessibilityLabel() -> String? {
        if let explicit = super.accessibilityLabel() { return explicit }
        switch kind {
        case .unread(let count): return "\(QuireDraw.grouped(count)) unread"
        case .messageCount(let count): return "\(QuireDraw.grouped(count)) messages"
        case .dot: return "New mail"
        case .attention: return "Sign in required"
        }
    }
}
