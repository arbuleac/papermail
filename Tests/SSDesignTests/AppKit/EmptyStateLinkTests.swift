import AppKit
import XCTest
@testable import SSDesign

/// An empty state's link (spec §5.9, the empty search's “Search Gmail”): `accent` words in the hint that act, a button
/// to VoiceOver inside a group, and none of it for a hint without one.
@MainActor
final class EmptyStateLinkTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    private func view(_ hint: [QuireEmptyStateView.HintPart]) -> QuireEmptyStateView {
        let view = QuireEmptyStateView(sentence: "No results for “porto”", hint: hint)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        return view
    }

    func testTheLinkIsAccentWordsAtTheEndOfTheHint() throws {
        let empty = view([.text("Not on this Mac?"), .link("Search Gmail")])
        let hint = try XCTUnwrap(empty.hintString())
        XCTAssertEqual(hint.string.replacingOccurrences(of: "\u{00A0}", with: " "), "Not on this Mac? Search Gmail")
        let linkStart = (hint.string as NSString).range(of: "Search").location
        XCTAssertEqual(hint.attribute(.foregroundColor, at: linkStart, effectiveRange: nil) as? NSColor, .qAccent)
        XCTAssertEqual(hint.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .qInk3, "the words before it stay quiet")
        XCTAssertNil(hint.attribute(.underlineStyle, at: linkStart, effectiveRange: nil), "underlined on hover only, as links are")

        let rect = try XCTUnwrap(empty.linkRect)
        XCTAssertTrue(empty.bounds.contains(rect))
        XCTAssertGreaterThanOrEqual(rect.height, 24, "every pointer target is at least 24 pt tall (§4.14)")
        XCTAssertGreaterThan(rect.minX, empty.bounds.midX - 60, "it follows the words, right of centre")
    }

    func testVoiceOverMeetsAButtonThatActs() throws {
        let empty = view([.text("Couldn't search Gmail ·"), .link("Try again")])
        var pressed = 0
        empty.onLink = { pressed += 1 }
        XCTAssertEqual(empty.accessibilityRole(), .group, "a group, so VoiceOver reaches the link inside it")
        XCTAssertEqual(empty.accessibilityLabel(), "No results for “porto” Couldn't search Gmail · Try again")
        let children = try XCTUnwrap(empty.accessibilityChildren())
        XCTAssertEqual(children.count, 1)
        let link = try XCTUnwrap(children.first as? NSAccessibilityElement)
        XCTAssertEqual(link.accessibilityRole(), .button)
        XCTAssertEqual(link.accessibilityLabel(), "Try again")
        XCTAssertTrue(link.accessibilityPerformPress())
        XCTAssertEqual(pressed, 1)
        empty.performLink()
        XCTAssertEqual(pressed, 2)
    }

    func testAHintWithoutALinkStaysStaticText() {
        let empty = view([.text("Searching Gmail…")])
        var pressed = 0
        empty.onLink = { pressed += 1 }
        XCTAssertEqual(empty.accessibilityRole(), .staticText)
        XCTAssertNil(empty.accessibilityChildren())
        XCTAssertNil(empty.linkRect)
        empty.performLink()
        XCTAssertEqual(pressed, 0, "nothing to press")
    }
}
