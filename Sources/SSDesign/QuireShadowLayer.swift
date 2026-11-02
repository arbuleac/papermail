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

    /// `CALayer.shadowOffset` for an unflipped layer, whose y grows up: a shadow that falls 6 pt is (0, -6).
    public var layerOffset: CGSize { CGSize(width: x, height: -y) }

    /// Puts this shadow on `layer`. The caller still sets `shadowPath` (spec §4.8 requires one on every
    /// shadowed layer, so AppKit never rasterises the alpha mask).
    public func apply(to layer: CALayer, flipped: Bool = false) {
        layer.shadowColor = NSColor(quireRGBA: rgba | 0xFF).cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = shadowRadius
        layer.shadowOffset = flipped ? CGSize(width: x, height: y) : layerOffset
    }
}
