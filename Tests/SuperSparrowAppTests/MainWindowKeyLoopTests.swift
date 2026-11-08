import AppKit
import XCTest
@testable import SuperSparrowApp

/// The window's Tab order (spec §3.4) where one shell stop lives inside another: the server row's link (§5.10) is a
/// subview of the list's table and a stop of its own after it. The stops here can always take focus, as the link can
/// with Full Keyboard Access on, which the test host has off.
@MainActor
final class MainWindowKeyLoopTests: XCTestCase {
    private final class Stop: NSView {
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
    }

    func testAStopInsideTheListIsItsOwnPlaceInTheLoop() {
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let field = Stop(), table = Stop(), link = Stop(), cell = Stop(), syncLine = Stop()
        [field, table, syncLine].forEach(content.addSubview)
        table.addSubview(link)
        table.addSubview(cell)
        window.shellKeyViews = { [field, table, link, syncLine] }

        window.makeFirstResponder(link)
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === syncLine, "Tab leaves the link for the stop after it")

        window.makeFirstResponder(link)
        window.selectPreviousKeyView(nil)
        XCTAssertTrue(window.firstResponder === table, "Shift-Tab goes back to the list")
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === link, "and Tab from the list reaches the link")

        window.makeFirstResponder(cell)
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === link, "focus elsewhere in the list counts as the list")
    }
}
