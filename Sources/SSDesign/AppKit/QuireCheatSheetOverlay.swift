import AppKit

/// The keyboard cheat sheet as an in-window overlay (spec §5.32): the scrim over the view it fills, and the
/// panel centred horizontally with its top at `cheatSheet.top` (92 pt, under the horizon) and at least
/// `cheatSheet.minMargin` (24 pt) above the bottom. A window shorter than the panel needs gets a shorter panel
/// whose bands scroll under the fixed title row.
///
/// The shell adds it over the window's content below the title-bar zone's controls (so the traffic lights
/// stay usable) and calls `present(animated:)`; it makes itself first responder and traps focus: Tab moves
/// between the close button and the overlay, the arrows and Page Up / Down scroll the bands, and every other
/// key is swallowed so learning a shortcut is safe. Esc, ?, ⌘/, ⌘W, the close button and a click on the scrim
/// call `onDismiss`; the shell then calls `dismiss(completion:)` and gives focus back.
///
/// Motion: in, the scrim fades over `dur.quick` and the panel fades and scales up from 0.98 over
/// `dur.standard` (`ease.settle`); out, both fade over `dur.quick` (`ease.leave`). Reduce Motion keeps the
/// fades and drops the scale. Under Reduce Transparency the scrim is opaque (`scrimSolid`).
@MainActor
public final class QuireCheatSheetOverlay: NSView, QuirePointerCover {
    public let scrim = QuireScrimView(frame: .zero)
    public let panel: QuireCheatSheetPanel

    /// Esc, ?, ⌘/, ⌘W, the close button or a click on the scrim asked to close.
    public var onDismiss: (@MainActor () -> Void)?

    /// The scale the panel grows from (`0.98`, §5.32).
    public static let entryScale: CGFloat = 0.98

    public init(frame frameRect: NSRect, sections: [QuireCheatSheetSection] = Quire.cheatSheet) {
        panel = QuireCheatSheetPanel(sections: sections)
        super.init(frame: frameRect)
        wantsLayer = true
        scrim.frame = bounds
        scrim.autoresizingMask = [.width, .height]
        scrim.onClick = { [weak self] in self?.onDismiss?() }
        panel.onClose = { [weak self] in self?.onDismiss?() }
        addSubview(scrim)
        addSubview(panel)
        needsLayout = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireCheatSheetOverlay is built in code") }

    public override var isFlipped: Bool { true }

    // MARK: Layout

    /// The panel's frame in a view of `size`: centred, top at 92 pt, as tall as its content or as the space
    /// down to 24 pt above the bottom allows.
    public static func panelFrame(in size: NSSize, sections: [QuireCheatSheetSection] = Quire.cheatSheet) -> NSRect {
        let c = Quire.Layout.CheatSheet.self
        let natural = QuireCheatSheetPanel.naturalHeight(for: sections)
        let height = max(0, min(natural, size.height - c.top - c.minMargin))
        return NSRect(x: ((size.width - c.width) / 2).rounded(), y: c.top, width: c.width, height: height)
    }

    public override func layout() {
        super.layout()
        // The scale transform belongs to the layer; frames are set without it.
        let transform = panel.layer?.transform
        panel.layer?.transform = CATransform3DIdentity
        panel.frame = QuireCheatSheetOverlay.panelFrame(in: bounds.size, sections: panel.sections)
        if let transform { panel.layer?.transform = transform }
        pointerRegionsDidChange()
    }

    // MARK: Pointer

    /// The hand over the scrim, which a click dismisses, around the panel (§4.17). The rects cover the window's content,
    /// so the reader's page under them sets no cursor of its own, and as a cover the overlay has the controls under it
    /// leave its frame to it.
    public var pointerRegions: [QuirePointerRegion] {
        QuirePointerRegion.regions(bounds, cursor: .pointingHand, cutting: childPointerAreas())
    }

    public override func resetCursorRects() {
        addPointerRects()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointerCoverDidChange()
    }

    public override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        pointerCoverDidChange()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pointerCoverDidChange()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        pointerRegionsDidChange()
        pointerCoverDidChange()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        pointerRegionsDidChange()
        pointerCoverDidChange()
    }

    // MARK: Motion

    /// Shows the overlay and takes keyboard focus. Without animation it appears at once (tests, snapshots).
    public func present(animated: Bool = true) {
        isHidden = false
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(self)
        guard animated, let scrimLayer = scrim.layer, let panelLayer = panel.layer else { return }
        scrimLayer.opacity = 0
        panelLayer.opacity = 0
        Quire.Motion.animate(scrimLayer, keyPath: "opacity", to: Float(1), duration: Quire.Motion.quick, curve: .settle, reduced: .keep)
        Quire.Motion.animate(panelLayer, keyPath: "opacity", to: Float(1), duration: Quire.Motion.standard, curve: .settle, reduced: .keep)
        let scale = Quire.Motion.plan(Quire.Motion.standard, .settle, reduced: .instant)
        guard scale.animatesMovement else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panelLayer.transform = QuireCheatSheetOverlay.scaleTransform(QuireCheatSheetOverlay.entryScale, size: panel.bounds.size)
        CATransaction.commit()
        Quire.Motion.animate(panelLayer, keyPath: "transform", to: NSValue(caTransform3D: CATransform3DIdentity), duration: Quire.Motion.standard,
                             curve: .settle, reduced: .instant)
    }

    /// Fades the overlay out, then hides it and calls `completion` (the shell removes it and restores focus).
    public func dismiss(animated: Bool = true, completion: (@MainActor () -> Void)? = nil) {
        guard animated, let scrimLayer = scrim.layer, let panelLayer = panel.layer else {
            isHidden = true
            completion?()
            return
        }
        Quire.Motion.animate(scrimLayer, keyPath: "opacity", to: Float(0), duration: Quire.Motion.quick, curve: .leave, reduced: .keep)
        Quire.Motion.animate(panelLayer, keyPath: "opacity", to: Float(0), duration: Quire.Motion.quick, curve: .leave, reduced: .keep) {
            [weak self] in
            self?.isHidden = true
            self?.scrim.layer?.opacity = 1
            self?.panel.layer?.opacity = 1
            completion?()
        }
    }

    /// A scale about the centre of a layer whose anchor is its origin, as AppKit sets up a view's layer.
    static func scaleTransform(_ scale: CGFloat, size: NSSize) -> CATransform3D {
        let affine = CGAffineTransform(translationX: size.width * (1 - scale) / 2, y: size.height * (1 - scale) / 2)
            .scaledBy(x: scale, y: scale)
        return CATransform3DMakeAffineTransform(affine)
    }

    // MARK: Keys

    public override var acceptsFirstResponder: Bool { true }

    /// What a key does while the overlay is open.
    enum KeyAction: Equatable {
        case dismiss
        case focusNext
        case focusPrevious
        case scroll(rows: CGFloat)
        case scrollPage(CGFloat)
        case swallow
    }

    static func action(forCharacters characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> KeyAction {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if keyCode == 53 { return .dismiss } // Esc
        if characters == "?" && flags.subtracting(.shift).isEmpty { return .dismiss }
        if flags == .command && (characters == "/" || characters == "w") { return .dismiss }
        if characters == "\t" { return flags.contains(.shift) ? .focusPrevious : .focusNext }
        if characters == "\u{19}" { return .focusPrevious } // Shift-Tab arrives as back-tab
        switch keyCode {
        case 125: return .scroll(rows: 1)   // ↓
        case 126: return .scroll(rows: -1)  // ↑
        case 121: return .scrollPage(1)     // Page Down
        case 116: return .scrollPage(-1)    // Page Up
        default: return .swallow
        }
    }

    private func perform(_ action: KeyAction) {
        switch action {
        case .dismiss: onDismiss?()
        case .focusNext, .focusPrevious:
            // Two stops, so forward and back both alternate between the close button and the bands.
            let onClose = window?.firstResponder === panel.closeButton
            window?.makeFirstResponder(onClose ? self : panel.closeButton)
        case .scroll(let rows): panel.scrollBands(byRows: rows)
        case .scrollPage(let pages): panel.scrollBands(byPages: pages)
        case .swallow: break
        }
    }

    public override func keyDown(with event: NSEvent) {
        perform(QuireCheatSheetOverlay.action(forCharacters: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode,
                                              modifiers: event.modifierFlags))
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHidden, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let action = QuireCheatSheetOverlay.action(forCharacters: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode,
                                                   modifiers: event.modifierFlags)
        guard action == .dismiss else { return super.performKeyEquivalent(with: event) }
        onDismiss?()
        return true
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { false }
}
