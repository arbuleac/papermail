import AppKit
import QuartzCore

/// One shadow layer of an elevation level, written as CSS writes it (spec §4.8).
public struct QuireShadowLayer: Equatable, Sendable {
    public let x: CGFloat
    /// Downward offset in points (CSS y grows down).
    public let y: CGFloat
    /// CSS blur radius; `CALayer.shadowRadius` is half of it.
    public let blur: CGFloat
    public let spread: CGFloat
    /// 0xRRGGBBAA; the alpha is the layer's opacity.
    public let rgba: UInt32

    public init(x: CGFloat, y: CGFloat, blur: CGFloat, spread: CGFloat, rgba: UInt32) {
        self.x = x
        self.y = y
        self.blur = blur
        self.spread = spread
        self.rgba = rgba
    }

    public var color: NSColor { NSColor(quireRGBA: rgba) }

    /// `CALayer.shadowOpacity`: the colour's alpha, because `shadowColor` is applied opaque.
    public var opacity: Float { Float(rgba & 0xFF) / 255 }

    /// `CALayer.shadowRadius`: CSS blur = 2 × shadowRadius.
    public var shadowRadius: CGFloat { blur / 2 }

    /// `CALayer.shadowOffset` for a layer in a bottom-up coordinate space: a shadow that falls 6 pt is (0, -6).
    public var layerOffset: CGSize { CGSize(width: x, height: -y) }

    /// `CALayer.shadowOffset` for a layer in a bottom-up (`flipped` false) or top-down (`flipped` true)
    /// coordinate space. The window server applies a flipped view's geometry to the shadow offsets of every
    /// layer in its tree, at any depth, so a shadow that falls 6 pt in a flipped view is (0, +6). Measured on
    /// macOS 27 with a window-server capture: (0, -6) under a flipped view's layer cast the shadow upward on
    /// screen. `cacheDisplay` disagrees in some hierarchies (it renders the offset unflipped when the cached
    /// view is itself flipped), so only a window-server capture can check the direction.
    public func layerOffset(flipped: Bool) -> CGSize {
        flipped ? CGSize(width: x, height: y) : layerOffset
    }

    /// Puts this shadow on `layer`. Pass `flipped` when the layer is in a flipped view's layer tree (every
    /// Quire component is flipped); see `layerOffset(flipped:)`. The caller still sets `shadowPath` (spec §4.8
    /// requires one on every shadowed layer, so AppKit never rasterises the alpha mask).
    public func apply(to layer: CALayer, flipped: Bool) {
        layer.shadowColor = NSColor(quireRGBA: rgba | 0xFF).cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = shadowRadius
        layer.shadowOffset = layerOffset(flipped: flipped)
    }

    /// Puts this shadow on `layer`, a layer in `view`'s layer tree, with the offset for `view`'s geometry.
    @MainActor
    public func apply(to layer: CALayer, in view: NSView) {
        apply(to: layer, flipped: view.isFlipped)
    }
}
