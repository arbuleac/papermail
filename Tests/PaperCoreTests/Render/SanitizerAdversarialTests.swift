import XCTest
@testable import PaperCore

/// Regressions from the adversarial review of the sanitizer. Each case is a construct that got past an earlier
/// version, usually because SwiftSoup reads the markup one way and WebKit reads the re-serialised output another.
final class SanitizerAdversarialTests: XCTestCase {
    /// Unclosed tags can nest a body hundreds deep. Sanitised at sync time on a concurrency pool thread (512 KB of
    /// stack), the recursive scrub of such a body overflowed it and crashed the app on every launch.
    func testABodyNestedToTheScrubsLimitIsSanitisedOffTheMainStack() async {
        let depth = 400
        let html = String(repeating: #"<div style="color:#333;font:12px \41rial">"#, count: depth) + "Deep words"
            + String(repeating: "</div>", count: depth)
        let task = Task.detached { RenderTestSupport.sanitize(html) }
        let sanitized = await task.value
        XCTAssertTrue(sanitized.plainText.contains("Deep words") || sanitized.html.contains("ss-body"))
    }

    // MARK: Foreign content (mutation XSS)

    /// SwiftSoup keeps `<style>` as raw text everywhere; inside `<svg>` WebKit parses its contents as markup,
    /// and `<img>` breaks out of the SVG into a live HTML element.
    func testSVGStyleCannotSmuggleMarkup() {
        let out = RenderTestSupport.sanitize(
            #"<svg><style>a{color:red}<img src="http://evil.example/t.gif" onerror="alert(1)"></style><circle r="4"/></svg><p>after</p>"#
        )
        assertNotContains(out.html, "evil.example")
        assertNotContainsIgnoringCase(out.html, "onerror")
        assertNotContainsIgnoringCase(out.html, "<img")
        assertContains(out.html, "<circle")
        assertContains(out.html, "<p>after</p>")
    }

    /// Entities are decoded inside SVG style text, so `&#117rl(` would become `url(` only in WebKit.
    func testSVGStyleCannotHideURLBehindEntities() {
        let out = RenderTestSupport.sanitize(#"<svg><style>rect{fill:&#117rl(http://evil.example/x)}</style><rect/></svg>"#)
        assertNotContains(out.html, "&#117")
        assertNotContains(out.html, "evil.example")
    }

    /// xmp, noembed, noframes and plaintext are serialised raw by SwiftSoup; inside SVG they are ordinary
    /// elements whose contents WebKit parses as markup.
    func testRawTextElementsInsideSVGCannotSmuggleMarkup() {
        for tag in ["xmp", "noembed", "noframes", "plaintext"] {
            let out = RenderTestSupport.sanitize("<svg><\(tag)><img src=http://evil.example/\(tag) onerror=alert(1)></\(tag)></svg><p>tail</p>")
            assertNotContains(out.html, "<img")
            assertNotContainsIgnoringCase(out.html, "<\(tag)")
        }
    }

    func testXmpContentSurvivesAsEscapedText() {
        let out = RenderTestSupport.sanitize("<p>a</p><xmp><b>literal</b></xmp>")
        assertContains(out.html, "<pre>&lt;b&gt;literal&lt;/b&gt;</pre>")
        assertNotContains(out.html, "<b>")
    }

    /// Defence in depth: whatever context a sheet lands in, it never carries a `<` that could open a tag.
    func testStyleSheetNeverEmitsLessThan() {
        let out = RenderTestSupport.sanitize(#"<style>p::after{content:"<img src=x onerror=alert(1)>"}</style><p>x</p>"#)
        assertNotContains(out.html, "<img")
        assertContains(out.html, #"content: "\3c img"#)
    }

    /// Old mailers wrap their sheets in `<!-- -->`; the markers have to go without taking the rules with them.
    func testHTMLCommentMarkersInStyleSheetAreDroppedButRulesKept() {
        let out = RenderTestSupport.sanitize("<style><!-- p{color:red} --></style><p>x</p>")
        assertNotContains(out.html, "<!--")
        assertContains(out.html, "p{color: red;}")
    }

    // MARK: CSS tokenisation

    /// `\"` outside a string is an escaped character, not the start of a string; treating it as one hid the
    /// url() that followed it from the rewriter.
    func testEscapedQuoteOutsideStringDoesNotHideURL() {
        let sheet = RenderTestSupport.sanitize(#"<style>p{color:\"red;background:url(http://evil.example/s);x:"}</style><p>x</p>"#)
        assertNotContains(sheet.html, "evil.example")
        XCTAssertEqual(sheet.blockedRemoteImageCount, 1)

        let inline = RenderTestSupport.sanitize(#"<p style='color:\"red;background:url(http://evil.example/a);x:"'>x</p>"#)
        assertNotContains(inline.html, "evil.example")
        XCTAssertEqual(inline.blockedRemoteImageCount, 1)
    }

    /// CSS decodes escapes in identifiers before it recognises `url(`, so `u\72l(` is a url token.
    func testEscapedURLFunctionNameIsDropped() {
        for function in [#"u\72l"#, #"\75rl"#, #"\75\72\6c"#, #"U\52 L"#] {
            let inline = RenderTestSupport.sanitize("<p style=\"background:\(function)(http://evil.example/a)\">x</p>")
            assertNotContains(inline.html, "evil.example")
            let sheet = RenderTestSupport.sanitize("<style>p{background:\(function)(http://evil.example/s)}</style><p>x</p>")
            assertNotContains(sheet.html, "evil.example")
        }
    }

    func testEscapedImageSetIsDropped() {
        let out = RenderTestSupport.sanitize(#"<style>p{background:image-s\65t("http://evil.example/x" 1x)}</style><p>x</p>"#)
        assertNotContains(out.html, "evil.example")
    }

    func testEscapedPositionFixedIsDropped() {
        let out = RenderTestSupport.sanitize(#"<style>p{pos\69tion:fixed}div{position:f\69xed}</style><p>x</p>"#)
        assertNotContains(out.html, "fixed")
        assertNotContains(out.html, #"f\69xed"#)
    }

    func testEscapesInFontNamesAreKept() {
        // Chinese newsletters spell Microsoft YaHei with escapes; that must not trip the escape checks.
        let out = RenderTestSupport.sanitize(#"<p style="font-family:\5FAE\8F6F\96C5\9ED1">x</p>"#)
        assertContains(out.html, #"font-family:\5FAE\8F6F\96C5\9ED1"#)
    }

    func testTrailingTokensAfterQuotedURLAreNotSkipped() {
        let out = RenderTestSupport.sanitize(#"<p style="background:url('cid:a' url(http://evil.example/x))">x</p>"#)
        assertNotContains(out.html, "evil.example")
    }

    // MARK: SVG references and fragments

    func testSVGResourceReferencesAreDropped() {
        let out = RenderTestSupport.sanitize(
            #"<svg><pattern id="p" xlink:href="http://evil.example/p"/><textPath href="https://evil.example/t"/>"#
                + #"<mpath xlink:href="http://evil.example/m"/><cursor xlink:href="http://evil.example/c"/>"#
                + #"<a href="https://good.example/"><text>ok</text></a></svg>"#
        )
        assertNotContains(out.html, "evil.example")
        assertContains(out.html, #"<a href="https://good.example/">"#)
    }

    func testSVGPaintAttributesCannotFetch() {
        let out = RenderTestSupport.sanitize(
            #"<svg><rect fill="url(http://evil.example/f#a)" filter="url(https://evil.example/x#f)" mask="u\72l(http://evil.example/m)"/></svg>"#
        )
        assertNotContains(out.html, "evil.example")
        XCTAssertEqual(out.blockedRemoteImageCount, 2)
    }

    /// Ids are prefixed, so `url(#g)` must follow or every gradient, clip path and marker stops resolving.
    func testSVGFragmentReferencesFollowPrefixedIDs() {
        let out = RenderTestSupport.sanitize(
            ##"<svg><linearGradient id="g"/><rect fill="url(#g)" style="stroke:url(#g)"/><textPath href="#g"/></svg>"##
        )
        assertContains(out.html, #"id="ss-g""#)
        assertContains(out.html, #"fill="url(&quot;#ss-g&quot;)""#)
        assertContains(out.html, #"style="stroke: url(&quot;#ss-g&quot;);""#)
        assertContains(out.html, ##"href="#ss-g""##)
    }

    func testLegacyResourceAttributesAreDropped() {
        let out = RenderTestSupport.sanitize(
            #"<img src="cid:a" lowsrc="http://evil.example/l" dynsrc="http://evil.example/d"><div srcdoc="&lt;script&gt;alert(1)&lt;/script&gt;" data="http://evil.example/o">x</div>"#
        )
        assertNotContains(out.html, "evil.example")
        assertNotContains(out.html, "srcdoc")
        assertContains(out.html, RenderTestSupport.inlineImageURL("a"))
    }

    // MARK: DOM clobbering

    /// Named images become properties of the frame's document, and would shadow its own: the shell reads
    /// `doc.images` to watch a body's pictures load.
    func testImageNamesArePrefixedToAvoidClobberingTheShell() {
        let out = RenderTestSupport.sanitize(##"<img name="images" src="cid:a"><map name="m"><area href="https://good.example/"></map><img usemap="#m" src="cid:b">"##)
        assertContains(out.html, #"name="ss-images""#)
        assertContains(out.html, #"<map name="ss-m">"#)
        assertContains(out.html, ##"usemap="#ss-m""##)
    }

    // MARK: Performance

    func testNestedBorderedBlocksStayLinear() {
        let filler = String(repeating: "word ", count: 400_000)
        let html = String(repeating: #"<div style="border-top:1px solid">x"#, count: 390) + filler + String(repeating: "</div>", count: 390)
        let elapsed = ContinuousClock().measure { _ = RenderTestSupport.sanitize(html) }
        XCTAssertLessThan(elapsed, .seconds(1.5))
    }
}
