import AppKit
import XCTest
@testable import PaperApp

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

    /// The day column's stops (or the week's) come after the reader's and before the shell's, both ways (§3.4, §5.54).
    func testTheCalendarsStopsComeAfterTheReadersAndBeforeTheShells() {
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                                backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        window.contentView = content
        let list = Stop(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        let reader = NSView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
        let action = Stop(frame: NSRect(x: 10, y: 250, width: 20, height: 20))
        let reply = Stop(frame: NSRect(x: 10, y: 10, width: 200, height: 20))
        reader.addSubview(action)
        reader.addSubview(reply)
        let previous = Stop(frame: NSRect(x: 410, y: 250, width: 20, height: 20))
        let timeline = Stop(frame: NSRect(x: 410, y: 10, width: 180, height: 200))
        [list, reader, previous, timeline].forEach(content.addSubview)
        window.shellKeyViews = { [list] }
        window.readerRoot = reader
        window.calendarKeyViews = { [previous, timeline] }

        window.makeFirstResponder(reply)
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === previous, "Tab from the reader's last stop goes to the column")
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === timeline)
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === list, "and from the column's last round to the shell")
        window.selectPreviousKeyView(nil)
        XCTAssertTrue(window.firstResponder === timeline, "Shift-Tab from the shell comes back to the column")
        window.makeFirstResponder(previous)
        window.selectPreviousKeyView(nil)
        XCTAssertTrue(window.firstResponder === reply, "and from the column's first to the reader's last")

        // With no calendar showing the loop is what it was.
        window.calendarKeyViews = { [] }
        window.makeFirstResponder(reply)
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === list)
    }
}
