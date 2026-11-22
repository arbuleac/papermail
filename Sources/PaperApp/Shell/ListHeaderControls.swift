import AppKit
import PaperDesign

/// The masthead (spec §5.3): the view's name in `masthead` (New York 20/24, `mastheadSans` under the SF Pro
/// font). While the rail shows it is a plain title: the folders are in the rail, so it takes no clicks (a click
/// drags the window like the rest of the title-bar zone), no hover and no focus, and VoiceOver reads it as a
/// heading. In minimal mode it is the title menu's button: `chevron.down` 9 pt Semibold in `ink2` 6 pt after the
/// text, a visual rect of text and chevron with 6 pt of padding that takes the `hover` and `pressed` washes
/// (radius `r.md`) and the focus ring. The text never truncates; the address after the cluster does.
@MainActor
final class MastheadButton: QuireControl {
    var title: String = "Inbox" {
        didSet { if oldValue != title { invalidateIntrinsicContentSize(); needsDisplay = true; titleDidChange() } }
    }

    /// Minimal mode: the masthead pops the title menu. Otherwise it is a plain title.
    var isMenu = false {
        didSet {
            guard oldValue != isMenu else { return }
            if !isMenu, window?.firstResponder === self { window?.makeFirstResponder(nil) }
            invalidateIntrinsicContentSize()
            titleDidChange()
            needsDisplay = true
            pointerRegionsDidChange()
        }
    }

    /// Forced while the title menu is open, so the masthead reads as pressed.
    var isMenuOpen = false { didSet { if oldValue != isMenuOpen { needsDisplay = true } } }

    private static let chevron = QuireSymbolSize.custom(Quire.Layout.ListHeader.chevron, weight: .semibold)

    /// Internal so tests can read the face the title is set in.
    var titleString: NSAttributedString { QuireFont.attributedString(title, role: .masthead, color: .qInk) }

    private var titleWidth: CGFloat { ceil(titleString.size().width) }

    private var chevronWidth: CGFloat {
        QuireSymbol.cachedImage(Quire.Icon.titleMenu, size: Self.chevron)?.size.width ?? Quire.Layout.ListHeader.chevron
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    /// A Font switch changes the title's width, never its line height; `ListHeaderView` lays the header out again
    /// on the same notification and reads the new size.
    override func appearanceDidChange() {
        super.appearanceDidChange()
        invalidateIntrinsicContentSize()
    }

    /// A menu button is labelled “Mailbox” with the view as its value; a plain title is the view's name.
    private func titleDidChange() {
        setAccessibilityLabel(isMenu ? "Mailbox" : title)
        setAccessibilityValue(isMenu ? title : nil)
    }

    override var intrinsicContentSize: NSSize {
        let pad = Quire.Layout.ListHeader.mastheadHitPad
        let chevron = isMenu ? Quire.Layout.ListHeader.chevronGap + chevronWidth : 0
        return NSSize(width: ceil(pad + titleWidth + chevron + pad), height: QuireFont.Role.masthead.lineHeight)
    }

    /// A plain title is part of the title-bar zone: clicks go through to it, so it drags the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isMenu ? super.hitTest(point) : nil
    }

    /// A plain title adds no region, so the title-bar zone's arrow shows over it (§4.17).
    override var pointerCursor: NSCursor? { isMenu ? super.pointerCursor : nil }

    override var acceptsFirstResponder: Bool { isMenu && super.acceptsFirstResponder }

    override var canBecomeKeyView: Bool { isMenu && super.canBecomeKeyView }

    override func draw(_ dirtyRect: NSRect) {
        let face = faceRect
        let radius = Quire.Radius.md
        let state = isMenu ? (isMenuOpen ? QuireDisplayState.pressed : interactionState) : .rest
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
        guard isMenu else { return }
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

    override func activate() {
        guard isMenu else { return }
        super.activate()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { isMenu ? .menuButton : NSAccessibility.Role(rawValue: "AXHeading") }

    override func accessibilityPerformPress() -> Bool { isMenu && super.accessibilityPerformPress() }
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
    func handlesKey(_ event: NSEvent) -> Bool { isMenu && isEnabled && event.isPlainReturn }
}

extension DemoTagButton: ShellKeyHandling {
    func handlesKey(_ event: NSEvent) -> Bool { isEnabled && event.isPlainReturn }
}
