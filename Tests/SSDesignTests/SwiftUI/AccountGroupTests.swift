import AppKit
import SwiftUI
import XCTest
@testable import SSDesign

/// `QuireAccountRow`, `QuireAccountGroup` and the +/− pair against spec §5.40.
@MainActor
final class AccountGroupTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private let s = Quire.Layout.Settings.self

    private func account(_ id: String, slot: Int = 0, status: QuireAccountStatus = .upToDate()) -> QuireAccountRowContent {
        QuireAccountRowContent(id: id, name: id.capitalized, tag: "Gmail", address: "\(id)@example.test", monogram: String(id.prefix(1)).uppercased(),
                               inkSlot: slot, status: status)
    }

    // MARK: State → token

    func testMarginRuleSelection() {
        XCTAssertEqual(QuireSelectionAppearance.resolve(isSelected: true, isWindowKey: true),
                       QuireSelectionAppearance(wash: .selWash, rule: .selRule))
        XCTAssertEqual(QuireSelectionAppearance.resolve(isSelected: true, isWindowKey: false),
                       QuireSelectionAppearance(wash: .selWashIdle, rule: .selRuleIdle))
        XCTAssertEqual(QuireSelectionAppearance.resolve(isSelected: false, isWindowKey: true), QuireSelectionAppearance(wash: nil, rule: nil))
    }

    func testStatusTable() {
        let up = QuireAccountStatus.upToDate(checked: "23:41")
        XCTAssertEqual(up.mark, .glyph("checkmark.circle.fill", .success))
        XCTAssertEqual(up.words, "Up to date")
        XCTAssertEqual(up.wordsColor, .ink2)
        XCTAssertEqual(up.tooltip, "Checked 23:41")
        XCTAssertEqual(QuireAccountStatus.waitingToSync.mark, .glyph("clock", .ink3))
        XCTAssertEqual(QuireAccountStatus.waitingToSync.wordsColor, .ink3)
        let downloading = QuireAccountStatus.downloading(done: 3412, total: 8120, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(downloading.mark, .spinner)
        XCTAssertEqual(downloading.words, "Downloading · 3,412 of 8,120")
        XCTAssertEqual(downloading.progress ?? 0, 3412.0 / 8120.0, accuracy: 1e-9)
        let unknown = QuireAccountStatus.downloading(done: 3412, total: nil, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(unknown.words, "Downloading · 3,412 messages")
        XCTAssertNil(unknown.progress, "no bar while the total is unknown")
        XCTAssertEqual(QuireAccountStatus.retrying(inSeconds: 30, cause: "Gmail is limiting requests.").words, "Retrying in 30 s")
        XCTAssertEqual(QuireAccountStatus.retrying(inSeconds: nil).words, "Retrying shortly")
        XCTAssertEqual(QuireAccountStatus.retrying(inSeconds: 30).mark, .glyph("clock", .warning))
        XCTAssertEqual(QuireAccountStatus.offline.mark, .glyph("wifi.slash", .ink2))
        let signIn = QuireAccountStatus.signInRequired
        XCTAssertNil(signIn.words, "the status block holds only the button")
        XCTAssertEqual(signIn.actionTitle, "Reconnect")
        XCTAssertEqual(signIn.addressReplacement, "Sign in required")
        let reconnecting = QuireAccountStatus.reconnecting
        XCTAssertEqual(reconnecting.words, "Waiting for your browser")
        XCTAssertEqual(reconnecting.actionTitle, "Cancel", "Cancel takes Reconnect's place")
        XCTAssertEqual(reconnecting.addressReplacement, "Sign in required", "it is still true")
        let error = QuireAccountStatus.error(reason: "Gmail returned an unexpected response.")
        XCTAssertEqual(error.mark, .glyph("exclamationmark.triangle.fill", .danger))
        XCTAssertEqual(error.wordsColor, .danger)
        XCTAssertEqual(error.actionTitle, "Retry")
        XCTAssertEqual(QuireAccountStatus.demo.words, "Made up, nothing syncs")
        for status in [up, .waitingToSync, .offline, error, .demo, .retrying(inSeconds: 1)] {
            if case .glyph(let name, _) = status.mark { XCTAssertTrue(QuireSymbol.exists(name), name) }
        }
    }

    func testPlusMinusStateTable() {
        let r = { QuireJoinedButtonAppearance.resolve(state: $0) }
        XCTAssertEqual(r(QuireControlState()).face, QuireFill(.raised))
        XCTAssertEqual(r(QuireControlState()).edge, .strong)
        XCTAssertEqual(r(QuireControlState()).glyph, .ink2)
        XCTAssertEqual(r(QuireControlState(isHovered: true)).face, QuireFill(.raised, wash: .hover))
        XCTAssertEqual(r(QuireControlState(isHovered: true)).glyph, .ink)
        XCTAssertEqual(r(QuireControlState(isPressed: true)).face, QuireFill(.raised, wash: .pressed))
        let disabled = r(QuireControlState(isHovered: true, isEnabled: false))
        XCTAssertEqual(disabled.face, QuireFill(.raised), "disabled: no fill change")
        XCTAssertEqual(disabled.glyph, .inkDisabled)
        XCTAssertEqual(r(QuireControlState(isFocused: true)).ringGap, 1)
    }

    // MARK: Geometry

    func testGroupCapsAtSixRows() {
        XCTAssertEqual(QuireAccountGroup<EmptyView>.rowCount(accounts: 0, hasPending: false), 1, "the empty row")
        XCTAssertEqual(QuireAccountGroup<EmptyView>.rowCount(accounts: 2, hasPending: true), 3)
        for (rows, height) in [(1, 56), (4, 224), (6, 336), (7, 336), (12, 336)] {
            XCTAssertEqual(QuireAccountGroup<EmptyView>.height(rows: rows), CGFloat(height), "\(rows) rows")
        }
        for count in [0, 3, 6, 7, 9] {
            let recorder = FrameRecorder()
            let accounts = (0..<count).map { account("account\($0)", slot: $0) }
            let view = QuireAccountGroup(accounts: accounts, selection: .constant(accounts.first?.id), onRemove: {}) { EmptyView() }
                .recordFrame("group", in: recorder)
                .frame(width: 512)
            let host = SwiftUIHost(view)
            let rows = max(1, count)
            let expected = CGFloat(min(rows, 6)) * s.accountRow + s.plusMinusTop + s.plusMinus
            XCTAssertEqual(recorder["group"].height, expected, accuracy: 0.5, "\(count) accounts: rows (at most 6), 8 pt, the 22 pt buttons")
            host.close()
        }
    }

    func testRowGeometry() {
        let recorder = FrameRecorder()
        let view = QuireAccountRow(account("contoso"), isSelected: true)
            .recordFrame("row", in: recorder)
            .frame(width: 512)
            .environment(\.controlActiveState, .key)
        let host = SwiftUIHost(view)
        XCTAssertEqual(recorder["row"].height, s.accountRow)
        let rep = host.render()
        let row = recorder["row"]
        let ink = TokenResolver.resolve("account:Persimmon", .light)
        // The face's leading edge is at x = 16, so the ring (2 pt gap, 2 pt ring) runs from x = 12 to 14.
        XCTAssertColor(rep.srgb(at: CGPoint(x: row.minX + 13, y: row.midY)), ink, "ring's outer band at x 12–14")
        XCTAssertColor(rep.srgb(at: CGPoint(x: row.minX + 15, y: row.midY)), TokenResolver.resolve("selWash", .light),
                       "the gap shows the row's fill (selWash here)")
        XCTAssertColor(rep.srgb(at: CGPoint(x: row.minX + 1.5, y: row.midY)), TokenResolver.resolve("selRule", .light), "the 3 pt margin rule")
        XCTAssertColor(rep.srgb(at: CGPoint(x: row.minX + 4, y: row.minY + 4)), TokenResolver.resolve("selWash", .light), "the wash")
        host.close()
    }

    func testIdleSelectionWhenSettingsIsNotKey() {
        for mode in QuireMode.allCases {
            QuireEnvironment.shared.setOverrides(.pinned(mode))
            for key in [true, false] {
                let recorder = FrameRecorder()
                let view = QuireAccountRow(account("contoso"), isSelected: true)
                    .recordFrame("row", in: recorder)
                    .frame(width: 400)
                    .environment(\.controlActiveState, key ? .key : .inactive)
                let host = SwiftUIHost(view, mode: mode)
                let rep = host.render()
                let row = recorder["row"]
                XCTAssertColor(rep.srgb(at: CGPoint(x: row.minX + 1.5, y: row.midY)), TokenResolver.resolve(key ? "selRule" : "selRuleIdle", mode),
                               "rule key \(key) \(mode)")
                XCTAssertColor(rep.srgb(at: CGPoint(x: row.minX + 6, y: row.minY + 3)), TokenResolver.resolve(key ? "selWash" : "selWashIdle", mode),
                               "wash key \(key) \(mode)")
                host.close()
            }
        }
    }

    func testSeparatorsStartAtTheTextColumnAndHideAroundTheSelection() {
        let recorder = FrameRecorder()
        let accounts = (0..<4).map { account("account\($0)", slot: $0) }
        let view = QuireAccountGroup(accounts: accounts, selection: .constant("account1"), onRemove: {}) { EmptyView() }
            .recordFrame("group", in: recorder)
            .frame(width: 512)
            .padding(10)
            .background(Color.qCanvas)
        let host = SwiftUIHost(view)
        let rep = host.render()
        let group = recorder["group"]
        let rule = TokenResolver.resolve("rule", .light)
        let sheet = TokenResolver.resolve("sheet", .light)
        let boundary = { (index: Int) in group.minY + CGFloat(index) * self.s.accountRow + 0.25 }
        // Row 3 / row 4: neither touches the selection, so the hairline shows from x = 62 on.
        XCTAssertColor(rep.srgb(at: CGPoint(x: group.minX + 200, y: boundary(3))), rule, "a separator between unselected rows")
        XCTAssertColor(rep.srgb(at: CGPoint(x: group.minX + s.accountHairlineX + 1, y: boundary(3))), rule, "starting at the text column")
        XCTAssertColor(rep.srgb(at: CGPoint(x: group.minX + s.accountHairlineX - 4, y: boundary(3))), sheet, "and not before it")
        // Above and below the selected second row: hidden.
        XCTAssertNotEqual(rep.srgb(at: CGPoint(x: group.minX + 200, y: boundary(1))), rule, "hidden above the selected row")
        XCTAssertNotEqual(rep.srgb(at: CGPoint(x: group.minX + 200, y: boundary(2))), rule, "hidden below it")
        host.close()
    }

    func testScrollingGroupMarksItsClippedBottomEdge() {
        let recorder = FrameRecorder()
        let accounts = (0..<8).map { account("account\($0)", slot: $0) }
        let view = QuireAccountGroup(accounts: accounts, selection: .constant("account0"), onRemove: {}) { EmptyView() }
            .recordFrame("group", in: recorder)
            .frame(width: 512)
            .padding(10)
            .background(Color.qCanvas)
        let host = SwiftUIHost(view)
        let rep = host.render()
        let group = recorder["group"]
        let bottom = group.minY + 6 * s.accountRow
        XCTAssertColor(rep.srgb(at: CGPoint(x: group.minX + 30, y: bottom - 0.25)), TokenResolver.resolve("rule", .light),
                       "a hairline across the clipped bottom edge, from the leading edge")
        XCTAssertNotEqual(rep.srgb(at: CGPoint(x: group.minX + 30, y: group.minY + 0.25)), TokenResolver.resolve("rule", .light),
                          "no top hairline before scrolling")
        host.close()
    }

    func testStatusBlockSitsSixteenPointsFromTheTrailingEdge() {
        let recorder = FrameRecorder()
        let view = QuireAccountRow(account("contoso", status: .signInRequired), onAction: {})
            .recordFrame("row", in: recorder)
            .frame(width: 512)
            .background(Color.qSheet)
        let host = SwiftUIHost(view)
        let rep = host.render()
        let row = recorder["row"]
        // The Reconnect button's edge (small secondary: ruleStrong) ends 16 pt from the trailing edge.
        let edgeX = row.maxX - s.statusTrailing - 0.25
        XCTAssertColor(rep.srgb(at: CGPoint(x: edgeX, y: row.midY)), TokenResolver.resolve("ruleStrong", .light), "button edge at trailing − 16")
        XCTAssertColor(rep.srgb(at: CGPoint(x: row.maxX - s.statusTrailing + 1.5, y: row.midY)), TokenResolver.resolve("sheet", .light))
        host.close()
    }

    // MARK: Keyboard and selection

    func testFocusedGroupMovesTheSelectionWithArrowsAndRingsTheSelectedRow() {
        let model = GroupModel()
        let recorder = FrameRecorder()
        let host = SwiftUIHost(GroupHarness(model: model, recorder: recorder).environment(\.controlActiveState, .key))
        host.window.makeFirstResponder(nil)
        host.settle()
        let group = recorder["group"]
        let ring = { (row: Int) -> RGBA in
            // The ring is inset 2 pt: its band runs from 2 to 4 pt inside the row's top edge.
            host.render().srgb(at: CGPoint(x: group.midX, y: group.minY + CGFloat(row) * self.s.accountRow + 3))
        }
        let focus = TokenResolver.resolve("focus", .light)
        XCTAssertNotEqual(ring(0), focus, "no ring without focus")
        model.wantsFocus = true
        host.settle()
        XCTAssertColor(ring(0), focus, "focused: the ring around the selected row, inset 2 pt")
        sendKey(host, keyCode: 125, function: NSDownArrowFunctionKey)
        XCTAssertEqual(model.selection, "b", "↓ moves the selection")
        XCTAssertColor(ring(1), focus, "the ring follows the selection")
        sendKey(host, keyCode: 125, function: NSDownArrowFunctionKey)
        sendKey(host, keyCode: 125, function: NSDownArrowFunctionKey)
        XCTAssertEqual(model.selection, "c", "↓ stops at the last row")
        sendKey(host, keyCode: 126, function: NSUpArrowFunctionKey)
        XCTAssertEqual(model.selection, "b", "↑ moves back")
        sendKey(host, keyCode: 51, characters: String(UnicodeScalar(0x7F)!))
        XCTAssertEqual(model.removals, 1, "⌫ asks to remove")
        host.close()
    }

    func testEmptyAndBusyStates() {
        let recorder = FrameRecorder()
        let empty = QuireAccountGroup(accounts: [], selection: .constant(nil), onRemove: {}) { EmptyView() }
            .recordFrame("empty", in: recorder).frame(width: 512)
        let host = SwiftUIHost(empty)
        XCTAssertEqual(recorder["empty"].height, s.accountRow + s.plusMinusTop + s.plusMinus, "one 56 pt row")
        host.close()
        // Pending: one more row at the end.
        let pending = QuireAccountGroup(accounts: [account("a")], selection: .constant("a"),
                                        pending: QuireAccountPending(provider: "Gmail", onCancel: {}), onRemove: {}) { EmptyView() }
            .recordFrame("pending", in: recorder).frame(width: 512)
        let host2 = SwiftUIHost(pending)
        XCTAssertEqual(recorder["pending"].height, 2 * s.accountRow + s.plusMinusTop + s.plusMinus)
        host2.close()
    }

    private func sendKey(_ host: SwiftUIHost<some View>, keyCode: UInt16, function: Int) {
        sendKey(host, keyCode: keyCode, characters: String(UnicodeScalar(function)!), flags: [.function, .numericPad])
    }

    private func sendKey(_ host: SwiftUIHost<some View>, keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                               windowNumber: host.window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { continue }
            host.window.sendEvent(event)
        }
        host.settle()
    }
}

@MainActor
final class GroupModel: ObservableObject {
    @Published var selection: String? = "a"
    @Published var wantsFocus = false
    var removals = 0
}

struct GroupHarness: View {
    @ObservedObject var model: GroupModel
    let recorder: FrameRecorder
    @FocusState private var focus: Bool

    var body: some View {
        QuireAccountGroup(accounts: ["a", "b", "c"].enumerated().map { index, id in
            QuireAccountRowContent(id: id, name: id.uppercased(), tag: "Gmail", address: "\(id)@example.test", monogram: id.uppercased(),
                                   inkSlot: index)
        }, selection: $model.selection, focus: $focus, onRemove: { model.removals += 1 }) {
            EmptyView()
        }
        .recordFrame("group", in: recorder)
        .frame(width: 512)
        .padding(10)
        .background(Color.qCanvas)
        .onChange(of: model.wantsFocus) { _, wants in focus = wants }
    }
}
