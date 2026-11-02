import AppKit
import SSCore
import SSDesign

/// The SF Symbols the reader shell draws, rasterised once (spec §4.11): WKWebView cannot draw SF Symbols and
/// redrawing them as SVG is not allowed, so each one becomes a black-on-clear PNG at 3× on a square canvas
/// 1.3 × its point size, carried as a `data:` URI in a CSS custom property the shell uses as a mask.
@MainActor
enum ReaderSymbolSheet {
    /// `:root{--sym-star:url("data:…");…}`, built on first use and shared by every pool.
    static let css: String = build()

    private static func build() -> String {
        let point = CGFloat(Quire.Platform.readerSymbolPointSize)
        let scale = CGFloat(Quire.Platform.readerSymbolScale)
        let canvas = (point * CGFloat(Quire.Platform.readerSymbolCanvas)).rounded()
        var declarations: [String] = []
        for name in ConversationShellAssets.symbols {
            guard let png = rasterise(name, pointSize: point, canvas: canvas, scale: scale) else {
                ConversationSignposts.log.error("reader symbol \(name, privacy: .public) did not rasterise")
                continue
            }
            declarations.append(ConversationShellAssets.symbolVariable(name) + ":url(\"data:image/png;base64," + png.base64EncodedString() + "\")")
        }
        return ":root{" + declarations.joined(separator: ";") + "}"
    }

    private static func rasterise(_ name: String, pointSize: CGFloat, canvas: CGFloat, scale: CGFloat) -> Data? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return nil
        }
        let pixels = Int(canvas * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // The point size must be set before the context exists: the context takes its scale from it.
        rep.size = NSSize(width: canvas, height: canvas)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let size = symbol.size
        let rect = NSRect(x: ((canvas - size.width) / 2), y: ((canvas - size.height) / 2), width: size.width, height: size.height)
        symbol.draw(in: rect)
        // The mask's alpha is all that matters; black keeps it legible when the PNG is inspected on its own.
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: canvas, height: canvas).fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
