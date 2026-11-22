import WebKit
import XCTest
@testable import PaperApp

/// Where a click on a link in a body goes (spec §4.17: a link shows the pointing hand because a click on it does
/// something). The links the sanitizer keeps open in the app that handles them, a phone number included; an in-message
/// anchor scrolls to its place (`ReaderAnchorTests`); a bare `#` and an inline picture's `ss-cid:` do nothing, and show
/// no hand (`ConversationShellPointerTests`). The shell and its body frames still load, and nothing else does.
@MainActor
final class ConversationNavigationPolicyTests: XCTestCase {
    private typealias Policy = ConversationNavigationPolicy

    private func decision(_ link: String, _ type: WKNavigationType = .linkActivated, main: Bool = false) -> Policy.Decision {
        Policy.decision(for: URL(string: link), navigationType: type, isMainFrame: main)
    }

    func testLinksAnotherAppOpensGoToIt() {
        for link in ["https://example.com/a", "http://example.com", "mailto:ada@example.com", "tel:+15551234", "TEL:+15551234"] {
            XCTAssertEqual(decision(link), .openExternally, link)
        }
    }

    /// A body's document takes the shell's base address, so WebKit asks to load the shell's address with the anchor into
    /// the body's frame: cancelled, and the shell scrolls to the place instead.
    func testAnInMessageAnchorScrollsToItsPlace() {
        XCTAssertEqual(decision("ss-shell://local/#ss-top"), .moveToAnchor("ss-top"))
        XCTAssertEqual(decision("about:srcdoc#ss-top"), .moveToAnchor("ss-top"))
        for link in ["ss-shell://local/#", "ss-shell://local/#ss-", "ss-shell://local/#top", "ss-shell://local/other#ss-top",
                     "about:srcdoc#", "about:blank#ss-top", "ss-cid://acct/msg/logo", "javascript:alert(1)", "file:///etc/hosts"] {
            XCTAssertEqual(decision(link), .cancel, link)
        }
        XCTAssertEqual(decision("ss-shell://local/#ss-top", main: true), .cancel, "the shell itself never moves to a body's anchor")
    }

    func testTheShellAndItsFramesStillLoadAndNothingElse() {
        XCTAssertEqual(decision("ss-shell://conversation/", .other, main: true), .allow)
        XCTAssertEqual(decision("about:srcdoc", .other), .allow)
        XCTAssertEqual(decision("about:blank", .other), .allow)
        XCTAssertEqual(decision("https://example.com", .other), .cancel)
        XCTAssertEqual(decision("https://example.com", .other, main: true), .cancel)
        XCTAssertEqual(decision("ss-shell://conversation/", .linkActivated, main: true), .cancel)
    }

    /// Block trackers (spec §5.60): a link opened from a message reaches the browser without its tracking parameters while
    /// the setting is on, and exactly as written while it is off.
    func testALinkLosesItsTrackingParametersWhileBlockingIsOn() {
        let policy = Policy()
        let link = URL(string: "https://shop.example/p/42?utm_source=news&color=red&fbclid=abc#reviews")!
        XCTAssertEqual(policy.outgoing(link), link)
        policy.stripsTrackingParameters = true
        XCTAssertEqual(policy.outgoing(link).absoluteString, "https://shop.example/p/42?color=red#reviews")
        let mail = URL(string: "mailto:ada@example.com?subject=Hi&utm_source=x")!
        XCTAssertEqual(policy.outgoing(mail), mail, "only web links")
    }
}
