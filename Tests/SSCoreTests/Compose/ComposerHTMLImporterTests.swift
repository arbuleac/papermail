import AppKit
import XCTest
@testable import SSCore

/// Reading the composer's HTML subset back (roadmap Q1.5: a signature is kept as that HTML and put back into the
/// editor): what the exporter writes comes back as the same paragraphs and styles, and anything else is reduced to
/// composer text.
final class ComposerHTMLImporterTests: XCTestCase {
    private typealias Run = ComposerHTMLImporter.Run
    private let importer = ComposerHTMLImporter()

    func testTheExportersOwnHTMLComesBackAsWritten() {
        let html = "<div><p><b>Alex Morgan</b></p><p><i>Head of <u>Rollout</u></i> · <a href=\"https://contoso.test/a?b=1&amp;c=2\">contoso</a></p>"
            + "<p><br></p><p>Tel &lt;+1&gt; 555&nbsp;0100<br>Lisbon</p></div>"
        XCTAssertEqual(importer.paragraphs(from: html), [
            [Run(text: "Alex Morgan", bold: true)],
            [Run(text: "Head of ", italic: true), Run(text: "Rollout", italic: true, underline: true), Run(text: " · "),
             Run(text: "contoso", link: "https://contoso.test/a?b=1&c=2")],
            [],
            [Run(text: "Tel <+1> 555\u{00A0}0100\u{2028}Lisbon")],
        ])
    }

    /// Exporting what was imported gives the same HTML, so a signature survives being loaded into the Settings field and
    /// saved again unchanged.
    func testARoundTripThroughTheExporterIsStable() {
        let html = "<div><p><b>Alex</b> <i>Morgan</i></p><p><br></p><p><a href=\"mailto:alex@contoso.test\"><u>Write to me</u></a></p></div>"
        let paragraphs = importer.paragraphs(from: html)
        let body = NSMutableAttributedString()
        for (index, runs) in paragraphs.enumerated() {
            if index > 0 { body.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)])) }
            for run in runs {
                var font = NSFont.systemFont(ofSize: 13)
                if run.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [.font: font]
                if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = link }
                body.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        XCTAssertEqual(ComposerHTMLExporter().export(body).html, html)
    }

    func testAnythingElseIsReducedToComposerText() {
        let html = """
            <div style="color:red" onclick="steal()">
              <p class="x"><span style="font-size:40px">Big</span> <font color="red">words</font><script>alert(1)</script></p>
              <style>p { color: red }</style>
              <ul><li><strong>Bold</strong> item</li></ul>
              <blockquote><p><em>Quoted</em></p></blockquote>
              <p><a href="javascript:alert(1)">bad link</a> <a href="https://ok.test" onmouseover="x()">good</a></p>
              <!-- a comment --><img src="https://tracker.test/p.gif">
            </div>
            """
        XCTAssertEqual(importer.paragraphs(from: html), [
            [Run(text: "Big words")],
            [Run(text: "Bold", bold: true), Run(text: " item")],
            [Run(text: "Quoted", italic: true)],
            [Run(text: "bad link "), Run(text: "good", link: "https://ok.test")],
        ])
    }

    func testEmptyAndPlainInput() {
        XCTAssertEqual(importer.paragraphs(from: ""), [])
        XCTAssertEqual(importer.paragraphs(from: "  \n "), [])
        XCTAssertEqual(importer.paragraphs(from: "<div></div>"), [])
        XCTAssertEqual(importer.paragraphs(from: "Just text"), [[Run(text: "Just text")]])
        XCTAssertEqual(importer.paragraphs(from: "<p></p>"), [[]], "a paragraph element is a paragraph, empty or not")
    }
}
