import AppKit
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The name under the welcome screen's mark (spec §5.39, docs/brand): the drawn wordmark, never the name set in a font;
/// the greeting “Welcome to SuperSparrow” lives on only as what VoiceOver says the screen is.
@MainActor
final class WelcomeWordmarkTests: XCTestCase {
    private func welcomeView() throws -> NSView {
        let welcome = WelcomeViewController()
        welcome.loadViewIfNeeded()
        welcome.view.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
        welcome.view.layoutSubtreeIfNeeded()
        return welcome.view
    }

    private func descendants<T: NSView>(_ type: T.Type, of view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, of: $0) }
    }

    func testTheWordmarkSitsUnderTheMarkAndNoTextSetsTheName() throws {
        let view = try welcomeView()
        let wordmark = try XCTUnwrap(descendants(WelcomeWordmarkView.self, of: view).first)
        let mark = try XCTUnwrap(descendants(WelcomeMarkView.self, of: view).first)
        XCTAssertEqual(wordmark.frame.minY, mark.frame.maxY + Quire.Layout.Welcome.titleGap, "titleGap below the mark")
        XCTAssertEqual(wordmark.frame.midX, view.bounds.midX, accuracy: 0.5, "centred under the mark")
        for field in descendants(NSTextField.self, of: view) {
            XCTAssertFalse(field.stringValue.contains("SuperSparrow"), "the name is drawn, never set in a font: \(field.stringValue)")
        }
        XCTAssertEqual(wordmark.accessibilityRole(), .image)
        XCTAssertEqual(wordmark.accessibilityLabel(), "SuperSparrow")
        XCTAssertEqual(view.accessibilityLabel(), "Welcome to SuperSparrow", "the greeting is the screen's description")
    }

    /// Its frame is the word from the cap height to the descender at `wordmarkCap`, the baseline on a whole point; the caps
    /// reach exactly `wordmarkCap` above it and the ink is centred across.
    func testTheWordmarkDrawsAtItsCapHeightOnAWholePointBaseline() throws {
        let cap = Quire.Layout.Welcome.wordmarkCap
        let scale = cap / Quire.Layout.Brand.capHeight
        XCTAssertEqual(WelcomeWordmarkView.baseline, WelcomeWordmarkView.baseline.rounded(), "baseline on a whole point")
        XCTAssertGreaterThanOrEqual(WelcomeWordmarkView.baseline, -Quire.Layout.Brand.Wordmark.top * scale, "the caps fit")
        let wordmark = WelcomeWordmarkView(frame: .zero)
        let size = wordmark.intrinsicContentSize
        wordmark.frame = NSRect(origin: .zero, size: size)
        wordmark.appearance = NSAppearance(named: .aqua)
        XCTAssertGreaterThanOrEqual(size.height - WelcomeWordmarkView.baseline, Quire.Layout.Brand.Wordmark.bottom * scale, "the descender fits")

        // Rendered at 2×: the rows and columns that carry ink.
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        wordmark.cacheDisplay(in: wordmark.bounds, to: rep)
        var rows: [Int] = [], columns: [Int] = []
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { rows.append(y); columns.append(x) } }
        let top = try XCTUnwrap(rows.min()), left = try XCTUnwrap(columns.min()), right = try XCTUnwrap(columns.max())
        // The straight-edged caps have no overshoot: the frame's top is the cap height.
        XCTAssertEqual(Quire.Layout.Brand.Wordmark.top, -Quire.Layout.Brand.capHeight)
        XCTAssertEqual(CGFloat(top) / 2, WelcomeWordmarkView.baseline - cap, accuracy: 0.5, "the caps reach wordmarkCap")
        XCTAssertEqual(CGFloat(left) / 2, size.width - CGFloat(right + 1) / 2, accuracy: 1, "the ink is centred")
        XCTAssertGreaterThan(rows.count, 2000, "it inks")
    }

    /// The mark and the wordmark are the brand's black and white (§4.11, docs/brand): every pixel they cover fully is
    /// exactly `layout.brand.ink` on a light page and `layout.brand.paper` on a dark one, in every theme, under Increase
    /// Contrast and under Graphite, so no theme's `ink` tints them; and each holds at least 15:1 on that theme's paper.
    func testTheMarkAndTheWordmarkAreTheBrandsBlackAndWhiteInEveryTheme() throws {
        let environment = QuireEnvironment.shared
        let saved = environment.overrides
        defer { environment.setOverrides(saved) }
        let wordmarkSize = WelcomeWordmarkView(frame: .zero).intrinsicContentSize
        let mark = Quire.Layout.Welcome.mark
        for mode in QuireMode.allCases {
            let want = mode.isDark ? Quire.Layout.Brand.paper : Quire.Layout.Brand.ink
            for theme in QuireTheme.allCases {
                for graphite in [false, true] {
                    environment.setOverrides(.init(isGraphite: graphite, increaseContrast: mode.isIncreasedContrast,
                                                   reduceMotion: false, reduceTransparency: false, theme: theme))
                    let label = "\(theme) \(mode.rawValue)\(graphite ? " Graphite" : "")"
                    for (name, build) in [("mark", { WelcomeMarkView(frame: NSRect(x: 0, y: 0, width: mark, height: mark)) as NSView }),
                                          ("wordmark", { WelcomeWordmarkView(frame: NSRect(origin: .zero, size: wordmarkSize)) as NSView })] {
                        let rep = try XCTUnwrap(QuireOffscreenRenderer.render(mode: mode, scale: 2, build: build), "\(label): \(name)")
                        let (solid, colours) = try opaqueColours(rep)
                        XCTAssertGreaterThan(solid, 500, "\(label): the \(name) inks")
                        XCTAssertEqual(colours, [want], "\(label): the \(name) is \(want) and nothing else")
                    }
                    let paper = mode.performAsCurrent { NSColor.qPaper.usingColorSpace(.sRGB) }
                    XCTAssertGreaterThanOrEqual(contrast(want, try XCTUnwrap(paper)), 15, "\(label): on paper")
                }
            }
        }
    }

    /// The pixels `rep` covers fully, counted, and their colours as `#RRGGBB`.
    private func opaqueColours(_ rep: NSBitmapImageRep) throws -> (Int, Set<String>) {
        let data = try XCTUnwrap(rep.bitmapData)
        XCTAssertEqual(rep.samplesPerPixel, 4)
        XCTAssertFalse(rep.bitmapFormat.contains(.alphaFirst))
        var count = 0, colours = Set<String>()
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let p = data + y * rep.bytesPerRow + x * 4
                guard p[3] == 255 else { continue }
                count += 1
                colours.insert(String(format: "#%02X%02X%02X", p[0], p[1], p[2]))
            }
        }
        return (count, colours)
    }

    /// WCAG 2 contrast between `#RRGGBB` and an sRGB colour.
    private func contrast(_ hex: String, _ background: NSColor) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat { 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) }
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        let a = luminance(CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
        let b = luminance(background.redComponent, background.greenComponent, background.blueComponent)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The welcome screen in Light and Dark, for looking at (`welcome-<light|dark>.png` in `SS_RENDER_DIR`, the temporary
    /// folder when unset):
    ///
    ///     SS_UI_TESTS=1 SS_RENDER_DIR=<dir> swift test --filter WelcomeWordmarkTests
    func testRenderTheWelcomeScreen() throws {
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else { throw XCTSkip("set SS_UI_TESTS=1 to render the welcome screen") }
        let output = ProcessInfo.processInfo.environment["SS_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = try welcomeView()
            view.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("welcome-\(name).png"))
        }
    }
}
