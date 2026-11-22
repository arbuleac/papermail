import AppKit

/// The dimming behind the cheat-sheet overlay (spec §5.32, §4.9): the one translucent app-drawn surface,
/// `scrim` over the window. Under Reduce Transparency it is drawn opaque as `scrimSolid` (what the scrim gives
/// over `canvas`), so the window behind is hidden rather than dimmed; it follows the setting while shown.
/// A click on it calls `onClick` (the overlay dismisses).
@MainActor
public final class QuireScrimView: NSView {
    public var onClick: (@MainActor () -> Void)?

    private var colors: QuireLayerColors!

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        colors = QuireLayerColors(view: self)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
        applyFill()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireScrimView is built in code") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { isSolid }

    /// True while Reduce Transparency makes the scrim opaque.
    public var isSolid: Bool { QuireEnvironment.reduceTransparency }

    /// The colour the scrim draws now.
    public var fillColor: NSColor { isSolid ? .qScrimSolid : .qScrim }

    private func applyFill() {
        // The layer belongs to the view; set it through QuireLayerColors so it follows appearance changes.
        if let layer { colors.set(fillColor, for: \CALayer.backgroundColor, of: layer) }
    }

    @objc private func environmentDidChange(_ note: Notification) {
        applyFill()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colors.refresh()
    }

    public override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    public override func isAccessibilityElement() -> Bool { false }
}
