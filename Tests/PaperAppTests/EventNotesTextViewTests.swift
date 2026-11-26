import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// The notes' text view (spec §5.54): nothing in it is ever detected, substituted or previewed, its menu holds Copy,
/// Copy Link and Open Link alone, and a link's click goes to the opener.
@MainActor
final class EventNotesTextViewTests: XCTestCase {
    private func view() -> EventNotesTextView {
        let view = EventNotesTextView()
        view.frame = NSRect(x: 0, y: 0, width: 272, height: 200)
        view.show(EventNotes(text: "Menu: https://menu.example.test/ or call", links: [
            .init(location: 6, length: 25, url: "https://menu.example.test/"),
        ]))
        return view
    }

    func testDetectionAndSubstitutionsAreOffAndCannotBeTurnedOn() {
        let notes = view()
        XCTAssertFalse(notes.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(notes.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(notes.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(notes.isEditable)
        XCTAssertFalse(notes.usesFindBar)
        notes.toggleAutomaticLinkDetection(nil)
        notes.toggleAutomaticDataDetection(nil)
        XCTAssertFalse(notes.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(notes.isAutomaticDataDetectionEnabled)
        let item = NSMenuItem(title: "Data Detectors", action: #selector(NSTextView.toggleAutomaticDataDetection(_:)), keyEquivalent: "")
        XCTAssertFalse(notes.validateUserInterfaceItem(item))
        notes.quickLook(with: NSEvent())
    }

    func testOnlyTheStoredRangesAreLinksAndAClickGoesToTheOpener() throws {
        let notes = view()
        var opened: [URL] = []
        notes.onLink = { opened.append($0) }
        let storage = try XCTUnwrap(notes.textStorage)
        XCTAssertNotNil(storage.attribute(.link, at: 10, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.link, at: 2, effectiveRange: nil))
        XCTAssertTrue(notes.textView(notes, clickedOnLink: URL(string: "https://menu.example.test/")!, at: 10))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://menu.example.test/"])
    }

    func testTheMenuHoldsCopyAndOverALinkCopyLinkAndOpenLink() throws {
        let notes = view()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 220), styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(notes)
        let plain = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: notes.convert(NSPoint(x: 2, y: 190), to: nil),
                                                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertEqual(notes.menu(for: plain)?.items.map(\.title), ["Copy"])
        let manager = try XCTUnwrap(notes.layoutManager)
        let glyph = manager.glyphIndexForCharacter(at: 10)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: try XCTUnwrap(notes.textContainer))
        let onLink = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: notes.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                                                     modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertEqual(notes.menu(for: onLink)?.items.map(\.title), ["Copy", "Copy Link", "Open Link"])
    }
}
