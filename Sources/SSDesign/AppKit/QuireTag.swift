import AppKit

/// A tag (spec §5.28): a 16 pt label with a 1 pt `ruleStrong` inset edge, radius 3, the `tag` role in `ink2`,
/// sentence case: “Other”, “Gmail”, “Microsoft 365”, “Demo”. The words carry the meaning; the tag has no fill.
@MainActor
public final class QuireTag: NSView {
    public var text: String {
        didSet { if oldValue != text { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    public init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        setFrameSize(intrinsicContentSize)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireTag is built in code") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        let width = QuireDraw.width(QuireDraw.line(text, .tag, .black))
        return NSSize(width: width + 2 * Quire.Layout.Tag.padX, height: Quire.Layout.Tag.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        QuireDraw.strokeInside(rect, radius: Quire.Layout.Tag.radius, width: Quire.Border.Strong.width, .qRuleStrong)
        let lineHeight = QuireFont.Role.tag.lineHeight
        QuireDraw.draw(QuireDraw.line(text, .tag, .qInk2), x: rect.minX + Quire.Layout.Tag.padX,
                       top: (rect.midY - lineHeight / 2).rounded(), maxWidth: rect.width - 2 * Quire.Layout.Tag.padX,
                       lineHeight: lineHeight)
    }

    @objc private func environmentDidChange(_ note: Notification) {
        needsDisplay = true
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    public override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? text }
}
