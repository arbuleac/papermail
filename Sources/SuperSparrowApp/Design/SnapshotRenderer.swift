import AppKit
import os
import SSDesign

/// Debug snapshots drawn by the app itself (`--snapshot-*`), because `screencapture` needs the Screen
/// Recording permission. Views render through `cacheDisplay`, in their window's appearance, at its backing
/// scale.
@MainActor
enum SnapshotRenderer {
    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "shell")

    /// The view and everything under it, layer content included.
    static func render(_ view: NSView, rect: NSRect? = nil) -> NSBitmapImageRep? {
        let rect = rect ?? view.bounds
        guard rect.width > 0, rect.height > 0, let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: rect, to: bitmap)
        }
        return bitmap
    }

    /// A window with its title bar: the frame view holds both.
    static func render(window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        return render(view)
    }

    /// Bitmaps one under the other, left-aligned on `background`, `gap` points apart, at the first one's scale.
    static func stack(_ bitmaps: [NSBitmapImageRep], gap: CGFloat = 24, background: NSColor = .qCanvas,
                      appearance: NSAppearance) -> NSBitmapImageRep? {
        guard let first = bitmaps.first else { return nil }
        let scale = CGFloat(first.pixelsWide) / max(1, first.size.width)
        let width = bitmaps.map(\.size.width).max() ?? 0
        let height = bitmaps.map(\.size.height).reduce(0, +) + gap * CGFloat(bitmaps.count - 1)
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((width * scale).rounded(.up)),
                                            pixelsHigh: Int((height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        canvas.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            background.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
        }
        var top: CGFloat = 0
        for bitmap in bitmaps {
            // Drawing coordinates run bottom-up; place each image from the top.
            let rect = NSRect(x: 0, y: height - top - bitmap.size.height, width: bitmap.size.width, height: bitmap.size.height)
            bitmap.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            top += bitmap.size.height + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return canvas
    }

    /// Writes a PNG, logging only the outcome (paths can name the user).
    @discardableResult
    static func writePNG(_ bitmap: NSBitmapImageRep, to path: String) -> Bool {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            log.error("snapshot: PNG encoding failed")
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            log.info("snapshot written")
            return true
        } catch {
            log.error("snapshot failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
