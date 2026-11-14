import AppKit
import XCTest
@testable import SSDesign

/// The find bar of Find in conversation (spec §5.19a, `layout.findBar`): its metrics, colours in every mode, the keys
/// its field answers, its buttons' state, and what VoiceOver hears.
@MainActor
final class FindBarTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireAccessibility.observer = nil
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    func testMetrics() {
        let bar = QuireFindBar()
        bar.layoutSubtreeIfNeeded()
        let f = Quire.Layout.FindBar.self
        XCTAssertEqual(bar.frame.size, NSSize(width: 320, height: 40))
        XCTAssertEqual(bar.surfaceView.cornerRadius, f.radius)
        XCTAssertEqual(bar.surfaceView.elevation, Quire.Elevation.e2)
        // Field 6 pt in, 28 pt high and centred; three 24 pt buttons 2 pt apart, 6 pt after it, ending 6 pt from the edge.
        XCTAssertEqual(bar.fieldRect, NSRect(x: 6, y: 6, width: 226, height: 28))
        let buttons = [bar.previousButton, bar.nextButton, bar.closeButton].map { $0.alignmentRect(forFrame: $0.frame) }
        XCTAssertEqual(buttons.map(\.minX), [238, 264, 290])
        XCTAssertEqual(buttons.last?.maxX, 320 - f.pad)
        XCTAssertTrue(buttons.allSatisfy { $0.size == NSSize(width: 24, height: 24) && $0.midY == 20 })
        XCTAssertEqual([bar.previousButton, bar.nextButton, bar.closeButton].map(\.symbolName), ["chevron.up", "chevron.down", "xmark"])
        XCTAssertEqual(bar.textField.placeholderAttributedString?.string, "Find in conversation")
    }

    func testColoursInEveryMode() {
        for mode in QuireMode.allCases {
            let bar = QuireFindBar()
            let snapshot = ComponentSnapshot.render(bar, mode: mode, surface: .qCanvas, padding: 20)
            XCTAssertTrue(snapshot.matches(expected("raised", mode: mode), at: NSPoint(x: 20 + 234.5, y: 20 + 3)), "\(mode) raised panel")
            XCTAssertTrue(snapshot.matches(expected("sheet", mode: mode), at: NSPoint(x: 20 + 200, y: 20 + 8)), "\(mode) sheet field")
            XCTAssertTrue(snapshot.matches(expected("ruleStrong", mode: mode), at: NSPoint(x: 20 + 120, y: 20 + 6.25)),
                          "\(mode) the field's ruleStrong edge: \(snapshot.hex(at: NSPoint(x: 20 + 120, y: 20 + 6.25)))")
            if mode.isIncreasedContrast {
                XCTAssertTrue(snapshot.matches(expected("ruleStrong", mode: mode), at: NSPoint(x: 20 + 160, y: 20.25)),
                              "\(mode) the panel's ruleStrong edge")
            }
        }
    }

    func testTheButtonsWaitForMatchesAndSayWhatTheyDo() {
        let bar = QuireFindBar()
        XCTAssertFalse(bar.previousButton.isEnabled)
        XCTAssertFalse(bar.nextButton.isEnabled)
        XCTAssertTrue(bar.closeButton.isEnabled)
        bar.hasMatches = true
        XCTAssertTrue(bar.previousButton.isEnabled)
        XCTAssertTrue(bar.nextButton.isEnabled)
        XCTAssertEqual(bar.previousButton.accessibilityLabel(), "Previous Match")
        XCTAssertEqual(bar.nextButton.accessibilityLabel(), "Next Match")
        XCTAssertEqual(bar.closeButton.accessibilityLabel(), "Close")
        XCTAssertEqual(bar.previousButton.toolTip, "Previous Match  ⇧⌘G")
        XCTAssertEqual(bar.nextButton.toolTip, "Next Match  ⌘G")
        XCTAssertEqual(bar.closeButton.toolTip, "Close  esc")
        var calls: [String] = []
        bar.onNext = { calls.append("next") }
        bar.onPrevious = { calls.append("previous") }
        bar.onClose = { calls.append("close") }
        bar.nextButton.performClick(nil)
        bar.previousButton.performClick(nil)
        bar.closeButton.performClick(nil)
        XCTAssertEqual(calls, ["next", "previous", "close"])
        XCTAssertEqual(bar.accessibilityRole(), .group)
        XCTAssertEqual(bar.accessibilityLabel(), "Find in conversation")
        XCTAssertEqual(bar.textField.accessibilityLabel(), "Find in conversation")
    }

    func testTheFieldAnswersReturnAndEscAndReportsTyping() throws {
        let bar = QuireFindBar()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 100), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(bar)
        defer { window.close() }
        var calls: [String] = []
        bar.onQueryChange = { calls.append("query:" + $0) }
        bar.onNext = { calls.append("next") }
        bar.onClose = { calls.append("close") }
        bar.focus()
        XCTAssertTrue(bar.isEditing)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("lisbon", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(calls, ["query:lisbon", "next", "close"])
        XCTAssertEqual(bar.query, "lisbon")
    }

    func testTheCountShowsBesideTheQueryAndIsAnnounced() throws {
        let bar = QuireFindBar()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 100), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(bar)
        defer { window.close() }
        var spoken: [String] = []
        QuireAccessibility.observer = { _, text in if let text { spoken.append(text) } }
        bar.countText = "3 of 12"
        XCTAssertNil(bar.countShown, "no query, no count")
        bar.query = "lisbon"
        XCTAssertEqual(bar.countShown, "3 of 12")
        XCTAssertEqual(spoken, [], "nobody is in the field to hear it")
        bar.focus()
        bar.announcement = "Match 4 of 12"
        bar.countText = "4 of 12"
        XCTAssertEqual(spoken, ["Match 4 of 12"], "the owner's words when it gives them")
        bar.announcement = nil
        bar.countText = "1 of 1"
        XCTAssertEqual(spoken, ["Match 4 of 12", "1 of 1"], "the count itself otherwise")
        // The query truncates before the count does.
        bar.layoutSubtreeIfNeeded()
        let field = bar.textField.convert(bar.textField.bounds, to: bar)
        XCTAssertLessThan(field.maxX, bar.fieldRect.maxX - 30)
    }
}
