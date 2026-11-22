import XCTest
import SwiftSoup
@testable import PaperCore

/// Opt-in measurement: `PAPER_PERF=1 swift test -c release --filter SanitizerThroughputTests`.
final class SanitizerThroughputTests: XCTestCase {
    func testNewsletterThroughput() throws {
        guard ProcessInfo.processInfo.environment["PAPER_PERF"] == "1" else {
            throw XCTSkip("Set PAPER_PERF=1 to measure sanitizer throughput.")
        }
        let html = MailShapeFixtures.largeNewsletter(approximateBytes: 200 * 1024)
        let body = MessageBody(html: html, text: nil)
        let sanitizer = HTMLSanitizer()
        // One warm-up pass so lazy caches inside SwiftSoup do not count.
        let warm = sanitizer.sanitize(body, messageID: RenderTestSupport.messageID)
        XCTAssertGreaterThan(warm.blockedRemoteImageCount, 100)
        assertNotContains(warm.html, " src=\"https://")

        let iterations = 100
        let sanitizeMs = Self.millisecondsPerIteration(iterations) {
            _ = sanitizer.sanitize(body, messageID: RenderTestSupport.messageID)
        }
        // The parse alone is a floor this module cannot go under (about 8.5 ms for this fixture on an M-series
        // Mac), so the budget in docs/ARCHITECTURE.md is relative: the scrub, the CSS filter, quote detection,
        // text extraction and a DOM serialisation together stay within 1.5 parses on top of the parse.
        let parseMs = try Self.millisecondsPerIteration(iterations) { _ = try SwiftSoup.parseHTML(html) }
        print(String(
            format: "HTMLSanitizer: %.2f ms per %d KB newsletter over %d iterations (budget %.2f ms = 2.5 × the SwiftSoup parse, %.2f ms)",
            sanitizeMs, html.utf8.count / 1024, iterations, parseMs * 2.5, parseMs
        ))
        #if !DEBUG
        XCTAssertLessThan(sanitizeMs, parseMs * 2.5, "sanitizing must not cost more than 1.5 parses on top of the parse")
        #endif
    }

    private static func millisecondsPerIteration(_ iterations: Int, _ block: () throws -> Void) rethrows -> Double {
        let elapsed = try ContinuousClock().measure {
            for _ in 0..<iterations { try block() }
        }
        let perIteration = elapsed / iterations
        return Double(perIteration.components.seconds) * 1000 + Double(perIteration.components.attoseconds) / 1e15
    }
}
