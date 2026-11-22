import Foundation
import XCTest
@testable import PaperCore

/// Find in conversation (spec §5.50), headless: the shell's reports read totally, the bar's words, the calls the app
/// makes, and the shell's side of the contract (its API and the marks' styles in every body document). The search
/// itself is driven in a web view by `ConversationShellFindTests` (PAPER_UI_TESTS=1) and in the real reader by the app's
/// `FindInConversationTests`.
final class ConversationFindTests: XCTestCase {
    typealias Result = ConversationFind.Result

    func testTheCountReadsAsTheBarShowsIt() {
        XCTAssertEqual(Result(query: "lisbon", count: 12, index: 2).countText, "3 of 12")
        XCTAssertEqual(Result(query: "lisbon", count: 1, index: 0).countText, "1 of 1")
        XCTAssertEqual(Result(query: "lisbon", count: 0, index: nil).countText, "No matches")
        XCTAssertNil(Result(query: "", count: 0, index: nil).countText, "nothing typed, nothing counted")
        XCTAssertNil(Result(query: "  \n", count: 0, index: nil).countText, "white space finds nothing")
        XCTAssertEqual(Result(query: "a", count: 12_345, index: 1_233).countText,
                       "\(1_234.formatted(.number.grouping(.automatic))) of \(12_345.formatted(.number.grouping(.automatic)))")
    }

    func testVoiceOverHearsWhatTheCountMeans() {
        XCTAssertEqual(Result(query: "lisbon", count: 12, index: 2).announcement, "Match 3 of 12")
        XCTAssertEqual(Result(query: "lisbon", count: 0, index: nil).announcement, "No matches")
        XCTAssertNil(Result(query: "", count: 0, index: nil).announcement)
    }

    func testReportsAreReadTotally() {
        let report = Result(body: ["kind": "find", "query": "lisbon", "count": NSNumber(value: 4), "index": NSNumber(value: 1)])
        XCTAssertEqual(report, Result(query: "lisbon", count: 4, index: 1))
        XCTAssertEqual(Result(body: ["query": "x", "count": NSNumber(value: 0), "index": NSNumber(value: -1)])?.index, nil,
                       "the shell's -1 is no current match")
        XCTAssertEqual(Result(body: ["query": "x", "count": NSNumber(value: 2), "index": NSNumber(value: 7)])?.index, nil,
                       "an index past the count is none")
        XCTAssertNil(Result(body: ["count": NSNumber(value: 1)]), "no query")
        XCTAssertNil(Result(body: ["query": "x"]), "no count")
        XCTAssertNil(Result(body: ["query": "x", "count": NSNumber(value: -3)]), "a negative count")
        XCTAssertNil(Result(body: ["query": 4, "count": NSNumber(value: 1)]))
    }

    func testTheCallsQuoteTheQueryAsAJavaScriptString() {
        XCTAssertEqual(ConversationFind.findScript("it's \"here\"</script>"), "window.ss.find(\"it's \\\"here\\\"\\u003c/script>\")")
        XCTAssertEqual(ConversationFind.stepScript(1), "window.ss.findStep(1)")
        XCTAssertEqual(ConversationFind.stepScript(-5), "window.ss.findStep(-1)")
        XCTAssertEqual(ConversationFind.clearScript, "window.ss.findClear()")
        XCTAssertTrue(ConversationFind.isSearchable(" a "))
        XCTAssertFalse(ConversationFind.isSearchable(" \t"))
    }

    func testTheShellOffersTheCallsAndPostsItsReports() {
        let js = ConversationShellAssets.js
        for name in ["find: startFind", "findStep: stepFind", "findClear: endFind", "findState: function"] {
            XCTAssertTrue(js.contains(name), name)
        }
        XCTAssertTrue(js.contains("post('ss', { kind: 'find', query: find.query, count: find.matches.length, index: find.index })"))
        // Bodies without a frame are read through DOMParser, whose document runs and loads nothing; never by an element
        // of the shell's own document, where an image's source would load.
        XCTAssertTrue(js.contains("new DOMParser().parseFromString("))
        XCTAssertFalse(js.contains("createElement('template')"))
    }

    func testEveryBodyDocumentCarriesTheMarksStylesAndTheirColours() {
        let css = ConversationShellAssets.bodyCSS
        XCTAssertTrue(css.contains(":root body mark.ss-find {"))
        XCTAssertTrue(css.contains("background-color: var(--q-findWash) !important; color: var(--q-ink) !important"))
        XCTAssertTrue(css.contains(":root body mark.ss-find.ss-find-now {"))
        XCTAssertTrue(css.contains("box-shadow: 0 0 0 1px var(--q-ruleStrong) !important"))
        // The variables travel into the frame in every mode block, so Increase Contrast switches them there too.
        let variables = ConversationShellAssets.bodyVariables
        for name in ["--q-findWash:", "--q-findCurrent:", "--q-ruleStrong:"] {
            XCTAssertGreaterThanOrEqual(variables.components(separatedBy: name).count - 1, 4, "\(name) in light, dark and both IC blocks")
        }
        XCTAssertTrue(variables.contains("--q-r-xs:3px"), "the marks' corner, `layout.findBar.matchRadius`")
        XCTAssertEqual(QuireCSS.head.contains("--q-r-xs:3px"), true)
    }
}
