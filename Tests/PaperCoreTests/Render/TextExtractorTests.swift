import XCTest
@testable import PaperCore

final class TextExtractorTests: XCTestCase {
    func testCollapsesWhitespaceAndBreaksBlocks() {
        let text = TextExtractor.plainText(fromHTML: "<p>Hello   \n  world</p>\n\n<p>Second &amp; <b>bold</b></p><div>a</div><div>b</div>")
        XCTAssertEqual(text, "Hello world\n\nSecond & bold\n\na\nb")
    }

    func testListsGetMarkers() {
        let text = TextExtractor.plainText(fromHTML: "<p>Items:</p><ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul><p>End</p>")
        XCTAssertEqual(text, "Items:\n\n- One\n- Two\n  - Nested\n\nEnd")
    }

    func testLinksKeepShortDifferentTargetsOnly() {
        XCTAssertEqual(TextExtractor.plainText(fromHTML: "<a href=\"https://x.example/\">x.example</a>"), "x.example")
        XCTAssertEqual(TextExtractor.plainText(fromHTML: "<a href=\"https://x.example/doc\">read this</a>"), "read this (https://x.example/doc)")
        let long = "https://x.example/" + String(repeating: "a", count: 90)
        XCTAssertEqual(TextExtractor.plainText(fromHTML: "<a href=\"\(long)\">text</a>"), "text")
        XCTAssertEqual(TextExtractor.plainText(fromHTML: "<a href=\"javascript:alert(1)\">x</a>"), "x")
        XCTAssertEqual(TextExtractor.plainText(fromHTML: "<a href=\"mailto:bob@example.com\">bob@example.com</a>"), "bob@example.com")
    }

    func testLineBreaksTablesAndImages() {
        XCTAssertEqual(TextExtractor.plainText(fromHTML: "a<br>b<br><br><br>c"), "a\nb\n\nc")
        XCTAssertEqual(TextExtractor.plainText(fromHTML: "<table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table>"), "a b\nc")
        XCTAssertEqual(TextExtractor.plainText(fromHTML: "<p>Logo: <img src=\"cid:x\" alt=\"Acme\"> <img src=\"cid:y\"></p>"), "Logo: [image: Acme]")
    }

    func testSkipsStyleAndScriptContent() {
        XCTAssertEqual(TextExtractor.plainText(fromHTML: "<style>p{color:red}</style><p>Visible</p><script>var x=1</script>"), "Visible")
    }

    func testPreservesPreformattedText() {
        XCTAssertEqual(TextExtractor.plainText(fromHTML: "<pre>line 1\n   indented</pre>"), "line 1\n   indented")
    }

    func testCollapsesNonBreakingAndZeroWidthSpaces() {
        XCTAssertEqual(TextExtractor.plainText(fromHTML: "a&nbsp;&nbsp;b&#8203;c"), "a bc")
    }

    func testCapsAt200KB() {
        let html = "<p>" + String(repeating: "word ", count: 60_000) + "</p>"
        let text = TextExtractor.plainText(fromHTML: html)
        XCTAssertLessThanOrEqual(text.utf8.count, TextExtractor.maxLength)
        XCTAssertGreaterThan(text.utf8.count, TextExtractor.maxLength - 64)
    }
}
