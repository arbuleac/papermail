import AppKit
import SSCore
@testable import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The pointer over the main window (spec §4.17), read from the cursor rects AppKit gets when it resets the window: the
/// pointing hand over everything a click acts on in the rail, the list and its header, the welcome screen and the
/// alerts AppKit makes, the arrow where a click changes nothing, the I-beam over the search field, the divider's resize
/// pointer kept, and the toast and the cheat sheet over the rest.
@MainActor
final class MainWindowPointerTests: XCTestCase {
    private func harness(accounts: Bool = true, threads: Int = 8) throws -> (MainWindowHarness, NSWindow) {
        let harness = try MainWindowHarness(threads: threads, accounts: accounts)
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.layoutIfNeeded()
        return (harness, window)
    }

    // MARK: The rail

    /// Every tile takes the hand over its 44 pt square, never its full-width frame, whose margins overlap the next tile's;
    /// the pending tile and a disabled Add take the arrow, since a click leaves them as they are.
    func testRailTilesTakeTheHandOverTheirSquaresOnly() throws {
        let (harness, window) = try harness()
        defer { harness.close() }
        let rail = harness.controller.strip
        let tiles = CursorRectRecorder.descendants(of: rail.view, as: AccountStripButton.self).filter { !$0.isHidden }
        XCTAssertGreaterThanOrEqual(tiles.count, 9, "the folders, All Inboxes and two accounts")
        var recorder = CursorRectRecorder(window)
        for tile in tiles {
            XCTAssertEqual(recorder.cursors(atCentreOf: tile.hitRect, in: tile), [.pointingHand], "\(tile.accessibilityLabel() ?? "")")
            // Beside the square, short of the divider's resize area.
            let margin = NSPoint(x: tile.hitRect.maxX + 3, y: tile.hitRect.midY)
            XCTAssertEqual(recorder.cursors(at: tile.convert(margin, to: nil)), [], "the frame's margin outside the square adds nothing")
        }
        assertDisjoint(tiles.flatMap { recorder.rects(of: $0).map(\.rect) })

        rail.setSignIn(active: true, adding: true, reconnecting: nil)
        window.layoutIfNeeded()
        let pending = try XCTUnwrap(CursorRectRecorder.descendants(of: rail.view, as: AccountStripButton.self).first { $0.content == .pending })
        let add = try XCTUnwrap(CursorRectRecorder.descendants(of: rail.view, as: QuireIconButton.self).first { $0.accessibilityLabel() == "Add Account" })
        recorder = CursorRectRecorder(window)
        XCTAssertEqual(recorder.cursors(atCentreOf: pending.hitRect, in: pending), [.arrow], "the pending tile does nothing")
        XCTAssertEqual(recorder.cursors(atCentreOf: add.hitRect, in: add), [.arrow], "Add waits while a sign-in runs")

        rail.setSignIn(active: false, adding: false, reconnecting: nil)
        window.layoutIfNeeded()
        recorder = CursorRectRecorder(window)
        XCTAssertEqual(recorder.cursors(atCentreOf: add.hitRect, in: add), [.pointingHand])
    }

    // MARK: The list header and the sync line

    /// The plain masthead is the title-bar zone's and adds nothing; as minimal mode's menu button it takes the hand. Compose
    /// and the Demo tag take the hand; the search field the I-beam over its whole face; the sync line, which opens
    /// Settings, the hand around its link, which keeps its own and takes the arrow while it waits.
    func testHeaderControlsAndTheSyncLine() throws {
        let (harness, window) = try harness()
        defer { harness.close() }
        let header = harness.controller.listPane.header
        let bar = harness.controller.listPane.statusBar
        var recorder = CursorRectRecorder(window)
        XCTAssertTrue(recorder.rects(of: header.masthead).isEmpty, "a plain title adds no region")
        XCTAssertEqual(recorder.cursors(atCentreOf: header.compose.hitRect, in: header.compose), [.pointingHand])
        XCTAssertEqual(Set(recorder.cursors(atCentreOf: header.search.hitRect, in: header.search).map(ObjectIdentifier.init)),
                       [ObjectIdentifier(NSCursor.iBeam)], "the field's face and its text both take the I-beam")
        let leading = NSRect(x: header.search.hitRect.minX + 2, y: header.search.hitRect.midY, width: 0, height: 0)
        XCTAssertEqual(recorder.cursors(atCentreOf: leading, in: header.search), [.iBeam], "the magnifier's side too")
        XCTAssertEqual(recorder.cursors(atCentreOf: bar.bounds, in: bar), [.pointingHand])

        header.masthead.isMenu = true
        header.showsDemoTag = true
        header.needsLayout = true
        window.layoutIfNeeded()
        bar.apply(SyncLineSummary(state: .error, glyph: .alert, lead: "Couldn't sync", action: .retry([]), isAlert: true))
        bar.layoutSubtreeIfNeeded()
        recorder = CursorRectRecorder(window)
        XCTAssertEqual(recorder.cursors(atCentreOf: header.masthead.hitRect, in: header.masthead), [.pointingHand])
        if !header.demoTag.isHidden {
            XCTAssertEqual(recorder.cursors(atCentreOf: header.demoTag.hitRect, in: header.demoTag), [.pointingHand])
        }
        let link = bar.actionButton
        XCTAssertFalse(link.isHidden)
        XCTAssertEqual(recorder.cursors(atCentreOf: link.hitRect, in: link), [.pointingHand], "the link alone, cut out of the line")
        XCTAssertEqual(recorder.cursors(atCentreOf: NSRect(x: 40, y: bar.bounds.midY, width: 0, height: 0), in: bar), [.pointingHand])
        assertDisjoint(recorder.rects(of: bar).map(\.rect) + recorder.rects(of: link).map(\.rect))

        bar.actionsEnabled = false
        recorder = CursorRectRecorder(window)
        XCTAssertEqual(recorder.cursors(atCentreOf: link.hitRect, in: link), [.arrow], "Retry waits while a sign-in runs")
    }

    // MARK: The list, the divider and the toast

    /// Conversation rows take the hand, running heads the arrow; the divider beside the list keeps its resize pointer
    /// alone, and the rows reach up to it.
    func testRowsTakeTheHandAndTheDividerKeepsItsResizePointer() throws {
        let (harness, window) = try harness(threads: 20)
        defer { harness.close() }
        let table = harness.list.tableView
        let recorder = CursorRectRecorder(window)
        let visible = table.rows(in: table.visibleRect)
        XCTAssertGreaterThan(visible.length, 3)
        var heads = 0
        for row in visible.location..<(visible.location + visible.length) {
            let rect = table.rect(ofRow: row).intersection(table.visibleRect)
            let isConversation = harness.list.layout.conversationIndex(atRow: row) != nil
            if !isConversation { heads += 1 }
            XCTAssertEqual(recorder.cursors(atCentreOf: rect, in: table), [isConversation ? .pointingHand : .arrow], "row \(row)")
        }
        XCTAssertGreaterThan(heads, 0, "a running head is among them")

        let row = table.rect(ofRow: visible.location + 1)
        let edge = table.convert(NSPoint(x: table.visibleRect.maxX - 0.5, y: row.midY), to: nil)
        let atDivider = recorder.cursors(at: edge)
        XCTAssertEqual(atDivider.count, 1, "the divider alone")
        XCTAssertFalse(atDivider.contains { $0 === NSCursor.pointingHand || $0 === NSCursor.arrow }, "its resize pointer")
        XCTAssertEqual(recorder.cursors(at: table.convert(NSPoint(x: table.visibleRect.maxX - 12, y: row.midY), to: nil)), [.pointingHand])
    }

    /// A toast's slip lies on the rows: over it the slip's arrow alone and over Undo its hand alone; once it has gone the
    /// rows take their hand back.
    func testAToastsSlipKeepsItsOwnPointerOverTheRows() throws {
        let (harness, window) = try harness(threads: 30)
        defer { harness.close() }
        harness.toasts.show("Archived", kind: .undoable, actionTitle: "Undo", keycap: "Z") {}
        let slip = try XCTUnwrap(harness.controller.listPane.toastView.slip)
        let undo = try XCTUnwrap(slip.actionButton)
        harness.spin { slip.alphaValue == 1 }
        window.layoutIfNeeded()
        var recorder = CursorRectRecorder(window)
        let words = NSRect(x: 30, y: slip.bounds.midY, width: 0, height: 0)
        XCTAssertEqual(recorder.cursors(atCentreOf: words, in: slip), [.arrow], "no row's hand through the slip")
        XCTAssertEqual(recorder.cursors(atCentreOf: undo.hitRect, in: undo), [.pointingHand])
        let table = harness.list.tableView
        let under = table.convert(slip.convert(NSPoint(x: words.midX, y: words.midY), to: nil), from: nil)
        XCTAssertGreaterThanOrEqual(table.row(at: under), 0, "a row lies under the slip")

        harness.toasts.dismiss()
        harness.spin { slip.superview == nil }
        recorder = CursorRectRecorder(window)
        let point = table.convert(under, to: nil)
        let expected: NSCursor = harness.list.layout.conversationIndex(atRow: table.row(at: under)) != nil ? .pointingHand : .arrow
        XCTAssertEqual(recorder.cursors(at: point), [expected])
    }

    // MARK: The cheat sheet

    /// The cheat sheet covers the window: its scrim's hand and its panel's arrow are all there is, a field's I-beam and the
    /// divider's resize pointer included. Dismissed, every control has its own again.
    func testTheCheatSheetLeavesTheWindowToItsOwnPointer() throws {
        let (harness, window) = try harness()
        defer { harness.close() }
        let controller = CheatSheetController.shared
        controller.present(in: window, animated: false)
        defer { controller.dismiss(animated: false) }
        let overlay = try XCTUnwrap(CursorRectRecorder.descendants(of: try XCTUnwrap(window.contentView), as: QuireCheatSheetOverlay.self).first)
        overlay.layoutSubtreeIfNeeded()
        var recorder = CursorRectRecorder(window)
        let header = harness.controller.listPane.header
        XCTAssertEqual(recorder.cursors(atCentreOf: header.search.hitRect, in: header.search), [.pointingHand], "the scrim, no I-beam")
        XCTAssertEqual(recorder.cursors(atCentreOf: header.compose.hitRect, in: header.compose), [.pointingHand], "the scrim's alone")
        let panel = overlay.panel
        XCTAssertEqual(recorder.cursors(atCentreOf: NSRect(x: 40, y: panel.bounds.midY, width: 0, height: 0), in: panel), [.arrow])
        XCTAssertEqual(recorder.cursors(atCentreOf: panel.closeButton.hitRect, in: panel.closeButton), [.pointingHand])
        // On the divider between the list header and the panel's top.
        let table = harness.list.tableView
        let divider = overlay.convert(table.convert(NSPoint(x: table.visibleRect.maxX - 0.5, y: 0), to: nil), from: nil)
        let edge = overlay.convert(NSPoint(x: divider.x, y: (panel.frame.minY + Quire.Layout.ListHeader.height) / 2), to: nil)
        XCTAssertEqual(recorder.cursors(at: edge), [.pointingHand], "no resize pointer under the scrim")

        controller.dismiss(animated: false)
        recorder = CursorRectRecorder(window)
        XCTAssertEqual(Set(recorder.cursors(atCentreOf: header.search.hitRect, in: header.search).map(ObjectIdentifier.init)),
                       [ObjectIdentifier(NSCursor.iBeam)])
        XCTAssertEqual(recorder.cursors(atCentreOf: header.compose.hitRect, in: header.compose), [.pointingHand])
    }

    // MARK: The welcome screen

    /// While a sign-in waits for the browser, the chosen button is loading and does nothing, the other disabled: the
    /// arrow on both, and on the setup link; Cancel takes the hand. Back at rest, every button does.
    func testWelcomeButtonsWhileASignInWaits() throws {
        let (harness, window) = try harness(accounts: false)
        defer { harness.close() }
        let welcome = try XCTUnwrap(window.contentViewController as? WelcomeViewController)
        let buttons = try XCTUnwrap((welcome.view as? WelcomeView)?.buttons)
        welcome.setActivity(.waiting(.gmail))
        window.layoutIfNeeded()
        var recorder = CursorRectRecorder(window)
        func cursor(_ button: QuireButton) -> [NSCursor] { recorder.cursors(atCentreOf: button.hitRect, in: button) }
        XCTAssertEqual(cursor(buttons.gmail), [.arrow], "loading")
        XCTAssertEqual(cursor(buttons.microsoft), [.arrow], "disabled")
        XCTAssertEqual(cursor(buttons.link), [.arrow], "disabled")
        XCTAssertEqual(cursor(buttons.demo), [.pointingHand], "Cancel")

        welcome.setActivity(.idle)
        window.layoutIfNeeded()
        recorder = CursorRectRecorder(window)
        for button in [buttons.gmail, buttons.microsoft, buttons.demo, buttons.link] {
            XCTAssertEqual(cursor(button), [.pointingHand], button.title)
        }
    }

    // MARK: What AppKit makes

    /// An alert's buttons, the Later picker's buttons and calendar take the hand from overlays that follow their
    /// `isEnabled`; the time field's stepper takes it over its own width, where AppKit draws it, and its digits do not.
    func testAlertsAndTheLaterPickerTakeTheHand() throws {
        let alert = AppAlert(title: "Remove “Work”?", body: "Its mail leaves this Mac.",
                             buttons: [.init(title: "Cancel"), .init(title: "Remove", role: .destructive)]).makeAlert()
        XCTAssertEqual(alert.buttons.count, 2)
        for button in alert.buttons {
            let overlay = try XCTUnwrap(button.subviews.compactMap { $0 as? QuirePointerOverlay }.first, button.title)
            XCTAssertEqual(overlay.pointerRegions.map(\.cursor), [.pointingHand])
        }

        let picker = LaterDatePicker(count: 1)
        picker.alert.layout()
        let snooze = try XCTUnwrap(picker.snoozeButton.subviews.compactMap { $0 as? QuirePointerOverlay }.first)
        picker.snoozeButton.isEnabled = true
        XCTAssertEqual(snooze.pointerRegions.map(\.cursor), [.pointingHand])
        picker.snoozeButton.isEnabled = false
        XCTAssertEqual(snooze.pointerRegions.map(\.cursor), [.arrow], "Snooze waits for a time ahead")
        let calendar = try XCTUnwrap(picker.calendarPicker.subviews.compactMap { $0 as? QuirePointerOverlay }.first)
        XCTAssertEqual(calendar.pointerRegions, [QuirePointerRegion(picker.calendarPicker.bounds, cursor: .pointingHand)])

        let time = picker.timePicker
        let stepper = try XCTUnwrap(time.subviews.compactMap { $0 as? QuirePointerTarget }.first { !($0 is QuirePointerOverlay) })
        XCTAssertNil(stepper.hitTest(NSPoint(x: 1, y: 1)), "clicks reach the picker")
        let region = try XCTUnwrap(stepper.pointerRegions.first)
        XCTAssertEqual(stepper.pointerRegions.count, 1)
        XCTAssertTrue(region.cursor === NSCursor.pointingHand)
        XCTAssertEqual(region.rect.maxX, time.bounds.maxX)
        XCTAssertGreaterThan(region.rect.width, 10)
        XCTAssertLessThan(region.rect.width, time.bounds.width / 2, "the digits keep the system's pointer")
        // Where AppKit says the stepper is, it takes the hand.
        let window = try XCTUnwrap(time.window, "the alert's accessory is in its window")
        let incrementor = try XCTUnwrap(incrementorFrame(of: time))
        let local = time.convert(window.convertFromScreen(incrementor), from: nil)
        XCTAssertTrue(region.rect.contains(NSPoint(x: local.midX, y: local.midY)), "\(region.rect) holds the stepper at \(local)")
        time.isEnabled = false
        XCTAssertEqual(stepper.pointerRegions.map(\.cursor), [.arrow])
    }

    // MARK: Helpers

    private func incrementorFrame(of picker: NSDatePicker) -> NSRect? {
        var queue: [Any] = [picker]
        while !queue.isEmpty {
            let element = queue.removeFirst() as AnyObject
            if (element.accessibilityRole?() as NSAccessibility.Role?) == .incrementor { return element.accessibilityFrame?() }
            queue += (element.accessibilityChildren?() as [Any]?) ?? []
        }
        return nil
    }

    private func assertDisjoint(_ rects: [NSRect], file: StaticString = #filePath, line: UInt = #line) {
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertTrue(rects[i].intersection(rects[j]).isEmpty, "\(rects[i]) overlaps \(rects[j])", file: file, line: line)
            }
        }
    }
}
