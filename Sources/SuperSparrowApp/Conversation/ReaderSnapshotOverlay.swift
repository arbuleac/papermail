import AppKit
import WebKit

/// Debug aid for `--snapshot`: `cacheDisplay` cannot draw WKWebView content, so the snapshot draws the web
/// view's own image over its frame, which would also cover what the reader draws over the web view (the quick
/// reply bar, spec §5.18). This draws those views back on top, in z order.
@MainActor
enum ReaderSnapshotOverlay {
    /// Draws, into the current graphics context (an unflipped bitmap of `root`), every visible view that sits
    /// above `webView` and overlaps it.
    static func draw(over webView: WKWebView, in root: NSView) {
        let webFrame = webView.convert(webView.bounds, to: root)
        var overlays: [NSView] = []
        var child: NSView = webView
        while let parent = child.superview, child !== root {
            if let index = parent.subviews.firstIndex(of: child) {
                for sibling in parent.subviews[(index + 1)...] where !sibling.isHiddenOrHasHiddenAncestor {
                    if sibling.convert(sibling.bounds, to: root).intersects(webFrame) { overlays.append(sibling) }
                }
            }
            child = parent
        }
        for overlay in overlays {
            guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { continue }
            overlay.cacheDisplay(in: overlay.bounds, to: rep)
            let image = NSImage(size: overlay.bounds.size)
            image.addRepresentation(rep)
            var frame = overlay.convert(overlay.bounds, to: root)
            if root.isFlipped { frame.origin.y = root.bounds.height - frame.maxY }
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}
