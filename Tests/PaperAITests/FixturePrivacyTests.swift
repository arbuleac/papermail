import XCTest

/// The fixtures were recorded on a real Mac with a real sign-in: nothing that identifies the person or the machine may
/// be committed with them. Any fixture added later passes through this too.
final class FixturePrivacyTests: XCTestCase {
    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad pattern \(pattern)")
            return []
        }
        let string = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: string.length)).map { string.substring(with: $0.range) }
    }

    func testThereAreFixtures() {
        XCTAssertGreaterThanOrEqual(FixtureFiles.all().count, 12)
        XCTAssertTrue(FixtureFiles.all().contains("cli/claude-stream.jsonl"))
    }

    func testNoFixtureNamesAPersonAMachineOrAnAccount() throws {
        for path in FixtureFiles.all() {
            let text = try FixtureFiles.string(path)
            XCTAssertEqual(matches(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#, in: text), [], "\(path): an address")
            XCTAssertEqual(matches(#"/Users/(?!someone\b)[^/"\s]+"#, in: text), [], "\(path): a home folder")
            XCTAssertEqual(matches(#"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, in: text)
                .filter { !$0.hasPrefix("00000000-0000-4000-8000-") }, [], "\(path): a real id")
            XCTAssertEqual(matches(#"\b(msg|req)_(?!fixture\d)[A-Za-z0-9]{6,}"#, in: text), [], "\(path): a message or request id")
            XCTAssertEqual(matches(#"cf-ray: (?!0{16}-XXX)\S+"#, in: text), [], "\(path): a Cloudflare ray")
            XCTAssertEqual(matches(#"sk-(?!not-a\*)[A-Za-z0-9_-]{8,}"#, in: text), [], "\(path): an API key")
            for field in ["email", "orgId", "orgName"] {
                XCTAssertEqual(matches(#"""# + field + #""\s*:\s*"(?!<redacted>)[^"]*""#, in: text), [], "\(path): \(field)")
            }
        }
    }
}
