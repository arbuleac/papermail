import AppKit
import XCTest
@testable import SSDesign

/// The button a swipe uncovers (spec §5.7, Swipe), drawn by the app and not by AppKit: its fill over the whole area it is
/// given, and its icon and label white on it, in every theme and mode and under Graphite; the label shown only whole, the
/// icon alone where the label would not fit; a click or VoiceOver's press, and the pointing hand.
@MainActor
final class QuireSwipeButtonTests: XCTestCase {
    private let titles: [QuireSwipeAction: String] = [.archive: "Archive", .markRead: "Mark as Read", .markUnread: "Mark as Unread"]

    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private func button(_ kind: QuireSwipeAction, width: CGFloat? = nil, height: CGFloat = Quire.Layout.Row.height,
                        textSize: QuireFont.TextSize = .default) -> QuireSwipeButton {
        let title = titles[kind]!
        let button = QuireSwipeButton(kind: kind, title: title, textSize: textSize)
        button.frame = NSRect(x: 0, y: 0, width: width ?? QuireSwipeButton.openWidth(title: title, textSize: textSize), height: height)
        return button
    }

    /// The pixels inside `rect` (in the button's coordinates, y down), one per point.
    private func pixels(_ snapshot: ComponentSnapshot, in rect: NSRect) -> [RGBA] {
        var out: [RGBA] = []
        var y = rect.minY + 0.5
        while y < rect.maxY {
            var x = rect.minX + 0.5
            while x < rect.maxX {
                out.append(snapshot.rgba(at: NSPoint(x: x, y: y)))
                x += 0.5
            }
            y += 0.5
        }
        return out
    }

    private func isWhite(_ c: RGBA) -> Bool { c.r > 0.97 && c.g > 0.97 && c.b > 0.97 }

    // MARK: Drawing

    /// The fill everywhere the content is not, and the icon and the label drawn white on it: their brightest pixels are
    /// white, and no pixel of the button is darker than its fill, so nothing on it is ever drawn dark (the black title
    /// AppKit's own button drew in a key window).
    func testItDrawsItsFillAndAWhiteIconAndLabelInEveryThemeModeAndUnderGraphite() {
        for theme in QuireTheme.allCases {
            for graphite in [false, true] {
                for mode in QuireMode.allCases {
                    for kind in QuireSwipeAction.allCases {
                        let view = button(kind)
                        let label = "\(kind) in \(theme) \(mode.rawValue)\(graphite ? " under Graphite" : "")"
                        let snapshot = ComponentSnapshot.render(view, mode: mode, scale: 2, graphite: graphite, theme: theme)
                        let fill = TokenResolver.rgba(kind.fill, mode)
                        XCTAssertTrue(snapshot.matches(fill, at: NSPoint(x: 2, y: 2)), "the fill at the corner: " + label)
                        XCTAssertTrue(snapshot.matches(fill, at: NSPoint(x: view.bounds.width - 2, y: view.bounds.height - 2)), label)
                        let layout = view.currentLayout
                        XCTAssertEqual(layout.iconAlpha, 1, label)
                        XCTAssertEqual(layout.labelAlpha, 1, "open, the label shows whole: " + label)
                        XCTAssertTrue(pixels(snapshot, in: layout.icon).contains(where: isWhite), "a white icon: " + label)
                        XCTAssertTrue(pixels(snapshot, in: layout.label).contains(where: isWhite), "a white label: " + label)
                        let floor = ColorLib.luminance(fill) - 0.004
                        let darkest = pixels(snapshot, in: view.bounds).map(ColorLib.luminance).min() ?? 0
                        XCTAssertGreaterThanOrEqual(darkest, floor, "nothing darker than the fill: " + label)
                        XCTAssertGreaterThanOrEqual(ColorLib.contrast(TokenResolver.rgba(kind.contentColor, mode), fill), 4.5, label)
                    }
                }
            }
        }
    }

    /// Each kind wears its own symbol, the one the Message menu and the toast show for the change.
    func testEachKindShowsTheMenusSymbol() {
        XCTAssertEqual(QuireSwipeAction.archive.symbolName, Quire.Icon.archive)
        XCTAssertEqual(QuireSwipeAction.markRead.symbolName, Quire.Icon.markRead)
        XCTAssertEqual(QuireSwipeAction.markUnread.symbolName, Quire.Icon.markUnread)
        for kind in QuireSwipeAction.allCases {
            XCTAssertTrue(QuireSymbol.exists(kind.symbolName), "\(kind)")
            XCTAssertNotNil(QuireSymbol.cachedImage(kind.symbolName, size: QuireSwipeButton.symbolSize), "\(kind)")
        }
    }

    // MARK: Narrow

    /// While the swipe uncovers only a little, the label shows only where it fits whole with room either side, fading in
    /// over the last `padX`, and never cut; the icon shows alone before it, centred, and the fill alone before that.
    func testTheLabelShowsOnlyWholeAndTheIconAloneBeforeIt() throws {
        let pad = Quire.Layout.Swipe.padX
        let glyph = Quire.Layout.Swipe.glyph
        for (kind, title) in titles {
            let open = QuireSwipeButton.openWidth(title: title, textSize: .default)
            let labelWidth = QuireSwipeButton.layout(title: title, textSize: .default, size: NSSize(width: open, height: 68)).label.width
            func layout(_ width: CGFloat) -> QuireSwipeButton.Layout {
                QuireSwipeButton.layout(title: title, textSize: .default, size: NSSize(width: width, height: 68))
            }
            XCTAssertEqual(layout(labelWidth + pad).labelAlpha, 0, "\(kind): hidden while it has only half its room")
            XCTAssertEqual(layout(labelWidth + 2 * pad).labelAlpha, 1, "\(kind): whole with its room")
            XCTAssertEqual(layout(glyph + pad).iconAlpha, 0, "\(kind)")
            XCTAssertEqual(layout(glyph + 2 * pad).iconAlpha, 1, "\(kind)")
            for width in stride(from: CGFloat(4), through: open, by: 3) {
                let l = layout(width)
                if l.labelAlpha > 0 {
                    XCTAssertGreaterThanOrEqual(l.label.minX, 0, "\(kind) at \(width): never cut")
                    XCTAssertLessThanOrEqual(l.label.maxX, width, "\(kind) at \(width): never cut")
                }
                XCTAssertEqual(l.icon.midX, (width / 2).rounded(), accuracy: 1, "\(kind) at \(width): centred")
            }
            // Drawn: the icon white, nothing where the label would be.
            let narrow = button(kind, width: glyph + 2 * pad)
            let snapshot = ComponentSnapshot.render(narrow, mode: .light, scale: 2)
            let l = narrow.currentLayout
            XCTAssertTrue(pixels(snapshot, in: l.icon).contains(where: isWhite), "\(kind): the icon alone")
            let below = NSRect(x: 0, y: l.icon.maxY + 2, width: narrow.bounds.width, height: narrow.bounds.height - l.icon.maxY - 4)
            XCTAssertFalse(pixels(snapshot, in: below).contains(where: isWhite), "\(kind): no label yet")
        }
    }

    /// Opened, the button holds its label whole with `padX` either side and is never narrower than `minWidth`, and the icon
    /// over the label fits in every row it can be uncovered on: standard and compact, at every Text size.
    func testOpenTheLabelFitsAndTheStackFitsEveryRow() {
        for textSize in QuireFont.TextSize.allCases {
            for (kind, title) in titles {
                let open = QuireSwipeButton.openWidth(title: title, textSize: textSize)
                XCTAssertGreaterThanOrEqual(open, Quire.Layout.Swipe.minWidth)
                for compact in [false, true] {
                    let height = QuireRowMetrics(textSize: textSize, compact: compact).height
                    let l = QuireSwipeButton.layout(title: title, textSize: textSize, size: NSSize(width: open, height: height))
                    let label = "\(kind) at \(textSize)\(compact ? ", compact" : "")"
                    XCTAssertEqual(l.labelAlpha, 1, label)
                    XCTAssertGreaterThanOrEqual(l.label.minX, Quire.Layout.Swipe.padX - 1, label)
                    XCTAssertLessThanOrEqual(l.label.maxX, open - Quire.Layout.Swipe.padX + 1, label)
                    XCTAssertGreaterThanOrEqual(l.icon.minY, Quire.Space.s2, "room above the icon: " + label)
                    XCTAssertLessThanOrEqual(l.label.maxY, height - Quire.Space.s2, "room below the label: " + label)
                    XCTAssertEqual(l.label.minY - l.icon.maxY, Quire.Layout.Swipe.glyphGap, accuracy: 1, label)
                }
            }
        }
    }

    // MARK: Behaviour

    func testVoiceOverPressesItAsAButtonNamedByItsWords() {
        let view = button(.markUnread)
        var pressed = 0
        XCTAssertFalse(view.accessibilityPerformPress(), "inert without an action")
        view.onPress = { pressed += 1 }
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .button)
        XCTAssertEqual(view.accessibilityLabel(), "Mark as Unread")
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(pressed, 1)
        XCTAssertFalse(view.acceptsFirstResponder, "no keyboard focus: E and U do the same")
    }

    func testThePointingHandOverAllOfIt() {
        let view = button(.archive)
        XCTAssertEqual(view.pointerRegions, [.control(view.bounds, acts: false)], "the arrow while it does nothing")
        view.onPress = {}
        XCTAssertEqual(view.pointerRegions, [QuirePointerRegion(view.bounds, cursor: .pointingHand)])
    }

    /// A button already out follows the theme: its colours are the live tokens, read when it draws, and it asks to be
    /// drawn again when the environment changes.
    func testAThemeChangeRedrawsAButtonAlreadyOut() {
        let view = button(.archive)
        let study = ComponentSnapshot.render(view, mode: .dark, scale: 2, theme: .study)
        let rain = ComponentSnapshot.render(view, mode: .dark, scale: 2, theme: .rain)
        XCTAssertNotEqual(study.hex(at: NSPoint(x: 2, y: 2)), rain.hex(at: NSPoint(x: 2, y: 2)))
        XCTAssertTrue(rain.matches(TokenResolver.rgba(.qSwipeArchive, .dark), at: NSPoint(x: 2, y: 2)))
        view.needsDisplay = false
        QuireEnvironment.shared.setOverrides(.init(isGraphite: true, increaseContrast: false, reduceMotion: false, reduceTransparency: false,
                                                   theme: .rain))
        XCTAssertTrue(view.needsDisplay, "Graphite marks it for drawing again")
    }
}
