import AppKit
import XCTest
@testable import PaperDesign

/// Renders a component into a bitmap in one colour mode, over a surface, the way AppKit would draw it on
/// screen (draw(_:) and layer content alike), and samples its pixels in view coordinates.
@MainActor
struct ComponentSnapshot {
    let rep: NSBitmapImageRep
    let scale: CGFloat

    /// The sRGB colour at a point in the host's coordinates (y down from the top-left).
    func rgba(at point: NSPoint) -> RGBA {
        let x = min(rep.pixelsWide - 1, max(0, Int((point.x * scale).rounded(.down))))
        let y = min(rep.pixelsHigh - 1, max(0, Int((point.y * scale).rounded(.down))))
        return ComponentSnapshot.rgba(of: rep, x: x, y: y)
    }

    /// The stored bytes of an 8-bit RGBA bitmap tagged sRGB, read as they are. `colorAt(x:y:)` would hand back
    /// a calibrated-RGB colour whose conversion to sRGB shifts every value, so the bytes are read directly.
    static func rgba(of rep: NSBitmapImageRep, x: Int, y: Int) -> RGBA {
        guard let data = rep.bitmapData, rep.bitsPerSample == 8, !rep.isPlanar else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        let offset = y * rep.bytesPerRow + x * rep.samplesPerPixel
        let alphaFirst = rep.bitmapFormat.contains(.alphaFirst)
        let a = rep.hasAlpha ? Double(data[offset + (alphaFirst ? 0 : 3)]) / 255 : 1
        let base = offset + (rep.hasAlpha && alphaFirst ? 1 : 0)
        // Premultiplied unless the format says otherwise; undo it so translucent pixels read as colours.
        let premultiplied = rep.hasAlpha && !rep.bitmapFormat.contains(.alphaNonpremultiplied)
        func channel(_ i: Int) -> Double {
            let v = Double(data[base + i]) / 255
            return premultiplied && a > 0 ? min(1, v / a) : v
        }
        return RGBA(r: channel(0), g: channel(1), b: channel(2), a: a)
    }

    func hex(at point: NSPoint) -> String { ColorLib.rgb2hex(rgba(at: point)) }

    /// True when the pixel is within `tolerance` (0…255 per channel) of the expected colour.
    func matches(_ expected: RGBA, at point: NSPoint, tolerance: Double = 3) -> Bool {
        let c = rgba(at: point)
        return abs(c.r - expected.r) * 255 <= tolerance && abs(c.g - expected.g) * 255 <= tolerance && abs(c.b - expected.b) * 255 <= tolerance
    }

    func write(to url: URL) throws {
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }

    /// Puts `view` on a host filled with `surface`, in an off-screen window of `mode`'s appearance, with the
    /// environment pinned to that mode's contrast, and renders the host.
    /// The bitmap is rendered at the window's backing scale unless `scale` asks for another: layer content is
    /// rasterised at that scale, and resampling it would blur the edges the tests sample.
    static func render(_ view: NSView, mode: QuireMode, surface: NSColor = .qPaper, padding: CGFloat = 0, scale: CGFloat? = nil,
                       graphite: Bool = false, reduceMotion: Bool = false, reduceTransparency: Bool = false,
                       theme: QuireTheme? = nil) -> ComponentSnapshot {
        QuireEnvironment.shared.setOverrides(.init(isGraphite: graphite, increaseContrast: mode.isIncreasedContrast,
                                                   reduceMotion: reduceMotion, reduceTransparency: reduceTransparency, theme: theme))
        let size = NSSize(width: view.frame.width + 2 * padding, height: view.frame.height + 2 * padding)
        let host = SnapshotHost(frame: NSRect(origin: .zero, size: size))
        host.fill = surface
        view.setFrameOrigin(NSPoint(x: padding, y: padding))
        host.addSubview(view)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = mode.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let scale = scale ?? window.backingScaleFactor
        let pixelsWide = Int((size.width * scale).rounded(.up))
        let pixelsHigh = Int((size.height * scale).rounded(.up))
        let device = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let rep = device.retagging(with: .sRGB) ?? device
        rep.size = size
        mode.performAsCurrent {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        return ComponentSnapshot(rep: rep, scale: scale)
    }
}

/// A flipped view that paints one surface colour, the surface a component sits on.
@MainActor
final class SnapshotHost: NSView {
    var fill: NSColor = .qPaper
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
    }
}

/// The expected colour of a token stack (a surface and the washes over it) in `mode`.
func expected(_ stack: String..., mode: QuireMode) -> RGBA {
    TokenResolver.resolveStack(stack, mode)
}
