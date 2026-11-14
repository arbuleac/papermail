import AppKit
import SSDesign

/// One tile on the rail (spec §5.2): a folder (one of the six views), All Inboxes, an account, or the pending
/// tile of a sign-in that is waiting for the browser.
///
/// The view spans the rail's full width so it can draw the selection's margin rule at x = 0 and the badge's
/// overhang; clicks count only in the 44 pt hit square around the 38 pt tile. Everything is drawn in
/// `draw(_:)` from tokens, so appearance, Increase Contrast and Graphite changes need only a redraw.
@MainActor
final class AccountStripButton: QuireControl {
    enum Content: Equatable {
        /// A view (Inbox, Starred…): drawn as All Inboxes is, with the view's symbol, but its selection is the
        /// raised tile alone, so it never reads as the account selection's margin rule.
        case folder(symbol: String)
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

    /// What the unread badge reads, nil while the tile shows none: the words the Dock badge uses for the same
    /// count (§5.28), so the Inbox tile, All Inboxes, the accounts and the Dock agree. Sign-in and first sync
    /// replace it; the pending tile never has one.
    var unreadBadgeText: String? {
        guard status == .normal, content != .pending else { return nil }
        return QuireBadge.unreadText(unreadCount)
    }

    /// Called with -1 or +1 when ↑ or ↓ is pressed while the tile has focus.
    var onArrow: ((Int) -> Void)?

    /// Rows dragged from the list are over the tile's hit square and it takes them (§5.2): the tile draws its
    /// pressed wash. The rail, not the tile, is the drag destination and sets this. The tile never takes focus
    /// for it, and hovering does not switch the view (no spring-loading).
    var isDropTarget = false { didSet { if oldValue != isDropTarget { needsDisplay = true } } }

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

    /// Frames are set by hand; a new size lays the contents out again.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
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

    /// Only the selected tile of each group is a Tab stop: Tab enters the folders once and the accounts once, and
    /// ↑/↓ move within the group (§5.2).
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
        // A drop target reads as the tile does under a click: what lands on it is about to act.
        let state: QuireDisplayState = content == .pending ? .rest : isDropTarget ? .pressed : interactionState
        let wash = Quire.Radius.xl

        switch content {
        case .unified, .folder:
            if state == .pressed {
                QuireDraw.fill(washRect, radius: wash, .qPressed)
            } else if state == .hover {
                QuireDraw.fill(washRect, radius: wash, .qHover)
            }
            if isSelected { drawRaisedTile(tile) }
            let glyph: NSColor = isSelected || state != .rest ? .qInk : .qInk2
            if case .folder(let symbol) = content {
                QuireSymbol.draw(symbol, size: .custom(Quire.Layout.Rail.folderGlyph), color: glyph, centredIn: tile)
            } else {
                QuireSymbol.draw(Quire.Icon.unifiedInbox, size: .custom(Quire.Layout.Rail.unifiedGlyph), color: glyph, centredIn: tile)
            }
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

        if isSelected, drawsMarginRule {
            let height = Quire.Layout.Rail.marginRuleHeight
            let rtl = userInterfaceLayoutDirection == .rightToLeft
            let width = Quire.Border.MarginRule.width
            let rule = NSRect(x: rtl ? bounds.maxX - width : bounds.minX, y: (tile.midY - height / 2).rounded(), width: width, height: height)
            QuireMarginRule.draw(in: rule, isWindowKey: isWindowKey, rightToLeft: rtl)
        }

        // The ring goes under the badge, whose cut-out keeps the count legible over it.
        if showsFocusRing {
            let gap = Quire.Border.FocusRing.gapAroundSheets
            if isSquircle {
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
            if unreadBadgeText != nil {
                let kind = QuireBadge.Kind.unread(unreadCount)
                QuireBadge.draw(kind, in: badgeRect(for: kind), cutoutColor: .qSpine)
            }
        }
    }

    /// The scope's selection is the margin rule (All Inboxes and the accounts); a folder's is the raised tile alone.
    private var drawsMarginRule: Bool {
        switch content {
        case .unified, .account: return true
        case .folder, .pending: return false
        }
    }

    /// Folders and All Inboxes are near-squircles; accounts and the pending tile are round.
    private var isSquircle: Bool {
        switch content {
        case .unified, .folder: return true
        case .account, .pending: return false
        }
    }

    /// The selected folder or All Inboxes tile: `raised` with a 1 pt `rule` edge outside it and the `e1` shadow.
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
        // The real count, as the badge view says it, never the cap.
        case .normal: return unreadBadgeText == nil ? nil : QuireBadge.unreadAccessibilityText(unreadCount)
        }
    }
}

extension AccountStripButton: ShellKeyHandling {
    /// ↑/↓ move within the rail and ↩ chooses, so the list's own ↑/↓/↩ must wait (§5.2).
    func handlesKey(_ event: NSEvent) -> Bool {
        guard content != .pending, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.specialKey {
        case .upArrow?, .downArrow?, .carriageReturn?, .enter?: return true
        default: return false
        }
    }
}
