import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The pointer over the reader's own AppKit chrome (spec §4.17): the header's actions show the pointing hand over their
/// hit rects and the arrow while disabled, and AppKit is asked again whenever a selection shows, hides, enables or
/// disables one; the find bar lies over the page and shows the arrow around its controls, so the hand of a link under it
/// never shows through. The page's own pointers are WebKit's (`ConversationShellPointerTests`).
@MainActor
final class ReaderPointerTests: XCTestCase {
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
}
