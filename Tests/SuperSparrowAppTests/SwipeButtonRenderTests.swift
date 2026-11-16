import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// What the list draws for a swipe (spec §5.7, Swipe): a row of the main window swiped open through the list's own swipe,
/// rendered as it draws on screen, in every theme, mode and under Graphite, and at the smallest and largest Text sizes in
/// both densities. Every render is held to the design: the button's fill exactly the live token over all it uncovered,
/// the icon and the label white on it, and nothing on it darker than the fill. Boards of them, `swipe-buttons.png` and
/// `swipe-buttons-sizes.png`, are written to `SS_RENDER_DIR` (the temporary folder when unset). Opt-in, because it writes
/// files: `SS_UI_TESTS=1 SS_RENDER_DIR=<dir> swift test --filter SwipeButtonRenderTests`.
@MainActor
final class SwipeButtonRenderTests: XCTestCase {
    private struct Variant {
        let mode: QuireMode
        let graphite: Bool
        let name: String
    }

    private let variants = [
        Variant(mode: .light, graphite: false, name: "Light"), Variant(mode: .dark, graphite: false, name: "Dark"),
        Variant(mode: .lightHC, graphite: false, name: "Light IC"), Variant(mode: .darkHC, graphite: false, name: "Dark IC"),
        Variant(mode: .light, graphite: true, name: "Graphite Light"), Variant(mode: .dark, graphite: true, name: "Graphite Dark"),
    ]

    private let index = 1

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else {
            throw XCTSkip("set SS_UI_TESTS=1 to swipe rows open and render them")
        }
    }

    override func tearDown() async throws {
        Quire.Motion.finishAll()
        try await super.tearDown()
    }

    func testTheListDrawsEachButtonWithAWhiteIconAndLabelInEveryThemeAndMode() throws {
        let environment = QuireEnvironment.shared
        let saved = environment.overrides
        defer { environment.setOverrides(saved) }
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        XCTAssertEqual(harness.list.conversations[index].unreadCount, 0, "a read row: Archive and Mark as Unread")

        var board: [[NSBitmapImageRep]] = []
        for variant in variants {
            var line: [NSBitmapImageRep] = []
            for theme in QuireTheme.allCases {
                environment.setOverrides(.init(isGraphite: variant.graphite, increaseContrast: variant.mode.isIncreasedContrast,
                                               reduceMotion: false, reduceTransparency: false, theme: theme))
                window.appearance = variant.mode.appearance
                for edge in [RowSwipe.Edge.trailing, .leading] {
                    line.append(try render(edge, mode: variant.mode, label: "\(theme) \(variant.name)", in: harness.list))
                }
            }
            board.append(line)
        }
        try write(board, columns: QuireTheme.allCases.count, to: "swipe-buttons.png")
    }

    /// The icon over the label fits every row the swipe can uncover: standard and compact, at the smallest and largest
    /// Text sizes, the label whole when the button is open.
    func testTheButtonFitsEveryRowHeight() throws {
        let environment = QuireEnvironment.shared
        let saved = environment.overrides
        defer { environment.setOverrides(saved) }
        // The list on its own, with settings of its own, and a host that takes its changes.
        let settings = ListTestSupport.settings()
        let (list, window) = ListTestSupport.host(store: try ListTestSupport.store(threads: 8), settings: settings)
        defer { window.close() }
        list.onRowAction = { _, _ in }
        window.appearance = QuireMode.light.appearance
        var board: [[NSBitmapImageRep]] = []
        for density in [AppSettings.ListDensity.standard, .compact] {
            settings.listDensity = density
            var line: [NSBitmapImageRep] = []
            for size in [QuireFont.TextSize.small, .default, .larger] {
                environment.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false,
                                               textSize: size, theme: .study))
                window.layoutIfNeeded()
                window.displayIfNeeded()
                XCTAssertEqual(list.rowMetrics, QuireRowMetrics(textSize: size, compact: density == .compact))
                for edge in [RowSwipe.Edge.trailing, .leading] {
                    let image = try render(edge, mode: .light, label: "\(density) at \(size)", in: list)
                    XCTAssertEqual(CGFloat(image.pixelsHigh) / 2, list.rowMetrics.height)
                    line.append(image)
                }
            }
            board.append(line)
        }
        try write(board, columns: 3, to: "swipe-buttons-sizes.png")
    }

    // MARK: One render

    /// Opens `edge`'s button on the row, renders the row as it draws and checks its pixels, then closes it.
    private func render(_ edge: RowSwipe.Edge, mode: QuireMode, label: String, in list: MessageListViewController) throws -> NSBitmapImageRep {
        let button = try list.openButton(index, edge)
        defer { list.swipe.close(animated: false) }
        let view = try list.rowView(ofConversation: index)
        let name = "\(button.title) in \(label)"
        let image = snapshot(view, mode: mode)
        let frame = button.frame
        XCTAssertEqual(frame.height, view.bounds.height, name + ": the row's full height")
        XCTAssertEqual(frame.width, abs(view.swipeOffset), name + ": all it uncovered")
        XCTAssertEqual(frame.minX, edge == .trailing ? view.bounds.width - frame.width : 0, name)

        let fill = rgba(button.kind.fill, mode)
        for corner in [NSPoint(x: frame.minX + 2, y: 2), NSPoint(x: frame.maxX - 2, y: frame.maxY - 2)] {
            XCTAssertEqual(hex(pixel(image, corner)), hex(fill), name + ": the fill, exactly")
        }
        let layout = button.currentLayout
        XCTAssertEqual(layout.labelAlpha, 1, name + ": the label shows whole")
        let icon = layout.icon.offsetBy(dx: frame.minX, dy: 0)
        let words = layout.label.offsetBy(dx: frame.minX, dy: 0)
        XCTAssertTrue(pixels(image, in: icon).contains(where: isWhite), name + ": a white icon")
        XCTAssertTrue(pixels(image, in: words).contains(where: isWhite), name + ": a white label")
        let floor = luminance(fill) - 0.004
        XCTAssertGreaterThanOrEqual(pixels(image, in: frame).map(luminance).min() ?? 0, floor, name + ": nothing darker than the fill")
        return image
    }

    // MARK: Pixels

    private struct RGB {
        var r: Double
        var g: Double
        var b: Double
    }

    /// The row as it draws, at 2×, in an sRGB bitmap read byte for byte.
    private func snapshot(_ view: NSView, mode: QuireMode) -> NSBitmapImageRep {
        let size = view.bounds.size
        let device = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let rep = device.retagging(with: .sRGB) ?? device
        rep.size = size
        mode.performAsCurrent { view.cacheDisplay(in: view.bounds, to: rep) }
        return rep
    }

    private func pixel(_ rep: NSBitmapImageRep, _ point: NSPoint) -> RGB {
        let x = min(rep.pixelsWide - 1, max(0, Int(point.x * 2)))
        let y = min(rep.pixelsHigh - 1, max(0, Int(point.y * 2)))
        guard let data = rep.bitmapData else { return RGB(r: 0, g: 0, b: 0) }
        let offset = y * rep.bytesPerRow + x * rep.samplesPerPixel
        let alpha = Double(data[offset + 3]) / 255
        func channel(_ i: Int) -> Double { alpha > 0 ? min(1, Double(data[offset + i]) / 255 / alpha) : 0 }
        return RGB(r: channel(0), g: channel(1), b: channel(2))
    }

    private func pixels(_ rep: NSBitmapImageRep, in rect: NSRect) -> [RGB] {
        var out: [RGB] = []
        var y = rect.minY + 0.25
        while y < rect.maxY {
            var x = rect.minX + 0.25
            while x < rect.maxX {
                out.append(pixel(rep, NSPoint(x: x, y: y)))
                x += 0.5
            }
            y += 0.5
        }
        return out
    }

    private func isWhite(_ c: RGB) -> Bool { c.r > 0.97 && c.g > 0.97 && c.b > 0.97 }

    private func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func rgba(_ color: NSColor, _ mode: QuireMode) -> RGB {
        let c = mode.performAsCurrent { color.usingColorSpace(.sRGB) }!
        return RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }

    private func hex(_ c: RGB) -> String {
        String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    // MARK: Board

    /// Each line one variant; each cell a theme (or a size) with its trailing button over its leading one.
    private func write(_ board: [[NSBitmapImageRep]], columns: Int, to name: String) throws {
        let gap: CGFloat = 8
        let cells = board.map { line in stride(from: 0, to: line.count, by: 2).map { Array(line[$0..<min($0 + 2, line.count)]) } }
        let cellWidth = (board.flatMap { $0 }.map { CGFloat($0.pixelsWide) / 2 }.max() ?? 0) + gap
        let lineHeights = cells.map { line in (line.map { pair in pair.map { CGFloat($0.pixelsHigh) / 2 }.reduce(0, +) }.max() ?? 0) + gap }
        let size = CGSize(width: cellWidth * CGFloat(columns) + gap, height: lineHeights.reduce(0, +) + gap)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        var top = gap
        for (l, line) in cells.enumerated() {
            for (c, pair) in line.enumerated() {
                var y = top
                for rep in pair {
                    guard let image = rep.cgImage else { continue }
                    let w = CGFloat(rep.pixelsWide) / 2, h = CGFloat(rep.pixelsHigh) / 2
                    context.draw(image, in: CGRect(x: gap + CGFloat(c) * cellWidth, y: size.height - y - h, width: w, height: h))
                    y += h
                }
            }
            top += lineHeights[l]
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = ProcessInfo.processInfo.environment["SS_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
    }
}
