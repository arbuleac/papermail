import XCTest
@testable import PaperCore

final class CallServiceTests: XCTestCase {
    func testKnownHostsNameTheirService() {
        XCTAssertEqual(CallService(joinURL: "https://meet.google.com/abc"), .meet)
        XCTAssertEqual(CallService(joinURL: "https://teams.microsoft.com/l/x"), .teams)
        XCTAssertEqual(CallService(joinURL: "https://teams.live.com/meet/1"), .teams)
        XCTAssertEqual(CallService(joinURL: "https://contoso.zoom.us/j/1"), .zoom)
        XCTAssertEqual(CallService(joinURL: "https://zoom.com/j/1"), .zoom)
        XCTAssertEqual(CallService(joinURL: "https://acme.webex.com/meet/x"), .webex)
        XCTAssertEqual(CallService(host: "US02WEB.ZOOM.US"), .zoom, "hosts are compared without case")
        XCTAssertNil(CallService(joinURL: "https://example.com/call"))
        XCTAssertNil(CallService(joinURL: "not a url"))
        XCTAssertNil(CallService(host: ""))
    }

    /// A service is named only for its own domain or a subdomain of it, never for a look-alike that ends the same way.
    func testALookAlikeIsNoService() {
        for lookAlike in ["https://securezoom.us/j/1", "https://notzoom.com/j/1", "https://fakewebex.com/x",
                          "https://evilmeet.google.com.example/x", "https://myteams.microsoft.com.example/x"] {
            XCTAssertNil(CallService(joinURL: lookAlike), lookAlike)
        }
    }

    func testAPlaceIsACallOnlyWhenItIsOneSecureAddressOnAKnownHost() {
        XCTAssertEqual(EventLinkPolicy.callAddress(inLocation: " https://acme.zoom.us/j/1 "), "https://acme.zoom.us/j/1")
        XCTAssertNil(EventLinkPolicy.callAddress(inLocation: "http://acme.zoom.us/j/1"), "http is not a call")
        XCTAssertNil(EventLinkPolicy.callAddress(inLocation: "https://example.com/j/1"), "an unknown host is not a call")
        XCTAssertNil(EventLinkPolicy.callAddress(inLocation: "https://zoom.us@evil.test/j/1"), "a user name hides the host")
        XCTAssertNil(EventLinkPolicy.callAddress(inLocation: "Room 4, https://acme.zoom.us/j/1"), "more than an address")
        XCTAssertNil(EventLinkPolicy.callAddress(inLocation: nil))
    }
}
