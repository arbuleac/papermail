import AppKit
import XCTest
@testable import SSDesign

/// State → colour: components rendered into bitmaps in all four modes, with pixels sampled where a state's
/// colour must show (spec §5.24–§5.30, §4.1).
@MainActor
final class ComponentColorTests: XCTestCase {
    private let pad: CGFloat = 10

    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    /// Renders `control` and returns the snapshot plus its face in host coordinates.
    private func render(_ control: QuireControl, _ mode: QuireMode, surface: NSColor = .qPaper, graphite: Bool = false)
        -> (ComponentSnapshot, NSRect) {
        control.sizeToFit()
        let snapshot = ComponentSnapshot.render(control, mode: mode, surface: surface, padding: pad, graphite: graphite)
        return (snapshot, control.faceRect.offsetBy(dx: pad, dy: pad))
    }

    private func assertPixel(_ snapshot: ComponentSnapshot, _ point: NSPoint, _ expected: RGBA, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(snapshot.matches(expected, at: point), "\(message): got \(snapshot.hex(at: point)), want \(ColorLib.rgb2hex(expected))",
                      file: file, line: line)
    }

    /// A point inside the face, clear of the label and the edge.
    private func fillPoint(_ face: NSRect) -> NSPoint { NSPoint(x: face.minX + 4, y: face.midY) }

    // MARK: Buttons

    func testPrimaryButtonFillsPerState() {
        for mode in QuireMode.allCases {
            for (state, token) in [(QuireDisplayState.rest, "accentFill"), (.hover, "accentFillHover"), (.pressed, "accentFillPressed")] {
                let button = QuireButton(title: "Send", variant: .primary)
                button.windowKeyOverride = true
                button.displayState = state
                let (snapshot, face) = render(button, mode)
                assertPixel(snapshot, fillPoint(face), expected(token, mode: mode), "\(mode) \(state)")
            }
        }
    }

    func testPrimaryDrawsAsSecondaryWhenTheWindowIsNotKey() {
        for mode in QuireMode.allCases {
            let button = QuireButton(title: "Send", variant: .primary)
            button.windowKeyOverride = false
            XCTAssertEqual(button.drawnVariant, .secondary)
            let (snapshot, face) = render(button, mode)
            assertPixel(snapshot, fillPoint(face), expected("raised", mode: mode), "\(mode) face")
            assertPixel(snapshot, NSPoint(x: face.midX, y: face.minY + 0.25), expected("ruleStrong", mode: mode), "\(mode) edge")
        }
    }

    func testSecondaryGhostAndDestructiveStates() {
        for mode in QuireMode.allCases {
            let secondary = QuireButton(title: "Reconnect", variant: .secondary)
            secondary.displayState = .hover
            var (snapshot, face) = render(secondary, mode)
            assertPixel(snapshot, fillPoint(face), expected("raised", "hover", mode: mode), "\(mode) secondary hover")
            assertPixel(snapshot, NSPoint(x: face.minX + 0.25, y: face.midY), expected("ruleStrong", mode: mode), "\(mode) secondary edge")

            let ghost = QuireButton(title: "Cancel", variant: .ghost)
            ghost.displayState = .pressed
            (snapshot, face) = render(ghost, mode)
            assertPixel(snapshot, fillPoint(face), expected("paper", "pressed", mode: mode), "\(mode) ghost pressed")

            let ghostRest = QuireButton(title: "Cancel", variant: .ghost)
            (snapshot, face) = render(ghostRest, mode)
            assertPixel(snapshot, fillPoint(face), expected("paper", mode: mode), "\(mode) ghost rest has no fill")

            let destructive = QuireButton(title: "Discard", variant: .destructive)
            destructive.displayState = .pressed
            (snapshot, face) = render(destructive, mode)
            assertPixel(snapshot, fillPoint(face), expected("dangerFillPressed", mode: mode), "\(mode) destructive pressed")
        }
    }

    func testDisabledButtonsUseFillWithoutAnEdge() {
        for mode in QuireMode.allCases {
            let button = QuireButton(title: "Reconnect", variant: .secondary)
            button.isEnabled = false
            let (snapshot, face) = render(button, mode)
            assertPixel(snapshot, fillPoint(face), expected("paper", "fill", mode: mode), "\(mode) disabled face")
            assertPixel(snapshot, NSPoint(x: face.minX + 0.25, y: face.midY), expected("paper", "fill", mode: mode), "\(mode) no edge")
        }
    }

    func testLinkButtonsNeverTakeAWash() {
        for mode in QuireMode.allCases {
            for state in [QuireDisplayState.hover, .pressed] {
                let link = QuireButton(title: "Load images", variant: .link, size: .small)
                link.displayState = state
                let (snapshot, face) = render(link, mode, surface: .qSheet)
                assertPixel(snapshot, NSPoint(x: face.minX + 1, y: face.minY + 1), expected("sheet", mode: mode), "\(mode) \(state)")
            }
        }
    }

    func testLinkUnderlineShowsOnHoverAndAtRestUnderGraphite() {
        func underlineInk(_ state: QuireDisplayState?, graphite: Bool) -> Bool {
            let link = QuireButton(title: "Load images", variant: .link, size: .small)
            link.displayState = state
            let (snapshot, face) = render(link, .light, graphite: graphite)
            // Scan the column under the label's first letters for an ink-coloured row below the baseline.
            let label = face.minX + Quire.Layout.Button.linkPadX + 2
            let baseline = face.midY - QuireFont.Role.label.lineHeight / 2 + QuireDraw.baselineFromTop(.label)
            let y = (baseline + Quire.Layout.TextStyle.linkUnderlineOffset).rounded() + 0.5
            let ink = expected(graphite ? "ink" : "accent", mode: .light)
            return snapshot.matches(ink, at: NSPoint(x: label, y: y), tolerance: 12)
                || snapshot.matches(ink, at: NSPoint(x: label + 3, y: y), tolerance: 12)
        }
        XCTAssertFalse(underlineInk(nil, graphite: false), "no underline at rest")
        XCTAssertTrue(underlineInk(.hover, graphite: false), "underline on hover")
        XCTAssertTrue(underlineInk(nil, graphite: true), "underline at rest under Graphite")
    }

    func testGraphiteSubstitutesThePrimaryFill() {
        let button = QuireButton(title: "Send", variant: .primary)
        button.windowKeyOverride = true
        let (snapshot, face) = render(button, .light, graphite: true)
        assertPixel(snapshot, fillPoint(face), ColorLib.hex2rgba("#1D1B18"), "accentFill → ink under Graphite")
    }

    // MARK: Focus ring

    func testFocusRingSitsOutsideTheGapAndGrowsInIncreaseContrast() {
        for mode in QuireMode.allCases {
            let button = QuireButton(title: "Send", variant: .primary)
            button.windowKeyOverride = true
            button.displayState = .focused
            let (snapshot, face) = render(button, mode)
            let midY = face.midY
            // Primary: 2 pt gap, then the ring.
            assertPixel(snapshot, NSPoint(x: face.minX - 1, y: midY), expected("paper", mode: mode), "\(mode) gap")
            assertPixel(snapshot, NSPoint(x: face.minX - 3, y: midY), expected("focus", mode: mode), "\(mode) ring")
            let outer = NSPoint(x: face.minX - 4.5, y: midY)
            if mode.isIncreasedContrast {
                assertPixel(snapshot, outer, expected("focus", mode: mode), "\(mode) 3 pt ring")
            } else {
                assertPixel(snapshot, outer, expected("paper", mode: mode), "\(mode) 2 pt ring")
            }
        }
    }

    func testNoRingWithoutFocusAndOneGapOnSecondaryControls() {
        let rest = QuireButton(title: "Reconnect")
        var (snapshot, face) = render(rest, .light)
        assertPixel(snapshot, NSPoint(x: face.minX - 2, y: face.midY), expected("paper", mode: .light), "no ring at rest")

        let focused = QuireButton(title: "Reconnect")
        focused.displayState = .focused
        (snapshot, face) = render(focused, .light)
        assertPixel(snapshot, NSPoint(x: face.minX - 0.5, y: face.midY), expected("paper", mode: .light), "1 pt gap")
        assertPixel(snapshot, NSPoint(x: face.minX - 2, y: face.midY), expected("focus", mode: .light), "ring")
    }

    // MARK: Icon buttons, badges

    func testIconButtonWashesAndOnStyles() {
        for mode in QuireMode.allCases {
            let hover = QuireIconButton(symbolName: Quire.Icon.archive)
            hover.displayState = .hover
            var (snapshot, face) = render(hover, mode)
            assertPixel(snapshot, NSPoint(x: face.minX + 3, y: face.minY + 3), expected("paper", "hover", mode: mode), "\(mode) hover")

            let quiet = QuireIconButton(symbolName: Quire.Icon.format)
            quiet.onStyle = .quiet
            quiet.isOn = true
            quiet.displayState = .pressed
            (snapshot, face) = render(quiet, mode)
            assertPixel(snapshot, NSPoint(x: face.minX + 3, y: face.minY + 3), expected("accentWashPressed", mode: mode), "\(mode) quiet on pressed")
        }
    }

    func testBadgeColours() {
        for mode in QuireMode.allCases {
            let unread = QuireBadge(.unread(3))
            var snapshot = ComponentSnapshot.render(unread, mode: mode, padding: pad)
            let c = Quire.Layout.Badge.cutout
            assertPixel(snapshot, NSPoint(x: pad + c + 8, y: pad + c + 2), expected("accentFill", mode: mode), "\(mode) unread")

            let count = QuireBadge(.messageCount(2))
            snapshot = ComponentSnapshot.render(count, mode: mode, surface: .qSelWash, padding: pad)
            assertPixel(snapshot, NSPoint(x: pad + c + 3, y: pad + c + 8), expected("selWash", "fill", mode: mode), "\(mode) count on selection")

            let attention = QuireBadge(.attention, cutoutColor: .qSpine)
            snapshot = ComponentSnapshot.render(attention, mode: mode, surface: .qRaised, padding: pad)
            assertPixel(snapshot, NSPoint(x: pad + c + 8, y: pad + c + 1.5), expected("dangerFill", mode: mode), "\(mode) attention")
            assertPixel(snapshot, NSPoint(x: pad + c + 8, y: pad + 0.5), expected("spine", mode: mode), "\(mode) cut-out ring")
        }
    }

    // MARK: Choices

    func testCheckboxFillsPerState() {
        for mode in QuireMode.allCases {
            let cases: [(NSControl.StateValue, QuireDisplayState?, [String])] = [
                (.off, nil, ["sheet"]), (.off, .hover, ["sheet", "hover"]), (.off, .pressed, ["sheet", "pressed"]),
                (.on, nil, ["accentFill"]), (.on, .hover, ["accentFillHover"]), (.on, .pressed, ["controlOnPressed"]),
            ]
            for (state, display, stack) in cases {
                let box = QuireCheckbox(state: state)
                box.displayState = display
                let (snapshot, _) = render(box, mode, surface: .qSheet)
                let rect = box.boxRect.offsetBy(dx: pad, dy: pad)
                assertPixel(snapshot, NSPoint(x: rect.minX + 2.5, y: rect.minY + 2.5), TokenResolver.resolveStack(stack, mode),
                            "\(mode) \(state.rawValue) \(String(describing: display))")
                if state == .off {
                    assertPixel(snapshot, NSPoint(x: rect.minX + 0.25, y: rect.midY), expected("ruleStrong", mode: mode), "\(mode) edge")
                }
            }
        }
    }

    func testRadioOnUsesControlOnPressedWhenPressed() {
        for mode in QuireMode.allCases {
            let radio = QuireRadioButton(isSelected: true)
            radio.displayState = .pressed
            let (snapshot, _) = render(radio, mode, surface: .qCanvas)
            let rect = radio.circleRect.offsetBy(dx: pad, dy: pad)
            assertPixel(snapshot, NSPoint(x: rect.midX, y: rect.minY + 2), expected("controlOnPressed", mode: mode), "\(mode) ring of the fill")
            assertPixel(snapshot, NSPoint(x: rect.midX, y: rect.midY), expected("onAccent", mode: mode), "\(mode) dot")
        }
    }

    func testToggleTrackAndKnobNeverTakeAWash() {
        for mode in QuireMode.allCases {
            for display in [nil, QuireDisplayState.hover, .pressed] {
                let off = QuireToggle(isOn: false)
                off.displayState = display
                var (snapshot, _) = render(off, mode, surface: .qSheet)
                var track = off.trackRect.offsetBy(dx: pad, dy: pad)
                assertPixel(snapshot, NSPoint(x: track.maxX - 5, y: track.midY), expected("sheet", "fill", mode: mode), "\(mode) off track \(String(describing: display))")
                assertPixel(snapshot, NSPoint(x: track.minX + 9, y: track.midY), expected("knob", mode: mode), "\(mode) knob face")

                let on = QuireToggle(isOn: true)
                on.displayState = display
                (snapshot, _) = render(on, mode, surface: .qSheet)
                track = on.trackRect.offsetBy(dx: pad, dy: pad)
                assertPixel(snapshot, NSPoint(x: track.minX + 4, y: track.midY), expected("accentFill", mode: mode), "\(mode) on track \(String(describing: display))")
            }
        }
    }

    // MARK: Fields

    func testTextFieldStates() {
        for mode in QuireMode.allCases {
            let hover = QuireTextField(placeholder: "Client ID")
            hover.displayState = .hover
            var (snapshot, face) = render(hover, mode, surface: .qSheet)
            assertPixel(snapshot, NSPoint(x: face.minX + 0.25, y: face.midY), expected("ink3", mode: mode), "\(mode) hover edge")

            let error = QuireTextField(placeholder: "Client ID")
            error.errorMessage = "That doesn't look like a Google client ID."
            (snapshot, face) = render(error, mode, surface: .qSheet)
            assertPixel(snapshot, NSPoint(x: face.minX + 0.5, y: face.midY), expected("danger", mode: mode), "\(mode) error edge")

            let disabled = QuireTextField(placeholder: "Disabled")
            disabled.isEnabled = false
            (snapshot, face) = render(disabled, mode, surface: .qSheet)
            assertPixel(snapshot, NSPoint(x: face.minX + 0.25, y: face.midY), expected("sheet", "fill", mode: mode), "\(mode) disabled, no edge")
        }
    }

    func testSearchFieldRestHoverAndDisabled() {
        for mode in QuireMode.allCases {
            let rest = QuireSearchField()
            var (snapshot, face) = render(rest, mode)
            assertPixel(snapshot, NSPoint(x: face.minX + 0.25, y: face.midY), expected("ruleStrong", mode: mode), "\(mode) resting edge")
            assertPixel(snapshot, NSPoint(x: face.minX + 4, y: face.minY + 4), expected("sheet", mode: mode), "\(mode) face")
            XCTAssertTrue(rest.showsKeycap)

            let hover = QuireSearchField()
            hover.displayState = .hover
            (snapshot, face) = render(hover, mode)
            assertPixel(snapshot, NSPoint(x: face.minX + 4, y: face.minY + 4), expected("sheet", "hover", mode: mode), "\(mode) hover face")

            let disabled = QuireSearchField()
            disabled.isEnabled = false
            (snapshot, face) = render(disabled, mode)
            assertPixel(snapshot, NSPoint(x: face.minX + 0.25, y: face.midY), expected("paper", "fill", mode: mode), "\(mode) disabled")
            XCTAssertFalse(disabled.showsKeycap)
        }
    }

    func testSearchTrailingContentFollowsState() {
        let search = QuireSearchField()
        XCTAssertTrue(search.showsKeycap)
        XCTAssertFalse(search.showsResults)
        search.query = "lisbon"
        XCTAssertFalse(search.showsKeycap, "no keycap once there is a query")
        XCTAssertFalse(search.showsResults)
        search.resultCount = 38
        XCTAssertTrue(search.showsResults)
        search.displayState = .focused
        search.query = ""
        XCTAssertFalse(search.showsKeycap, "no keycap while focused")
    }

    // MARK: Tabs, rules, popups

    func testTabUnderlineFollowsWindowKeyState() {
        for mode in QuireMode.allCases {
            for key in [true, false] {
                let tabs = QuireUnderlineTabs(titles: ["All", "Focused", "Other"])
                tabs.windowKeyOverride = key
                let (snapshot, _) = render(tabs, mode)
                let label = tabs.labelRect(forTab: 0).offsetBy(dx: pad, dy: pad)
                let y = pad + tabs.bodyRect.minY + 39
                assertPixel(snapshot, NSPoint(x: label.midX, y: y), expected(key ? "ink" : "ink3", mode: mode), "\(mode) key \(key)")
                let other = tabs.labelRect(forTab: 1).offsetBy(dx: pad, dy: pad)
                assertPixel(snapshot, NSPoint(x: other.midX, y: y), expected("paper", mode: mode), "\(mode) no underline on rest tabs")
            }
        }
    }

    func testDisabledTabsDrawNoUnderline() {
        let tabs = QuireUnderlineTabs(titles: ["All", "Focused", "Other"])
        tabs.windowKeyOverride = true
        tabs.isEnabled = false
        let (snapshot, _) = render(tabs, .light)
        let label = tabs.labelRect(forTab: 0).offsetBy(dx: pad, dy: pad)
        assertPixel(snapshot, NSPoint(x: label.midX, y: pad + tabs.bodyRect.minY + 39), expected("paper", mode: .light), "first sync")
    }

    func testMarginRuleColourFollowsWindowKeyState() {
        for mode in QuireMode.allCases {
            for key in [true, false] {
                let rule = QuireMarginRule(height: 24)
                rule.windowKeyOverride = key
                let snapshot = ComponentSnapshot.render(rule, mode: mode, padding: pad)
                assertPixel(snapshot, NSPoint(x: pad + 1, y: pad + 12), expected(key ? "selRule" : "selRuleIdle", mode: mode), "\(mode) key \(key)")
            }
        }
    }

    func testPopupInkKeepsItsRaisedHaloWhenPressed() {
        for mode in QuireMode.allCases {
            let popup = QuirePopUpButton(titles: ["Persimmon"])
            popup.inkMark = .swatch(slot: 0)
            popup.displayState = .pressed
            let (snapshot, face) = render(popup, mode)
            let swatchMinX = face.minX + Quire.Layout.Popup.padLeft
            assertPixel(snapshot, NSPoint(x: swatchMinX - 1, y: face.midY), expected("raised", mode: mode), "\(mode) halo")
            assertPixel(snapshot, NSPoint(x: face.minX + 3, y: face.midY), expected("raised", "pressed", mode: mode), "\(mode) pressed face")
            assertPixel(snapshot, NSPoint(x: swatchMinX + 7, y: face.midY), TokenResolver.resolve("account:Persimmon", mode), "\(mode) swatch")
        }
    }

    func testBorderlessPopupHasNoFaceAtRest() {
        let popup = QuirePopUpButton(titles: ["Alex Morgan"], isBorderless: true)
        let (snapshot, face) = render(popup, .light)
        assertPixel(snapshot, NSPoint(x: face.minX + 0.25, y: face.midY), expected("paper", mode: .light), "no edge")
    }

    // MARK: Surfaces

    func testBannerWashes() {
        let kinds: [(QuireBanner.Kind, [String])] = [
            (.neutral, ["sheet", "fill"]), (.info, ["infoWash"]), (.success, ["successWash"]), (.warning, ["warningWash"]), (.danger, ["dangerWash"]),
        ]
        for mode in QuireMode.allCases {
            for (kind, stack) in kinds {
                let banner = QuireBanner(kind: kind, message: "Words")
                banner.setFrameSize(NSSize(width: 300, height: 32))
                let snapshot = ComponentSnapshot.render(banner, mode: mode, surface: .qSheet, padding: pad)
                assertPixel(snapshot, NSPoint(x: pad + 4, y: pad + 16), TokenResolver.resolveStack(stack, mode), "\(mode) \(kind)")
            }
        }
    }

    func testSlipIsDarkInBothAppearances() {
        for mode in QuireMode.allCases {
            let slip = QuireSlipView(kind: .confirmation, message: "Undid Archive")
            let snapshot = ComponentSnapshot.render(slip, mode: mode, padding: 20)
            let point = NSPoint(x: 20 + 6, y: 20 + 17)
            assertPixel(snapshot, point, expected("slip", mode: mode), "\(mode) slip")
            XCTAssertLessThan(ColorLib.luminance(snapshot.rgba(at: point)), 0.05, "\(mode): dark")
        }
    }

    func testSheetEdgeAndIncreaseContrastOutline() {
        for mode in QuireMode.allCases {
            let sheet = QuireSheetView(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
            let snapshot = ComponentSnapshot.render(sheet, mode: mode, surface: .qCanvas, padding: 20)
            assertPixel(snapshot, NSPoint(x: 20 + 60, y: 20 + 30), expected("sheet", mode: mode), "\(mode) fill")
            let edge = sheet.surface.resolvedEdge
            if mode.isIncreasedContrast {
                XCTAssertEqual(edge.width, 1, "\(mode): ruleStrong outline")
                assertPixel(snapshot, NSPoint(x: 20 + 60, y: 20.25), expected("ruleStrong", mode: mode), "\(mode) outline")
            } else {
                let scale = sheet.window?.backingScaleFactor ?? 2
                XCTAssertEqual(edge.width, 1 / scale, "\(mode): one device pixel")
            }
            XCTAssertGreaterThan(sheet.surface.resolvedShadowOpacity, 0, "\(mode): e1 keeps its shadow")
        }
    }

    func testScrimTurnsSolidUnderReduceTransparency() {
        let scrim = QuireScrimView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        scrim.appearance = QuireMode.light.appearance
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false))
        XCTAssertFalse(scrim.isSolid)
        XCTAssertEqual(ColorLib.rgb2hex(rgba(scrim.layer?.backgroundColor)), "#1D1B18")
        XCTAssertEqual(scrim.layer?.backgroundColor?.alpha ?? 0, CGFloat(0x47) / 255, accuracy: 0.002)
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: true))
        XCTAssertTrue(scrim.isSolid)
        XCTAssertEqual(ColorLib.rgb2hex(rgba(scrim.layer?.backgroundColor)), "#B8B6B1", "scrimSolid, opaque")
        XCTAssertEqual(scrim.layer?.backgroundColor?.alpha, 1)
    }

    func testSpinnerColours() {
        let spinner = QuireSpinnerView()
        spinner.appearance = QuireMode.dark.appearance
        spinner.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(ColorLib.rgb2hex(rgba(spinner.resolvedColor)), "#A8A297", "ink3 in Dark")
        let button = QuireButton(title: "Send", variant: .primary)
        button.appearance = QuireMode.light.appearance
        button.windowKeyOverride = true
        button.loadingTitle = "Sending…"
        button.isLoading = true
        XCTAssertEqual(ColorLib.rgb2hex(rgba(button.spinner?.resolvedColor)), "#FFFFFF", "onAccent inside the primary fill")
        button.windowKeyOverride = false
        XCTAssertEqual(ColorLib.rgb2hex(rgba(button.spinner?.resolvedColor)), "#625C55", "ink3 once it draws as secondary")
    }

    private func rgba(_ cg: CGColor?) -> RGBA {
        guard let cg, let c = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        return RGBA(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }
}
