import AppKit
import SSDesign

/// One tile on the account rail (spec §5.2): All Inboxes, an account, or the pending tile of a sign-in that is
/// waiting for the browser.
///
/// The view spans the rail's full width so it can draw the selection's margin rule at x = 0 and the badge's
/// overhang; clicks count only in the 44 pt hit square around the 38 pt tile. Everything is drawn in
/// `draw(_:)` from tokens, so appearance, Increase Contrast and Graphite changes need only a redraw.
@MainActor
final class AccountStripButton: QuireControl {
    enum Content: Equatable {
        case unified
        case account(monogram: String, slot: Int)
        /// A sign-in waiting for the browser (§5.44): a dashed placeholder, not selectable.
        case pending
    }

    /// What replaces the unread badge.
    enum Status: Equatable {
        case normal
        /// The account needs signing in again: the attention badge, also while a reconnect waits (§5.44).
        case needsSignIn
        /// The account's first download is running: a 12 pt spinner.
        case firstSync
    }

    /// Room above and below the tile for the badge's overhang and the focus ring.
    static let verticalMargin: CGFloat = 8
    static var height: CGFloat { Quire.Layout.Rail.tile + 2 * verticalMargin }

    var content: Content { didSet { if oldValue != content { contentDidChange() } } }
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    var unreadCount = 0 { didSet { if oldValue != unreadCount { needsDisplay = true } } }
    var status: Status = .normal { didSet { if oldValue != status { contentDidChange() } } }

    /// Called with -1 or +1 when ↑ or ↓ is pressed while the tile has focus.
    var onArrow: ((Int) -> Void)?

    private var spinner: QuireSpinnerView?

    init(content: Content) {
        self.content = content
        super.init(frame: NSRect(x: 0, y: 0, width: Quire.Layout.Rail.width, height: Self.height))
        contentDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    // MARK: Geometry

    /// The frame is laid out by hand; the focus ring and badge live in the vertical margin.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    /// The 38 pt tile, centred in the rail.
    var tileRect: NSRect {
        let side = Quire.Layout.Rail.tile
        return NSRect(x: ((bounds.width - side) / 2).rounded(), y: Self.verticalMargin, width: side, height: side)
    }

    /// The 30 pt face inside an account tile's 2 pt gap and 2 pt ring.
    private var accountFace: NSRect {
        let face = Quire.Layout.Rail.face
        let tile = tileRect
        return NSRect(x: tile.midX - face / 2, y: tile.midY - face / 2, width: face, height: face)
    }

    override var faceRect: NSRect { tileRect }

    /// The 44 pt hit square (§4.14: rail tiles 44 pt).
    override var hitRect: NSRect {
        let grow = (Quire.Layout.Rail.tileHit - Quire.Layout.Rail.tile) / 2
        return tileRect.insetBy(dx: -grow, dy: -grow)
    }

    private var washRect: NSRect { hitRect }

    /// The unread badge's rect: top −5, trailing −8 relative to the tile.
    private func badgeRect(for kind: QuireBadge.Kind) -> NSRect {
        let size = QuireBadge.size(for: kind)
        let tile = tileRect
        return NSRect(x: tile.maxX - Quire.Layout.Rail.badgeTrailing - size.width, y: tile.minY + Quire.Layout.Rail.badgeTop,
                      width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        guard let spinner else { return }
        let tile = tileRect
        if content == .pending {
            let d = QuireSpinnerView.Size.medium.diameter
            spinner.frame = NSRect(x: (tile.midX - d / 2).rounded(), y: (tile.midY - d / 2).rounded(), width: d, height: d)
        } else {
            // The first-sync spinner sits where the badge would: 12 pt, top −4, trailing −6 (the specimen's rail).
            let d = QuireSpinnerView.Size.small.diameter
            spinner.frame = NSRect(x: tile.maxX + 6 - d, y: tile.minY - 4, width: d, height: d)
        }
    }

    // MARK: State

    private func contentDidChange() {
        let wantsSpinner = content == .pending || status == .firstSync
        if wantsSpinner, spinner == nil {
            let spinner = QuireSpinnerView(size: content == .pending ? .medium : .small, color: .qInk3)
            addSubview(spinner)
            self.spinner = spinner
            spinner.startAnimation()
        } else if !wantsSpinner, let spinner {
            spinner.stopAnimation()
            spinner.removeFromSuperview()
            self.spinner = nil
        }
        spinner?.size = content == .pending ? .medium : .small
        needsLayout = true
        needsDisplay = true
    }

    /// Only the selected tile is a Tab stop: Tab enters the rail once and ↑/↓ move within it (§5.2).
    override var canBecomeKeyView: Bool {
        isSelected && content != .pending && super.canBecomeKeyView
    }

    override var acceptsFirstResponder: Bool {
        content != .pending && super.acceptsFirstResponder
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow?: onArrow?(-1)
        case .downArrow?: onArrow?(1)
        case .carriageReturn?, .enter?: activate()
        default: super.keyDown(with: event)
        }
    }

    override func activate() {
        guard content != .pending else { return }
        super.activate()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let tile = tileRect
        let state = content == .pending ? QuireDisplayState.rest : interactionState
        let wash = Quire.Radius.xl

        switch content {
        case .unified:
            if state == .pressed {
                QuireDraw.fill(washRect, radius: wash, .qPressed)
            } else if state == .hover {
                QuireDraw.fill(washRect, radius: wash, .qHover)
            }
            if isSelected { drawRaisedTile(tile) }
            let glyph: NSColor = isSelected || state != .rest ? .qInk : .qInk2
            QuireSymbol.draw(Quire.Icon.unifiedInbox, size: .custom(Quire.Layout.Rail.unifiedGlyph), color: glyph, centredIn: tile)
        case .account(let monogram, let slot):
            // The wash sits under the ring (`spine + hover` is an asserted ring surface); a press darkens only
            // the face, so every account ink keeps 3:1 against what is beside it.
            if state != .rest { QuireDraw.fill(washRect, radius: wash, .qHover) }
            QuireAvatarRenderer.drawAccountFace(monogram: monogram, slot: slot, in: accountFace)
            if state == .pressed { QuireDraw.fillCircle(accountFace, .qPressed) }
            QuireAvatarRenderer.drawRing(around: accountFace, accountSlot: slot)
        case .pending:
            QuireDraw.fillCircle(accountFace, .qFill)
            let ring = NSBezierPath(ovalIn: tile.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.setLineDash([3, 2], count: 2, phase: 0)
            NSColor.qRuleStrong.setStroke()
            ring.stroke()
        }

        if isSelected, content != .pending {
            let height = Quire.Layout.Rail.marginRuleHeight
            let rtl = userInterfaceLayoutDirection == .rightToLeft
            let width = Quire.Border.MarginRule.width
            let rule = NSRect(x: rtl ? bounds.maxX - width : bounds.minX, y: (tile.midY - height / 2).rounded(), width: width, height: height)
            QuireMarginRule.draw(in: rule, isWindowKey: isWindowKey, rightToLeft: rtl)
        }

        // The ring goes under the badge, whose cut-out keeps the count legible over it.
        if showsFocusRing {
            let gap = Quire.Border.FocusRing.gapAroundSheets
            if content == .unified {
                QuireFocusRing.draw(around: tile, cornerRadius: Quire.Layout.Rail.tileRadius, gap: gap)
            } else {
                QuireFocusRing.draw(around: tile, cornerRadius: tile.width / 2, gap: gap)
            }
        }
        switch status {
        case .needsSignIn:
            QuireBadge.draw(.attention, in: badgeRect(for: .attention), cutoutColor: .qSpine)
        case .firstSync:
            break
        case .normal:
            if unreadCount > 0, content != .pending {
                let kind = QuireBadge.Kind.unread(unreadCount)
                QuireBadge.draw(kind, in: badgeRect(for: kind), cutoutColor: .qSpine)
            }
        }
    }

    /// The selected All Inboxes tile: `raised` with a 1 pt `rule` edge outside it and the `e1` shadow.
    private func drawRaisedTile(_ tile: NSRect) {
        let radius = Quire.Layout.Rail.tileRadius
        let mode = QuireMode(NSAppearance.currentDrawing())
        NSGraphicsContext.saveGraphicsState()
        for layer in Quire.Elevation.e1.layers(for: mode) {
            let shadow = NSShadow()
            shadow.shadowColor = layer.color
            shadow.shadowBlurRadius = layer.blur
            // Shadow offsets live in the base space, where y grows upward.
            shadow.shadowOffset = NSSize(width: layer.x, height: -layer.y)
            shadow.set()
            QuireDraw.fill(tile, radius: radius, .qRaised)
        }
        NSGraphicsContext.restoreGraphicsState()
        QuireDraw.fill(tile.insetBy(dx: -1, dy: -1), radius: radius + 1, .qRule)
        QuireDraw.fill(tile, radius: radius, .qRaised)
    }

    // MARK: Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { content == .pending ? .staticText : .radioButton }

    override func accessibilityValue() -> Any? {
        content == .pending ? nil : NSNumber(value: isSelected)
    }

    override func accessibilityHelp() -> String? {
        switch status {
        case .needsSignIn: return "Sign in required"
        case .firstSync: return "Downloading mail"
        case .normal: return unreadCount > 0 ? "\(unreadCount) unread" : nil
        }
    }
}
