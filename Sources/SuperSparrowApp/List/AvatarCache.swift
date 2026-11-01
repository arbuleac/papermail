import AppKit
import CoreText

/// Initials avatars, rendered once per (initials, color) off the main thread and kept in an `NSCache`.
///
/// A row asks for its image while being configured. When the image is not ready the row shows nothing in the
/// circle and receives the image through `ready` later, without a relayout, so scrolling never waits on drawing.
@MainActor
final class AvatarCache {
    struct Key: Hashable {
        let initials: String
        let colorIndex: Int
    }

    /// Muted but distinct hues that keep white initials legible in both appearances.
    static let palette: [NSColor] = [
        NSColor(srgbRed: 0.91, green: 0.36, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.40, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.67, green: 0.42, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 0.52, green: 0.46, blue: 0.84, alpha: 1),
        NSColor(srgbRed: 0.36, green: 0.52, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.24, green: 0.62, blue: 0.88, alpha: 1),
        NSColor(srgbRed: 0.18, green: 0.66, blue: 0.70, alpha: 1),
        NSColor(srgbRed: 0.22, green: 0.68, blue: 0.54, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.68, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.80, green: 0.60, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.50, blue: 0.28, alpha: 1),
        NSColor(srgbRed: 0.58, green: 0.50, blue: 0.44, alpha: 1),
    ]

    static func colorIndex(for seed: UInt64) -> Int {
        Int(seed % UInt64(palette.count))
    }

    let diameter: CGFloat

    private let cache = NSCache<NSString, NSImage>()
    private var waiters: [Key: [@MainActor (NSImage) -> Void]] = [:]
    private let renderQueue = DispatchQueue(label: "SuperSparrow.avatar-render", qos: .userInitiated, attributes: .concurrent)
    private let font: NSFont

    init(diameter: CGFloat = 36) {
        self.diameter = diameter
        font = NSFont.systemFont(ofSize: (diameter * 0.4).rounded(), weight: .medium)
        // A few thousand distinct senders is a large address book; beyond that the oldest get re-rendered.
        cache.countLimit = 4_000
    }

    func cachedImage(for key: Key) -> NSImage? {
        cache.object(forKey: cacheKey(for: key))
    }

    /// Returns the image at once when cached. Otherwise schedules one render for this key (however many rows
    /// ask meanwhile) and calls every `ready` on the main thread when it lands.
    func image(for key: Key, ready: @escaping @MainActor (NSImage) -> Void) -> NSImage? {
        if let image = cachedImage(for: key) { return image }
        if waiters[key] != nil {
            waiters[key]?.append(ready)
            return nil
        }
        waiters[key] = [ready]
        let color = AvatarCache.palette[key.colorIndex % AvatarCache.palette.count]
        let request = RenderRequest(initials: key.initials, color: color.cgColor, diameter: diameter, font: font)
        renderQueue.async {
            let image = AvatarCache.render(request)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(key: key, image: image) }
            }
        }
        return nil
    }

    private func finish(key: Key, image: NSImage) {
        cache.setObject(image, forKey: cacheKey(for: key))
        let callbacks = waiters.removeValue(forKey: key) ?? []
        for callback in callbacks { callback(image) }
    }

    private func cacheKey(for key: Key) -> NSString {
        "\(key.colorIndex)|\(key.initials)" as NSString
    }

    // MARK: Rendering

    /// Fonts and CGColors are immutable once created, which is what makes handing them to the render queue safe.
    private struct RenderRequest: @unchecked Sendable {
        let initials: String
        let color: CGColor
        let diameter: CGFloat
        let font: NSFont
    }

    /// Draws with Core Graphics and Core Text only, so it needs no AppKit graphics context and can run on any
    /// queue. Rendered at 2x and tagged with its point size; a 1x display just downsamples.
    private nonisolated static func render(_ request: RenderRequest) -> NSImage {
        let scale: CGFloat = 2
        let pointSize = NSSize(width: request.diameter, height: request.diameter)
        let pixels = Int((request.diameter * scale).rounded())
        guard pixels > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return NSImage(size: pointSize) }

        context.scaleBy(x: scale, y: scale)
        let circle = CGRect(x: 0, y: 0, width: request.diameter, height: request.diameter)
        context.setFillColor(request.color)
        context.fillEllipse(in: circle)

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): request.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: request.initials, attributes: attributes))
        // Glyph path bounds, not typographic ones, so the letters sit optically centered in the circle.
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: circle.midX - bounds.midX, y: circle.midY - bounds.midY)
        CTLineDraw(line, context)

        guard let cgImage = context.makeImage() else { return NSImage(size: pointSize) }
        return NSImage(cgImage: cgImage, size: pointSize)
    }
}
