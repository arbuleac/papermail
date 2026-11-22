import XCTest
@testable import PaperCore

/// Plain-text bodies are attacker controlled too; these used to crash or stall sync.
final class PlainTextAdversarialTests: XCTestCase {
    /// Each ">" level was one recursion; on a 512 KB concurrency-pool stack 20k of them overflowed it.
    func testDeeplyNestedQuotesDoNotOverflowTheStack() {
        let text = String(repeating: ">", count: 20_000) + " hi"
        let done = expectation(description: "rendered")
        var html = ""
        let thread = Thread {
            html = RenderTestSupport.sanitizeText(text).html
            done.fulfill()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        wait(for: [done], timeout: 30)
        assertContains(html, "hi")
    }

    /// Trimming a trailing ")" recounted the parentheses of the whole URL each time: quadratic in the run.
    func testLongParenthesisRunLinkifiesInLinearTime() {
        let text = "see http://a.example/" + String(repeating: ")", count: 20_000)
        var html = ""
        let elapsed = ContinuousClock().measure { html = PlainTextRenderer.linkify(text) }
        XCTAssertLessThan(elapsed, .seconds(1))
        assertContains(html, #"<a href="http://a.example/">"#)
    }

    func testBalancedParenthesesStayInURL() {
        let html = PlainTextRenderer.linkify("(see https://en.wikipedia.org/wiki/Foo_(bar)))")
        assertContains(html, #"href="https://en.wikipedia.org/wiki/Foo_(bar)""#)
    }

    func testURLWithQuotesCannotBreakOutOfAttribute() {
        let html = PlainTextRenderer.linkify(#"http://x.example/a"onmouseover="alert(1) and http://y.example/b'c"#)
        assertNotContains(html, #""onmouseover"#)
        assertNotContains(html, "'c")
    }
}
