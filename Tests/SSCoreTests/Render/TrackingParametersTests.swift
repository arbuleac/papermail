import Foundation
import XCTest
@testable import SSCore

/// Link stripping (spec §5.60): tracking parameters go, everything else of the address stays exactly as written, and a
/// redirect is left whole.
final class TrackingParametersTests: XCTestCase {
    private func strip(_ address: String) -> String { TrackingParameters.stripped(address) }

    func testCampaignTagsAndClickIDsGo() {
        XCTAssertEqual(strip("https://shop.example/p/42?utm_source=news&utm_medium=email&utm_campaign=fall"), "https://shop.example/p/42")
        XCTAssertEqual(strip("https://shop.example/?fbclid=IwAR0abc"), "https://shop.example/")
        XCTAssertEqual(strip("https://shop.example/?gclid=a&dclid=b&gbraid=c&wbraid=d&msclkid=e&yclid=f&igshid=g"), "https://shop.example/")
        XCTAssertEqual(strip("https://shop.example/?mc_cid=1&mc_eid=2&_hsenc=3&_hsmi=4&__hssc=5&__hstc=6&__hsfp=7&hsCtaTracking=8"),
                       "https://shop.example/")
        XCTAssertEqual(strip("https://shop.example/?mkt_tok=1&oly_anon_id=2&oly_enc_id=3&vero_id=4&_kx=5&ck_subscriber_id=6"),
                       "https://shop.example/")
    }

    func testOtherParametersKeepTheirOrderAndSpelling() {
        XCTAssertEqual(strip("https://shop.example/search?q=red+shoes&utm_source=news&page=2&sort=Price%20asc&utm_term=x"),
                       "https://shop.example/search?q=red+shoes&page=2&sort=Price%20asc")
        XCTAssertEqual(strip("https://shop.example/?a=1&&b=2&fbclid=x"), "https://shop.example/?a=1&&b=2", "an empty piece is kept as written")
        XCTAssertEqual(strip("https://shop.example/?flag&utm_source=x"), "https://shop.example/?flag")
    }

    func testThePathAndTheFragmentAreNeverTouched() {
        XCTAssertEqual(strip("https://shop.example/utm_source/fbclid?utm_source=x#utm_medium=y"), "https://shop.example/utm_source/fbclid#utm_medium=y")
        XCTAssertEqual(strip("https://shop.example/page#section?utm_source=x"), "https://shop.example/page#section?utm_source=x",
                       "a mark after the fragment starts no query")
    }

    func testNamesAreComparedWithoutCaseAndDecoded() {
        XCTAssertEqual(strip("https://shop.example/?UTM_Source=x&FBCLID=y&keep=1"), "https://shop.example/?keep=1")
        XCTAssertEqual(strip("https://shop.example/?utm%5Fsource=x&keep=1"), "https://shop.example/?keep=1")
        XCTAssertEqual(strip("https://shop.example/?utm_=x"), "https://shop.example/?utm_=x", "the bare prefix is no tag")
        XCTAssertEqual(strip("https://shop.example/?utmost=1&gclidx=2"), "https://shop.example/?utmost=1&gclidx=2", "lookalike names stay")
    }

    /// A redirect may check its own parameters, and the page it leads to is the sender's to name: left whole.
    func testRedirectsAreLeftWhole() {
        let wrapped = "https://click.example.com/track/click?u=1&url=https%3A%2F%2Fshop.example%2F%3Futm_source%3Dx&utm_source=y"
        XCTAssertEqual(strip(wrapped), wrapped)
        let google = "https://www.google.com/url?q=https://shop.example/?utm_source%3Dx&sa=D&utm_campaign=z"
        XCTAssertEqual(strip(google), google)
        let safelinks = "https://eur01.safelinks.protection.outlook.com/?url=http%3A%2F%2Fshop.example&data=05&utm_medium=x"
        XCTAssertEqual(strip(safelinks), safelinks)
    }

    func testOtherSchemesAndCleanLinksAreUnchanged() {
        XCTAssertEqual(strip("mailto:ada@example.com?subject=Hi&utm_source=x"), "mailto:ada@example.com?subject=Hi&utm_source=x")
        XCTAssertEqual(strip("tel:+15551234"), "tel:+15551234")
        XCTAssertEqual(strip("https://shop.example/p/42?color=red"), "https://shop.example/p/42?color=red")
        XCTAssertEqual(strip("https://shop.example/p/42"), "https://shop.example/p/42")
        let url = URL(string: "https://shop.example/?a=1")!
        XCTAssertTrue(TrackingParameters.stripped(url) == url)
        XCTAssertEqual(TrackingParameters.stripped(URL(string: "HTTP://shop.example/x?utm_source=a&b=1")!).absoluteString,
                       "HTTP://shop.example/x?b=1")
    }
}
