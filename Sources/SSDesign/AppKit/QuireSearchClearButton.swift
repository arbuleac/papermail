import AppKit

/// The search field's clear button (spec §5.6): a 16 pt `fill` disc with `xmark` 9 pt, `ink2` at rest and
/// `ink` on hover, with a 24 pt hit rect.
@MainActor
final class QuireSearchClearButton: QuireControl {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Clear search")
        toolTip = "Clear"
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Quire.Layout.Search.clearVisual, height: Quire.Layout.Search.clearVisual)
    }

    override func draw(_ dirtyRect: NSRect) {
        let face = faceRect
        QuireDraw.fillCircle(face, .qFill)
        let state = interactionState
        if state == .pressed { QuireDraw.fillCircle(face, .qPressed) }
        QuireDraw.symbol(Quire.Icon.remove, size: .custom(Quire.Layout.Search.clearGlyph),
                         color: state == .rest ? .qInk2 : .qInk, centredIn: face)
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: face.height / 2, gap: QuireFocusRing.gap)
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
}
