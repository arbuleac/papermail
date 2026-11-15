import AppKit
import SSCore
@testable import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The pointer over the reader's native parts (spec §4.17), read from the cursor rects AppKit gets when it resets the
/// main window: the header's actions, the headline's I-beam over its own line only, and the quick reply in each of its
/// states, one pointer at every point of the bar.
@MainActor
final class ReaderPointerTests: XCTestCase {
    private func harness() throws -> (MainWindowHarness, NSWindow) {
        let harness = try MainWindowHarness()
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.layoutIfNeeded()
        return (harness, window)
    }

    private func openThread(_ harness: MainWindowHarness) throws {
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { !harness.reader.currentMessages.isEmpty }
    }

    /// The reader header's actions take the hand and its headline the I-beam; the quick reply's field the I-beam over its
    /// whole face, keycap included, the bar around it the arrow, Send the arrow until there is something to send.
    func testTheReaderHeaderAndTheQuickReplyAtRest() throws {
        let (harness, window) = try harness()
        defer { harness.close() }
        try openThread(harness)
        let header = harness.reader.header
        let bar = harness.reader.quickReplyBar
        window.layoutIfNeeded()
        var recorder = CursorRectRecorder(window)
        let actions = CursorRectRecorder.descendants(of: header, as: QuireIconButton.self).filter { !$0.isHidden && $0.isEnabled }
        XCTAssertGreaterThanOrEqual(actions.count, 4, "Archive, Trash, Reply, Forward and the rest")
        for action in actions {
            XCTAssertEqual(recorder.cursors(atCentreOf: action.hitRect, in: action), [.pointingHand], action.accessibilityLabel() ?? "")
        }

        let rest = bar.restGeometry
        let send = try XCTUnwrap(CursorRectRecorder.descendants(of: bar, as: QuireIconButton.self).first { !$0.isHidden && $0.frame.contains(NSPoint(x: rest.send.midX, y: rest.send.midY)) })
        XCTAssertTrue(Set(recorder.cursors(atCentreOf: rest.field, in: bar).map(ObjectIdentifier.init)) == [ObjectIdentifier(NSCursor.iBeam)])
        XCTAssertEqual(recorder.cursors(atCentreOf: rest.keycap, in: bar), [.iBeam], "the R keycap is the field's")
        XCTAssertEqual(recorder.cursors(atCentreOf: rest.face, in: bar), [.iBeam], "and so is the face")
        XCTAssertEqual(recorder.cursors(atCentreOf: send.hitRect, in: send), [.arrow], "nothing to send yet")
        if rest.field.minX > 4 {
            let beside = NSRect(x: rest.field.minX / 2, y: rest.field.midY, width: 0, height: 0)
            XCTAssertEqual(recorder.cursors(atCentreOf: beside, in: bar), [.arrow], "the bar around the field, on the page")
        }

        bar.text = "Tuesday works"
        window.layoutIfNeeded()
        recorder = CursorRectRecorder(window)
        XCTAssertEqual(recorder.cursors(atCentreOf: send.hitRect, in: send), [.pointingHand])
        XCTAssertTrue(Set(recorder.cursors(atCentreOf: rest.field, in: bar).map(ObjectIdentifier.init)) == [ObjectIdentifier(NSCursor.iBeam)],
                      "the preview of the text, unfocused, is the field too")
    }

    /// Every rect lies inside its own view. A view's visible rect reaches past its bounds now that views no longer clip to
    /// them, and AppKit's own I-beam over a text view's visible rect would cover the whole reader: the page's links could
    /// not show their hand under it. The headline's I-beam is its own line.
    func testEveryRectLiesInsideItsOwnView() throws {
        let (harness, window) = try harness()
        defer { harness.close() }
        try openThread(harness)
        harness.toasts.show("Archived", kind: .undoable, actionTitle: "Undo", keycap: "Z") {}
        window.layoutIfNeeded()
        let recorder = CursorRectRecorder(window)
        XCTAssertGreaterThan(recorder.rects.count, 20)
        for rect in recorder.rects where !rect.rect.isEmpty {
            let own = rect.view.convert(rect.view.bounds, to: nil).insetBy(dx: -0.5, dy: -0.5)
            XCTAssertTrue(own.contains(rect.rect), "\(type(of: rect.view)) adds \(rect.rect) outside its \(own)")
        }
        let header = harness.reader.header
        let headline = try XCTUnwrap(recorder.rects.first { $0.cursor === NSCursor.iBeam && $0.view.isDescendant(of: header) })
        XCTAssertLessThanOrEqual(headline.rect.height, header.bounds.height, "the headline's line, not the reader")
        let page = header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.maxY + 200), to: nil)
        XCTAssertFalse(recorder.cursors(at: page).contains { $0 === NSCursor.iBeam }, "no I-beam over the page")
    }

    /// Focused, the tool row's controls take the hand (the chosen tab the arrow), the band around them the arrow, the text
    /// the I-beam; a failed send's words take the hand, as a click on them opens the composer; the countdown's strip the
    /// hand, Undo its own; while a composer holds the reply the whole field takes the hand and no I-beam is left.
    func testTheQuickReplysStates() throws {
        let (harness, window) = try harness()
        defer { harness.close() }
        try openThread(harness)
        let bar = harness.reader.quickReplyBar
        bar.text = "Tuesday works"
        bar.focus()
        XCTAssertTrue(bar.isFocused)
        settle(bar)
        var recorder = CursorRectRecorder(window)
        let send = try XCTUnwrap(CursorRectRecorder.descendants(of: bar, as: QuireButton.self).first { !$0.isHidden && $0.title == "Send" })
        let tabs = try XCTUnwrap(CursorRectRecorder.descendants(of: bar, as: QuireUnderlineTabs.self).first { !$0.isHidden })
        let options = try XCTUnwrap(CursorRectRecorder.descendants(of: bar, as: QuireIconButton.self).first { !$0.isHidden && $0.accessibilityLabel() == "Send Options" })
        XCTAssertEqual(recorder.cursors(atCentreOf: send.hitRect, in: send), [.pointingHand])
        XCTAssertEqual(recorder.cursors(atCentreOf: options.hitRect, in: options), [.pointingHand])
        XCTAssertEqual(recorder.cursors(atCentreOf: tabs.slotRect(forTab: 0), in: tabs), [.arrow], "Reply is chosen")
        XCTAssertEqual(recorder.cursors(atCentreOf: tabs.slotRect(forTab: 1), in: tabs), [.arrow], "Reply all, with one other person")
        bar.replyAllAvailable = true
        recorder = CursorRectRecorder(window)
        XCTAssertEqual(recorder.cursors(atCentreOf: tabs.slotRect(forTab: 1), in: tabs), [.pointingHand], "Reply all, with several")
        let composer = try XCTUnwrap(CursorRectRecorder.descendants(of: bar, as: QuireIconButton.self).first { !$0.isHidden && $0.accessibilityLabel() == "Open in Composer" })
        let tools = composer.convert(composer.hitRect, to: bar)
        let gap = NSRect(x: (tools.maxX + send.convert(send.hitRect, to: bar).minX) / 2, y: tools.midY, width: 0, height: 0)
        XCTAssertEqual(recorder.cursors(atCentreOf: gap, in: bar), [.arrow], "the tool row's band")
        assertOnePointerEach(recorder, over: bar)

        bar.status = .error
        settle(bar)
        recorder = CursorRectRecorder(window)
        let label = try XCTUnwrap(CursorRectRecorder.descendants(of: bar, as: NSTextField.self).first { !$0.isHidden && $0.stringValue.contains("Open in composer") })
        XCTAssertEqual(recorder.cursors(atCentreOf: label.bounds, in: label), [.pointingHand])
        bar.status = .noRecipients
        settle(bar)
        recorder = CursorRectRecorder(window)
        let quiet = try XCTUnwrap(CursorRectRecorder.descendants(of: bar, as: NSTextField.self).first { !$0.isHidden && $0.stringValue.contains("No one") })
        XCTAssertEqual(recorder.cursors(atCentreOf: quiet.bounds, in: quiet), [.arrow], "these words do nothing")
        XCTAssertTrue(CursorRectRecorder.descendants(of: bar, as: QuireButton.self).filter { !$0.isHidden && $0.title.isEmpty }.isEmpty,
                      "no empty action takes a click beside them")
        bar.status = .none

        bar.showStrip(.counting(endsAt: Date().addingTimeInterval(5), duration: 5, recipient: "Ben Carter"))
        settle(bar)
        recorder = CursorRectRecorder(window)
        let strip = try XCTUnwrap(CursorRectRecorder.descendants(of: bar, as: QuickReplyStripView.self).first { !$0.isHidden })
        let undo = try XCTUnwrap(CursorRectRecorder.descendants(of: strip, as: QuireButton.self).first { !$0.isHidden && $0.title == "Undo" })
        XCTAssertEqual(recorder.cursors(atCentreOf: NSRect(x: 60, y: strip.bounds.midY, width: 0, height: 0), in: strip), [.pointingHand])
        XCTAssertEqual(recorder.cursors(atCentreOf: undo.hitRect, in: undo), [.pointingHand])
        bar.showStrip(.sent)
        strip.layoutSubtreeIfNeeded()
        recorder = CursorRectRecorder(window)
        XCTAssertEqual(recorder.cursors(atCentreOf: NSRect(x: 60, y: strip.bounds.midY, width: 0, height: 0), in: strip), [.arrow])
        bar.hideStrip()

        bar.blur()
        bar.text = ""
        bar.isComposerOpen = true
        settle(bar)
        recorder = CursorRectRecorder(window)
        let field = bar.restGeometry.field
        XCTAssertEqual(recorder.cursors(atCentreOf: field, in: bar), [.pointingHand], "a click brings the composer forward")
        let beams = recorder.rects.filter { $0.cursor === NSCursor.iBeam && $0.view.isDescendant(of: bar) }
        XCTAssertTrue(beams.isEmpty, "the text view no longer takes the click or the I-beam: \(beams.map { type(of: $0.view) })")
    }

    // MARK: Helpers

    /// Waits for the bar's height to finish moving, then lays it out.
    private func settle(_ bar: QuickReplyView) {
        ListTestSupport.spin(until: { abs(bar.frame.height - bar.barHeight) < 0.5 }, timeout: 2)
        bar.window?.layoutIfNeeded()
        bar.layoutSubtreeIfNeeded()
    }

    /// Every point of `view`'s visible area that a rect covers has one pointer only, sampled every 4 pt.
    private func assertOnePointerEach(_ recorder: CursorRectRecorder, over view: NSView, file: StaticString = #filePath, line: UInt = #line) {
        let visible = view.visibleRect.intersection(view.bounds)
        var y = visible.minY + 1
        while y < visible.maxY {
            var x = visible.minX + 1
            while x < visible.maxX {
                let point = view.convert(NSPoint(x: x, y: y), to: nil)
                let cursors = Set(recorder.cursors(at: point).map(ObjectIdentifier.init))
                XCTAssertLessThanOrEqual(cursors.count, 1, "two pointers at \(NSPoint(x: x, y: y))", file: file, line: line)
                x += 4
            }
            y += 4
        }
    }
}
