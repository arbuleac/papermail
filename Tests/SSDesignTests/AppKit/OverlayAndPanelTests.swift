import AppKit
import XCTest
@testable import SSDesign

/// The undo-send panel (§5.31), the g-sequence HUD and the cheat-sheet overlay (§5.32): metrics, states,
/// content from `cheatSheetContent`, keys and colours.
@MainActor
final class OverlayAndPanelTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    // MARK: Undo panel

    func testUndoPanelMetricsAndCountingState() {
        let panel = QuireUndoPanelView(summary: "Re: Contoso rollout · to Ben Carter")
        XCTAssertEqual(panel.frame.size, NSSize(width: 280, height: 52))
        XCTAssertEqual(panel.surfaceRadius, 12)
        XCTAssertEqual(panel.surfaceElevation, Quire.Elevation.e3)
        panel.startCountdown(5, remaining: 3.9)
        panel.isCountdownPaused = true
        XCTAssertEqual(panel.state, .counting(secondsLeft: 4), "whole seconds, counted up")
        XCTAssertEqual(panel.state.title, "Sending in 4 s")
        XCTAssertFalse(panel.countdownContrail.isHidden)
        XCTAssertEqual(panel.countdownContrail.mode, .countdown(duration: 5, remaining: 3.9))
        let action = try! XCTUnwrap(panel.actionButton)
        XCTAssertEqual(action.title, "Undo")
        XCTAssertEqual(action.keycap, "⌘Z")
        XCTAssertTrue(action.showsRestingOutline, "no divider, so the outline says “button”")
        panel.layoutSubtreeIfNeeded()
        let visual = action.alignmentRect(forFrame: action.frame)
        XCTAssertEqual(visual.maxX, 280 - Quire.Layout.UndoPanel.padRight)
        XCTAssertEqual(visual.height, Quire.Layout.UndoPanel.action)
        XCTAssertEqual(visual.midY, 26, accuracy: 0.5)
        panel.ownsUndoKey = false
        XCTAssertNil(panel.actionButton?.keycap, "a newer toast took ⌘Z: the keycap hides, the click still works")
        XCTAssertEqual(QuireUndoPanelView.shadowMargins.top, 32)
        XCTAssertEqual(QuireUndoPanelView.shadowMargins.bottom, 68)
        XCTAssertEqual(QuireUndoPanelView.shadowMargins.left, 48)
    }

    func testUndoPanelStates() {
        let panel = QuireUndoPanelView(summary: "Re: Lunch · to Maya Singh")
        panel.state = .sending
        XCTAssertNil(panel.actionButton, "sending has no action")
        XCTAssertNil(panel.state.symbolName, "the spinner takes the glyph's place")
        XCTAssertEqual(panel.state.title, "Sending…")
        panel.state = .sent
        XCTAssertEqual(panel.state.symbolName, Quire.Icon.upToDate)
        XCTAssertEqual(panel.accessibilityLabel(), "Sent. Re: Lunch · to Maya Singh.")
        panel.state = .undoTooLate
        XCTAssertEqual(panel.accessibilityLabel(), "Already sent. Undo came after the message left.")
        panel.state = .failed
        XCTAssertEqual(panel.actionButton?.title, "Open draft")
        XCTAssertNil(panel.actionButton?.keycap)
        XCTAssertEqual(panel.state.symbolName, Quire.Icon.error)
        var clicked: [QuireUndoPanelView.State] = []
        panel.onAction = { clicked.append($0) }
        panel.actionButton?.performClick(nil)
        XCTAssertEqual(clicked, [.failed])
        XCTAssertEqual(QuireUndoPanelView.wholeSeconds(4.2), 5)
        XCTAssertEqual(QuireUndoPanelView.wholeSeconds(4.0), 4)
        XCTAssertEqual(QuireUndoPanelView.wholeSeconds(0), 0)
    }

    func testUndoPanelColours() {
        for mode in [QuireMode.light, .dark, .lightHC, .darkHC] {
            let panel = QuireUndoPanelView(state: .sent, summary: "Re: Lunch")
            let snapshot = ComponentSnapshot.render(panel, mode: mode, surface: .qPaper, padding: 20)
            XCTAssertTrue(snapshot.matches(expected("slip", mode: mode), at: NSPoint(x: 20 + 200, y: 20 + 40)), "\(mode) slip fill")
            // slipEdge is translucent white over the slip (clear in light appearances).
            XCTAssertTrue(snapshot.matches(expected("slip", "slipEdge", mode: mode), at: NSPoint(x: 20 + 140, y: 20.25)),
                          "\(mode) slipEdge: \(snapshot.hex(at: NSPoint(x: 20 + 140, y: 20.25)))")
        }
    }

    // MARK: HUD

    func testHUDRowsComeFromTheCheatSheet() {
        let rows = QuireSequenceHUDView.sequenceRows()
        XCTAssertEqual(rows.map(\.keys), ["I", "L", "S", "T", "D", "#", "A"])
        XCTAssertEqual(rows.map(\.label), ["Inbox", "Later", "Starred", "Sent", "Drafts", "Trash", "All Mail"])
        let hud = QuireSequenceHUDView()
        XCTAssertEqual(hud.frame.size, NSSize(width: 220, height: 212), "12 + 28 + 6 + 7 × 22 + 12, Later's row included")
        // The shell leaves Later's row out while nothing is snoozed (§5.32): the six views, 190 pt.
        let six = QuireSequenceHUDView(rows: rows.filter { $0.keys != "L" })
        XCTAssertEqual(six.frame.size, NSSize(width: 220, height: 190), "12 + 28 + 6 + 6 × 22 + 12")
        XCTAssertFalse(hud.acceptsFirstResponder, "not focusable")
        XCTAssertEqual(hud.accessibilityLabel()?.hasPrefix("Go to…"), true)
    }

    func testHUDColours() {
        for mode in [QuireMode.light, .dark] {
            let hud = QuireSequenceHUDView()
            let snapshot = ComponentSnapshot.render(hud, mode: mode, surface: .qPaper, padding: 20)
            XCTAssertTrue(snapshot.matches(expected("slip", mode: mode), at: NSPoint(x: 20 + 200, y: 20 + 100)), "\(mode) slip fill")
        }
    }

    // MARK: Cheat sheet

    func testCheatSheetPanelMetrics() {
        XCTAssertEqual(QuireCheatSheetPanel.naturalHeight(), 652, "24 + 28 + 16 + (22 + 9 × 28) + 20 + (22 + 7 × 28) + 20 + 28 + 24")
        XCTAssertEqual(QuireCheatSheetPanel.naturalHeight(searchTerms: []), 604, "no search line, no room for one")
        let bands = QuireCheatSheetPanel.bands(of: Quire.cheatSheet)
        XCTAssertEqual(bands.map { $0.map(\.title) }, [["Move", "Act", "Go"], ["Write", "Format", "View"]])
        let panel = QuireCheatSheetPanel()
        XCTAssertEqual(panel.frame.size, NSSize(width: 816, height: 652))
        XCTAssertFalse(panel.scrolls)
        panel.layoutSubtreeIfNeeded()
        let close = panel.closeButton.alignmentRect(forFrame: panel.closeButton.frame)
        XCTAssertEqual(close, NSRect(x: 816 - 16 - 24, y: 16, width: 24, height: 24), "a 24 pt close button 16 pt from the corner")
        XCTAssertEqual(panel.accessibilityLabel(), "Keyboard Shortcuts")
        XCTAssertEqual(panel.accessibilitySubrole(), .dialog)
    }

    /// The search operators' line (§5.32, §5.6): every operator the field takes, as typed, on one line that fits
    /// after the key column without truncating.
    func testTheSearchLineListsTheOperatorsAndFits() {
        XCTAssertEqual(Quire.cheatSheetSearchTitle, "Search")
        XCTAssertEqual(Quire.cheatSheetSearch, ["from:", "to:", "subject:", "is:unread", "is:read", "is:starred", "has:attachment",
                                                "before:", "after:", "in:sent", "in:trash", "\"phrase\"", "-word"])
        let c = Quire.Layout.CheatSheet.self
        let terms = Quire.cheatSheetSearch.map { QuireDraw.width(QuireDraw.line($0, .snippet, .qInk)) }
        let width = terms.reduce(0, +) + CGFloat(terms.count - 1) * c.searchTermGap
        XCTAssertLessThanOrEqual(width, c.width - 2 * c.pad - c.keyColumn, "\(width) pt of operators")
    }

    func testOverlayPlacesThePanelUnderTheHorizon() {
        let roomy = QuireCheatSheetOverlay.panelFrame(in: NSSize(width: 1280, height: 800))
        XCTAssertEqual(roomy, NSRect(x: 232, y: 92, width: 816, height: 652), "centred, top at 92, whole: 92 + 652 + 24 = 768 ≤ 800")
        let short = QuireCheatSheetOverlay.panelFrame(in: NSSize(width: 960, height: 600))
        XCTAssertEqual(short.minY, 92)
        XCTAssertEqual(short.height, 600 - 92 - 24, "at least 24 pt from the bottom; the bands scroll")
        XCTAssertEqual(short.minX, 72, "72 pt to spare on each side of the minimum window")
        let overlay = QuireCheatSheetOverlay(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        overlay.layoutSubtreeIfNeeded()
        XCTAssertTrue(overlay.panel.scrolls)
        XCTAssertEqual(overlay.scrim.frame, overlay.bounds)
    }

    func testOverlayKeys() {
        let action = QuireCheatSheetOverlay.action(forCharacters:keyCode:modifiers:)
        XCTAssertEqual(action("\u{1b}", 53, []), .dismiss, "Esc")
        XCTAssertEqual(action("?", 44, .shift), .dismiss, "? again")
        XCTAssertEqual(action("/", 44, .command), .dismiss, "⌘/ again")
        XCTAssertEqual(action("w", 13, .command), .dismiss, "⌘W")
        XCTAssertEqual(action("\t", 48, []), .focusNext)
        XCTAssertEqual(action("\u{19}", 48, .shift), .focusPrevious)
        XCTAssertEqual(action("", 125, []), .scroll(rows: 1))
        XCTAssertEqual(action("", 121, []), .scrollPage(1))
        XCTAssertEqual(action("e", 14, []), .swallow, "single keys are swallowed, so learning them is safe")
        XCTAssertEqual(action("j", 38, []), .swallow)
        var dismissed = 0
        let overlay = QuireCheatSheetOverlay(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        overlay.onDismiss = { dismissed += 1 }
        overlay.scrim.mouseDown(with: NSEvent())
        overlay.panel.closeButton.performClick(nil)
        XCTAssertEqual(dismissed, 2, "a click on the scrim and the close button dismiss")
    }

    func testOverlayMotionScalesFromTheCentreAndOnlyFadesUnderReduceMotion() {
        let t = QuireCheatSheetOverlay.scaleTransform(0.98, size: NSSize(width: 816, height: 576))
        let affine = CATransform3DGetAffineTransform(t)
        let centre = CGPoint(x: 408, y: 288).applying(affine)
        XCTAssertEqual(centre.x, 408, accuracy: 0.001)
        XCTAssertEqual(centre.y, 288, accuracy: 0.001)
        XCTAssertEqual(affine.a, 0.98, accuracy: 0.0001)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let overlay = QuireCheatSheetOverlay(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        window.contentView = overlay
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: true, reduceTransparency: false))
        overlay.present()
        XCTAssertNil(overlay.panel.layer?.animation(forKey: "quire.transform"), "Reduce Motion: fades only")
        XCTAssertNotNil(overlay.panel.layer?.animation(forKey: "quire.opacity"))
        XCTAssertTrue(window.firstResponder === overlay, "the overlay takes focus")
        Quire.Motion.finishAll()
        QuireTestEnvironment.forceDefaults()
        overlay.present()
        XCTAssertNotNil(overlay.panel.layer?.animation(forKey: "quire.transform"), "the panel scales up from 0.98")
        Quire.Motion.finishAll()
        XCTAssertTrue(CATransform3DIsIdentity(overlay.panel.layer?.transform ?? CATransform3DIdentity))
    }

    func testCheatSheetPanelColoursAndIncreasedContrastEdge() {
        for mode in QuireMode.allCases {
            let panel = QuireCheatSheetPanel()
            let snapshot = ComponentSnapshot.render(panel, mode: mode, surface: .qPaper, padding: 30)
            XCTAssertTrue(snapshot.matches(expected("raised", mode: mode), at: NSPoint(x: 30 + 400, y: 30 + 10)), "\(mode) raised fill")
            if mode.isIncreasedContrast {
                XCTAssertTrue(snapshot.matches(expected("ruleStrong", mode: mode), at: NSPoint(x: 30 + 400, y: 30.25)), "\(mode) ruleStrong edge")
            }
        }
    }
}
