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

    func testHeadCoversEveryVariableFamily() {
        let head = QuireCSS.head
        for needle in ["--q-paper:", "--q-acct-1:", "--q-av-clay-face:", "--q-e1:", "--q-font-subject:", "--q-track-runningHead:0.6px",
                       "--q-s1:2px", "--q-r-lg:8px", "--q-dur-standard:180ms", "--q-ease-settle:cubic-bezier(0.2,0.8,0.2,1)",
                       "@media (prefers-contrast:more)", "html.ss-ic{", "html.ss-graphite{", "html.ss-ic.ss-graphite{"] {
            XCTAssertTrue(head.contains(needle), needle)
        }
    }
}
