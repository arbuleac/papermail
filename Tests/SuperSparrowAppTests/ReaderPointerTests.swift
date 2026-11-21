import AppKit
import SSCore
@testable import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The pointer over the reader's own AppKit chrome (spec §4.17). Alone in a window: the header's actions show the
/// pointing hand over their hit rects and the arrow while disabled, and AppKit is asked again whenever a selection shows,
/// hides, enables or disables one; the find bar lies over the page and shows the arrow around its controls, so the hand of
/// a link under it never shows through. In the main window, read from the cursor rects AppKit gets when it resets it: the
/// header's actions, the headline's I-beam over its own line only, and the quick reply in each of its states, one pointer
/// at every point of the bar. The page's own pointers are WebKit's (`ConversationShellPointerTests`).
@MainActor
final class ReaderPointerTests: XCTestCase {
    // MARK: The header and the find bar, alone in a window

    /// Records which views AppKit is asked to reset the cursor rects of.
    private final class RecordingWindow: NSWindow {
        var invalidated: [NSView] = []

        override func invalidateCursorRects(for view: NSView) {
            invalidated.append(view)
            super.invalidateCursorRects(for: view)
        }

        func wasInvalidated(_ view: NSView) -> Bool { invalidated.contains { $0 === view } }
    }

    private func window() -> RecordingWindow {
        let window = RecordingWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600), styleMask: [.titled],
                                     backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func header(in window: NSWindow) -> ReaderHeaderView {
        let header = ReaderHeaderView(frame: .zero)
        let host = window.contentView ?? NSView()
        host.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: host.topAnchor),
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        return header
    }

    private func show(_ context: ReaderActionSet.Context, in header: ReaderHeaderView) {
        header.apply(ReaderHeaderView.Content(kicker: nil, headline: "Engines", placeholder: "No subject", actions: .make(context)))
        header.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func one(_ view: MailboxView, replyAll: Bool) -> ReaderActionSet.Context {
        .one(view: view, inTrash: false, emptied: false, starred: false, replyAllAvailable: replyAll)
    }

    /// Every action the header shows takes the hand over its hit rect, inside the band, and Reply All, disabled with only
    /// one other person, the arrow. A draft hides the six and shows its own two, reusing the header's buttons; enabling
    /// Reply All gives it the hand back. Each change asks AppKit for the changed button's rects again.
    func testTheHeadersActionsShowTheHandAndADisabledOneTheArrow() {
        let window = window()
        defer { window.close() }
        let header = header(in: window)
        show(one(.inbox, replyAll: false), in: header)

        let buttons = header.subviews.compactMap { $0 as? QuireIconButton }
        let shown = buttons.filter { !$0.isHidden }
        XCTAssertEqual(shown.count, 6, "Star, Archive, Trash, Reply, Reply All, Forward")
        for button in shown {
            XCTAssertEqual(button.pointerRegions, [.control(button.hitRect, acts: button.isEnabled)], button.accessibilityLabel() ?? "")
            XCTAssertTrue(header.bounds.contains(header.convert(button.hitRect, from: button)), "inside the band")
        }
        XCTAssertEqual(shown.filter { !$0.isEnabled }.compactMap { $0.accessibilityLabel() }, ["Reply All"])
        let replyAll = shown.first { $0.accessibilityLabel() == "Reply All" }

        window.invalidated = []
        show(one(.drafts, replyAll: false), in: header)
        XCTAssertTrue(shown.allSatisfy { $0.isHidden && window.wasInvalidated($0) }, "the hidden actions' rects go")
        let draftActions = header.subviews.compactMap { $0 as? QuireIconButton }.filter { !$0.isHidden }
        XCTAssertEqual(draftActions.compactMap { $0.accessibilityLabel() }.sorted(), ["Continue Editing", "Discard Draft"])
        XCTAssertTrue(draftActions.allSatisfy { $0.pointerRegions.allSatisfy { $0.cursor === NSCursor.pointingHand } })

        window.invalidated = []
        show(one(.inbox, replyAll: true), in: header)
        XCTAssertTrue(shown.allSatisfy { !$0.isHidden && window.wasInvalidated($0) }, "shown again, they are asked for again")
        XCTAssertEqual(replyAll?.pointerRegions.map(\.cursor), [NSCursor.pointingHand], "Reply All reaches someone now")
    }

    /// The find bar opens above everything over the page, under the header: the arrow around its controls, the I-beam
    /// over its field, the arrow over Previous and Next while nothing matches, the hand over Close.
    func testTheFindBarOverThePageShowsTheArrowAroundItsControls() throws {
        let window = window()
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        let header = header(in: window)
        let page = NSView(frame: host.bounds)
        host.addSubview(page, positioned: .below, relativeTo: header)
        let find = ReaderFind(session: FindSession())
        find.host = host
        find.header = header
        find.open()
        host.layoutSubtreeIfNeeded()
        let bar = try XCTUnwrap(find.bar)
        XCTAssertTrue(host.subviews.last === bar, "over the page and the header")
        XCTAssertTrue(page.frame.contains(bar.frame))

        XCTAssertFalse(bar.pointerRegions.isEmpty)
        XCTAssertTrue(bar.pointerRegions.allSatisfy { $0.cursor === NSCursor.arrow })
        let controls = bar.subviews.compactMap { $0 as? QuireControl }
        XCTAssertEqual(controls.map { $0.pointerRegions.first?.cursor }, [.iBeam, .arrow, .arrow, .pointingHand])
        for control in controls {
            let area = bar.convert(control.hitRect, from: control)
            XCTAssertTrue(bar.pointerRegions.allSatisfy { $0.rect.intersection(area).isEmpty }, "the bar leaves its controls' areas to them")
        }
        find.close(returningFocus: false)
    }

    // MARK: The reader in the main window

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
        let send = try XCTUnwrap(CursorRectRecorder.descendants(of: bar, as: QuireSplitSegment.self).first { $0.kind == .action && $0.title == "Send" })
        let tabs = try XCTUnwrap(CursorRectRecorder.descendants(of: bar, as: QuireUnderlineTabs.self).first { !$0.isHidden })
        let options = try XCTUnwrap(CursorRectRecorder.descendants(of: bar, as: QuireSplitSegment.self).first { $0.kind == .menu && $0.accessibilityLabel() == "Send Options" })
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
