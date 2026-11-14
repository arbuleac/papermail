import AppKit
import SwiftUI
import XCTest
@testable import SSDesign

/// The theme tiles and their picker against spec §5.40: the state table, the geometry, a miniature drawn in the
/// pictured theme in the window's mode (Graphite included) inside the window theme's edge, the chosen name's bar and
/// the focus ring as the only ring, the keyboard, and what VoiceOver is given. Set `QUIRE_GALLERY_DIR` to an absolute
/// directory to write the picker's renders as `theme-picker-<mode>.png`.
@MainActor
final class ThemePickerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private func rgba(_ token: QuireColorToken, _ theme: QuireTheme, _ mode: QuireMode, graphite: Bool = false) -> RGBA {
        let values = graphite ? (token.graphiteValues(theme: theme) ?? token.values(theme: theme)) : token.values(theme: theme)
        return ColorLib.hex2rgba(String(format: "#%06X", values[mode] >> 8))
    }

    // MARK: State

    func testTheChoiceIsMarkedByWeightAndABarNeverByARing() {
        let resolve = QuireThemeTileAppearance.resolve
        XCTAssertEqual(resolve(true, QuireControlState()),
                       QuireThemeTileAppearance(nameRole: .labelStrong, name: .ink, mark: .selRule, showsFocusRing: false))
        XCTAssertEqual(resolve(true, QuireControlState(isWindowKey: false)).mark, .selRuleIdle, "idle while Settings is not key")
        XCTAssertEqual(resolve(false, QuireControlState()),
                       QuireThemeTileAppearance(nameRole: .label, name: .ink2, mark: nil, showsFocusRing: false))
        XCTAssertEqual(resolve(false, QuireControlState(isHovered: true)).name, .ink, "hover turns the name ink")
        XCTAssertNil(resolve(false, QuireControlState(isHovered: true)).mark, "and draws nothing else")
        XCTAssertEqual(resolve(false, QuireControlState(isHovered: true, isPressed: true)).mark, .ruleStrong, "pressed, until mouse-up")
        XCTAssertEqual(resolve(true, QuireControlState(isPressed: true)).mark, .ruleStrong)
        XCTAssertTrue(resolve(true, QuireControlState(isFocused: true)).showsFocusRing, "the ring goes round the chosen tile")
        XCTAssertFalse(resolve(false, QuireControlState(isFocused: true)).showsFocusRing, "and round no other")
        XCTAssertFalse(resolve(true, QuireControlState(isFocused: true, isWindowKey: false)).showsFocusRing, "never in a window that is not key")
        XCTAssertNil(resolve(false, QuireControlState(isHovered: true, isPressed: true, isEnabled: false)).mark, "disabled takes no press")
    }

    // MARK: Geometry

    func testTheTilesFillTheFieldColumnAndTheCaptionKeepsTwoLines() {
        let s = Quire.Layout.Settings.self
        let tile = NSHostingView(rootView: QuireThemeTile(.study, isChosen: true))
        XCTAssertEqual(tile.fittingSize.width, s.themeTile[0])
        XCTAssertEqual(tile.fittingSize.height, s.themeTile[1] + s.themeNameGap + QuireFont.Role.label.lineHeight + s.themeUnderlineGap + s.themeUnderline,
                       "picture, the name 6 pt under it, and the bar's place 3 pt under the name")
        XCTAssertLessThanOrEqual(tile.fittingSize.height, s.themeRow)
        var heights: Set<CGFloat> = []
        for theme in QuireTheme.allCases {
            let picker = NSHostingView(rootView: QuireThemePicker("Theme", selection: .constant(theme)))
            XCTAssertEqual(picker.fittingSize.width, s.fieldWidth, "five tiles 15 pt apart are the field column")
            heights.insert(picker.fittingSize.height)
        }
        XCTAssertEqual(heights, [s.themeRow + s.themeCaptionLines * QuireFont.Role.meta.lineHeight],
                       "every caption keeps two lines, so a choice never moves the rows below")
        XCTAssertEqual(CGFloat(QuireTheme.allCases.count) * s.themeTile[0] + CGFloat(QuireTheme.allCases.count - 1) * s.themeTileGap, s.fieldWidth)
    }

    // MARK: Drawing

    /// Each tile pictures its own theme in the window's mode; the edge is the window theme's.
    func testATilePicturesItsThemeInTheWindowsModeInsideTheWindowThemesEdge() {
        let s = Quire.Layout.Settings.self
        let spine = CGPoint(x: s.themeTileSpine / 2, y: s.themeTile[1] / 2)
        let list = CGPoint(x: s.themeTileSpine + s.themeTilePaper / 2, y: s.themeTile[1] - 4)
        let desk = CGPoint(x: s.themeTileSpine + s.themeTilePaper + s.themeTileInset / 2, y: s.themeTile[1] / 2)
        let sheet = CGPoint(x: s.themeTile[0] - 12, y: s.themeTile[1] - 6)
        let pip = CGPoint(x: s.themeTileSpine + s.themeTileInset / 2 + s.themeTilePip / 2, y: s.themeTileInset + s.themeTilePip / 2)
        let edge = CGPoint(x: Quire.Border.Strong.width / 2, y: s.themeTile[1] / 2)
        for mode in [QuireMode.light, .dark] {
            for theme in QuireTheme.allCases {
                let host = SwiftUIHost(QuireThemeTile(theme, isChosen: false).background(.qCanvas), mode: mode)
                let rep = host.render()
                let label = "\(theme) \(mode)"
                XCTAssertColor(rep.srgb(at: spine), rgba(.spine, theme, mode), label + ": the rail")
                XCTAssertColor(rep.srgb(at: list), rgba(.paper, theme, mode), label + ": the list")
                XCTAssertColor(rep.srgb(at: desk), rgba(.canvas, theme, mode), label + ": the desk")
                XCTAssertColor(rep.srgb(at: sheet), rgba(.sheet, theme, mode), label + ": the sheet")
                XCTAssertColor(rep.srgb(at: pip), rgba(.accent, theme, mode), label + ": the pip in the ink")
                XCTAssertColor(rep.srgb(at: edge), rgba(.ruleStrong, .study, mode), label + ": the window's edge, not the pictured one's")
                host.close()
            }
        }
    }

    /// A Graphite user sees what they will get: every tile's pip is its theme's text ink.
    func testUnderGraphiteEveryTilePicturesTheInklessWindow() {
        QuireEnvironment.shared.setOverrides(.pinned(.light, graphite: true))
        let s = Quire.Layout.Settings.self
        let pip = CGPoint(x: s.themeTileSpine + s.themeTileInset / 2 + s.themeTilePip / 2, y: s.themeTileInset + s.themeTilePip / 2)
        for theme in QuireTheme.allCases {
            let host = SwiftUIHost(QuireThemeRoot(QuireThemeTile(theme, isChosen: false)))
            XCTAssertColor(host.render().srgb(at: pip), rgba(.accent, theme, .light, graphite: true), "\(theme)")
            host.close()
        }
    }

    func testOnlyTheChosenNameCarriesTheBarAndOnlyFocusDrawsARing() throws {
        let s = Quire.Layout.Settings.self
        let pad: CGFloat = 10
        let directory = ProcessInfo.processInfo.environment["QUIRE_GALLERY_DIR"]
        for mode in [QuireMode.light, .dark] {
            for focused in [false, true] {
                let picker = QuireThemePicker("Theme", selection: .constant(.rain))
                    .quireForcedStates(focused ? .focused : [])
                    .padding(pad)
                    .background(.qCanvas)
                    .environment(\.controlActiveState, .key)
                let host = SwiftUIHost(picker, mode: mode)
                // SwiftUI gives a new window's first focusable view default focus; the unfocused case starts from none.
                host.window.makeFirstResponder(nil)
                let rep = host.render()
                if let directory, focused {
                    try rep.writePNG(to: "\(directory)/theme-picker-\(mode.rawValue).png")
                }
                let barY = pad + s.themeTile[1] + s.themeNameGap + QuireFont.Role.label.lineHeight + s.themeUnderlineGap + s.themeUnderline / 2
                let ringOffset = Quire.Border.FocusRing.gapAroundSheets + Quire.Border.FocusRing.width / 2
                for (i, theme) in QuireTheme.allCases.enumerated() {
                    let minX = pad + CGFloat(i) * (s.themeTile[0] + s.themeTileGap)
                    let bar = rep.srgb(at: CGPoint(x: minX + s.themeTile[0] / 2, y: barY))
                    let ring = rep.srgb(at: CGPoint(x: minX - ringOffset, y: pad + s.themeTile[1] / 2))
                    let label = "\(theme) \(mode)\(focused ? " focused" : "")"
                    if theme == .rain {
                        XCTAssertColor(bar, rgba(.selRule, .study, mode), label + ": the chosen name's bar")
                        XCTAssertColor(ring, focused ? rgba(.focus, .study, mode) : rgba(.canvas, .study, mode), label + ": the ring is focus's")
                    } else {
                        XCTAssertColor(bar, rgba(.canvas, .study, mode), label + ": no bar")
                        XCTAssertColor(ring, rgba(.canvas, .study, mode), label + ": no ring")
                    }
                }
                host.close()
            }
        }
    }

    // MARK: Keyboard

    /// Focus moves programmatically, as in the radio group's test: Tab order depends on the Mac's Keyboard navigation
    /// setting, which a test must not change.
    func testArrowsMoveAndApplyTheChoiceClampedAtTheEnds() {
        let model = ThemePickerModel()
        let host = SwiftUIHost(ThemePickerHarness(model: model).environment(\.controlActiveState, .key))
        defer { host.close() }
        host.window.makeFirstResponder(nil)
        host.settle()
        model.wantsFocus = true
        host.settle()
        XCTAssertTrue(model.groupFocused, "the group is the one focusable element")
        let right = (keyCode: UInt16(124), characters: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        let left = (keyCode: UInt16(123), characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let down = (keyCode: UInt16(125), characters: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        let up = (keyCode: UInt16(126), characters: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        var seen: [QuireTheme] = []
        for _ in 0..<5 {
            sendKey(host, right)
            seen.append(model.selection)
            XCTAssertTrue(model.groupFocused, "focus stays on the group")
        }
        XCTAssertEqual(seen, [.gallery, .rain, .grove, .dusk, .dusk], "→ steps through every theme and stops at the last")
        sendKey(host, up)
        XCTAssertEqual(model.selection, .grove, "↑ steps back")
        sendKey(host, left)
        XCTAssertEqual(model.selection, .rain, "← steps back")
        sendKey(host, down)
        XCTAssertEqual(model.selection, .grove, "↓ steps on")
        for _ in 0..<5 { sendKey(host, left) }
        XCTAssertEqual(model.selection, .study, "← stops at the first")
    }

    private func sendKey(_ host: SwiftUIHost<some View>, _ key: (keyCode: UInt16, characters: String)) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                                               windowNumber: host.window.windowNumber, context: nil, characters: key.characters,
                                               charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode)
            else { continue }
            host.window.sendEvent(event)
        }
        host.settle()
    }

    // MARK: VoiceOver

    func testVoiceOverReadsARadioPerThemeInSettingsOrder() {
        XCTAssertEqual(QuireThemePicker.radios(selection: .study).map(\.spoken),
                       ["Study, 1 of 5, selected", "Gallery, 2 of 5", "Rain, 3 of 5", "Grove, 4 of 5", "Dusk, 5 of 5"])
        XCTAssertEqual(QuireThemePicker.radios(selection: .rain).filter(\.isSelected).map(\.spoken), ["Rain, 3 of 5, selected"])
        XCTAssertEqual(QuireThemePicker.radios(selection: .dusk).map(\.theme), QuireTheme.allCases)
    }
}

@MainActor
final class ThemePickerModel: ObservableObject {
    @Published var selection = QuireTheme.study
    @Published var wantsFocus = false
    var groupFocused = false
}

private struct ThemePickerHarness: View {
    @ObservedObject var model: ThemePickerModel
    @FocusState private var focus: Bool

    var body: some View {
        QuireThemePicker("Theme", selection: $model.selection, focus: $focus)
            .padding(10)
            .background(.qCanvas)
            .onChange(of: model.wantsFocus) { _, wants in focus = wants }
            .onChange(of: focus, initial: true) { _, focused in model.groupFocused = focused }
    }
}
