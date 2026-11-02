import AppKit
import SSDesign

/// The masthead (spec §5.3): the view's name in `masthead` (New York 20/24), then `chevron.down` 9 pt Semibold
/// in `ink2` 6 pt after it. The control's visual rect is the hit area, text and chevron with 6 pt of padding,
/// which takes the `hover` and `pressed` washes (radius `r.md`) and the focus ring. Clicking it pops the title
/// menu. The text never truncates; the address after the cluster does.
@MainActor
final class MastheadButton: QuireControl {
    var title: String = "Inbox" {
        didSet { if oldValue != title { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityValue(title) } }
    }

    /// Forced while the title menu is open, so the masthead reads as pressed.
    var isMenuOpen = false { didSet { if oldValue != isMenuOpen { needsDisplay = true } } }

    private static let chevron = QuireSymbolSize.custom(Quire.Layout.ListHeader.chevron, weight: .semibold)

    private var titleString: NSAttributedString { QuireFont.attributedString(title, role: .masthead, color: .qInk) }

    private var titleWidth: CGFloat { ceil(titleString.size().width) }

    private var chevronWidth: CGFloat {
        QuireSymbol.cachedImage(Quire.Icon.titleMenu, size: Self.chevron)?.size.width ?? Quire.Layout.ListHeader.chevron
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Mailbox")
        setAccessibilityValue(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var intrinsicContentSize: NSSize {
        let pad = Quire.Layout.ListHeader.mastheadHitPad
        let width = pad + titleWidth + Quire.Layout.ListHeader.chevronGap + chevronWidth + pad
        return NSSize(width: ceil(width), height: QuireFont.Role.masthead.lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let face = faceRect
        let radius = Quire.Radius.md
        let state = isMenuOpen ? QuireDisplayState.pressed : interactionState
        if state == .pressed {
            QuireDraw.fill(face, radius: radius, .qPressed)
        } else if state == .hover {
            QuireDraw.fill(face, radius: radius, .qHover)
        }
        let pad = Quire.Layout.ListHeader.mastheadHitPad
        let lineHeight = QuireFont.Role.masthead.lineHeight
        let text = titleString
        let width = titleWidth
        text.draw(with: NSRect(x: face.minX + pad, y: (face.midY - lineHeight / 2).rounded(), width: width + 1, height: lineHeight),
                  options: QuireFont.drawingOptions, context: nil)
        let chevronX = face.minX + pad + width + Quire.Layout.ListHeader.chevronGap
        QuireSymbol.draw(Quire.Icon.titleMenu, size: Self.chevron, color: .qInk2,
                         centredIn: NSRect(x: chevronX, y: face.minY, width: chevronWidth, height: face.height))
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: radius)
        }
    }

    override func keyDown(with event: NSEvent) {
        if handlesKey(event) { activate() } else { super.keyDown(with: event) }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .menuButton }
}

/// The demo marker in the masthead (spec §5.43): a “Demo” tag (16 pt, `tag` role, `ink2`, 1 pt `ruleStrong`
/// edge, radius `r.xs`) with a small chevron, which is a pull-down button: hover takes the `hover` wash and
/// `ink` text, pressed or menu open the `pressed` wash, focus the ring.
@MainActor
final class DemoTagButton: QuireControl {
    var isMenuOpen = false { didSet { if oldValue != isMenuOpen { needsDisplay = true } } }

    private static let chevron = QuireSymbolSize.custom(7, weight: .semibold)
    private static let chevronGap: CGFloat = 3

    private var chevronWidth: CGFloat {
        QuireSymbol.cachedImage(Quire.Icon.titleMenu, size: Self.chevron)?.size.width ?? 7
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "These mailboxes are made up and live only on this Mac."
        setAccessibilityLabel("Demo")
        setAccessibilityHelp("These mailboxes are made up and live only on this Mac.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    private func label(_ color: NSColor) -> NSAttributedString { QuireFont.attributedString("Demo", role: .tag, color: color) }

    override var intrinsicContentSize: NSSize {
        let width = 2 * Quire.Layout.Tag.padX + ceil(label(.black).size().width) + Self.chevronGap + chevronWidth
        return NSSize(width: ceil(width), height: Quire.Layout.Tag.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let face = faceRect
        let radius = Quire.Layout.Tag.radius
        let state = isMenuOpen ? QuireDisplayState.pressed : interactionState
        if state == .pressed {
            QuireDraw.fill(face, radius: radius, .qPressed)
        } else if state == .hover {
            QuireDraw.fill(face, radius: radius, .qHover)
        }
        QuireDraw.strokeInside(face, radius: radius, width: Quire.Border.Strong.width, .qRuleStrong)
        let color: NSColor = state == .rest ? .qInk2 : .qInk
        let text = label(color)
        let width = ceil(text.size().width)
        let lineHeight = QuireFont.Role.tag.lineHeight
        text.draw(with: NSRect(x: face.minX + Quire.Layout.Tag.padX, y: (face.midY - lineHeight / 2).rounded(), width: width + 1,
                               height: lineHeight), options: QuireFont.drawingOptions, context: nil)
        let chevronX = face.minX + Quire.Layout.Tag.padX + width + Self.chevronGap
        QuireSymbol.draw(Quire.Icon.titleMenu, size: Self.chevron, color: color,
                         centredIn: NSRect(x: chevronX, y: face.minY, width: chevronWidth, height: face.height))
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: radius)
        }
    }

    override func keyDown(with event: NSEvent) {
        if handlesKey(event) { activate() } else { super.keyDown(with: event) }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .menuButton }
}

/// ↩ opens the focused menu button's menu, as Space does; otherwise the router would open the selected
/// conversation from behind the masthead.
extension MastheadButton: ShellKeyHandling {
    func handlesKey(_ event: NSEvent) -> Bool { isEnabled && event.isPlainReturn }
}

extension DemoTagButton: ShellKeyHandling {
    func handlesKey(_ event: NSEvent) -> Bool { isEnabled && event.isPlainReturn }
}
