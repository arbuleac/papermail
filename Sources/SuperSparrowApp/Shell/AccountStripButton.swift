import AppKit

/// One round button in the account strip: initials in the account's color (or the stacked-envelope glyph for
/// the unified inbox), a ring when selected, and an unread badge.
@MainActor
final class AccountStripButton: NSView {
    enum Content {
        case unified
        case account(initials: String, color: NSColor)
        case symbol(String, String)
    }

    static let diameter: CGFloat = 36
    static let size = NSSize(width: 48, height: 48)

    var content: Content { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var badgeCount = 0 { didSet { if badgeCount != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?

    private var isPressed = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(content: Content) {
        self.content = content
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let d = Self.diameter
        let circle = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)

        if isSelected {
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -3.5, dy: -3.5))
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }

        let path = NSBezierPath(ovalIn: circle)
        switch content {
        case .unified, .symbol:
            (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.quaternaryLabelColor.withAlphaComponent(isHovered ? 0.5 : 0.25)).setFill()
            path.fill()
            let (name, label): (String, String)
            if case .symbol(let symbol, let description) = content {
                (name, label) = (symbol, description)
            } else {
                (name, label) = ("tray.full", "All inboxes")
            }
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration) {
                let tint: NSColor = isSelected ? .controlAccentColor : .secondaryLabelColor
                let tinted = image.tinted(tint)
                let size = tinted.size
                tinted.draw(in: NSRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2, width: size.width, height: size.height))
            }
        case .account(let initials, let color):
            color.withAlphaComponent(isHovered || isSelected ? 1 : 0.88).setFill()
            path.fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let text = initials as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attributes)
        }

        if isPressed {
            NSColor.black.withAlphaComponent(0.15).setFill()
            path.fill()
        }

        if badgeCount > 0 {
            drawBadge(near: circle)
        }
    }

    private func drawBadge(near circle: NSRect) {
        let text = (badgeCount > 99 ? "99+" : "\(badgeCount)") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let height: CGFloat = 16
        let width = max(height, size.width + 8)
        let rect = NSRect(x: min(bounds.maxX - width, circle.maxX - width / 2 - 2), y: circle.minY - 4, width: width, height: height)
        let capsule = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        NSColor.windowBackgroundColor.setStroke()
        capsule.lineWidth = 2
        capsule.stroke()
        NSColor.systemRed.setFill()
        capsule.fill()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}

extension NSImage {
    /// Template symbols drawn directly ignore `contentTintColor`, so tint them into a new image.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}
