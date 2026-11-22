import AppKit

/// A semantic banner (spec §5.16, §5.38): 32 pt, radius 6, padding 0 6 0 10, gap 8, a 14 pt glyph in the
/// kind's colour, the message in `snippet` `ink`, an optional trailing link button and an optional dismiss
/// button (`xmark` 9 pt `ink2`, 24 pt hit).
///
/// Single-line banners truncate the message. With `allowsMultipleLines` the message wraps instead (Settings
/// notices, sign-in errors): the banner grows from 32 pt with 8 pt top and bottom padding, the glyph aligns
/// to the first line, and the link sits after the text on its last line (on a line of its own when it does
/// not fit there). `height(forWidth:)` gives the height for a width; the intrinsic height follows the
/// current width.
@MainActor
public final class QuireBannerView: NSView {
    public var kind: Kind {
        didSet { needsDisplay = true }
    }

    public var message: String {
        didSet { contentDidChange() }
    }

    /// The glyph; nil uses the kind's default (`info.circle`, `checkmark.circle.fill`, the triangle).
    public var symbolName: String? {
        didSet { needsDisplay = true }
    }

    /// The glyph's colour; nil uses the kind's. A neutral banner reporting a partial failure (“2 images
    /// couldn't load”) keeps its `fill` wash and draws the triangle in `warning` (§5.16).
    public var glyphColor: NSColor? {
        didSet { needsDisplay = true }
    }

    /// The colour the glyph draws in now.
    public var resolvedGlyphColor: NSColor { glyphColor ?? kind.glyphColor }

    public var allowsMultipleLines = false {
        didSet { contentDidChange() }
    }

    /// The link button, when the banner has an action. Set its target and action.
    public private(set) var actionButton: QuireButton?
    /// The dismiss button, when shown. Set its target and action.
    public private(set) var dismissButton: QuireIconButton?

    /// Work is running: a 12 pt spinner replaces the glyph (“Loading 3 images…”).
    public var isLoading = false {
        didSet { if oldValue != isLoading { loadingDidChange() } }
    }

    /// Internal so a gallery can show a revealed spinner without waiting out its delay.
    var spinner: QuireSpinnerView?

    public init(kind: Kind, message: String, symbolName: String? = nil) {
        self.kind = kind
        self.message = message
        self.symbolName = symbolName
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Quire.Layout.Banner.height))
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireBannerView is built in code") }

    public override var isFlipped: Bool { true }

    // MARK: Action and dismiss

    /// Adds (or retitles) the trailing link button; nil removes it. Sentence case: banners are content (§4.13).
    @discardableResult
    public func setAction(_ title: String?, target: AnyObject? = nil, action: Selector? = nil) -> QuireButton? {
        guard let title else {
            actionButton?.removeFromSuperview()
            actionButton = nil
            contentDidChange()
            return nil
        }
        let button = actionButton ?? QuireButton(title: title, variant: .link, size: .small)
        button.title = title
        button.target = target
        button.action = action
        if actionButton == nil { addSubview(button) }
        actionButton = button
        contentDidChange()
        return button
    }

    /// Shows or hides the dismiss button (tooltip “Don't Show Again” on the Original colors notice).
    @discardableResult
    public func setDismissible(_ dismissible: Bool, target: AnyObject? = nil, action: Selector? = nil) -> QuireIconButton? {
        guard dismissible else {
            dismissButton?.removeFromSuperview()
            dismissButton = nil
            contentDidChange()
            return nil
        }
        let button = dismissButton ?? QuireIconButton(symbolName: Quire.Icon.dismiss, size: .medium, accessibilityLabel: "Dismiss")
        button.symbolSize = .custom(Quire.Layout.Banner.dismissGlyph)
        button.target = target
        button.action = action
        if dismissButton == nil { addSubview(button) }
        dismissButton = button
        contentDidChange()
        return button
    }

    // MARK: Layout

    private struct Geometry {
        var height: CGFloat
        var textRect: NSRect
        var glyphCenterY: CGFloat
        var actionVisual: NSRect?
        var dismissVisual: NSRect?
    }

    private var role: QuireFont.Role { .snippet }

    private func string(wrapping: Bool) -> NSAttributedString {
        var attributes = QuireFont.attributes(role, color: .qInk)
        if wrapping {
            let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            attributes[.paragraphStyle] = style
        }
        return NSAttributedString(string: message, attributes: attributes)
    }

    private func geometry(width: CGFloat) -> Geometry {
        let b = Quire.Layout.Banner.self
        let lineHeight = role.lineHeight
        let textX = b.padLeft + b.glyph + b.gap
        var trailing = width - b.padRight
        var dismissVisual: NSRect?
        if dismissButton != nil {
            let side = QuireIconButton.Size.medium.side
            dismissVisual = NSRect(x: trailing - side, y: 0, width: side, height: side)
            trailing -= side + b.gap
        }
        let actionSize = actionButton?.intrinsicContentSize

        guard allowsMultipleLines else {
            var actionVisual: NSRect?
            if let actionSize {
                actionVisual = NSRect(x: trailing - actionSize.width, y: 0, width: actionSize.width, height: actionSize.height)
                trailing -= actionSize.width + b.gap
            }
            let height = b.height
            let centre = height / 2
            func centred(_ r: NSRect?) -> NSRect? { r.map { NSRect(x: $0.minX, y: (centre - $0.height / 2).rounded(), width: $0.width, height: $0.height) } }
            return Geometry(height: height,
                            textRect: NSRect(x: textX, y: (centre - lineHeight / 2).rounded(), width: max(0, trailing - textX), height: lineHeight),
                            glyphCenterY: centre, actionVisual: centred(actionVisual), dismissVisual: centred(dismissVisual))
        }

        // Wrapped: lay the text out in the room left of the dismiss button, then put the link after its last
        // line, or on a line of its own when it does not fit there.
        let textWidth = max(1, trailing - textX)
        let storage = NSTextStorage(attributedString: string(wrapping: true))
        let manager = NSLayoutManager()
        QuireFont.configure(manager)
        let container = NSTextContainer(size: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var lines: [NSRect] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, _ in
            lines.append(used)
        }
        if lines.isEmpty { lines = [NSRect(x: 0, y: 0, width: 0, height: lineHeight)] }
        var textHeight = CGFloat(lines.count) * lineHeight
        var actionVisual: NSRect?
        if let actionSize {
            let last = lines[lines.count - 1]
            let lastTop = CGFloat(lines.count - 1) * lineHeight
            if last.width + b.gap + actionSize.width <= textWidth {
                actionVisual = NSRect(x: textX + ceil(last.width) + b.gap, y: b.padY + lastTop + (lineHeight - actionSize.height) / 2,
                                      width: actionSize.width, height: actionSize.height)
            } else {
                // On a line of its own the link's words start on the text column; its 4 pt padding, part of
                // its hit area, hangs into the margin instead of indenting it.
                let inset = actionButton?.variant == .link ? Quire.Layout.Button.linkPadX : 0
                actionVisual = NSRect(x: textX - inset, y: b.padY + textHeight + (lineHeight - actionSize.height) / 2,
                                      width: actionSize.width, height: actionSize.height)
                textHeight += lineHeight
            }
        }
        let height = max(b.height, b.padY + textHeight + b.padY)
        if let d = dismissVisual {
            dismissVisual = NSRect(x: d.minX, y: (b.padY + lineHeight / 2 - d.height / 2).rounded(), width: d.width, height: d.height)
        }
        return Geometry(height: height,
                        textRect: NSRect(x: textX, y: b.padY, width: textWidth, height: CGFloat(lines.count) * lineHeight),
                        glyphCenterY: b.padY + lineHeight / 2, actionVisual: actionVisual, dismissVisual: dismissVisual)
    }

    /// The banner's height at `width`.
    public func height(forWidth width: CGFloat) -> CGFloat {
        geometry(width: width).height
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 400))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, allowsMultipleLines { invalidateIntrinsicContentSize() }
    }

    public override func layout() {
        super.layout()
        let g = geometry(width: bounds.width)
        if let button = actionButton, let visual = g.actionVisual {
            button.frame = button.frame(forVisualRect: visual)
        }
        if let button = dismissButton, let visual = g.dismissVisual {
            button.frame = button.frame(forVisualRect: visual)
        }
        if let spinner {
            let d = QuireSpinnerView.Size.small.diameter
            let centreX = Quire.Layout.Banner.padLeft + Quire.Layout.Banner.glyph / 2
            spinner.frame = NSRect(x: (centreX - d / 2).rounded(), y: (g.glyphCenterY - d / 2).rounded(), width: d, height: d)
        }
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let b = Quire.Layout.Banner.self
        QuireDraw.fill(bounds, radius: b.radius, kind.wash)
        let g = geometry(width: bounds.width)
        if !isLoading {
            let glyphRect = NSRect(x: b.padLeft, y: g.glyphCenterY - b.glyph / 2, width: b.glyph, height: b.glyph)
            QuireDraw.symbol(symbolName ?? kind.defaultSymbol, size: .custom(b.glyph), color: resolvedGlyphColor, centredIn: glyphRect)
        }
        if allowsMultipleLines {
            string(wrapping: true).draw(with: g.textRect, options: [.usesLineFragmentOrigin], context: nil)
        } else {
            QuireDraw.draw(string(wrapping: false), x: g.textRect.minX, top: g.textRect.minY, maxWidth: g.textRect.width,
                           lineHeight: g.textRect.height)
        }
    }

    private func contentDidChange() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private func loadingDidChange() {
        if isLoading {
            let spinner = QuireSpinnerView(size: .small, color: .qInk3)
            addSubview(spinner)
            self.spinner = spinner
            spinner.startAnimation()
        } else {
            spinner?.stopAnimation()
            spinner?.removeFromSuperview()
            spinner = nil
        }
        needsLayout = true
        needsDisplay = true
    }

    @objc private func environmentDidChange(_ note: Notification) {
        needsDisplay = true
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? message }
}
