import AppKit
import SwiftUI
import XCTest
@testable import SSDesign

/// `QuireFieldStyle`, `QuirePopupLabel` / `QuirePopup` and `QuireFocusRing` against spec §5.25, §5.27 and §4.1.
@MainActor
final class FieldAndPopupTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    // MARK: Field

    func testFieldStateTable() {
        let r = { (error: Bool, s: QuireControlState) in QuireFieldAppearance.resolve(hasError: error, state: s) }
        XCTAssertEqual(r(false, QuireControlState()).face, QuireFill(.sheet))
        XCTAssertEqual(r(false, QuireControlState()).edge, .strong)
        XCTAssertEqual(r(false, QuireControlState()).text, .ink)
        XCTAssertEqual(r(false, QuireControlState()).placeholder, .ink3)
        XCTAssertEqual(r(false, QuireControlState(isHovered: true)).edge, QuireStroke(.ink3))
        let focused = r(false, QuireControlState(isFocused: true))
        XCTAssertEqual(focused.edge, .strong, "focus keeps the edge; the ring carries it, never a 1 pt colour change")
        XCTAssertEqual(focused.ringGap, 1)
        XCTAssertEqual(r(true, QuireControlState(isHovered: true)).edge, QuireStroke(.danger, width: 1.5), "the error edge outranks hover")
        let disabled = r(false, QuireControlState(isHovered: true, isFocused: true, isEnabled: false))
        XCTAssertEqual(disabled.face, QuireFill(wash: .fill))
        XCTAssertNil(disabled.edge)
        XCTAssertEqual(disabled.text, .inkDisabled)
        XCTAssertNil(disabled.ringGap)
    }

    func testFieldHeightsAndHelpLine() {
        let recorder = FrameRecorder()
        let view = VStack(alignment: .leading, spacing: 0) {
            TextField("", text: .constant("x")).quireFieldStyle().frame(width: 200).recordFrame("settings", in: recorder)
            TextField("", text: .constant("x")).quireFieldStyle(height: Quire.Layout.TextField.height).frame(width: 200)
                .recordFrame("regular", in: recorder)
            TextField("", text: .constant("x")).quireFieldStyle(.mono, error: "That doesn't look like a Google client ID.").frame(width: 300)
                .recordFrame("error", in: recorder)
        }
        let host = SwiftUIHost(view)
        XCTAssertEqual(recorder["settings"].height, 24, "24 pt in Settings rows")
        XCTAssertEqual(recorder["regular"].height, 28)
        XCTAssertEqual(recorder["error"].height, 24 + Quire.Layout.TextField.helpGap + QuireFont.Role.meta.lineHeight, accuracy: 1,
                       "the help line sits 5 pt under the field, one meta line tall")
        host.close()
    }

    func testRenderedFieldFaceEdgeAndErrorEdge() {
        for mode in QuireMode.allCases {
            QuireEnvironment.shared.setOverrides(.pinned(mode))
            let recorder = FrameRecorder()
            let view = VStack(spacing: 12) {
                TextField("", text: .constant("")).quireFieldStyle().frame(width: 120).recordFrame("plain", in: recorder)
                TextField("", text: .constant("")).quireFieldStyle(error: "Bad").frame(width: 120).recordFrame("error", in: recorder)
            }
            .padding(8).background(Color.qCanvas)
            let host = SwiftUIHost(view, mode: mode)
            let rep = host.render()
            let plain = recorder["plain"]
            let error = recorder["error"]
            XCTAssertColor(rep.srgb(at: CGPoint(x: plain.maxX - 3, y: plain.midY)), TokenResolver.resolve("sheet", mode), "face \(mode)")
            XCTAssertColor(rep.srgb(at: CGPoint(x: plain.maxX - 0.25, y: plain.midY)), TokenResolver.resolve("ruleStrong", mode), "edge \(mode)")
            XCTAssertColor(rep.srgb(at: CGPoint(x: error.maxX - 0.75, y: error.minY + 12)), TokenResolver.resolve("danger", mode),
                           "1.5 pt error edge \(mode)")
            host.close()
        }
    }

    /// Focus is real here: the field is made first responder through AppKit, and the style must notice through
    /// its own `@FocusState` and draw the ring.
    func testFieldDrawsTheRingWhenItTakesFocus() throws {
        let recorder = FrameRecorder()
        let view = VStack(spacing: 16) {
            TextField("", text: .constant("first")).quireFieldStyle().frame(width: 120).recordFrame("first", in: recorder)
            TextField("", text: .constant("second")).quireFieldStyle().frame(width: 120).recordFrame("second", in: recorder)
        }
        .padding(10).background(Color.qCanvas)
        .environment(\.controlActiveState, .key)
        let host = SwiftUIHost(view)
        host.window.makeFirstResponder(nil)
        host.window.selectNextKeyView(nil)
        host.settle()
        let first = recorder["first"]
        let second = recorder["second"]
        let ringOffset = Quire.Border.FocusRing.gap + Quire.Border.FocusRing.width / 2
        let focus = TokenResolver.resolve("focus", .light)
        let canvas = TokenResolver.resolve("canvas", .light)
        var rep = host.render()
        XCTAssertColor(rep.srgb(at: CGPoint(x: first.midX, y: first.minY - ringOffset)), focus, "the focused field rings")
        XCTAssertColor(rep.srgb(at: CGPoint(x: second.midX, y: second.minY - ringOffset)), canvas, "the other does not")
        // Tab inside the field editor, as a person presses it.
        pressTab(host)
        rep = host.render()
        XCTAssertColor(rep.srgb(at: CGPoint(x: first.midX, y: first.minY - ringOffset)), canvas, "the ring follows focus")
        XCTAssertColor(rep.srgb(at: CGPoint(x: second.midX, y: second.minY - ringOffset)), focus)
        host.close()
    }

    private func pressTab(_ host: SwiftUIHost<some View>) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: host.window.windowNumber, context: nil, characters: "\t",
                                               charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) else { continue }
            host.window.sendEvent(event)
        }
        host.settle()
    }

    func testPlaceholderIsInk3AndTextIsInk() {
        for (text, token) in [("", "ink3"), ("WWWWWW", "ink")] {
            let view = TextField("", text: .constant(text), prompt: QuireFieldStyle.prompt("WWWWWW"))
                .quireFieldStyle().frame(width: 120).padding(6).background(Color.qCanvas)
            let host = SwiftUIHost(view)
            let rep = host.render()
            // The darkest pixel of the glyphs is their colour (the W strokes are thick enough to cover pixels).
            var darkest = RGBA(r: 1, g: 1, b: 1, a: 1)
            for x in stride(from: CGFloat(6 + 8), to: 6 + 60, by: 0.5) {
                for y in stride(from: CGFloat(6 + 4), to: 6 + 20, by: 0.5) {
                    let c = rep.srgb(at: CGPoint(x: x, y: y))
                    if c.r + c.g + c.b < darkest.r + darkest.g + darkest.b { darkest = c }
                }
            }
            XCTAssertColor(darkest, TokenResolver.resolve(token, .light), text.isEmpty ? "placeholder" : "text")
            host.close()
        }
    }

    // MARK: Popup

    func testPopupStateTable() {
        let r = { (s: QuireControlState) in QuirePopupAppearance.resolve(state: s) }
        XCTAssertEqual(r(QuireControlState()).face, QuireFill(.raised))
        XCTAssertEqual(r(QuireControlState()).edge, .strong)
        XCTAssertEqual(r(QuireControlState()).label, .ink)
        XCTAssertEqual(r(QuireControlState()).chevron, .ink2)
        XCTAssertEqual(r(QuireControlState(isHovered: true)).face, QuireFill(.raised, wash: .hover))
        XCTAssertEqual(r(QuireControlState(isPressed: true)).face, QuireFill(.raised, wash: .pressed))
        XCTAssertEqual(r(QuireControlState(isFocused: true)).ringGap, 1)
        let disabled = r(QuireControlState(isFocused: true, isEnabled: false))
        XCTAssertEqual(disabled.face, QuireFill(wash: .fill))
        XCTAssertNil(disabled.edge)
        XCTAssertEqual(disabled.label, .inkDisabled)
        XCTAssertEqual(disabled.chevron, .inkDisabled)
        XCTAssertNil(disabled.ringGap)
        // Borderless: nothing until hovered, then the face without an edge.
        XCTAssertEqual(QuirePopupAppearance.resolve(borderless: true, state: QuireControlState()).face, .clear)
        XCTAssertNil(QuirePopupAppearance.resolve(borderless: true, state: QuireControlState()).edge)
        XCTAssertEqual(QuirePopupAppearance.resolve(borderless: true, state: QuireControlState(isHovered: true)).face,
                       QuireFill(.raised, wash: .hover))
    }

    func testPopupMetrics() {
        let p = Quire.Layout.Popup.self
        let recorder = FrameRecorder()
        let view = VStack(alignment: .leading) {
            QuirePopupLabel("5 seconds").recordFrame("label", in: recorder)
            QuirePopupLabel("Persimmon", swatch: 0, width: Quire.Layout.Settings.colourPopupWidth).recordFrame("colour", in: recorder)
            QuirePopup("Undo send", selection: .constant(5), options: [5, 10, 20]) { "\($0) seconds" }.recordFrame("menu", in: recorder)
        }
        let host = SwiftUIHost(view)
        let text = ("5 seconds" as NSString).size(withAttributes: [.font: QuireFont.font(.body)]).width
        XCTAssertEqual(recorder["label"].height, p.height)
        XCTAssertEqual(recorder["label"].width, p.padLeft + text + Quire.Space.s4 + p.chevron + p.padRight, accuracy: 2,
                       "padding 0 6 0 9, the value, 8 pt, the 12 pt chevron")
        XCTAssertEqual(recorder["colour"].size, CGSize(width: 160, height: 24))
        XCTAssertEqual(recorder["menu"].size, recorder["label"].size, "the live popup is exactly its Quire face")
        host.close()
    }

    func testRenderedPopupKeepsTheSwatchHaloWhenPressed() {
        for mode in QuireMode.allCases {
            QuireEnvironment.shared.setOverrides(.pinned(mode))
            let view = QuirePopupLabel("Persimmon", swatch: 0).quireForcedStates(.pressed).padding(6).background(Color.qCanvas)
            let host = SwiftUIHost(view, mode: mode)
            let rep = host.render()
            let p = Quire.Layout.Popup.self
            let swatchMinX = 6 + p.padLeft
            let midY = 6 + p.height / 2
            // 1 pt left of the swatch is the halo: raised, unwashed. Further left is the pressed face.
            XCTAssertColor(rep.srgb(at: CGPoint(x: swatchMinX - 1, y: midY)), TokenResolver.resolve("raised", mode), "halo \(mode)")
            XCTAssertColor(rep.srgb(at: CGPoint(x: swatchMinX - 4, y: midY)), Expected.color(QuireFill(.raised, wash: .pressed), over: .canvas, mode),
                           "pressed face \(mode)")
            XCTAssertColor(rep.srgb(at: CGPoint(x: swatchMinX + 7, y: midY)), TokenResolver.resolve("account:Persimmon", mode), "swatch \(mode)")
            host.close()
        }
    }

    // MARK: QuireFocusRing

    func testFocusRingModifierFollowsFocusAndKeyState() {
        let model = FocusModel()
        let recorder = FrameRecorder()
        let host = SwiftUIHost(FocusRingHarness(model: model, recorder: recorder))
        host.window.makeFirstResponder(nil)
        host.settle()
        let tile = recorder["tile"]
        let ringPoint = CGPoint(x: tile.midX, y: tile.minY - 2 - Quire.Border.FocusRing.width / 2)
        let focus = TokenResolver.resolve("focus", .light)
        let canvas = TokenResolver.resolve("canvas", .light)
        XCTAssertColor(host.render().srgb(at: ringPoint), canvas, "no focus, no ring")
        model.focused = true
        host.settle()
        XCTAssertColor(host.render().srgb(at: ringPoint), focus, "focused: the ring, 2 pt out (gap 2)")
        model.key = false
        host.settle()
        XCTAssertColor(host.render().srgb(at: ringPoint), canvas, "a window that is not key shows no ring")
        host.close()
    }
}

@MainActor
final class FocusModel: ObservableObject {
    @Published var focused = false
    @Published var key = true
}

/// A focusable tile with `.quireFocusRing`, focused from outside through a second `@FocusState` on the same
/// view: the modifier must see the focus however it arrives.
struct FocusRingHarness: View {
    @ObservedObject var model: FocusModel
    let recorder: FrameRecorder
    @FocusState private var focus: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6).fill(Color.qSheet).frame(width: 60, height: 24)
            .recordFrame("tile", in: recorder)
            .quireFocusRing(.roundedRectangle(cornerRadius: 6), gap: 2, focusable: true)
            .focused($focus)
            .padding(12)
            .background(Color.qCanvas)
            .environment(\.controlActiveState, model.key ? .key : .inactive)
            .onChange(of: model.focused) { _, wants in focus = wants }
    }
}
