import Foundation
import XCTest
@testable import PaperCore

/// Spec §4.11, §8.7: the shell draws only the SF Symbols of `readerSymbols`, every one of them rasterised by the
/// app, so a glyph added to the shell without being added to the list fails here instead of drawing blank.
final class ReaderSymbolTests: XCTestCase {
    private func tokensReaderSymbols() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Conversation
            .deletingLastPathComponent() // PaperCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
            .appendingPathComponent("docs/design/tokens.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(object as? [String: Any])
        if let list = root["readerSymbols"] as? [String] { return list }
        let platform = try XCTUnwrap(root["platform"] as? [String: Any])
        return try XCTUnwrap(platform["readerSymbols"] as? [String])
    }

    func testTheShellsListIsTheTokensList() throws {
        XCTAssertEqual(ConversationShellAssets.symbols, try tokensReaderSymbols())
    }

    func testTheShellNamesOnlyListedSymbols() throws {
        let listed = Set(ConversationShellAssets.symbols.map { $0.replacingOccurrences(of: ".", with: "-") })
        let source = ConversationShellAssets.css + ConversationShellAssets.script
        // Every `--sym-…` custom property and every `sym('…')` call in the script.
        let variables = matches(of: "--sym-([a-z0-9-]+)", in: source)
        let calls = matches(of: "sym\\('([a-z0-9.]+)'", in: ConversationShellAssets.script).map { $0.replacingOccurrences(of: ".", with: "-") }
        XCTAssertFalse(calls.isEmpty)
        for name in variables + calls {
            XCTAssertTrue(listed.contains(name), "the shell draws `\(name)`, which is not a reader symbol")
        }
        for name in listed {
            XCTAssertTrue(ConversationShellAssets.css.contains(".ss-sym-\(name){--sym:var(--sym-\(name))}"), "no modifier class for \(name)")
        }
    }

    func testSymbolVariablesFollowOneSpelling() {
        XCTAssertEqual(ConversationShellAssets.symbolVariable("star.fill"), "--sym-star-fill")
        XCTAssertEqual(ConversationShellAssets.symbolVariable("arrowshape.turn.up.left.2"), "--sym-arrowshape-turn-up-left-2")
    }

    private func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
