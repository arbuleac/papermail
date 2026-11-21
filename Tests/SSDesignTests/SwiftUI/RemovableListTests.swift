import AppKit
import SwiftUI
import XCTest
@testable import SSDesign

/// `QuireRemovableList` and `QuireRuleSheet`, the Senders sheet's parts, against spec §5.40 (Sender rules (Q4.2)): 40 pt
/// rows on `sheet`, capped at eight before the group scrolls, a − per row that removes that row, and the sheet's width.
@MainActor
final class RemovableListTests: XCTestCase {
    private let s = Quire.Layout.Settings.self

    private func rows(_ count: Int) -> [QuireRemovableList.Row] {
        (0..<count).map { QuireRemovableList.Row(id: "r\($0)", title: "sender\($0)@example.test", detail: "Blocked") }
    }

    func testTheGroupCapsAtEightRows() {
        for (count, height) in [(0, 56), (1, 40), (3, 120), (8, 320), (9, 320), (20, 320)] {
            XCTAssertEqual(QuireRemovableList.height(rows: count), CGFloat(height), "\(count) rows")
        }
        for count in [0, 2, 8, 10] {
            let recorder = FrameRecorder()
            let view = QuireRemovableList(rows: rows(count), emptyTitle: "No sender rules", emptyHint: "Set one from a message's menu.",
                                          onRemove: { _ in })
                .recordFrame("list", in: recorder)
                .frame(width: 392)
            let host = SwiftUIHost(view)
            XCTAssertEqual(recorder["list"].height, QuireRemovableList.height(rows: count), accuracy: 0.5, "\(count) rows")
            host.close()
        }
    }

    /// The group is `sheet` on `canvas`, and each − is the +/− pair's half: `raised` behind the glyph.
    func testColours() {
        for mode in [QuireMode.light, .dark] {
            let recorder = FrameRecorder()
            let view = QuireRemovableList(rows: rows(1), emptyTitle: "", emptyHint: "", onRemove: { _ in })
                .recordFrame("list", in: recorder)
                .frame(width: 392)
                .padding(10)
                .background(Color.qCanvas)
            let host = SwiftUIHost(view, mode: mode)
            let rep = host.render()
            let list = recorder["list"]
            XCTAssertColor(rep.srgb(at: CGPoint(x: list.minX + 6, y: list.midY)), TokenResolver.resolve("sheet", mode), "\(mode) group fill")
            // The − sits `senderRemoveInset` from the trailing edge, 22 pt square, centred in the row: its face 3 pt in from
            // its leading edge, clear of the 1 pt edge and of the 11 pt glyph centred in it.
            let button = CGPoint(x: list.maxX - s.senderRemoveInset - s.plusMinus + 3, y: list.midY)
            XCTAssertColor(rep.srgb(at: button), TokenResolver.resolve("raised", mode), "\(mode) − face")
            host.close()
        }
    }

    func testAClickOnARowsMinusRemovesThatRow() {
        let recorder = FrameRecorder()
        let removed = RemovalLog()
        let view = QuireRemovableList(rows: rows(3), emptyTitle: "", emptyHint: "", onRemove: { removed.ids.append($0.id) })
            .recordFrame("list", in: recorder)
            .frame(width: 392)
        let host = SwiftUIHost(view)
        let list = recorder["list"]
        // The second row's −, in the hosting view's flipped-to-window coordinates.
        let x = list.maxX - s.senderRemoveInset - s.plusMinus / 2
        let y = list.minY + s.senderRow * 1.5
        let point = host.hostingView.convert(NSPoint(x: x, y: y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: 1) else { continue }
            host.window.sendEvent(event)
        }
        host.settle()
        XCTAssertEqual(removed.ids, ["r1"])
        host.close()
    }

    /// A row already on its way out (“Removing…”) keeps its − in place, disabled: a click on it removes nothing, while the
    /// next row's still acts.
    func testARowOnItsWayOutCannotBeRemovedAgain() {
        let recorder = FrameRecorder()
        let removed = RemovalLog()
        var rows = rows(2)
        rows[0].state = "Removing…"
        rows[0].isRemovable = false
        rows[1].state = "Saving to Gmail…"
        let view = QuireRemovableList(rows: rows, emptyTitle: "", emptyHint: "", onRemove: { removed.ids.append($0.id) })
            .recordFrame("list", in: recorder)
            .frame(width: 392)
        let host = SwiftUIHost(view)
        let list = recorder["list"]
        let x = list.maxX - s.senderRemoveInset - s.plusMinus / 2
        for row in 0..<2 {
            let point = host.hostingView.convert(NSPoint(x: x, y: list.minY + s.senderRow * (CGFloat(row) + 0.5)), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                     windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: 1) else { continue }
                host.window.sendEvent(event)
            }
            host.settle()
        }
        XCTAssertEqual(removed.ids, ["r1"])
        host.close()
    }

    func testTheSheetIsItsTokenWide() {
        let recorder = FrameRecorder()
        let view = QuireRuleSheet(title: "Senders", caption: "Mail from these senders is archived or moved to the Trash as it arrives.",
                                  rows: rows(2), emptyTitle: "", emptyHint: "", onRemove: { _ in }, onDone: {})
            .recordFrame("sheet", in: recorder)
        let host = SwiftUIHost(view)
        XCTAssertEqual(recorder["sheet"].width, s.sendersWidth, accuracy: 0.5)
        host.close()
    }
}

@MainActor
private final class RemovalLog {
    var ids: [String] = []
}
