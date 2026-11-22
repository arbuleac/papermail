import AppKit

/// What checkboxes, radios and toggles share (spec §5.26): the label beside the control (`body` `ink`, 8 pt
/// away, part of the hit area), the box's fills per state, and the disabled look (0.45 opacity on the control,
/// the label `inkDisabled`).
enum QuireChoiceDrawing {
    static var labelGap: CGFloat { Quire.Layout.Checkbox.labelGap }

    static func labelString(_ title: String, enabled: Bool) -> NSAttributedString {
        QuireDraw.line(title, .body, enabled ? .qInk : .qInkDisabled)
    }

    /// The control plus its label: the intrinsic size of a choice control.
    static func size(control: NSSize, title: String?) -> NSSize {
        guard let title, !title.isEmpty else { return control }
        let width = control.width + labelGap + QuireDraw.width(labelString(title, enabled: true))
        return NSSize(width: width, height: max(control.height, QuireFont.Role.body.lineHeight))
    }

    /// The control's rect at the leading edge of `body`, centred vertically.
    static func controlRect(_ size: NSSize, in body: NSRect) -> NSRect {
        NSRect(x: body.minX, y: (body.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    static func drawLabel(_ title: String?, enabled: Bool, after control: NSRect, in body: NSRect) {
        guard let title, !title.isEmpty else { return }
        let lineHeight = QuireFont.Role.body.lineHeight
        let x = control.maxX + labelGap
        QuireDraw.draw(labelString(title, enabled: enabled), x: x, top: (body.midY - lineHeight / 2).rounded(),
                       maxWidth: body.maxX - x, lineHeight: lineHeight)
    }

    /// The fill of a checkbox or radio: off `sheet` (+ `hover` / `pressed`), on `accentFill`, hover
    /// `accentFillHover`, pressed `controlOnPressed` (which keeps 3:1 on `sheet` and `canvas`, unlike
    /// `accentFillPressed`).
    static func boxFills(on: Bool, state: QuireDisplayState) -> [NSColor] {
        if on {
            switch state {
            case .pressed: return [.qControlOnPressed]
            case .hover: return [.qAccentFillHover]
            case .rest, .focused: return [.qAccentFill]
            }
        }
        switch state {
        case .pressed: return [.qSheet, .qPressed]
        case .hover: return [.qSheet, .qHover]
        case .rest, .focused: return [.qSheet]
        }
    }

    /// Runs `body` with the control drawn at the disabled opacity when `enabled` is false.
    static func withDisabledOpacity(_ enabled: Bool, in rect: NSRect, _ body: () -> Void) {
        guard !enabled, let context = NSGraphicsContext.current?.cgContext else { body(); return }
        context.saveGState()
        context.setAlpha(Quire.Layout.Checkbox.disabledOpacity)
        context.beginTransparencyLayer(in: rect.insetBy(dx: -2, dy: -2), auxiliaryInfo: nil)
        body()
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
