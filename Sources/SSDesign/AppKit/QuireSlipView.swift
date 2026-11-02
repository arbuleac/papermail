import AppKit

/// The slip (spec §2, §5.30): the small dark surface feedback arrives on, dark in both appearances. This is the
/// view only; the shell owns presenting it, coalescing and timing.
///
/// Anatomy: 34 pt, radius 8, `slip` with its 1 pt `slipEdge` and `e2`; padding 0 6 0 14 with an action, 0 14 0 14
/// without; 10 pt between parts: the symbol (14 pt `onSlip2`), the message (`bodyMedium` `onSlip`, truncating
/// first), a 1 × 16 `onSlipEdge` divider, and the action with its keycap. A 2 pt `onSlip` contrail drains along
/// the bottom edge over the toast's life, only when there is an action; it freezes while the pointer rests on
/// the slip (`onPointerHover` tells the shell, which pauses its own timer).
@MainActor
public final class QuireSlipView: NSView {
    public var kind: Kind {
        didSet { contentDidChange() }
    }

    /// The symbol; nil uses the kind's default.
    public var symbolName: String? {
        didSet { contentDidChange() }
    }

    public var message: String {
        didSet { contentDidChange() }
    }

    /// The action, when the slip has one.
    public private(set) var actionButton: QuireSlipActionButton?

    /// Called when the pointer starts or stops resting on the slip.
    public var onPointerHover: (@MainActor (Bool) -> Void)?

    private let surface = QuireSurfaceView(frame: .zero)
    private let content = SlipContentView(frame: .zero)
    private let contrail = QuireContrailView(color: .qOnSlip)
    private var hoverArea: NSTrackingArea?

    public init(kind: Kind, message: String, symbolName: String? = nil) {
        self.kind = kind
        self.message = message
        self.symbolName = symbolName
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Quire.Layout.Toast.height))
        clipsToBounds = false
        surface.fillColor = .qSlip
        surface.cornerRadius = Quire.Layout.Toast.radius
        surface.elevation = Quire.Elevation.e2
        surface.edge = { _ in .solid(.qSlipEdge, width: 1) }
        content.wantsLayer = true
        content.layer?.cornerRadius = Quire.Layout.Toast.radius
        content.layer?.masksToBounds = true
        content.owner = self
        contrail.isHidden = true
        addSubview(surface)
        addSubview(content)
        content.addSubview(contrail)
        setFrameSize(intrinsicContentSize)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireSlipView is built in code") }

    public override var isFlipped: Bool { true }

    // MARK: Action and lifetime

    /// Adds (or changes) the action, “Undo” with its keycap “Z”; nil removes it. Sentence case (§4.13).
    @discardableResult
    public func setAction(_ title: String?, keycap: String? = nil, target: AnyObject? = nil, action: Selector? = nil) -> QuireSlipActionButton? {
        guard let title else {
            actionButton?.removeFromSuperview()
            actionButton = nil
            contentDidChange()
            return nil
        }
        let button = actionButton ?? QuireSlipActionButton(title: title)
        button.title = title
        button.keycap = keycap
        button.target = target
        button.action = action
        if actionButton == nil { content.addSubview(button, positioned: .below, relativeTo: contrail) }
        actionButton = button
        contentDidChange()
        return button
    }

    /// Starts the contrail draining over `duration` (the toast's life, `dur.toastLife`). Shown only on slips
    /// with an action.
    public func startLifetime(_ duration: TimeInterval = Quire.Motion.toastLife) {
        contrail.mode = .countdown(duration)
        contrail.isPaused = isPointerInside
        updateContrailVisibility()
    }

    /// Stops and hides the contrail.
    public func stopLifetime() {
        contrail.mode = .determinate(0)
        contrail.isHidden = true
    }

    /// The contrail, for tests and for owners that read its state.
    public var lifetimeContrail: QuireContrailView { contrail }

    private func updateContrailVisibility() {
        if case .countdown = contrail.mode {
            contrail.isHidden = actionButton == nil
        } else {
            contrail.isHidden = true
        }
    }

    // MARK: Geometry

    private var symbol: String { symbolName ?? kind.defaultSymbol }

    private var messageString: NSAttributedString { QuireDraw.line(message, .bodyMedium, .qOnSlip) }

    public override var intrinsicContentSize: NSSize {
        let t = Quire.Layout.Toast.self
        var width = t.padLeft + t.glyph + t.gap + QuireDraw.width(messageString)
        if let actionButton {
            width += t.gap + 1 + t.gap + actionButton.intrinsicContentSize.width + t.padRight
        } else {
            width += t.padRightNoAction
        }
        return NSSize(width: ceil(width), height: t.height)
    }

    fileprivate struct Geometry {
        var symbol: NSRect
        var message: NSRect
        var divider: NSRect?
        var action: NSRect?
    }

    fileprivate func geometry() -> Geometry {
        let t = Quire.Layout.Toast.self
        let height = bounds.height
        let centre = height / 2
        let symbol = NSRect(x: t.padLeft, y: centre - t.glyph / 2, width: t.glyph, height: t.glyph)
        var trailing = bounds.width - (actionButton == nil ? t.padRightNoAction : t.padRight)
        var divider: NSRect?
        var action: NSRect?
        if let actionButton {
            let size = actionButton.intrinsicContentSize
            action = NSRect(x: trailing - size.width, y: (centre - size.height / 2).rounded(), width: size.width, height: size.height)
            trailing -= size.width + t.gap
            divider = NSRect(x: trailing - 1, y: (centre - t.divider / 2).rounded(), width: 1, height: t.divider)
            trailing -= 1 + t.gap
        }
        let lineHeight = QuireFont.Role.bodyMedium.lineHeight
        let messageX = symbol.maxX + t.gap
        let message = NSRect(x: messageX, y: (centre - lineHeight / 2).rounded(), width: max(0, trailing - messageX), height: lineHeight)
        return Geometry(symbol: symbol, message: message, divider: divider, action: action)
    }

    public override func layout() {
        super.layout()
        surface.frame = bounds
        content.frame = bounds
        let g = geometry()
        if let actionButton, let rect = g.action {
            actionButton.frame = actionButton.frame(forVisualRect: rect)
        }
        let line = Quire.Layout.Progress.contrail
        let head = Quire.Layout.Progress.contrailHead
        // The contrail's line lies on the slip's bottom edge, inside the corner clip.
        contrail.frame = NSRect(x: 0, y: bounds.height - line - (head - line) / 2, width: bounds.width, height: head)
    }

    private func contentDidChange() {
        invalidateIntrinsicContentSize()
        updateContrailVisibility()
        needsLayout = true
        content.needsDisplay = true
    }

    // MARK: Hover

    private var isPointerInside = false

    public override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    public override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    public override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    private func setPointerInside(_ inside: Bool) {
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        contrail.isPaused = inside
        onPointerHover?(inside)
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? message }

    // MARK: Content

    /// Draws the symbol, the message and the divider; the action and the contrail are its subviews.
    fileprivate final class SlipContentView: NSView {
        weak var owner: QuireSlipView?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                                   name: QuireEnvironment.didChangeNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("built in code") }

        @objc private func environmentDidChange(_ note: Notification) {
            needsDisplay = true
        }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let owner else { return }
            let g = owner.geometry()
            QuireDraw.symbol(owner.symbol, size: .custom(Quire.Layout.Toast.glyph), color: .qOnSlip2, centredIn: g.symbol)
            QuireDraw.draw(owner.messageString, x: g.message.minX, top: g.message.minY, maxWidth: g.message.width,
                           lineHeight: g.message.height)
            if let divider = g.divider {
                NSColor.qOnSlipEdge.setFill()
                divider.fill()
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func isAccessibilityElement() -> Bool { false }
    }
}
