import Foundation
import XCTest
@testable import SSCore

/// Spec §8.4: the specimen's `<style>` head is exactly `QuireCSS.head`. Both are generated from tokens.json (the
/// specimen by docs/design/source/build.py, the Swift string by scripts/tools/quire-tokens.swift), so this
/// holds the two generators to each other, variable by variable.
final class QuireCSSTests: XCTestCase {
    private func specimenHead() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Conversation
            .deletingLastPathComponent() // SSCoreTests
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

    func testHeadCoversEveryVariableFamily() {
        let head = QuireCSS.head
        for needle in ["--q-paper:", "--q-acct-1:", "--q-av-clay-face:", "--q-e1:", "--q-font-subject:", "--q-track-runningHead:0.6px",
                       "--q-s1:2px", "--q-r-lg:8px", "--q-dur-standard:180ms", "--q-ease-settle:cubic-bezier(0.2,0.8,0.2,1)",
                       "@media (prefers-contrast:more)", "html.ss-ic{", "html.ss-graphite{", "html.ss-ic.ss-graphite{"] {
            XCTAssertTrue(head.contains(needle), needle)
        }
    }
}
