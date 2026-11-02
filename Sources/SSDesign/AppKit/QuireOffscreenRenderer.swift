import AppKit

/// Renders a view in a given colour mode, off screen, for galleries and specimens that show a mode the app
/// is not in, such as an Increased contrast card beside the normal page.
///
/// An appearance cannot carry Increase Contrast (`NSAppearance(named: .accessibilityHighContrastAqua)`
/// resolves as plain Aqua, see `QuireMode`), so the view is built and drawn with the `QuireEnvironment`
/// override set to the mode's contrast (layer colours, hairline widths, ring widths) and inside
/// `QuireMode.performAsCurrent` (drawn colours). The previous overrides come back before this returns.
@MainActor
public enum QuireOffscreenRenderer {
    /// Builds a view with `build` and renders it in `mode` at `scale`, in its own borderless window far off
    /// screen. The view's frame size is the bitmap's size in points.
    public static func render(mode: QuireMode, scale: CGFloat, build: () -> NSView) -> NSBitmapImageRep? {
        let environment = QuireEnvironment.shared
        let saved = environment.overrides
        var forced = saved
        forced.increaseContrast = mode.isIncreasedContrast
        environment.setOverrides(forced)
        defer { environment.setOverrides(saved) }

        let view = build()
        let size = view.frame.size
        // The view sits in a page inside the window's root and the page is cached, the hierarchy the app's
        // gallery snapshot uses, in which `cacheDisplay` casts layer shadows the way the screen does.
        let page = QuireFlippedView(frame: NSRect(origin: .zero, size: size))
        view.setFrameOrigin(.zero)
        page.addSubview(view)
        let root = QuireFlippedView(frame: page.frame)
        root.addSubview(page)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -40_000, y: -40_000), size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = mode.appearance
        window.contentView = root
        defer { window.contentView = nil }
        page.layoutSubtreeIfNeeded()
        page.displayIfNeeded()
        let pixelsWide = Int((size.width * scale).rounded(.up))
        let pixelsHigh = Int((size.height * scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0,
              let device = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let rep = device.retagging(with: .sRGB) ?? device
        rep.size = size
        mode.performAsCurrent {
            page.cacheDisplay(in: page.bounds, to: rep)
        }
        return rep
    }
}
