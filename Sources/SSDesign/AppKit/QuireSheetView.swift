import AppKit

/// The card surface (spec §5.14, §4.8): an opaque `sheet` with radius 8, a hairline `rule` edge and `e1`, the
/// surface messages, the stack, Settings groups and popovers are made of. In Increase Contrast it gains the
/// 1 pt `ruleStrong` outline (`border.icOutline`) and keeps its shadow. The target message's sheet draws the
/// 1 pt `ruleStrong` edge instead of the hairline (`isTarget`); keyboard focus draws the ring outside a 2 pt
/// gap (`isFocused`).
///
/// Put content in `contentView`, which is clipped to the corner radius. The shadow and the ring draw outside
/// the bounds, so give the sheet room in its superview.
@MainActor
public final class QuireSheetView: NSView {
    /// `sheet` by default; `raised` for popovers, the cheat sheet and the selected unified tile.
    public var fillColor: NSColor = .qSheet {
        didSet { surface.fillColor = fillColor }
    }

    public var cornerRadius: CGFloat = Quire.Layout.Reader.sheetRadius {
        didSet { surface.cornerRadius = cornerRadius; contentView.layer?.cornerRadius = cornerRadius }
    }

    /// `e1` by default; `e2` for popovers and autocomplete, `e3` for the cheat sheet. `e0` for the stack.
    public var elevation: QuireElevationLevel = Quire.Elevation.e1 {
        didSet { surface.elevation = elevation }
    }

    /// The hairline `rule` edge at rest. Popovers turn it off and show an edge only in Increase Contrast.
    public var showsEdge = true {
        didSet { surface.apply() }
    }

    /// The target message's 1 pt `ruleStrong` edge (§5.14).
    public var isTarget = false {
        didSet { surface.apply() }
    }

    /// The keyboard ring around the sheet, outside a 2 pt gap (`n`/`p`, Tab).
    public var isFocused = false {
        didSet { surface.ringColor = isFocused ? .qFocus : nil }
    }

    /// Where the sheet's content goes; clipped to the corner radius.
    public let contentView: NSView

    let surface = QuireSurfaceView(frame: .zero)

    public override init(frame frameRect: NSRect) {
        contentView = QuireFlippedView(frame: NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)
        clipsToBounds = false
        surface.fillColor = fillColor
        surface.cornerRadius = cornerRadius
        surface.elevation = elevation
        surface.edge = { [weak self] mode in
            guard let self else { return .none }
            if self.isTarget || mode.isIncreasedContrast {
                return .solid(.qRuleStrong, width: Quire.Border.IcOutline.width)
            }
            return self.showsEdge ? .hairline(.qRule) : .none
        }
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = cornerRadius
        contentView.layer?.masksToBounds = true
        addSubview(surface)
        addSubview(contentView)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireSheetView is built in code") }

    public override var isFlipped: Bool { true }

    public override func isAccessibilityElement() -> Bool { false }
}
