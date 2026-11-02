import XCTest
@testable import SSCore

/// The design facts the sanitizer records at sync time: `typesetting`, `declaresColors` and `coveredByNewYork`.
final class SanitizerTypesettingTests: XCTestCase {
    private func assertFacts(
        _ out: SanitizedBody,
        _ typesetting: BodyTypesetting,
        declaresColors: Bool,
        covered: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(out.typesetting, typesetting, "typesetting", file: file, line: line)
        XCTAssertEqual(out.declaresColors, declaresColors, "declaresColors", file: file, line: line)
        XCTAssertEqual(out.coveredByNewYork, covered, "coveredByNewYork", file: file, line: line)
    }

    // MARK: Plain

    func testTextPartIsPlain() {
        assertFacts(RenderTestSupport.sanitizeText("Hi Bob,\n\nSee you Thursday.\n\n> On Monday you wrote:\n> Hello"),
                    .plain, declaresColors: false)
    }

    func testBlankHTMLFallsBackToPlain() {
        let out = HTMLSanitizer().sanitize(MessageBody(html: " \n ", text: "plain"), messageID: RenderTestSupport.messageID)
        assertFacts(out, .plain, declaresColors: false)
        let empty = HTMLSanitizer().sanitize(MessageBody(html: nil, text: nil), messageID: RenderTestSupport.messageID)
        assertFacts(empty, .plain, declaresColors: false)
    }

    // MARK: Unstyled

    func testPersonalMailFromCommonClientsIsUnstyled() {
        // Gmail's quote bar (margin, border, padding) and Apple Mail's wrapping on <body> are not author styling.
        for (name, html) in [
            ("gmail", MailShapeFixtures.gmailReply),
            ("apple", MailShapeFixtures.appleMailReply),
            ("generic", MailShapeFixtures.genericReply),
            ("inline image", MailShapeFixtures.inlineImage),
        ] {
            let out = RenderTestSupport.sanitize(html)
            XCTAssertEqual(out.typesetting, .unstyled, name)
            XCTAssertFalse(out.declaresColors, name)
        }
    }

    func testNeutralMarkupStaysUnstyled() {
        let cases = [
            #"<div dir="rtl" style="text-align:right;direction:rtl">שלום</div>"#,
            #"<blockquote style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex">quoted</blockquote>"#,
            #"<p style="white-space:pre-wrap;word-break:break-word">long</p>"#,
            #"<img src="cid:photo" style="width:400px;max-width:100%;height:auto"><p>Our trip</p>"#,
            #"<table border="1"><tr><th>Item</th><th>Qty</th></tr><tr><td>Pens</td><td>4</td></tr></table>"#,
            #"<font>no attributes</font>"#,
            #"<style>/* only a comment */</style><p>x</p>"#,
            #"<style><!-- --></style><p>x</p>"#,
        ]
        for html in cases {
            let out = RenderTestSupport.sanitize(html)
            XCTAssertEqual(out.typesetting, .unstyled, html)
            XCTAssertFalse(out.declaresColors, html)
        }
    }

    // MARK: Styled

    func testNewsletterIsStyledAndDeclaresColors() {
        assertFacts(RenderTestSupport.sanitize(MailShapeFixtures.newsletter), .styled, declaresColors: true)
        assertFacts(RenderTestSupport.sanitize(MailShapeFixtures.largeNewsletter(approximateBytes: 20_000)),
                    .styled, declaresColors: true)
    }

    func testClientsThatSetFontsOrColoursAreStyled() {
        assertFacts(RenderTestSupport.sanitize(MailShapeFixtures.outlookWebReply), .styled, declaresColors: true)
        assertFacts(RenderTestSupport.sanitize(MailShapeFixtures.yahooReply), .styled, declaresColors: true)
    }

    func testAuthorStylingWithoutColourIsStyled() {
        let cases = [
            "<style>p{margin:0}</style><p>x</p>",
            #"<p style="font-family:Georgia,serif">x</p>"#,
            #"<p style="font-size:18px">x</p>"#,
            #"<div style="width:600px">x</div>"#,
            #"<img src="cid:a" style="display:block;width:100px">"#,
            #"<font face="Arial">x</font>"#,
            #"<font size="4">x</font>"#,
            #"<table width="600"><tr><td>x</td></tr></table>"#,
            #"<table cellpadding="0" cellspacing="0"><tr><td>x</td></tr></table>"#,
            #"<table align="center"><tr><td>x</td></tr></table>"#,
            #"<table role="Presentation"><tr><td>x</td></tr></table>"#,
            "<table><tr><td><table><tr><td>nested</td></tr></table></td></tr></table>",
            // A colour declaration that paints nothing is still a declaration the sender wrote.
            #"<p style="color:inherit">x</p>"#,
        ]
        for html in cases {
            let out = RenderTestSupport.sanitize(html)
            XCTAssertEqual(out.typesetting, .styled, html)
            XCTAssertFalse(out.declaresColors, html)
        }
    }

    // MARK: Colours

    func testEveryColourSourceInTheDefinitionCounts() {
        let cases = [
            #"<p style="color:#333">x</p>"#,
            #"<p style="COLOR: Red !important">x</p>"#,
            #"<div style="background:#fafafa">x</div>"#,
            #"<div style="background-color:rgb(250,250,250)">x</div>"#,
            ##"<table><tr><td bgcolor="#eeeeee">x</td></tr></table>"##,
            #"<font color="red">x</font>"#,
            "<style>p{color:red}</style><p>x</p>",
            "<style>@media (min-width:1px){.a{background-color:#000}}</style><p class=a>x</p>",
            "<html><body text=\"#000000\"><p>x</p></body></html>",
            "<html><body link=\"#0000ee\"><p>x</p></body></html>",
            "<html><body bgcolor=\"#ffffff\"><p>x</p></body></html>",
            // Blocked remote backgrounds still count: they are part of the design and come back with images.
            #"<div background="https://cdn.example/bg.png">x</div>"#,
            #"<div style="background-image:url(https://cdn.example/a.png)">x</div>"#,
            "<style>.hero{background:url(https://cdn.example/hero.jpg) center/cover}</style><div class=hero>x</div>",
        ]
        for html in cases {
            let out = RenderTestSupport.sanitize(html)
            XCTAssertTrue(out.declaresColors, html)
            XCTAssertEqual(out.typesetting, .styled, html)
        }
    }

    func testKeywordsThatPaintNothingAreNotColours() {
        for html in [
            #"<p style="color:inherit">x</p>"#,
            #"<p style="color: currentColor">x</p>"#,
            #"<p style="background:transparent !important">x</p>"#,
            #"<p style="background-image:none">x</p>"#,
            #"<p style="background-color:initial">x</p>"#,
            #"<p style="color:">x</p>"#,
        ] {
            XCTAssertFalse(RenderTestSupport.sanitize(html).declaresColors, html)
        }
    }

    func testColourAttributesOutsideTheirElementsDoNotCount() {
        // `color` and `face` mean something only on <font>; `text` and `link` only on <body>.
        for html in [#"<hr color="red" size="3">"#, ##"<p text="#000">x</p>"##, ##"<p link="#00f">x</p>"##] {
            let out = RenderTestSupport.sanitize(html)
            XCTAssertFalse(out.declaresColors, html)
            XCTAssertEqual(out.typesetting, .unstyled, html)
        }
    }

    func testColoursSurviveTheFilterUnchanged() {
        let out = RenderTestSupport.sanitize(#"<p style="color:#333;font-size:14px">x</p><font color="red">y</font>"#)
        assertContains(out.html, "color:#333")
        assertContains(out.html, #"color="red""#)
    }

    // MARK: New York coverage

    func testLatinGreekAndCyrillicAreCovered() {
        for text in [
            "Café, naïve façade — “quoted” … 12 € ½",
            "Vietnamese: Tiếng Việt có dấu",
            "Ελληνικά: Καλημέρα σας",
            "Русский: Съешь же ещё этих мягких французских булок",
            "Українська: Ґанок, їжак, єнот",
            "Emoji and symbols fall back the same in both faces: 🎉 👍🏽 ✓ → ★",
        ] {
            XCTAssertTrue(RenderTestSupport.sanitizeText(text).coveredByNewYork, text)
            XCTAssertTrue(RenderTestSupport.sanitize("<p>\(text)</p>").coveredByNewYork, text)
        }
    }

    func testCJKArabicAndOtherScriptsAreNotCovered() {
        for text in [
            "日本語のメール",
            "中文邮件",
            "한국어 이메일",
            "مرحبا بالعالم",
            "שלום עולם",
            "สวัสดีครับ",
            "नमस्ते दुनिया",
            "Mostly English with one word: 東京",
        ] {
            XCTAssertFalse(RenderTestSupport.sanitizeText(text).coveredByNewYork, text)
            XCTAssertFalse(RenderTestSupport.sanitize("<div>\(text)</div>").coveredByNewYork, text)
        }
    }

    func testCoverageTableIsWellFormed() {
        let ranges = NewYorkCoverage.ranges
        XCTAssertEqual(ranges.count % 2, 0)
        for index in stride(from: 0, to: ranges.count, by: 2) {
            XCTAssertLessThanOrEqual(ranges[index], ranges[index + 1])
            if index > 0 { XCTAssertGreaterThan(ranges[index], ranges[index - 1] + 1, "ranges must be sorted and merged") }
        }
        for scalar in ["A", "z", "0", "é", "Ж", "Ω", "ẞ", "€"].compactMap({ $0.unicodeScalars.first }) {
            XCTAssertTrue(NewYorkCoverage.contains(scalar), String(scalar))
        }
        for scalar in ["日", "ا", "א", "ก", "\u{00AD}", "\u{1F600}"].compactMap({ $0.unicodeScalars.first }) {
            XCTAssertFalse(NewYorkCoverage.contains(scalar), String(scalar))
        }
        XCTAssertTrue(NewYorkCoverage.contains("\u{1F16B}"), "the last range's upper bound")
        XCTAssertFalse(NewYorkCoverage.contains("\u{10FFFF}"))
    }
}
