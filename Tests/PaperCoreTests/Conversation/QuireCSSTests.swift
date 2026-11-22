import Foundation
import XCTest
@testable import PaperCore

/// Spec §8.4: the specimen's `<style>` head is exactly `QuireCSS.head`. Both are generated from tokens.json (the
/// specimen by docs/design/source/build.py, the Swift string by scripts/tools/quire-tokens.swift), so this
/// holds the two generators to each other, variable by variable.
final class QuireCSSTests: XCTestCase {
    private func specimenHead() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Conversation
            .deletingLastPathComponent() // PaperCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
            .appendingPathComponent("docs/design/specimen.html")
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("/* ===== Quire tokens: generated") }) + 1
        let end = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("/* Specimen-only scopes") })
        return Array(lines[start..<end])
    }

    /// `--name:value` pairs per line, in order.
    private func variables(_ lines: [String]) -> [[(String, String)]] {
        lines.map { line in
            var out: [(String, String)] = []
            var rest = Substring(line)
            while let r = rest.range(of: "--") {
                let tail = rest[r.lowerBound...]
                guard let colon = tail.firstIndex(of: ":"), let semi = tail[colon...].firstIndex(of: ";") else { break }
                out.append((String(tail[..<colon]), String(tail[tail.index(after: colon)..<semi])))
                rest = tail[tail.index(after: semi)...]
            }
            return out
        }
    }

    func testHeadIsTheSpecimensStyleHead() throws {
        let generated = QuireCSS.head.components(separatedBy: "\n")
        let specimen = try specimenHead()
        XCTAssertEqual(generated.count, specimen.count, "block count")
        let g = variables(generated)
        let s = variables(specimen)
        for (i, (gl, sl)) in zip(g, s).enumerated() {
            XCTAssertEqual(gl.map(\.0), sl.map(\.0), "variable names in block \(i)")
            for ((gn, gv), (_, sv)) in zip(gl, sl) where gv != sv {
                XCTFail("block \(i): \(gn) is \(gv) here and \(sv) in the specimen")
            }
        }
        XCTAssertEqual(QuireCSS.head, specimen.joined(separator: "\n"), "byte for byte")
    }

    /// Text size (spec §4.15): one class per size but Default, each redefining every type shorthand of the head with
    /// size and line height moved by the step, held at 11 pt; tracking, weight and family stay. Each role's step is a
    /// variable of its own (`--q-step-<role>`), which the shell's fixed boxes add to their Default heights.
    func testTextSizesMoveEveryTypeVariableByTheStep() throws {
        let head = Dictionary(uniqueKeysWithValues: variables(QuireCSS.head.components(separatedBy: "\n")).flatMap { $0 }
            .filter { $0.0.hasPrefix("--q-font-") })
        let lines = QuireCSS.textSizes.components(separatedBy: "\n")
        XCTAssertEqual(lines.map { String($0.prefix { $0 != "{" }) }, ["html.ss-text-small", "html.ss-text-large", "html.ss-text-larger"])
        XCTAssertFalse(QuireCSS.textSizes.contains("--q-track-"), "tracking stays")
        let shorthand = try NSRegularExpression(pattern: "^((?:italic )?\\d+) (\\d+(?:\\.\\d+)?)px/(\\d+(?:\\.\\d+)?)px (.+)$")
        func parts(_ value: String) throws -> (lead: String, size: Double, line: Double, family: String) {
            let match = try XCTUnwrap(shorthand.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), value)
            func group(_ i: Int) -> String { String(value[Range(match.range(at: i), in: value)!]) }
            return (group(1), Double(group(2))!, Double(group(3))!, group(4))
        }
        for (line, delta) in zip(lines, [-1.0, 1, 2]) {
            let sized = Dictionary(uniqueKeysWithValues: variables([line])[0])
            for (name, value) in head {
                let base = try parts(value)
                let step = max(delta, min(0, 11 - base.size))
                let stepName = "--q-step-" + name.dropFirst("--q-font-".count)
                guard step != 0 else {
                    XCTAssertNil(sized[name], "\(name) at \(delta): a role the step leaves alone is not repeated")
                    XCTAssertNil(sized[stepName], "\(stepName) at \(delta)")
                    continue
                }
                XCTAssertEqual(sized[stepName], "\(Int(step))px", "\(stepName) at \(delta)")
                let moved = try parts(try XCTUnwrap(sized[name], "\(name) at \(delta)"))
                XCTAssertEqual(moved.size, base.size + step, "\(name) at \(delta)")
                XCTAssertEqual(moved.line, base.line + step, "\(name) at \(delta)")
                XCTAssertEqual(moved.lead, base.lead, "\(name): weight and style stay")
                XCTAssertEqual(moved.family, base.family, "\(name): the family stays")
            }
        }
        XCTAssertTrue(ConversationShellAssets.css.contains(QuireCSS.textSizes), "the shell carries every size")
        let names = Set(head.keys.map { "--q-step-" + $0.dropFirst("--q-font-".count) })
        for line in lines {
            for (name, _) in variables([line])[0] where name.hasPrefix("--q-step-") {
                XCTAssertTrue(names.contains(name), "\(name) steps a role of the head")
            }
        }
    }

    // MARK: Themes (spec §4.16)

    private func repository() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Conversation
            .deletingLastPathComponent() // PaperCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
    }

    /// `themes` of tokens.json, Study first.
    private func themes() throws -> [[String: Any]] {
        let data = try Data(contentsOf: repository().appendingPathComponent("docs/design/tokens.json"))
        let tokens = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(tokens["themes"] as? [[String: Any]])
    }

    private func table(_ theme: [String: Any], _ key: String) throws -> [String: [String: String]] {
        let raw = try XCTUnwrap(theme[key] as? [String: [String: Any]], key)
        return raw.mapValues { $0.compactMapValues { $0 as? String } }
    }

    /// A block's selector and media query, without the declarations the head's own blocks open with.
    private func selector(_ line: String) -> String {
        let head = line.range(of: "--").map { String(line[..<$0.lowerBound]) } ?? line
        return head.lastIndex(of: "{").map { String(head[...$0]) } ?? head
    }

    private func isSubsequence(_ names: [String], of order: [String]) -> Bool {
        var rest = order[...]
        for name in names {
            guard let at = rest.firstIndex(of: name) else { return false }
            rest = rest[rest.index(after: at)...]
        }
        return true
    }

    /// The blocks of the head that hold colours, in its order: the six mode blocks, then the six Graphite ones, each
    /// with the mode it draws (the `html.ss-ic` blocks are Increase Contrast's).
    private func colourBlocks() -> [(line: Int, mode: String, graphite: Bool)] {
        let lines = QuireCSS.head.components(separatedBy: "\n")
        let modes = ["light", "dark", "lightHC", "darkHC", "lightHC", "darkHC"]
        let plain = lines.indices.filter { lines[$0].contains("--q-paper:") }
        let graphite = lines.indices.filter { lines[$0].contains("ss-graphite{") }
        return zip(plain, modes).map { ($0, $1, false) } + zip(graphite, modes).map { ($0, $1, true) }
    }

    /// Study is the head itself, so its sheet is empty, as is any id no theme has.
    func testStudysThemeSheetIsEmpty() {
        XCTAssertEqual(QuireCSS.themeIDs.first, "study")
        XCTAssertEqual(QuireCSS.themeSheet("study"), "")
        XCTAssertEqual(QuireCSS.themeSheet("nonesuch"), "")
        XCTAssertEqual(ShellTheme.study.shell, "")
        XCTAssertEqual(ShellTheme.study.body, "")
    }

    /// Each theme's sheet repeats the head's twelve colour blocks with the same selectors, in the same order and with the
    /// variables in the head's order, so it overrides the head by order alone and Increase Contrast and Graphite still
    /// win by specificity. Every block carries every token that differs from Study's in any mode, at the theme's value for
    /// the block's mode (tokens.json), and nothing else; the page's focus ring and link colour go with them.
    func testEveryThemeSheetCarriesEveryDifferingTokenInEveryBlockInTheHeadsOrder() throws {
        let all = try themes()
        let study = try XCTUnwrap(all.first)
        XCTAssertEqual(all.compactMap { $0["id"] as? String }, QuireCSS.themeIDs)
        let head = QuireCSS.head.components(separatedBy: "\n")
        let blocks = colourBlocks()
        XCTAssertEqual(blocks.count, 12, "six mode blocks and six Graphite blocks")
        let studyColours = try table(study, "color")
        let studyGraphite = try table(study, "graphite")
        let studyFocus = try XCTUnwrap(study["focusOnPage"] as? [String: String])
        let modes = ["light", "dark", "lightHC", "darkHC"]
        for theme in all.dropFirst() {
            let id = try XCTUnwrap(theme["id"] as? String)
            let colours = try table(theme, "color")
            let graphite = try table(theme, "graphite")
            let focus = try XCTUnwrap(theme["focusOnPage"] as? [String: String])
            // Under Graphite the page's ring is the light ink (IC's under Increase Contrast) and an uncoloured link the ink.
            func graphitePage(_ t: [String: [String: String]], _ g: [String: [String: String]], _ mode: String) -> [String: String] {
                ["--q-focusOnPage": t["ink"]?[mode.hasSuffix("HC") ? "lightHC" : "light"] ?? "",
                 "--q-linkOnPage": g["accent"]?[mode] ?? ""]
            }
            let sheet = QuireCSS.themeSheet(id).components(separatedBy: "\n")
            XCTAssertEqual(sheet.count, blocks.count, "\(id): one line per colour block")
            for (line, block) in zip(sheet, blocks) {
                XCTAssertEqual(selector(line), selector(head[block.line]), "\(id): the head's selector, in its order")
                let names = variables([line])[0].map(\.0)
                XCTAssertTrue(isSubsequence(names, of: variables([head[block.line]])[0].map(\.0)),
                              "\(id) \(selector(line)): the head's variables in the head's order")
                var expected: [String: String] = [:]
                let own = block.graphite ? graphite : colours
                let base = block.graphite ? studyGraphite : studyColours
                for (token, values) in own where modes.contains(where: { values[$0] != base[token]?[$0] }) {
                    expected["--q-" + token] = values[block.mode]
                }
                if block.graphite {
                    let page = graphitePage(colours, graphite, block.mode)
                    for (name, value) in page where modes.contains(where: { graphitePage(colours, graphite, $0)[name]
                        != graphitePage(studyColours, studyGraphite, $0)[name] }) {
                        expected[name] = value
                    }
                } else if modes.contains(where: { focus[$0] != studyFocus[$0] }) {
                    expected["--q-focusOnPage"] = focus[block.mode]
                }
                let carried = Dictionary(variables([line])[0], uniquingKeysWith: { first, _ in first })
                XCTAssertEqual(carried, expected, "\(id) \(selector(line))")
            }
        }
    }

    /// A body document's theme sheet is its shell sheet cut to what bodies read, block by block, by the one cut that also
    /// makes the bodies' own variables, so the two can never disagree (spec §8.4).
    func testEveryBodySheetIsTheKeepListOfItsShellSheetBlockByBlock() {
        XCTAssertTrue(ConversationShellAssets.bodyKeep.isSuperset(of: ["--q-focusOnPage", "--q-linkOnPage"]))
        for id in QuireCSS.themeIDs {
            let shell = QuireCSS.themeSheet(id)
            let theme = ShellTheme(id: id)
            XCTAssertEqual(theme.shell, shell, id)
            XCTAssertEqual(theme.body, ConversationShellAssets.bodyCut(shell), id)
            let expected = shell.components(separatedBy: "\n").compactMap { line -> (selector: String, kept: [String])? in
                let kept = variables([line])[0].filter { ConversationShellAssets.bodyKeep.contains($0.0) }
                return kept.isEmpty ? nil : (selector(line), kept.map { $0.0 + ":" + $0.1 })
            }
            let body = theme.body.isEmpty ? [] : theme.body.components(separatedBy: "\n")
            XCTAssertEqual(body.count, expected.count, "\(id): a block for every shell block a body reads from")
            for (line, block) in zip(body, expected) {
                XCTAssertEqual(selector(line), block.selector, id)
                XCTAssertEqual(variables([line])[0].map { $0.0 + ":" + $0.1 }, block.kept, "\(id) \(block.selector)")
                XCTAssertEqual(line.filter { $0 == "{" }.count, line.filter { $0 == "}" }.count, "balanced: \(line.prefix(60))")
            }
            if id != "study" {
                XCTAssertTrue(theme.body.contains("--q-focusOnPage:"), "\(id): the white page's ring follows the theme")
                XCTAssertFalse(theme.body.contains("--q-spine:"), "\(id): only what bodies read")
            }
        }
    }

    func testHeadCoversEveryVariableFamily() {
        let head = QuireCSS.head
        for needle in ["--q-paper:", "--q-acct-1:", "--q-av-clay-face:", "--q-e1:", "--q-font-subject:", "--q-track-runningHead:0px",
                       "--q-s1:2px", "--q-r-lg:8px", "--q-dur-standard:180ms", "--q-ease-settle:cubic-bezier(0.2,0.8,0.2,1)",
                       "@media (prefers-contrast:more)", "html.ss-ic{", "html.ss-graphite{", "html.ss-ic.ss-graphite{"] {
            XCTAssertTrue(head.contains(needle), needle)
        }
    }
}
