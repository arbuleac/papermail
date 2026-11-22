import AppKit
import SwiftUI
import XCTest
@testable import PaperDesign

/// Themes in the runtime (spec §4.16): every theme's providers, Study's equality with `color`, the change notification,
/// the cache keys, the link flags, lazy colours, the redraw sweep, SwiftUI redrawing in place, and the source rules that
/// keep a switch reaching every surface.
@MainActor
final class ThemeTests: XCTestCase {
    private let file = DesignTokensFile.shared

    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireEnvironment.shared.setTheme(.study)
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private func hex(_ color: NSColor, _ mode: QuireMode) -> String {
        let c = TokenResolver.rgba(color, mode)
        func byte(_ x: Double) -> UInt32 { UInt32((x * 255).rounded()) }
        return String(format: "#%08X", byte(c.r) << 24 | byte(c.g) << 16 | byte(c.b) << 8 | byte(c.a))
    }

    private func hex(_ value: UInt32) -> String { String(format: "#%08X", value) }

    private func hex(json: String) -> String {
        var h = json.hasPrefix("#") ? String(json.dropFirst()) : json
        if h.count == 6 { h += "FF" }
        return "#" + h.uppercased()
    }

    private var themesJSON: [[String: Any]] { file.array("themes").map { $0 as! [String: Any] } }

    // MARK: Values

    func testEveryThemeResolvesEveryTokenInEveryModeAndUnderGraphite() {
        XCTAssertEqual(themesJSON.map { $0["id"] as? String }, QuireTheme.allCases.map(\.rawValue), "the themes, in Settings order")
        for (theme, entry) in zip(QuireTheme.allCases, themesJSON) {
            let colors = entry["color"] as! [String: [String: String]]
            let graphite = entry["graphite"] as! [String: [String: String]]
            XCTAssertEqual(Set(colors.keys), Set(QuireColorToken.allCases.map(\.rawValue)), "\(theme): every token")
            for isGraphite in [false, true] {
                QuireEnvironment.shared.setOverrides(.init(isGraphite: isGraphite, increaseContrast: false, reduceMotion: false,
                                                           reduceTransparency: false, theme: theme))
                for token in QuireColorToken.allCases {
                    for mode in QuireMode.allCases {
                        let substitute = isGraphite ? graphite[token.rawValue]?[mode.rawValue] : nil
                        let want = hex(json: substitute ?? colors[token.rawValue]![mode.rawValue]!)
                        let label = "\(theme) \(token.rawValue) \(mode.rawValue)\(isGraphite ? " Graphite" : "")"
                        XCTAssertEqual(hex(token.color, mode), want, label)
                        XCTAssertEqual(hex(NSColor.quire(token, theme: theme), mode), want, "pinned: " + label)
                        let raw = isGraphite ? (token.graphiteValues(theme: theme) ?? token.values(theme: theme)) : token.values(theme: theme)
                        XCTAssertEqual(hex(raw[mode]), want, "values: " + label)
                    }
                }
            }
        }
    }

    func testStudyIsTheQuire17PaletteValueForValue() {
        let colors = file.object("color")
        for token in QuireColorToken.allCases {
            XCTAssertEqual(token.values(theme: .study), token.values, token.rawValue)
            let entry = colors[token.rawValue] as! [String: Any]
            for mode in QuireMode.allCases {
                XCTAssertEqual(hex(token.values[mode]), hex(json: entry[mode.rawValue] as! String), "\(token.rawValue) \(mode)")
            }
        }
        XCTAssertEqual(QuireTheme.allCases.first, .study)
        XCTAssertEqual(QuireEnvironment.Snapshot(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false).theme,
                       .study, "a snapshot nobody set a theme on is Study")
    }

    func testTheSemanticTokensAndThePageAreTheSameInEveryTheme() {
        let fixed: [QuireColorToken] = [.originalPage, .slipEdge, .onDanger, .star, .success, .warning, .danger, .info, .findWash, .findCurrent,
                                        .dangerFill, .dangerFillHover, .dangerFillPressed]
        for token in fixed {
            XCTAssertFalse(token.isThemed, token.rawValue)
            for theme in QuireTheme.allCases { XCTAssertEqual(token.values(theme: theme), token.values, "\(token.rawValue) \(theme)") }
        }
        for theme in QuireTheme.allCases {
            for mode in QuireMode.allCases { XCTAssertEqual(QuireColorToken.originalPage.values(theme: theme)[mode], 0xFFFFFFFF) }
        }
    }

    // MARK: The environment

    func testSetThemePostsOnceAndOnlyOnAChange() {
        // No theme override, so the app's setting is what the snapshot shows.
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false))
        var posts = 0
        let observer = NotificationCenter.default.addObserver(forName: QuireEnvironment.didChangeNotification, object: nil, queue: nil) { _ in
            posts += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        QuireEnvironment.shared.setTheme(.study)
        XCTAssertEqual(posts, 0, "the same theme again is no change")
        QuireEnvironment.shared.setTheme(.rain)
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(QuireEnvironment.theme, .rain)
        QuireEnvironment.shared.setTheme(.rain)
        XCTAssertEqual(posts, 1, "nothing changed")
        QuireEnvironment.shared.setTheme(.dusk)
        XCTAssertEqual(posts, 2)
        // An override wins over the setting, and the setting underneath is kept.
        QuireEnvironment.shared.setOverrides(.init(theme: .gallery))
        XCTAssertEqual(QuireEnvironment.theme, .gallery)
        QuireEnvironment.shared.setOverrides(.init())
        XCTAssertEqual(QuireEnvironment.theme, .dusk)
    }

    func testTheAccountKeyFollowsTheThemeAndTheEnvironmentKeyDoesNot() {
        let light = NSAppearance(named: .aqua)!
        var cacheKeys = Set<String>(), accountKeys = Set<String>(), senderKeys = Set<String>()
        for theme in QuireTheme.allCases {
            QuireTestEnvironment.forceDefaults(theme: theme)
            cacheKeys.insert(QuireEnvironment.cacheKey(for: light))
            accountKeys.insert(QuireAvatarRenderer.accountCacheKey(monogram: "C", slot: 0, diameter: 30, appearance: light))
            senderKeys.insert(QuireAvatarRenderer.cacheKey(initials: "AM", tint: .clay, diameter: 30, appearance: light))
        }
        XCTAssertEqual(cacheKeys.count, 1, "a sender's face draws only the avatar palette, which no theme changes")
        XCTAssertEqual(senderKeys.count, 1)
        XCTAssertEqual(accountKeys.count, QuireTheme.allCases.count, "an account face draws sheet and ink")
    }

    // MARK: Links

    func testBothLinkFlagsAreTheOnesInTokensJSON() {
        for (theme, entry) in zip(QuireTheme.allCases, themesJSON) {
            let links = entry["linkUnderlineAtRest"] as! [String: Bool]
            let quotes = entry["quoteLinkUnderlineAtRest"] as! [String: Bool]
            let page = entry["sheetIsPage"] as! [String: Bool]
            XCTAssertEqual(theme.name, entry["name"] as? String)
            XCTAssertEqual(theme.caption, entry["caption"] as? String)
            XCTAssertEqual(theme.isInkless, entry["inkless"] as? Bool)
            for mode in QuireMode.allCases {
                XCTAssertEqual(theme.underlinesLinksAtRest(mode), links[mode.rawValue], "\(theme) \(mode)")
                XCTAssertEqual(theme.underlinesQuoteLinksAtRest(mode), quotes[mode.rawValue], "\(theme) \(mode)")
                XCTAssertEqual(theme.sheetIsPage(mode), page[mode.rawValue], "\(theme) \(mode)")
            }
        }
    }

    func testStudyUnderlinesNoLinkAtRestOutsideGraphite() {
        for mode in QuireMode.allCases {
            QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: mode.isIncreasedContrast, reduceMotion: false,
                                                       reduceTransparency: false, theme: .study))
            XCTAssertFalse(QuireEnvironment.underlinesLinksAtRest(for: mode.appearance), "\(mode)")
            QuireEnvironment.shared.setOverrides(.init(isGraphite: true, increaseContrast: mode.isIncreasedContrast, theme: .study))
            XCTAssertTrue(QuireEnvironment.underlinesLinksAtRest(for: mode.appearance), "Graphite, \(mode)")
            QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: mode.isIncreasedContrast, theme: .gallery))
            XCTAssertTrue(QuireEnvironment.underlinesLinksAtRest(for: mode.appearance), "Gallery, \(mode)")
        }
    }

    // MARK: Cost

    func testAThemeNeverDrawnMakesNoColour() {
        let values = QuireTheme.allCases.map { _ in QuireColorValues(light: 0x112233FF, dark: 0x445566FF, lightHC: 0x778899FF, darkHC: 0xAABBCCFF) }
        let before = QuireThemedColorSets.made.withLock { $0 }
        let color = NSColor.quire("themeTests.probe", themes: values)
        XCTAssertEqual(QuireThemedColorSets.made.withLock { $0 }, before, "making the provider makes no colour")
        for theme in [QuireTheme.study, .rain] {
            QuireTestEnvironment.forceDefaults(theme: theme)
            for mode in QuireMode.allCases { _ = TokenResolver.rgba(color, mode) }
        }
        let after = QuireThemedColorSets.made.withLock { $0 }
        for theme in QuireTheme.allCases {
            XCTAssertEqual(after[theme.index] - before[theme.index], theme == .study || theme == .rain ? 1 : 0,
                           "\(theme): one set when first drawn, none when never drawn")
        }
    }

    // MARK: Redrawing

    func testAThemeSwitchRedrawsEveryViewOfEveryWindowAndRetakesItsBackground() throws {
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 120, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .qPaper
        // A view that paints a surface in draw(_:) and redraws only when told, as the composer's views do.
        let child = PaperView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        window.contentView?.addSubview(child)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func flush() {
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        flush()
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let drawn = child.draws
        XCTAssertGreaterThan(drawn, 0)
        XCTAssertEqual(child.layer?.needsDisplay(), false)
        QuireEnvironment.shared.setTheme(.grove)
        XCTAssertEqual(frameView.layer?.needsDisplay(), true, "the frame view, so the window background redraws")
        XCTAssertEqual(child.layer?.needsDisplay(), true)
        XCTAssertTrue(window.backgroundColor.isQuireToken)
        XCTAssertEqual(hex(window.backgroundColor, .light), hex(QuireColorToken.paper.values(theme: .grove)[.light]))
        flush()
        XCTAssertEqual(child.draws, drawn + 1, "drawn again, in Grove")
    }

    func testSwiftUIRedrawsInPlaceKeepingStateAndFocus() throws {
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: false, reduceTransparency: false))
        let probe = AppearanceProbe()
        let host = SwiftUIHost(QuireThemeRoot(ThemedProbeView(probe: probe)), size: CGSize(width: 200, height: 80))
        defer { host.close() }
        let point = CGPoint(x: 10, y: 70)
        XCTAssertColor(host.render().srgb(at: point), TokenResolver.resolve("canvas", .light))
        // Focus the field, as a user tabbing into Settings would.
        let field = try XCTUnwrap(findTextField(in: host.hostingView))
        host.window.makeFirstResponder(field)
        host.settle()
        let editor = host.window.firstResponder
        XCTAssertTrue(editor is NSTextView, "the field is being edited")
        for theme in [QuireTheme.rain, .dusk, .gallery, .grove, .study] {
            QuireEnvironment.shared.setTheme(theme)
            let want = ColorLib.hex2rgba(String(format: "#%06X", QuireColorToken.canvas.values(theme: theme)[.light] >> 8))
            XCTAssertColor(host.render(settle: 0.1).srgb(at: point), want, "\(theme): the canvas redrew in the new theme")
            XCTAssertTrue(host.window.firstResponder === editor, "\(theme): keyboard focus stayed in the field")
        }
        XCTAssertEqual(probe.appearances, 1, "the subtree kept its identity: it never appeared again")
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews { if let found = findTextField(in: subview) { return found } }
        return nil
    }

    // MARK: Source rules

    private static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sources(_ directories: [String]) -> [(path: String, lines: [String])] {
        var out: [(String, [String])] = []
        for directory in directories {
            let root = Self.repository.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" && !url.path.contains("/Generated/") {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                out.append((String(url.path.dropFirst(Self.repository.path.count + 1)), text.components(separatedBy: "\n")))
            }
        }
        XCTAssertFalse(out.isEmpty, "no sources under \(directories)")
        return out
    }

    private func isComment(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

    /// SwiftUI never asks `Color(nsColor:)` again when a provider's output changes, so a `Color.q…` token in a view stays
    /// in the theme it was first drawn in. Views use the shape styles (`.qInk`), which resolve from the environment.
    /// Account inks and avatar tints are the same in every theme and may stay colours.
    func testNoSwiftUIViewUsesAColourToken() throws {
        let pattern = try NSRegularExpression(pattern: "(?<![A-Za-z])Color\\.q(?!Account|Avatar)[A-Z]")
        for (path, lines) in sources(["Sources/PaperDesign/SwiftUI", "Sources/PaperApp/Shell/Settings"]) {
            for (i, line) in lines.enumerated() where !isComment(line) {
                if pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    XCTFail("\(path):\(i + 1) uses a Color token in a SwiftUI view: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    /// Every link drawn in the ink takes its underline at rest from `underlinesLinksAtRest`, never from Graphite alone:
    /// a theme whose ink sits near its text ink needs it too (R10). A file that draws a link in the ink with an underline
    /// must ask the helper, unless its links are always underlined.
    func testEveryLinkInTheInkAsksTheUnderlineHelper() {
        let alwaysUnderlined: Set<String> = [
            "Sources/PaperApp/Compose/ComposeTextView.swift",          // the composer's links are always underlined
            "Sources/PaperApp/Compose/ComposeWindowController.swift",  // Format › Underline, not a link
            "Sources/PaperDesign/SwiftUI/QuireSettingsGallery.swift",            // a signature sample, underlined as typed
        ]
        let sites = ["Sources/PaperDesign/AppKit/QuireButton.swift", "Sources/PaperDesign/AppKit/QuireEmptyStateView.swift",
                     "Sources/PaperDesign/SwiftUI/QuireButtonStyle.swift", "Sources/PaperDesign/SwiftUI/QuireInlineLinkText.swift",
                     "Sources/PaperApp/Shell/SyncStatusBar.swift", "Sources/PaperApp/List/ListFooterRowView.swift"]
        let all = sources(["Sources/PaperDesign", "Sources/PaperApp"])
        for site in sites {
            guard let file = all.first(where: { $0.path == site }) else { XCTFail("\(site) is gone: update this test"); continue }
            XCTAssertTrue(file.lines.contains { $0.contains("underlinesLinksAtRest") }, "\(site) must ask underlinesLinksAtRest")
        }
        for (path, lines) in all where !alwaysUnderlined.contains(path) && !path.hasSuffix("QuireEnvironment.swift") {
            let code = lines.filter { !isComment($0) }
            for (i, line) in code.enumerated() where line.contains("isGraphite") && line.lowercased().contains("underline")
                && !line.contains("underlinesLinksAtRest") {
                XCTFail("\(path): a link underline decided by Graphite alone: \(line.trimmingCharacters(in: .whitespaces)) (\(i))")
            }
            let drawsInkLinks = code.contains { $0.contains("qAccent") || $0.contains(".accent") } && code.contains { $0.contains("underline") }
            if drawsInkLinks {
                XCTAssertTrue(code.contains { $0.contains("underlinesLinksAtRest") },
                              "\(path) draws a link in the ink with an underline but never asks underlinesLinksAtRest")
            }
        }
    }

    /// A `CGColor` is a snapshot: one taken from a token outside `draw(_:)` or `updateLayer()` keeps the theme it was
    /// taken in. Layer colours go through `QuireLayerColors`, which re-resolves them on every change; the avatar
    /// renderer resolves inside its own drawing and keys its cache on the environment.
    func testEveryTokenColourSetOutsideDrawingGoesThroughQuireLayerColors() throws {
        let allowed: Set<String> = ["Sources/PaperDesign/QuireLayerColors.swift", "Sources/PaperDesign/AppKit/QuireAvatarRenderer.swift"]
        let pattern = try NSRegularExpression(pattern: "\\.q[A-Z][A-Za-z0-9]*(\\([^)]*\\))?(\\.[a-zA-Z]+\\([^)]*\\))*\\.cgColor")
        for (path, lines) in sources(["Sources/PaperDesign", "Sources/PaperApp"]) where !allowed.contains(path) {
            for (i, line) in lines.enumerated() where !isComment(line) {
                if pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    XCTFail("\(path):\(i + 1) takes a CGColor from a token outside QuireLayerColors: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }
}

/// Paints `paper` in draw(_:) and counts its draws.
private final class PaperView: NSView {
    var draws = 0

    override func draw(_ dirtyRect: NSRect) {
        draws += 1
        NSColor.qPaper.setFill()
        bounds.fill()
    }
}

/// Counts how often its view appears: a rebuilt subtree appears again.
@MainActor
final class AppearanceProbe {
    var appearances = 0
}

private struct ThemedProbeView: View {
    let probe: AppearanceProbe
    @State private var text = "Rain"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $text).quireFieldStyle().frame(width: 160)
            Button("Save") {}.buttonStyle(.quire(.primary))
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 200, height: 80, alignment: .topLeading)
        .background(.qCanvas)
        .onAppear { probe.appearances += 1 }
    }
}
