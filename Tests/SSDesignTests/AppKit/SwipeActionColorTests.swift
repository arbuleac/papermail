import AppKit
import XCTest
@testable import SSDesign

/// A swipe's buttons (spec §5.7, Swipe): Archive on the theme's fill and Mark as Read or Unread on the quiet grey, each
/// holding AppKit's white title at 4.5:1 in every theme, mode and under Graphite, apart from each other, and following
/// a theme switch on a button already made. The values come from tokens.json, so a change there that the runtime does
/// not follow, or that lets the fills meet, fails here.
@MainActor
final class SwipeActionColorTests: XCTestCase {
    private let file = DesignTokensFile.shared
    private let tokens: [QuireSwipeAction: String] = [.archive: "swipeArchive", .readState: "swipeRead"]

    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private func force(_ theme: QuireTheme, graphite: Bool) {
        QuireEnvironment.shared.setOverrides(.init(isGraphite: graphite, increaseContrast: false, reduceMotion: false,
                                                   reduceTransparency: false, theme: theme))
    }

    /// The token's value in tokens.json for `theme` and `mode`, its Graphite value when `graphite` and it has one.
    private func expected(_ token: String, _ theme: QuireTheme, _ mode: QuireMode, graphite: Bool) throws -> RGBA {
        let entry = try XCTUnwrap(file.array("themes").compactMap { $0 as? [String: Any] }.first { $0["id"] as? String == theme.rawValue })
        let colors = try XCTUnwrap(entry["color"] as? [String: [String: String]])
        let substitutes = try XCTUnwrap(entry["graphite"] as? [String: [String: String]])
        let hex = (graphite ? substitutes[token]?[mode.rawValue] : nil) ?? colors[token]?[mode.rawValue]
        return ColorLib.hex2rgba(try XCTUnwrap(hex, "\(token) in \(theme)"))
    }

    private func hex(_ c: RGBA) -> String { ColorLib.rgb2hex(c) }

    // MARK: Values

    func testEachButtonsFillAndTitleInEveryThemeModeAndUnderGraphite() throws {
        for theme in QuireTheme.allCases {
            for graphite in [false, true] {
                force(theme, graphite: graphite)
                for mode in QuireMode.allCases {
                    for style in QuireSwipeAction.allCases {
                        let label = "\(style) in \(theme) \(mode.rawValue)\(graphite ? " under Graphite" : "")"
                        let fill = TokenResolver.rgba(style.fill, mode)
                        let title = TokenResolver.rgba(style.titleColor, mode)
                        XCTAssertEqual(hex(fill), hex(try expected(tokens[style]!, theme, mode, graphite: graphite)), label)
                        XCTAssertEqual(fill.a, 1, "opaque, so the title's ratio never depends on the row behind: " + label)
                        XCTAssertEqual(hex(title), "#FFFFFF", "AppKit's white: " + label)
                        XCTAssertGreaterThanOrEqual(ColorLib.contrast(title, fill), 4.5, label)
                    }
                }
            }
        }
    }

    /// Archive is the theme's own fill, as on a primary button; under Graphite, and in Gallery, whose ink is its text
    /// ink, `ink` would turn light at night under a white title, so Archive takes the slip there.
    func testArchiveIsTheThemesFillAndTheSlipWithoutColour() throws {
        for theme in QuireTheme.allCases {
            for mode in QuireMode.allCases {
                force(theme, graphite: false)
                let archive = hex(TokenResolver.rgba(QuireSwipeAction.archive.fill, mode))
                let fill = hex(TokenResolver.rgba(.qAccentFill, mode))
                let slip = hex(TokenResolver.rgba(.qSlip, mode))
                XCTAssertEqual(archive, theme == .gallery ? slip : fill, "\(theme) \(mode.rawValue)")
                force(theme, graphite: true)
                XCTAssertEqual(hex(TokenResolver.rgba(QuireSwipeAction.archive.fill, mode)), slip, "\(theme) \(mode.rawValue) Graphite")
            }
        }
    }

    /// The two edges never wear one colour: at least 12 ΔE00 apart, and 9 under every simulated colour-vision
    /// deficiency, in every theme and mode and under Graphite. The word still tells them apart; the fill says it first.
    func testTheTwoFillsStayApart() {
        for theme in QuireTheme.allCases {
            for graphite in [false, true] {
                force(theme, graphite: graphite)
                for mode in QuireMode.allCases {
                    let archive = TokenResolver.rgba(QuireSwipeAction.archive.fill, mode)
                    let read = TokenResolver.rgba(QuireSwipeAction.readState.fill, mode)
                    let distances = ColorLib.deAll(archive, read)
                    let label = "\(theme) \(mode.rawValue)\(graphite ? " Graphite" : ""): \(hex(archive)) vs \(hex(read))"
                    XCTAssertGreaterThanOrEqual(distances[.normal]!, 12, label)
                    XCTAssertGreaterThanOrEqual(distances.values.min()!, 9, label)
                }
            }
        }
    }

    // MARK: Live

    /// A button already made follows a theme switch, Graphite and the mode, because its fill is the live token and not
    /// a colour resolved when it was made.
    func testAThemeSwitchChangesAButtonAlreadyMade() throws {
        force(.study, graphite: false)
        let archive = QuireSwipeAction.archive.rowAction(title: "Archive") { _, _ in }
        let read = QuireSwipeAction.readState.rowAction(title: "Mark as Read") { _, _ in }
        for mode in QuireMode.allCases {
            force(.study, graphite: false)
            let studyArchive = hex(TokenResolver.rgba(archive.backgroundColor, mode))
            let studyRead = hex(TokenResolver.rgba(read.backgroundColor, mode))
            XCTAssertEqual(studyArchive, hex(try expected("swipeArchive", .study, mode, graphite: false)))
            for theme in QuireTheme.allCases where theme != .study {
                force(theme, graphite: false)
                let themedArchive = hex(TokenResolver.rgba(archive.backgroundColor, mode))
                let themedRead = hex(TokenResolver.rgba(read.backgroundColor, mode))
                XCTAssertEqual(themedArchive, hex(try expected("swipeArchive", theme, mode, graphite: false)), "\(theme) \(mode.rawValue)")
                XCTAssertEqual(themedRead, hex(try expected("swipeRead", theme, mode, graphite: false)), "\(theme) \(mode.rawValue)")
                XCTAssertNotEqual(themedArchive, studyArchive, "\(theme) \(mode.rawValue): Archive takes the theme's colour")
                XCTAssertNotEqual(themedRead, studyRead, "\(theme) \(mode.rawValue): the grey takes the theme's paper")
            }
            force(.study, graphite: true)
            XCTAssertEqual(hex(TokenResolver.rgba(archive.backgroundColor, mode)), hex(try expected("swipeArchive", .study, mode, graphite: true)),
                           "\(mode.rawValue): Graphite on a button already made")
        }
    }

    // MARK: The row action

    func testTheRowActionIsRegularWithTheLiveFillAndNoImage() {
        let action = QuireSwipeAction.readState.rowAction(title: "Mark as Unread") { _, _ in }
        XCTAssertEqual(action.title, "Mark as Unread", "the words AppKit draws and VoiceOver reads")
        XCTAssertEqual(action.style, .regular, "no destructive animation: the list never animates a row leaving")
        XCTAssertTrue(action.backgroundColor === QuireSwipeAction.readState.fill, "the live token, not a resolved copy")
        XCTAssertNil(action.image, "an image would move the title out of the capsule")
        XCTAssertFalse(QuireSwipeAction.archive.fill === QuireSwipeAction.readState.fill)
    }
}
