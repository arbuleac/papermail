import XCTest
@testable import SSCore

/// Every case removes one hostile construct and checks the benign content around it is still there.
final class SanitizerAttackTests: XCTestCase {
    func testInlineScriptIsRemoved() {
        let out = RenderTestSupport.sanitize(AttackFixtures.inlineScript)
        assertNotContainsIgnoringCase(out.html, "<script")
        assertNotContains(out.html, "alert(")
        assertContains(out.html, "<p>Hello</p>")
        assertContains(out.html, "<p>World</p>")
        XCTAssertEqual(out.plainText, "Hello\n\nWorld")
    }

    func testImageEventHandlerIsRemoved() {
        let out = RenderTestSupport.sanitize(AttackFixtures.imgOnError)
        assertNotContainsIgnoringCase(out.html, "onerror")
        assertContains(out.html, "src=\"\(RenderTestSupport.inlineImageURL("logo"))\"")
        assertContains(out.html, "alt=\"Logo\"")
        assertContains(out.html, "<p>Before</p>")
        assertContains(out.html, "<p>After</p>")
    }

    func testJavascriptHrefIsDropped() {
        let out = RenderTestSupport.sanitize(AttackFixtures.javascriptHref)
        assertNotContainsIgnoringCase(out.html, "javascript:")
        assertContains(out.html, "<a>here</a>")
        assertContains(out.html, "<a href=\"https://good.example/\">there</a>")
    }

    func testObfuscatedJavascriptHrefIsDropped() {
        let out = RenderTestSupport.sanitize(AttackFixtures.javascriptHrefObfuscated)
        assertNotContainsIgnoringCase(out.html, "script:")
        assertContains(out.html, ">tab</a>")
        assertContains(out.html, ">case</a>")
    }

    func testDataHTMLHrefIsDropped() {
        let out = RenderTestSupport.sanitize(AttackFixtures.dataHTMLHref)
        assertNotContains(out.html, "data:text/html")
        assertContains(out.html, "<a>open</a>")
        assertContains(out.html, "<p>Rest</p>")
    }

    func testDataImageHrefIsDroppedOnLinks() {
        let out = RenderTestSupport.sanitize(AttackFixtures.dataImageHref)
        assertNotContains(out.html, "data:image")
        assertContains(out.html, "image link")
    }

    func testDataImageSourceIsKeptOnImages() {
        let tiny = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        let out = RenderTestSupport.sanitize("<img src=\"\(tiny)\" alt=\"dot\"><p>x</p>")
        assertContains(out.html, "src=\"\(tiny)\"")
        XCTAssertEqual(out.blockedRemoteImageCount, 0)
    }

    func testOversizedDataImageIsDropped() {
        let payload = String(repeating: "A", count: 2 * 1024 * 1024 + 16)
        let out = RenderTestSupport.sanitize("<img src=\"data:image/png;base64,\(payload)\" alt=\"big\"><p>x</p>")
        assertNotContains(out.html, "data:image/png")
        assertContains(out.html, "alt=\"big\"")
    }

    func testSVGScriptAndOnloadAreRemoved() {
        let out = RenderTestSupport.sanitize(AttackFixtures.svgOnload)
        assertNotContainsIgnoringCase(out.html, "onload")
        assertNotContainsIgnoringCase(out.html, "<script")
        assertNotContainsIgnoringCase(out.html, "javascript:")
        assertContains(out.html, "<circle")
        assertContains(out.html, "<p>Logo</p>")
        assertContains(out.html, "<p>Tail</p>")
    }

    func testSVGRemoteReferencesAreRemoved() {
        let out = RenderTestSupport.sanitize(AttackFixtures.svgUse)
        assertNotContains(out.html, "evil.example")
        assertNotContainsIgnoringCase(out.html, "<use")
        assertContains(out.html, "<p>kept</p>")
    }

    func testMetaRefreshIsRemoved() {
        let out = RenderTestSupport.sanitize(AttackFixtures.metaRefresh)
        assertNotContainsIgnoringCase(out.html, "<meta")
        assertNotContainsIgnoringCase(out.html, "refresh")
        assertNotContainsIgnoringCase(out.html, "<title")
        assertContains(out.html, "<p>Body text</p>")
    }

    func testRemoteFormIsRemoved() {
        let out = RenderTestSupport.sanitize(AttackFixtures.remoteForm)
        assertNotContainsIgnoringCase(out.html, "<form")
        assertNotContainsIgnoringCase(out.html, "<input")
        assertNotContainsIgnoringCase(out.html, "<button")
        assertNotContains(out.html, "evil.example")
        assertContains(out.html, "<p>Intro</p>")
        assertContains(out.html, "<p>Outro</p>")
    }

    func testBaseHrefIsRemoved() {
        let out = RenderTestSupport.sanitize(AttackFixtures.baseHref)
        assertNotContainsIgnoringCase(out.html, "<base")
        assertNotContains(out.html, "evil.example")
        assertContains(out.html, "<a href=\"https://good.example/\">good</a>")
    }

    func testCSSURLInStyleAttributeIsDropped() {
        let out = RenderTestSupport.sanitize(AttackFixtures.cssExfilStyleAttribute)
        assertNotContains(out.html, "evil.example")
        assertNotContains(out.html, "url(")
        assertContains(out.html, "color: red;")
        assertContains(out.html, "font-weight: bold;")
        assertContains(out.html, ">Styled</div>")
        XCTAssertEqual(out.blockedRemoteImageCount, 1)
    }

    func testCSSURLInStyleElementIsDropped() {
        let out = RenderTestSupport.sanitize(AttackFixtures.cssExfilStyleElement)
        assertNotContains(out.html, "evil.example")
        assertContains(out.html, "<style>")
        assertContains(out.html, "color: blue;")
        assertContains(out.html, "font-weight: bold;")
        assertContains(out.html, "<p class=\"a\">Text</p>")
        XCTAssertEqual(out.blockedRemoteImageCount, 1)
    }

    func testCSSImportIsDropped() {
        let out = RenderTestSupport.sanitize(AttackFixtures.cssImport)
        assertNotContainsIgnoringCase(out.html, "@import")
        assertNotContains(out.html, "evil.example")
        assertContains(out.html, "color: green;")
        assertContains(out.html, "<p>Hi</p>")
    }

    func testCSSExpressionAndBindingsAreDropped() {
        let out = RenderTestSupport.sanitize(AttackFixtures.cssExpression)
        assertNotContainsIgnoringCase(out.html, "expression(")
        assertNotContainsIgnoringCase(out.html, "behavior")
        assertNotContainsIgnoringCase(out.html, "-moz-binding")
        assertNotContains(out.html, "evil.example")
        assertContains(out.html, "color: red;")
        assertContains(out.html, "color: blue;")
    }

    func testPositionFixedIsDropped() {
        let out = RenderTestSupport.sanitize(AttackFixtures.cssPositionFixed)
        assertNotContainsIgnoringCase(out.html, "fixed")
        assertContains(out.html, "top: 0;")
        assertContains(out.html, "color: red;")
        assertContains(out.html, "color: green;")
    }

    func testCIDTraversalIsRejected() {
        let out = RenderTestSupport.sanitize(AttackFixtures.cidTraversal)
        assertNotContains(out.html, "etc/passwd")
        assertNotContains(out.html, "ss-cid://")
        assertNotContains(out.html, "cid:")
        assertContains(out.html, "alt=\"x\"")
        assertContains(out.html, "alt=\"y\"")
        assertContains(out.html, "<p>end</p>")
    }

    func testSrcsetIsRemoved() {
        let out = RenderTestSupport.sanitize(AttackFixtures.srcsetRemote)
        assertNotContainsIgnoringCase(out.html, "srcset")
        assertNotContains(out.html, "evil.example")
        assertContains(out.html, "src=\"\(RenderTestSupport.inlineImageURL("logo"))\"")
        assertContains(out.html, "<p>after</p>")
        XCTAssertEqual(out.blockedRemoteImageCount, 0)
    }

    func testIframeSrcdocIsRemoved() {
        let out = RenderTestSupport.sanitize(AttackFixtures.iframeSrcdoc)
        assertNotContainsIgnoringCase(out.html, "<iframe")
        assertNotContainsIgnoringCase(out.html, "srcdoc")
        assertNotContains(out.html, "evil.example")
        assertContains(out.html, "<p>A</p>")
        assertContains(out.html, "<p>B</p>")
    }

    func testPluginsAndMathAreRemoved() {
        let out = RenderTestSupport.sanitize(AttackFixtures.objectEmbed)
        for tag in ["<object", "<embed", "<applet", "<math"] { assertNotContainsIgnoringCase(out.html, tag) }
        assertNotContains(out.html, "evil.example")
        assertContains(out.html, "<p>ok</p>")
    }

    func testEventHandlersAreRemovedRegardlessOfCase() {
        let out = RenderTestSupport.sanitize(AttackFixtures.eventHandlersMixedCase)
        assertNotContainsIgnoringCase(out.html, "onclick")
        assertNotContainsIgnoringCase(out.html, "onmouseover")
        // Nothing in the style needed filtering, so it is kept exactly as written.
        assertContains(out.html, "style=\"color:red\"")
        assertContains(out.html, ">text</p>")
    }

    func testIdentifiersArePrefixed() {
        let out = RenderTestSupport.sanitize(AttackFixtures.idCollision)
        assertContains(out.html, "id=\"ss-shell\"")
        assertContains(out.html, "id=\"ss-ss-shell\"")
        assertContains(out.html, "href=\"#ss-shell\"")
        assertContains(out.html, "#ss-shell{")
        assertNotContains(out.html, "id=\"shell\"")
    }

    func testSpoofedShellMarkupIsStripped() {
        let out = RenderTestSupport.sanitize(AttackFixtures.spoofedShellMarkup)
        assertNotContains(out.html, "evil.example")
        assertNotContains(out.html, "data-ss-collapsed")
        assertNotContains(out.html, "ss-quote")
        assertContains(out.html, "class=\"other\"")
        assertContains(out.html, ">hidden</div>")
        XCTAssertFalse(out.hasQuotedContent)
    }

    func testBodyBackgroundImageIsBlockedAndCounted() {
        let out = RenderTestSupport.sanitize("<html><body background=\"https://evil.example/bg.png\" bgcolor=\"#fafafa\"><p>x</p></body></html>")
        assertNotContains(out.html, "evil.example")
        assertContains(out.html, "class=\"ss-body\" style=\"background-color: #fafafa;background-image: none;\"")
        XCTAssertEqual(out.blockedRemoteImageCount, 1)
    }

    func testPathologicalNestingDoesNotCrash() {
        let out = RenderTestSupport.sanitize(AttackFixtures.deepNesting)
        assertContains(out.html, "class=\"ss-body\"")
    }

    func testOutputIsPlainHTMLWithoutPrettyPrinting() {
        let out = RenderTestSupport.sanitize("<p>caf\u{E9} &amp; <b>x</b><br>y</p>\n<p>z</p>")
        // SwiftSoup writes void elements as `<br />` in HTML syntax too; browsers ignore the slash.
        assertContains(out.html, "<p>café &amp; <b>x</b><br />y</p>\n<p>z</p>")
        assertNotContains(out.html, "&eacute;")
        assertNotContains(out.html, "&#")
        assertNotContains(out.html, "\n ")
    }
}
