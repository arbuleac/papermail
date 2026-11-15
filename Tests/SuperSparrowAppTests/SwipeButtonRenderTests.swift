import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// What AppKit draws for the list's swipe buttons (spec §5.7, Swipe), on a real swipe of a row in the main window, and
/// a board of both buttons in every theme, mode and under Graphite, `swipe-buttons.png`, written to `SS_RENDER_DIR`
/// (the temporary folder when unset). Opt-in, because it shows the window on a screen (invisible, and taking no clicks)
/// and writes a file: `SS_UI_TESTS=1 SS_RENDER_DIR=<dir> swift test --filter SwipeButtonRenderTests`.
///
/// The design rests on what this observes on macOS 26 and later: the button is a capsule whose layer takes the
/// action's `backgroundColor` as it is, with the title inside it in white; the title's colour is not the app's to set,
/// so the fills are chosen for white (`onSwipe`). If AppKit ever draws the title in another colour, moves it out of
/// the capsule or stops following the live fill, this fails and §5.7 needs another look.
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

    func testAppKitDrawsEachButtonInItsColoursAndFollowsTheThemeWhileOut() throws {
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else {
            throw XCTSkip("set SS_UI_TESTS=1 to swipe a row and render its buttons")
        }
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled, let screen = NSScreen.screens.first else {
            throw XCTSkip("this Mac tracks no swipe from scroll events, or has no screen")
        }
        let environment = QuireEnvironment.shared
        let saved = environment.overrides
        defer { environment.setOverrides(saved) }
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        // AppKit tracks a swipe only in a window on a screen; at the screen's origin, a point in the window is the same
        // point on the screen, which is where an event made without a window says it happened.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(screen.frame.origin)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        harness.spin { window.isVisible }

        let list = harness.list
        let index = 1
        let summary = list.conversations[index]
        XCTAssertEqual(summary.unreadCount, 0, "a read row: Archive and Mark as Unread")
        // One edge is out at a time, so each is swiped open and then taken through every theme, mode and Graphite while
        // it is out. Nothing here marks the button: AppKit fills its capsule again only when that view is marked or the
        // appearance changes, so what keeps it in step is the app's own redraw on each change, which this holds.
        var board = [[(paper: CGColor, image: CGImage)]](repeating: [], count: variants.count)
        for (edge, style, title) in [(NSTableView.RowActionEdge.trailing, QuireSwipeAction.archive, "Archive"),
                                     (.leading, .readState, "Mark as Unread")] {
            environment.setOverrides(saved)
            window.appearance = nil
            let row = try XCTUnwrap(list.layout.row(ofConversation: index))
            let (button, capsule, label) = try reveal(edge, row: row, title: title, in: list.tableView)
            XCTAssertEqual(rgb(label.textColor), "#FFFFFF", "\(title): AppKit's title is white, onSwipe")
            XCTAssertTrue(label.frame.intersects(try XCTUnwrap(capsuleFrame(capsule, in: button))),
                          "\(title): the title sits on the capsule, so its ratio is the fill's")
            func expect(_ mode: QuireMode, _ name: String) throws {
                window.displayIfNeeded()
                let want = resolved(style.fill, mode)
                // AppKit fills the capsule on its next pass after the change.
                ListTestSupport.spin(until: { capsule.backgroundColor.map(rgb) == rgb(want) }, timeout: 1)
                XCTAssertEqual(rgb(try XCTUnwrap(capsule.backgroundColor, name)), rgb(want), name)
                XCTAssertEqual(rgb(label.textColor), "#FFFFFF", name)
            }
            for (line, variant) in variants.enumerated() {
                for theme in QuireTheme.allCases {
                    environment.setOverrides(.init(isGraphite: variant.graphite, increaseContrast: variant.mode.isIncreasedContrast,
                                                   reduceMotion: false, reduceTransparency: false, theme: theme))
                    window.appearance = variant.mode.appearance
                    try expect(variant.mode, "\(title) in \(theme) \(variant.name)")
                    board[line].append((resolved(.qPaper, variant.mode), try snapshot(button)))
                }
            }
            // Graphite and Increase Contrast alone, in one theme and appearance: neither is a theme switch, whose sweep
            // marks every view, nor an appearance change, which AppKit redraws for on its own.
            for (plain, increased) in [(QuireMode.light, QuireMode.lightHC), (.dark, .darkHC)] {
                window.appearance = plain.appearance
                for (graphite, contrast) in [(false, false), (true, false), (true, true), (false, true), (false, false)] {
                    environment.setOverrides(.init(isGraphite: graphite, increaseContrast: contrast, reduceMotion: false,
                                                   reduceTransparency: false, theme: .rain))
                    let mode = contrast ? increased : plain
                    try expect(mode, "\(title) in Rain \(mode.rawValue)\(graphite ? " under Graphite" : ""), the theme and appearance kept")
                }
            }
        }
        // Archive and Mark as Unread side by side in each theme.
        let themes = QuireTheme.allCases.count
        board = board.map { line in (0..<themes).flatMap { [line[$0], line[themes + $0]] } }
        try write(board)
    }

    // MARK: Swipe

    /// The start of a two-finger swipe over `row`, as the trackpad sends it: a continuous sideways scroll in its began
    /// phase, which the table answers by asking its delegate for that edge's buttons and laying them out.
    private func reveal(_ edge: NSTableView.RowActionEdge, row: Int, title: String,
                        in tableView: NSTableView) throws -> (NSView, CALayer, NSTextField) {
        tableView.rowActionsVisible = false
        ListTestSupport.spin(for: 0.3)
        let rect = tableView.rect(ofRow: row)
        let point = tableView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let screenHeight = try XCTUnwrap(NSScreen.screens.first).frame.height
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0,
                                          wheel2: edge == .trailing ? 8 : -8, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        event.location = CGPoint(x: point.x, y: screenHeight - point.y)
        tableView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        ListTestSupport.spin(until: { tableView.rowActionsVisible }, timeout: 2)
        XCTAssertTrue(tableView.rowActionsVisible, "\(title): the swipe uncovers its button")
        let rowView = try XCTUnwrap(tableView.rowView(atRow: row, makeIfNecessary: false))
        let button = try XCTUnwrap(descendants(of: rowView).first {
            $0 is NSControl && !($0 is ConversationCellView) && $0.accessibilityLabel() == title
        }, "\(title): AppKit's button, named by the action's title for VoiceOver")
        // AppKit fades the button in as the fingers carry the row; this swipe never moves, so it is shown for the board.
        button.alphaValue = 1
        func filled() -> CALayer? { descendants(of: button).compactMap(\.layer).first { $0.backgroundColor != nil } }
        markNeedsDisplay(button)
        tableView.window?.displayIfNeeded()
        ListTestSupport.spin(until: { filled() != nil }, timeout: 2)
        let capsule = try XCTUnwrap(filled(), "\(title): the capsule AppKit fills with the action's backgroundColor")
        let label = try XCTUnwrap(descendants(of: button).compactMap { $0 as? NSTextField }.first { $0.stringValue == title },
                                  "\(title): AppKit's title")
        return (button, capsule, label)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func capsuleFrame(_ capsule: CALayer, in button: NSView) -> NSRect? {
        descendants(of: button).first { $0.layer === capsule }.map { button.convert($0.bounds, from: $0) }
    }

    private func markNeedsDisplay(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(markNeedsDisplay)
    }

    // MARK: Colours

    private func resolved(_ color: NSColor, _ mode: QuireMode) -> CGColor {
        mode.performAsCurrent { color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor }
    }

    private func rgb(_ color: NSColor?) -> String {
        guard let c = color?.usingColorSpace(.sRGB) else { return "none" }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    private func rgb(_ color: CGColor) -> String { rgb(NSColor(cgColor: color)) }

    // MARK: Board

    private func snapshot(_ view: NSView) throws -> CGImage {
        let layer = try XCTUnwrap(view.layer)
        let size = view.bounds.size
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        // A bitmap context's origin is at the bottom; AppKit's button lays out its layers from the top.
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        return try XCTUnwrap(context.makeImage())
    }

    /// One line per variant, one cell per theme and button, each on the theme's paper in that mode.
    private func write(_ board: [[(paper: CGColor, image: CGImage)]]) throws {
        let cell = CGSize(width: 220, height: 84)
        let columns = board.map(\.count).max() ?? 0
        let size = CGSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(board.count))
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        for (r, line) in board.enumerated() {
            for (c, entry) in line.enumerated() {
                let origin = CGPoint(x: CGFloat(c) * cell.width, y: size.height - CGFloat(r + 1) * cell.height)
                context.setFillColor(entry.paper)
                context.fill(CGRect(origin: origin, size: cell))
                let w = CGFloat(entry.image.width) / 2, h = CGFloat(entry.image.height) / 2
                context.draw(entry.image, in: CGRect(x: origin.x + (cell.width - w) / 2, y: origin.y + (cell.height - h) / 2, width: w, height: h))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = ProcessInfo.processInfo.environment["SS_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("swipe-buttons.png"))
    }
}
