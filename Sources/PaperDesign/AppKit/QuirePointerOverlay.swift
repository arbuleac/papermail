import AppKit

/// The pointer for a control AppKit makes and Quire cannot subclass (spec §4.17): an alert's buttons, the Later
/// picker's calendar. Laid over the control and sized with it, it takes no clicks and shows the pointing hand over the
/// control while the control is enabled and the arrow while it is not, following `isEnabled` as it changes.
///
///     alert.buttons.forEach { QuirePointerOverlay.install(on: $0) }
@MainActor
public final class QuirePointerOverlay: NSView, QuirePointerTarget {
    private weak var control: NSControl?
    private var enabledObservation: NSKeyValueObservation?

    /// Lays an overlay over `control` and returns it; on a control that has one already, returns that one.
    @discardableResult
    public static func install(on control: NSControl) -> QuirePointerOverlay {
        if let existing = control.subviews.lazy.compactMap({ $0 as? QuirePointerOverlay }).first { return existing }
        let overlay = QuirePointerOverlay(control: control)
        control.addSubview(overlay)
        return overlay
    }

    private init(control: NSControl) {
        self.control = control
        super.init(frame: control.bounds)
        autoresizingMask = [.width, .height]
        enabledObservation = control.observe(\.isEnabled) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.pointerRegionsDidChange() }
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuirePointerOverlay is built in code") }

    public var pointerRegions: [QuirePointerRegion] {
        guard let control else { return [] }
        return [.control(bounds, acts: control.isEnabled)]
    }

    public override func resetCursorRects() {
        addPointerRects()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func isAccessibilityElement() -> Bool { false }
}
