import AppKit
import SwiftUI
import XCTest
@testable import SSDesign

/// `QuireButtonStyle` against spec §5.24 and `layout.button`.
@MainActor
final class ButtonStyleTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private let rest = QuireControlState()
    private let hover = QuireControlState(isHovered: true)
    private let pressed = QuireControlState(isHovered: true, isPressed: true)
    private let focused = QuireControlState(isFocused: true)
    private let disabled = QuireControlState(isHovered: true, isPressed: true, isFocused: true, isEnabled: false)
    private let notKey = QuireControlState(isWindowKey: false)

    // MARK: State → token

    func testPrimaryStates() {
        let r = { QuireButtonAppearance.resolve(.primary, size: .regular, state: $0) }
        XCTAssertEqual(r(rest).fill, QuireFill(.accentFill))
        XCTAssertEqual(r(rest).label, .onAccent)
        XCTAssertNil(r(rest).edge)
        XCTAssertEqual(r(rest).font, .bodyStrong, "primary labels take the size's strong role")
        XCTAssertEqual(r(hover).fill, QuireFill(.accentFillHover))
        XCTAssertEqual(r(pressed).fill, QuireFill(.accentFillPressed), "pressed wins over hover")
        XCTAssertEqual(r(focused).ringGap, Quire.Border.FocusRing.gapOnAccentFill, "2 pt gap around accent fills")
        XCTAssertNil(r(rest).ringGap)
        XCTAssertEqual(r(disabled).fill, QuireFill(wash: .fill))
        XCTAssertEqual(r(disabled).label, .inkDisabled)
        XCTAssertNil(r(disabled).ringGap, "a disabled button never shows a ring")
    }

    func testPrimaryInANonKeyWindowDrawsAsSecondary() {
        let primary = QuireButtonAppearance.resolve(.primary, size: .small, state: notKey)
        let secondary = QuireButtonAppearance.resolve(.secondary, size: .small, state: rest)
        XCTAssertEqual(primary, secondary)
        XCTAssertEqual(primary.fill, QuireFill(.raised))
        XCTAssertEqual(primary.edge, .strong)
        XCTAssertEqual(primary.label, .ink)
        XCTAssertEqual(primary.font, .label)
        XCTAssertNil(QuireButtonAppearance.resolve(.primary, size: .small, state: QuireControlState(isFocused: true, isWindowKey: false)).ringGap,
                     "no focus ring in a window that is not key")
        // Every other variant is unchanged by key state (spec §3.4).
        for variant in [QuireButtonVariant.secondary, .ghost, .destructive, .link, .icon] {
            XCTAssertEqual(QuireButtonAppearance.resolve(variant, size: .small, state: notKey),
                           QuireButtonAppearance.resolve(variant, size: .small, state: rest), "\(variant)")
        }
    }

    func testSecondaryStates() {
        let r = { QuireButtonAppearance.resolve(.secondary, size: .regular, state: $0) }
        XCTAssertEqual(r(rest).fill, QuireFill(.raised))
        XCTAssertEqual(r(rest).edge, QuireStroke(.ruleStrong, width: 1))
        XCTAssertEqual(r(rest).label, .ink)
        XCTAssertEqual(r(rest).font, .bodyMedium)
        XCTAssertEqual(r(hover).fill, QuireFill(.raised, wash: .hover))
        XCTAssertEqual(r(pressed).fill, QuireFill(.raised, wash: .pressed))
        XCTAssertEqual(r(focused).ringGap, Quire.Border.FocusRing.gap)
        XCTAssertEqual(r(disabled).fill, QuireFill(wash: .fill))
        XCTAssertNil(r(disabled).edge, "disabled secondary loses its edge")
        XCTAssertEqual(r(disabled).label, .inkDisabled)
    }

    func testGhostAndIconStates() {
        for variant in [QuireButtonVariant.ghost, .icon] {
            let r = { QuireButtonAppearance.resolve(variant, size: .small, state: $0) }
            XCTAssertEqual(r(rest).fill, .clear, "\(variant)")
            XCTAssertEqual(r(rest).label, .ink2)
            XCTAssertEqual(r(hover).fill, QuireFill(wash: .hover))
            XCTAssertEqual(r(hover).label, .ink)
            XCTAssertEqual(r(pressed).fill, QuireFill(wash: .pressed))
            XCTAssertEqual(r(pressed).label, .ink)
            XCTAssertEqual(r(focused).ringGap, Quire.Border.FocusRing.gap)
            XCTAssertEqual(r(disabled).fill, .clear)
            XCTAssertEqual(r(disabled).label, .inkDisabled)
        }
    }

    func testDestructiveStates() {
        let r = { QuireButtonAppearance.resolve(.destructive, size: .large, state: $0) }
        XCTAssertEqual(r(rest).fill, QuireFill(.dangerFill))
        XCTAssertEqual(r(rest).label, .onDanger)
        XCTAssertEqual(r(rest).font, .buttonLargeStrong)
        XCTAssertEqual(r(hover).fill, QuireFill(.dangerFillHover))
        XCTAssertEqual(r(pressed).fill, QuireFill(.dangerFillPressed))
        XCTAssertEqual(r(focused).ringGap, Quire.Border.FocusRing.gapOnAccentFill)
        XCTAssertEqual(r(disabled).fill, QuireFill(wash: .fill))
        XCTAssertEqual(r(disabled).label, .inkDisabled)
    }

    func testLinkNeverTakesAWash() {
        let r = { QuireButtonAppearance.resolve(.link, size: .small, state: $0) }
        for state in [rest, hover, pressed, focused, disabled] {
            XCTAssertEqual(r(state).fill, .clear, "a link sits on washes and never adds one (spec §5.24)")
        }
        XCTAssertEqual(r(rest).label, .accent)
        XCTAssertFalse(r(rest).underline)
        XCTAssertEqual(r(hover).label, .accent)
        XCTAssertTrue(r(hover).underline)
        XCTAssertEqual(r(pressed).label, .ink2, "pressed: ink2 with the underline kept")
        XCTAssertTrue(r(pressed).underline)
        XCTAssertEqual(r(disabled).label, .inkDisabled)
        XCTAssertFalse(r(disabled).underline)
        XCTAssertEqual(r(focused).ringGap, Quire.Border.FocusRing.gap)
    }

    func testLinkIsUnderlinedAtRestUnderGraphite() {
        let state = QuireControlState(isGraphite: true)
        XCTAssertTrue(QuireButtonAppearance.resolve(.link, size: .regular, state: state).underline)
        XCTAssertFalse(QuireButtonAppearance.resolve(.ghost, size: .regular, state: state).underline)
    }

    func testForcedStatesAddToTheLiveState() {
        XCTAssertEqual(rest.forcing([.hovered, .focused]), QuireControlState(isHovered: true, isFocused: true))
        XCTAssertEqual(rest.forcing(.pressed).isPressed, true)
        XCTAssertEqual(disabled.forcing(.hovered).isEnabled, false, "forcing never enables")
    }

    // MARK: Metrics

    func testSizesComeFromTheTokens() {
        XCTAssertEqual(QuireButtonSize.small.height, 22)
        XCTAssertEqual(QuireButtonSize.regular.height, 28)
        XCTAssertEqual(QuireButtonSize.large.height, 36)
        XCTAssertEqual(QuireButtonSize.allCases.map(\.padX), [9, 12, 16])
        XCTAssertEqual(QuireButtonSize.allCases.map(\.radius), [5, 6, 8])
        XCTAssertEqual(QuireButtonSize.allCases.map(\.font), [.label, .bodyMedium, .buttonLarge])
        XCTAssertEqual(QuireButtonSize.allCases.map(\.fontStrong), [.labelStrong, .bodyStrong, .buttonLargeStrong])
        XCTAssertEqual(QuireButtonSize.allCases.map(\.glyph), [12, 14, 18])
        XCTAssertEqual(QuireButtonSize.allCases.map(\.iconSide), [22, 24, 28])
        XCTAssertEqual(QuireButtonSize.allCases.map(\.iconRadius), [5, 5, 6])
        // Every role name in tokens.json resolves to a role, so the fallback never fires.
        for name in [Quire.Layout.Button.Small.font, Quire.Layout.Button.Small.fontStrong, Quire.Layout.Button.Regular.font,
                     Quire.Layout.Button.Regular.fontStrong, Quire.Layout.Button.Large.font, Quire.Layout.Button.Large.fontStrong] {
            XCTAssertNotNil(QuireFont.Role(rawValue: name), name)
        }
    }

    func testHostedButtonsHaveTheTokenHeightAndPadding() {
        for size in QuireButtonSize.allCases {
            for variant in [QuireButtonVariant.primary, .secondary, .ghost, .destructive] {
                let title = "Reconnect"
                let host = SwiftUIHost(Button(title) {}.buttonStyle(.quire(variant, size: size)))
                let fitting = host.hostingView.fittingSize
                XCTAssertEqual(fitting.height, size.height, "\(variant) \(size)")
                let role = (variant == .primary || variant == .destructive) ? size.fontStrong : size.font
                let text = (title as NSString).size(withAttributes: [.font: QuireFont.font(role)]).width
                XCTAssertEqual(fitting.width, text + 2 * size.padX, accuracy: 1.5, "\(variant) \(size): label + padX each side")
                host.close()
            }
        }
    }

    func testIconAndLinkGeometry() {
        for size in QuireButtonSize.allCases {
            let icon = SwiftUIHost(Button {} label: { QuireButtonLabel(glyph: Quire.Icon.archive, accessibilityLabel: "Archive") }
                .buttonStyle(.quire(.icon, size: size)))
            XCTAssertEqual(icon.hostingView.fittingSize, CGSize(width: size.iconSide, height: size.iconSide), "\(size)")
            icon.close()
            let link = SwiftUIHost(Button("Load images") {}.buttonStyle(.quire(.link, size: size)))
            XCTAssertEqual(link.hostingView.fittingSize.height, max(size.height, Quire.Layout.Button.minHit),
                           "a link is never shorter than the 24 pt hit")
            link.close()
        }
    }

    func testLoadingLabelKeepsTheWiderWidth() {
        let idle = SwiftUIHost(Button {} label: { QuireButtonLabel("Send", glyph: Quire.Icon.send, loadingTitle: "Sending…") }
            .buttonStyle(.quire(.primary, size: .small)))
        let loading = SwiftUIHost(Button {} label: {
            QuireButtonLabel("Send", glyph: Quire.Icon.send, isLoading: true, loadingTitle: "Sending…")
        }.buttonStyle(.quire(.primary, size: .small)))
        XCTAssertEqual(idle.hostingView.fittingSize.width, loading.hostingView.fittingSize.width,
                       "the width is kept between rest and loading")
        let sending = ("Sending…" as NSString).size(withAttributes: [.font: QuireFont.font(.labelStrong)]).width
        XCTAssertGreaterThanOrEqual(idle.hostingView.fittingSize.width,
                                    sending + Quire.Layout.Progress.spinner[0] + Quire.Layout.Button.glyphGap + 2 * QuireButtonSize.small.padX - 1)
        idle.close()
        loading.close()
    }

    // MARK: Rendered colours

    func testRenderedFacesMatchTheirTokensInEveryMode() {
        for mode in QuireMode.allCases {
            QuireEnvironment.shared.setOverrides(.pinned(mode))
            let cells: [(QuireButtonVariant, QuireForcedStates, Bool, QuireFill)] = [
                (.primary, [], true, QuireFill(.accentFill)),
                (.primary, .hovered, true, QuireFill(.accentFillHover)),
                (.primary, .pressed, true, QuireFill(.accentFillPressed)),
                (.primary, [], false, QuireFill(.raised)),
                (.secondary, .pressed, true, QuireFill(.raised, wash: .pressed)),
                (.ghost, .hovered, true, QuireFill(wash: .hover)),
                (.destructive, [], true, QuireFill(.dangerFill)),
            ]
            for (variant, forced, key, fill) in cells {
                let view = Button {} label: { Color.clear.frame(width: 40, height: 10) }
                    .buttonStyle(.quire(variant, size: .regular))
                    .quireForcedStates(forced)
                    .environment(\.controlActiveState, key ? .key : .inactive)
                    .padding(8)
                    .background(Color.qCanvas)
                let host = SwiftUIHost(view, mode: mode)
                let rep = host.render()
                // Inside the face, clear of the label and of the edge.
                XCTAssertColor(rep.srgb(at: CGPoint(x: 8 + 6, y: 8 + 14)), Expected.color(fill, over: .canvas, mode),
                               "\(variant) \(forced) key \(key) \(mode)")
                host.close()
            }
        }
    }

    func testFocusRingIsDrawnOutsideTheGapAndThickensUnderIncreaseContrast() {
        for mode in QuireMode.allCases {
            QuireEnvironment.shared.setOverrides(.pinned(mode))
            let pad: CGFloat = 10
            let view = Button {} label: { Color.clear.frame(width: 40, height: 10) }
                .buttonStyle(.quire(.secondary, size: .regular))
                .quireForcedStates(.focused)
                .environment(\.controlActiveState, .key)
                .padding(pad)
                .background(Color.qCanvas)
            let host = SwiftUIHost(view, mode: mode)
            let rep = host.render()
            let midY = pad + 14
            let gap = Quire.Border.FocusRing.gap
            let width = mode.isIncreasedContrast ? Quire.Border.FocusRing.widthHC : Quire.Border.FocusRing.width
            let focus = TokenResolver.resolve("focus", mode)
            let canvas = TokenResolver.resolve("canvas", mode)
            // Leftward from the face: the 1 pt gap shows the canvas, then the ring, then canvas again.
            XCTAssertColor(rep.srgb(at: CGPoint(x: pad - gap / 2, y: midY)), canvas, "gap \(mode)")
            XCTAssertColor(rep.srgb(at: CGPoint(x: pad - gap - width / 2, y: midY)), focus, "ring \(mode)")
            XCTAssertColor(rep.srgb(at: CGPoint(x: pad - gap - width - 0.75, y: midY)), canvas, "outside the ring \(mode)")
            // 2.5 pt out from the gap: inside a 3 pt IC ring, outside a 2 pt one.
            XCTAssertColor(rep.srgb(at: CGPoint(x: pad - gap - 2.5, y: midY)), mode.isIncreasedContrast ? focus : canvas,
                           "ring width \(mode)")
            host.close()
        }
    }

    func testFocusRingHiddenWhenTheWindowIsNotKey() {
        let pad: CGFloat = 10
        let view = Button {} label: { Color.clear.frame(width: 40, height: 10) }
            .buttonStyle(.quire(.secondary, size: .regular))
            .quireForcedStates(.focused)
            .environment(\.controlActiveState, .inactive)
            .padding(pad)
            .background(Color.qCanvas)
        let host = SwiftUIHost(view)
        let rep = host.render()
        XCTAssertColor(rep.srgb(at: CGPoint(x: pad - 2, y: pad + 14)), TokenResolver.resolve("canvas", .light))
        host.close()
    }
}
