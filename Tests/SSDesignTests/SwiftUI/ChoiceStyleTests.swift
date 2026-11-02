import AppKit
import SwiftUI
import XCTest
@testable import SSDesign

/// `QuireToggleStyle`, `QuireCheckboxStyle` and `QuireRadioGroup` against spec §5.26.
@MainActor
final class ChoiceStyleTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    // MARK: Toggle

    func testToggleNeverWashesTrackOrKnob() {
        for isOn in [false, true] {
            let states = [QuireControlState(), QuireControlState(isHovered: true), QuireControlState(isHovered: true, isPressed: true)]
            let appearances = states.map { QuireToggleAppearance.resolve(isOn: isOn, state: $0) }
            XCTAssertEqual(Set(appearances.map(\.track.stack)).count, 1, "the track never changes with hover or press")
            XCTAssertEqual(Set(appearances.map(\.knobFace)), [.knob])
            XCTAssertEqual(appearances[0], appearances[1], "hover changes nothing (as native switches)")
        }
        let off = QuireToggleAppearance.resolve(isOn: false, state: QuireControlState())
        XCTAssertEqual(off.track, QuireFill(wash: .fill))
        XCTAssertEqual(off.trackEdge, .strong)
        let on = QuireToggleAppearance.resolve(isOn: true, state: QuireControlState())
        XCTAssertEqual(on.track, QuireFill(.accentFill))
        XCTAssertNil(on.trackEdge)
        XCTAssertEqual(on.knobEdge, QuireStroke(.ruleStrong, width: 1), "the knob keeps its edge in both states")
        XCTAssertEqual(off.knobEdge, on.knobEdge)
    }

    func testToggleKnobGeometryAndPressStretch() {
        let t = Quire.Layout.Toggle.self
        let off = QuireToggleAppearance.resolve(isOn: false, state: QuireControlState())
        let on = QuireToggleAppearance.resolve(isOn: true, state: QuireControlState())
        let offPressed = QuireToggleAppearance.resolve(isOn: false, state: QuireControlState(isPressed: true))
        let onPressed = QuireToggleAppearance.resolve(isOn: true, state: QuireControlState(isPressed: true))
        XCTAssertEqual(off.knobWidth, 14)
        XCTAssertEqual(off.knobX, 2, "knob leading, 2 pt inset")
        XCTAssertEqual(on.knobX, 30 - 2 - 14, "knob trailing")
        XCTAssertEqual(offPressed.knobWidth, t.knobPressedWidth)
        XCTAssertEqual(offPressed.knobX, 2, "off, the knob grows from its leading edge toward the centre")
        XCTAssertEqual(onPressed.knobX + onPressed.knobWidth, t.width - t.inset, "on, it grows back from its trailing edge")
    }

    func testToggleRingGapAndDisabled() {
        XCTAssertEqual(QuireToggleAppearance.resolve(isOn: false, state: QuireControlState(isFocused: true)).ringGap, 1)
        XCTAssertEqual(QuireToggleAppearance.resolve(isOn: true, state: QuireControlState(isFocused: true)).ringGap, 2)
        let disabled = QuireToggleAppearance.resolve(isOn: true, state: QuireControlState(isPressed: true, isFocused: true, isEnabled: false))
        XCTAssertEqual(disabled.controlOpacity, 0.45)
        XCTAssertEqual(disabled.label, .inkDisabled)
        XCTAssertEqual(disabled.knobWidth, 14, "a disabled toggle takes no press")
        XCTAssertNil(disabled.ringGap)
    }

    func testToggleSizeAndLabelGap() {
        let recorder = FrameRecorder()
        let view = Toggle(isOn: .constant(true)) {
            Text("New mail").recordFrame("label", in: recorder)
        }
        .toggleStyle(.quire)
        .recordFrame("toggle", in: recorder)
        let host = SwiftUIHost(view)
        let toggle = recorder["toggle"]
        let label = recorder["label"]
        XCTAssertEqual(label.minX - toggle.minX, Quire.Layout.Toggle.width + Quire.Layout.Checkbox.labelGap, "track, then 8 pt, then the label")
        XCTAssertEqual(toggle.height, max(Quire.Layout.Toggle.height, QuireFont.Role.body.lineHeight), accuracy: 0.5)
        host.close()
    }

    func testRenderedToggleTrackAndKnob() {
        for mode in QuireMode.allCases {
            QuireEnvironment.shared.setOverrides(.pinned(mode))
            for isOn in [false, true] {
                let view = Toggle("", isOn: .constant(isOn)).toggleStyle(.quire).labelsHidden()
                    .padding(6).background(Color.qSheet)
                let host = SwiftUIHost(view, mode: mode)
                let rep = host.render()
                // A point of track the knob never covers: near the end the knob is not at.
                let trackX: CGFloat = isOn ? 6 + 5 : 6 + 25
                let expected = isOn ? Expected.color(QuireFill(.accentFill), over: .sheet, mode) : Expected.color(QuireFill(wash: .fill), over: .sheet, mode)
                XCTAssertColor(rep.srgb(at: CGPoint(x: trackX, y: 6 + 9)), expected, "track on \(isOn) \(mode)")
                // The knob's face, at its centre.
                let knobCenter: CGFloat = isOn ? 6 + 14 + 7 : 6 + 2 + 7
                XCTAssertColor(rep.srgb(at: CGPoint(x: knobCenter, y: 6 + 9)), TokenResolver.resolve("knob", mode), "knob on \(isOn) \(mode)",)
                host.close()
            }
        }
    }

    // MARK: Checkbox and radio

    func testCheckboxStateTable() {
        let r = { (on: Bool, s: QuireControlState) in QuireChoiceAppearance.resolve(isOn: on, state: s) }
        XCTAssertEqual(r(false, QuireControlState()).face, QuireFill(.sheet))
        XCTAssertEqual(r(false, QuireControlState()).edge, .strong)
        XCTAssertEqual(r(false, QuireControlState(isHovered: true)).face, QuireFill(.sheet, wash: .hover))
        XCTAssertEqual(r(false, QuireControlState(isHovered: true, isPressed: true)).face, QuireFill(.sheet, wash: .pressed))
        XCTAssertEqual(r(true, QuireControlState()).face, QuireFill(.accentFill))
        XCTAssertNil(r(true, QuireControlState()).edge)
        XCTAssertEqual(r(true, QuireControlState(isHovered: true)).face, QuireFill(.accentFillHover))
        XCTAssertEqual(r(true, QuireControlState(isPressed: true)).face, QuireFill(.controlOnPressed),
                       "on + pressed is controlOnPressed, never accentFillPressed (spec §4.1)")
        XCTAssertEqual(r(true, QuireControlState()).mark, .onAccent)
        XCTAssertEqual(r(false, QuireControlState(isFocused: true)).ringGap, 1)
        XCTAssertEqual(r(true, QuireControlState(isFocused: true)).ringGap, 2)
        let disabled = r(true, QuireControlState(isHovered: true, isFocused: true, isEnabled: false))
        XCTAssertEqual(disabled.face, QuireFill(.accentFill), "disabled takes no hover")
        XCTAssertEqual(disabled.controlOpacity, 0.45)
        XCTAssertEqual(disabled.label, .inkDisabled)
        XCTAssertNil(disabled.ringGap)
    }

    func testCheckboxAndRadioSizes() {
        let recorder = FrameRecorder()
        let view = VStack(alignment: .leading) {
            Toggle(isOn: .constant(true)) { Text("Rows").recordFrame("checkLabel", in: recorder) }
                .toggleStyle(.quireCheckbox)
                .recordFrame("check", in: recorder)
            QuireRadioGroup("Density", selection: .constant("A"), options: ["A", "B"]) { $0 }
                .recordFrame("radios", in: recorder)
        }
        let host = SwiftUIHost(view)
        XCTAssertEqual(recorder["checkLabel"].minX - recorder["check"].minX, Quire.Layout.Checkbox.size + Quire.Layout.Checkbox.labelGap)
        let a = ("A" as NSString).size(withAttributes: [.font: QuireFont.font(.body)]).width
        let b = ("B" as NSString).size(withAttributes: [.font: QuireFont.font(.body)]).width
        let option = { (w: CGFloat) in Quire.Layout.Radio.size + Quire.Layout.Checkbox.labelGap + w }
        XCTAssertEqual(recorder["radios"].width, option(a) + Quire.Space.s6 + option(b), accuracy: 1.5,
                       "options 16 pt apart, each circle 8 pt from its label")
        host.close()
    }

    func testRenderedCheckboxFaces() {
        for mode in QuireMode.allCases {
            QuireEnvironment.shared.setOverrides(.pinned(mode))
            let recorder = FrameRecorder()
            let view = HStack(spacing: 10) {
                Toggle("", isOn: .constant(false)).toggleStyle(.quireCheckbox).labelsHidden()
                    .recordFrame("off", in: recorder)
                Toggle("", isOn: .constant(true)).toggleStyle(.quireCheckbox).labelsHidden().quireForcedStates(.pressed)
                    .recordFrame("on", in: recorder)
            }
            .padding(6).background(Color.qCanvas)
            let host = SwiftUIHost(view, mode: mode)
            let rep = host.render()
            // The box leads each toggle and is centred in its height.
            let box = { (frame: CGRect) in CGRect(x: frame.minX, y: frame.midY - 7, width: 14, height: 14) }
            let off = box(recorder["off"])
            let on = box(recorder["on"])
            XCTAssertColor(rep.srgb(at: CGPoint(x: off.minX + 3, y: off.minY + 3)), TokenResolver.resolve("sheet", mode), "off face \(mode)")
            XCTAssertColor(rep.srgb(at: CGPoint(x: off.minX + 0.25, y: off.midY)), TokenResolver.resolve("ruleStrong", mode), "off edge \(mode)")
            XCTAssertColor(rep.srgb(at: CGPoint(x: on.minX + 2, y: on.minY + 2)), TokenResolver.resolve("controlOnPressed", mode),
                           "on pressed \(mode)")
            XCTAssertColor(rep.srgb(at: CGPoint(x: on.minX + 0.25, y: on.midY)), TokenResolver.resolve("controlOnPressed", mode),
                           "an on box has no edge \(mode)")
            host.close()
        }
    }

    // MARK: Radio group keyboard

    func testArrowStepsClampAtTheEnds() {
        XCTAssertEqual(QuireStep.index(after: 0, by: 1, count: 2), 1)
        XCTAssertEqual(QuireStep.index(after: 1, by: 1, count: 2), 1, "no wrap past the last")
        XCTAssertEqual(QuireStep.index(after: 0, by: -1, count: 2), 0, "no wrap before the first")
        XCTAssertEqual(QuireStep.index(after: nil, by: 1, count: 3), 0)
        XCTAssertEqual(QuireStep.index(after: nil, by: -1, count: 3), 2)
        XCTAssertNil(QuireStep.index(after: nil, by: 1, count: 0))
    }

    /// Focus moves programmatically here: Tab order depends on the Mac's Keyboard navigation setting, which is
    /// off on the machine these tests run on, and a test must not change it. With it off, macOS leaves radio
    /// groups out of the Tab loop natively too.
    func testFocusedGroupRingsTheSelectionAndArrowsMoveTheChoice() {
        let model = RadioModel()
        let recorder = FrameRecorder()
        let host = SwiftUIHost(RadioHarness(model: model, recorder: recorder).environment(\.controlActiveState, .key))
        // SwiftUI gives a new window's first focusable view default focus; start from none.
        host.window.makeFirstResponder(nil)
        host.settle()
        XCTAssertFalse(model.groupFocused)
        XCTAssertFalse(ringShows(host, around: recorder["group"]), "no ring without focus")
        model.wantsFocus = true
        host.settle()
        XCTAssertTrue(model.groupFocused, "the group itself is the focusable element")
        XCTAssertTrue(ringShows(host, around: recorder["group"]), "focused, the ring circles the selected option")
        sendKey(host, keyCode: 124, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        XCTAssertEqual(model.selection, "Compact", "→ moves the choice")
        sendKey(host, keyCode: 124, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        XCTAssertEqual(model.selection, "Compact", "→ stops at the last option")
        sendKey(host, keyCode: 123, characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        XCTAssertEqual(model.selection, "Standard", "← moves it back")
        model.wantsFocus = false
        host.settle()
        XCTAssertFalse(ringShows(host, around: recorder["group"]), "the ring leaves with focus")
        host.close()
    }

    /// True when the focus ring is drawn left of the first (selected) radio: 2 pt gap, then the ring.
    private func ringShows(_ host: SwiftUIHost<some View>, around group: CGRect) -> Bool {
        let rep = host.render()
        let ringX = group.minX - Quire.Border.FocusRing.gapOnAccentFill - Quire.Border.FocusRing.width / 2
        let c = rep.srgb(at: CGPoint(x: ringX, y: group.midY))
        let focus = TokenResolver.resolve("focus", .light)
        return max(abs(c.r - focus.r), abs(c.g - focus.g), abs(c.b - focus.b)) < 0.05
    }

    private func sendKey(_ host: SwiftUIHost<some View>, keyCode: UInt16, characters: String) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                                               windowNumber: host.window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { continue }
            host.window.sendEvent(event)
        }
        host.settle()
    }
}

@MainActor
final class RadioModel: ObservableObject {
    @Published var selection = "Standard"
    @Published var wantsFocus = false
    var groupFocused = false
}

struct RadioHarness: View {
    @ObservedObject var model: RadioModel
    let recorder: FrameRecorder
    @FocusState private var focus: Bool

    var body: some View {
        QuireRadioGroup("Density", selection: $model.selection, options: ["Standard", "Compact"], focus: $focus) { $0 }
            .recordFrame("group", in: recorder)
            .padding(10)
            .background(Color.qCanvas)
            .onChange(of: model.wantsFocus) { _, wants in focus = wants }
            .onChange(of: focus, initial: true) { _, focused in model.groupFocused = focused }
    }
}
