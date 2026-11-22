import AppKit
import SwiftUI
import XCTest
@testable import PaperDesign

/// Hosts SwiftUI views the way Settings will: in an `NSHostingView` inside a real (off-screen) window, so
/// TextFields, menus and focus behave as they do in the app, and renders them with `cacheDisplay`, which draws
/// platform-backed views that `ImageRenderer` leaves blank.
@MainActor
final class SwiftUIHost<Content: View> {
    let window: NSWindow
    let hostingView: NSHostingView<HostRoot<Content>>
    /// Nil: the window follows the content's fitting size, which can change after the first pass (paragraphs
    /// measure their line height in place), so it is re-fitted before every render.
    private let fixedSize: CGSize?

    init(_ content: Content, mode: QuireMode = .light, size: CGSize? = nil) {
        fixedSize = size
        hostingView = NSHostingView(rootView: HostRoot(content: content))
        let fitting = hostingView.fittingSize
        let frame = NSRect(origin: .zero, size: size ?? CGSize(width: max(fitting.width, 1), height: max(fitting.height, 1)))
        window = UnconstrainedWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = mode.appearance
        window.contentView = hostingView
        hostingView.frame = frame
        // On screen as far as AppKit is concerned (a text field only takes focus in an ordered window), but
        // placed far outside every display so the test run never flashes windows at the person at the Mac.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        settle()
    }

    /// Lets SwiftUI lay out, resolve focus and run its updates.
    func settle(_ seconds: TimeInterval = 0.05) {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        hostingView.layoutSubtreeIfNeeded()
    }

    /// Draws the hosting view as it is now, at `scale` pixels per point (2 by default, whatever the screen the
    /// test runs on, so hairlines and 1 pt edges are measurable).
    func render(scale: CGFloat = 2, settle seconds: TimeInterval = 0.05) -> NSBitmapImageRep {
        settle(seconds)
        if fixedSize == nil {
            let fitting = hostingView.fittingSize
            if fitting != hostingView.frame.size {
                window.setContentSize(fitting)
                hostingView.frame = NSRect(origin: .zero, size: fitting)
                settle()
            }
        }
        let bounds = hostingView.bounds
        // Tagged sRGB, the space the tokens are tuned in, so the stored components are the tokens' own.
        guard let blank = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let rep = blank.retagging(with: .sRGB) else {
            preconditionFailure("no bitmap for \(bounds)")
        }
        rep.size = bounds.size
        hostingView.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

/// A window AppKit does not shrink to the screen: a tall gallery would otherwise be squeezed to the display's
/// height and SwiftUI would compress its flexible views to fit.
final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The hosted root: names the coordinate space frames are recorded in, the hosting view's own (top-left
/// origin). SwiftUI's global space on macOS is offset by the window's title bar.
struct HostRoot<Content: View>: View {
    let content: Content

    var body: some View {
        content.coordinateSpace(.named(FrameRecorder.space))
    }
}

extension NSBitmapImageRep {
    /// Points per pixel column: the backing scale the window drew at.
    var scale: CGFloat { CGFloat(pixelsWide) / size.width }

    /// The sRGB colour of the pixel under `point` (points, top-left origin, as in the flipped hosting view).
    /// Read as raw samples: the bitmap is tagged sRGB, but `colorAt` builds its colour from the rep's
    /// `colorSpaceName` (Generic RGB) and would shift every value on conversion.
    func srgb(at point: CGPoint) -> RGBA {
        let x = min(max(Int((point.x * scale).rounded(.down)), 0), pixelsWide - 1)
        let y = min(max(Int((point.y * scale).rounded(.down)), 0), pixelsHigh - 1)
        var samples = [Int](repeating: 0, count: max(samplesPerPixel, 4))
        getPixel(&samples, atX: x, y: y)
        return RGBA(r: Double(samples[0]) / 255, g: Double(samples[1]) / 255, b: Double(samples[2]) / 255,
                    a: Double(hasAlpha ? samples[3] : 255) / 255)
    }

    func writePNG(to path: String) throws {
        guard let data = representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: URL(fileURLWithPath: path))
    }
}

/// Expected colours of composited stacks, resolved through the generated tokens.
enum Expected {
    static func color(_ fill: QuireFill, over surface: QuireColorToken, _ mode: QuireMode) -> RGBA {
        TokenResolver.resolveStack([surface.rawValue] + fill.stack.map(\.rawValue), mode)
    }

    static func color(_ token: QuireColorToken, over surface: QuireColorToken, _ mode: QuireMode) -> RGBA {
        TokenResolver.resolveStack([surface.rawValue, token.rawValue], mode)
    }
}

/// Colour comparison with a small tolerance: renders go through colour management and 8-bit quantisation.
func XCTAssertColor(_ actual: RGBA, _ expected: RGBA, tolerance: Double = 2.5 / 255, _ message: String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    let d = max(abs(actual.r - expected.r), abs(actual.g - expected.g), abs(actual.b - expected.b))
    XCTAssert(d <= tolerance, "\(ColorLib.rgb2hex(actual)) is not \(ColorLib.rgb2hex(expected)) (Δ \(Int((d * 255).rounded()))) \(message)",
              file: file, line: line)
}

/// Collects the frames of tagged views, in the hosting view's coordinates (top-left origin), so layout tests
/// can measure positions as the spec states them.
@MainActor
final class FrameRecorder {
    nonisolated static let space = "quire.host"

    private(set) var frames: [String: CGRect] = [:]

    subscript(name: String) -> CGRect {
        guard let frame = frames[name] else {
            XCTFail("no frame recorded for \(name)")
            return .zero
        }
        return frame
    }

    func record(_ name: String, _ frame: CGRect) {
        frames[name] = frame
    }
}

extension View {
    /// Records this view's frame under `name`.
    func recordFrame(_ name: String, in recorder: FrameRecorder) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(FrameRecorder.space))
        } action: { frame in
            MainActor.assumeIsolated { recorder.record(name, frame) }
        }
    }
}

extension QuireEnvironment.Overrides {
    /// Defaults pinned, Increase Contrast as `mode` asks.
    static func pinned(_ mode: QuireMode, graphite: Bool = false) -> QuireEnvironment.Overrides {
        QuireEnvironment.Overrides(isGraphite: graphite, increaseContrast: mode.isIncreasedContrast, reduceMotion: false,
                                   reduceTransparency: false)
    }
}
