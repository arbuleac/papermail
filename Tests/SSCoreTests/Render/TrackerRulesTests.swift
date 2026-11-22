import Foundation
import JavaScriptCore
import XCTest
@testable import SSCore

/// The tracker rules (spec §5.60): every known endpoint matches its pixel, the addresses around it do not, the heuristics
/// take tiny and hidden images and leave content alone, and the content blocker's expressions say exactly what the
/// sanitizer's matcher says.
final class TrackerRulesTests: XCTestCase {
    /// One real-shaped pixel address for every endpoint, in `TrackerRules.endpoints` order.
    private let pixels: [String] = [
        "https://us21.list-manage.com/track/open.php?u=8a1f&id=77c0&e=31d4",
        "https://mandrillapp.com/track/open.php?u=30061&id=9c2b",
        "https://u1234567.ct.sendgrid.net/wf/open?upn=abc123",
        "https://url4417.shop.example.com/wf/open?upn=Z2l2ZS1tZQ",
        "https://email.mg.example.com/o/eJwlzEEOgjAQBdDTlKWZ",
        "https://spgo.io/q/WbELmrJx7bLk",
        "https://eu.sparkpostmail.com/q/aGVsbG8",
        "https://pstmrk.it/open?m=v3_1.abc",
        "https://a1b2.r.us-east-1.awstrack.me/I0/0100018b/abc=",
        "https://x5k2.mjt.lu/oo/BAAAAKcd",
        "https://r.sb.sendibt3.com/tr/op/Ab1-cD2",
        "https://news.cmail19.com/t/d-o-abcdef-xyz/o.gif",
        "https://r20.rs6.net/on.jsp?a=1101&r=3",
        "https://track.customer.io/e/o/eyJlbWFpbF9pZCI6IjEifQ",
        "https://links.example.com/e/o/eyJlbWFpbF9pZCI6IjIifQ==",
        "https://trk.klclick.com/open/abc",
        "https://ctrk.klclick1.com/o/abc",
        "https://ctrk.klclick2.com/o/abc",
        "https://ctrk.klclick3.com/o/abc",
        "https://links.iterable.com/e/eo?_t=abc&_m=def",
        "https://intercom-mail.com/via/o?h=abc",
        "https://via.intercom.io/o?h=abc",
        "https://open.convertkit-mail.com/abc123",
        "https://open.convertkit-mail2.com/abc123",
        "https://abc.emltrk.com/v2/abc?d=1",
        "https://d2v8tf04.na1.hubspotlinks.com/e2t/to/VWm9xP",
        "https://track.hubspot.com/__ptq.gif?a=1&k=14",
        "https://go.example.com/trk?t=1&mid=MzIxLUFCQy0wMDI",
        "https://pi.pardot.com/r/123/open/1",
        "https://cl.s7.exct.net/open.aspx?ffcb10-fec811",
        "https://click.e.example.com/open.aspx?ffcb10-fe8b",
        "https://s1234.t.eloqua.com/e/FooterImages/FooterImage1?elq=abc",
        "https://news.example.com/pub/as?_ri_=X0Gzc2X",
        "https://mailtrack.io/trace/mail/3d5c.png?u=12",
        "https://email.mixmax.com/api/track/v2/abc/def",
        "https://t.yesware.com/t/abc/def/spacer.gif",
        "https://mailfoogae.appspot.com/t?sender=abc&type=zerocontent&guid=def",
        "https://r.superhuman.com/AbC123.gif",
        "https://email81.com/case/abc/1.png",
        "https://bl-1.com/x/abc.png",
        "https://bowtie.mailbutler.io/tracking/hit/abc/c.gif",
        "https://app.frontapp.com/api/1/noauth/companies/acme/seen?id=abc",
        "https://www.facebook.com/tr?id=123&ev=PageView&noscript=1",
        "https://www.linkedin.com/emimp/ip_abc.gif",
        "https://px.ads.linkedin.com/collect/?pid=123&fmt=gif",
        "https://twitter.com/scribe/ibis?t=1&cn=abc",
        "https://x.com/scribe/ibis?t=1",
        "https://t.co/i/adsct?txn_id=abc&p_id=Twitter",
        "https://analytics.twitter.com/i/adsct?p_id=1",
        "https://www.google-analytics.com/collect?v=1&tid=UA-1&t=event",
        "https://stats.g.doubleclick.net/r/collect?v=1",
    ]

    /// Addresses that look near one but are real images, or other services altogether.
    private let content: [String] = [
        "https://mcusercontent.com/8a1f/images/hero.jpg",
        "https://gallery.mailchimp.com/8a1f/images/logo.png",
        "https://us21.list-manage.com/track/click?u=8a1f&id=77c0",
        "https://cdn.example.com/wf/open",                              // SendGrid's path without its parameter
        "https://cdn.example.com/wf/opener?upn=1",
        "https://cdn.example.com/o/photo.jpg",                          // Mailgun's path without its zlib token
        "https://cdn.example.com/e/o/hero.png",
        "https://images.example.com/t/banner/hero.gif",                 // Campaign Monitor's shape, another file
        "https://evil-list-manage.com/track/open.php",                  // not a subdomain of the host
        "https://list-manage.com.example.net/track/open.php",
        "https://www.facebook.com/tree.png",
        "https://www.facebook.com/images/fb_icon.png",
        "https://scontent.xx.fbcdn.net/v/t1.0-9/photo.jpg",
        "https://media.licdn.com/dms/image/abc/profile.jpg",
        "https://pbs.twimg.com/media/abc.jpg",
        "https://go.example.com/trk?t=1",                               // Marketo's path without its parameter
        "https://images.example.com/open.aspx.png",
        "https://pardot.com/l/123/image.png",
        "https://www.google.com/images/branding/logo.png",
        "https://example.com/track/open.php",                           // Mailchimp's path on another host
        "https://hubspot.com/hubfs/logo.png",
        "https://eloqua.com/EloquaImages/clients/Acme/logo.png",
    ]

    func testEveryKnownEndpointMatchesItsPixel() {
        XCTAssertEqual(pixels.count, TrackerRules.endpoints.count, "one sample per endpoint")
        for (endpoint, pixel) in zip(TrackerRules.endpoints, pixels) {
            XCTAssertTrue(endpoint.matches(pixel), "\(endpoint.service) misses \(pixel)")
            XCTAssertNotNil(TrackerRules.knownEndpoint(for: pixel), pixel)
            XCTAssertEqual(TrackerRules.reason(forImageAt: pixel, hints: .init(width: "600", height: "300")), .known,
                           "a known endpoint is a tracker however large it is drawn: \(pixel)")
        }
    }

    func testContentAndLookalikesAreNotKnownEndpoints() {
        for address in content {
            XCTAssertNil(TrackerRules.knownEndpoint(for: address), "\(address) taken for \(TrackerRules.knownEndpoint(for: address)?.service ?? "")")
        }
    }

    func testMatchingIgnoresCasePortUserAndTrailingDot() {
        XCTAssertNotNil(TrackerRules.knownEndpoint(for: "HTTPS://US21.LIST-MANAGE.COM/TRACK/OPEN.PHP?u=1"))
        XCTAssertNotNil(TrackerRules.knownEndpoint(for: "https://us21.list-manage.com:443/track/open.php"))
        XCTAssertNotNil(TrackerRules.knownEndpoint(for: "https://someone@us21.list-manage.com/track/open.php"))
        XCTAssertNotNil(TrackerRules.knownEndpoint(for: "https://us21.list-manage.com./track/open.php"))
        XCTAssertNotNil(TrackerRules.knownEndpoint(for: "http://www.google-analytics.com"), "a host with no path")
        XCTAssertNil(TrackerRules.knownEndpoint(for: "ftp://www.google-analytics.com/collect"), "only http and https")
        XCTAssertNil(TrackerRules.knownEndpoint(for: "data:image/gif;base64,R0lGODlh"))
        XCTAssertNil(TrackerRules.knownEndpoint(for: "https://www.facebook.com/tr/extra"), "an exact path takes nothing after it")
        XCTAssertNotNil(TrackerRules.knownEndpoint(for: "https://go.example.com/trk?mid=1&t=1"), "the parameter anywhere in the query")
    }

    // MARK: Heuristics

    private let image = "https://cdn.example.com/images/photo.png"

    func testTinyImagesAreTrackers() {
        let cases: [(TrackerRules.ImageHints, String)] = [
            (.init(width: "1", height: "1"), "1 × 1 attributes"),
            (.init(width: "3", height: "2"), "3 × 2"),
            (.init(width: "1px", height: "1px"), "px in an attribute, as browsers read it"),
            (.init(width: "0", height: "40"), "zero width"),
            (.init(width: "600", height: "0"), "zero height"),
            (.init(style: "width:1px;height:1px"), "inline size"),
            (.init(style: "WIDTH: 2PX !important; height: 1px"), "case and !important"),
            (.init(width: "600", height: "300", style: "width:1px;height:1px"), "the style wins over the attributes"),
            (.init(style: "height:0"), "zero height in the style"),
            (.init(width: "1", height: "1", style: "border:0"), "a style that says nothing of size"),
        ]
        for (hints, name) in cases {
            XCTAssertEqual(TrackerRules.reason(forImageAt: image, hints: hints), .tiny, name)
        }
    }

    func testHiddenImagesAreTrackers() {
        let cases: [(TrackerRules.ImageHints, String)] = [
            (.init(style: "display:none"), "display none"),
            (.init(width: "1", height: "1", style: "display:none"), "a hidden pixel"),
            (.init(style: "display: none !important"), "display none, important"),
            (.init(style: "visibility:hidden"), "visibility hidden"),
            (.init(style: "visibility:collapse"), "visibility collapse"),
            (.init(style: "opacity:0"), "opacity 0"),
            (.init(style: "opacity: 0.0"), "opacity 0.0"),
            (.init(style: "opacity:0%"), "opacity 0%"),
            (.init(style: "max-height:0px;overflow:hidden"), "max-height 0"),
            (.init(style: "max-width:0"), "max-width 0"),
            (.init(hidden: true), "the hidden attribute"),
            (.init(width: "3", height: "3", style: "visibility:hidden"), "hidden at the tiny size"),
        ]
        for (hints, name) in cases {
            XCTAssertEqual(TrackerRules.reason(forImageAt: image, hints: hints), .hidden, name)
        }
    }

    /// A responsive email hides its mobile-only picture inline and shows it again from an `@media` rule, which the rules
    /// never read: a picture that declares a real size, or that a stylesheet can reach by its class or id, is not taken for
    /// a tracker because it is hidden. One that is tiny is a tracker all the same.
    func testPicturesHiddenUntilAStylesheetShowsThemAreNotTrackers() {
        let cases: [(TrackerRules.ImageHints, String)] = [
            (.init(width: "320", height: "200", style: "display:none;max-height:0;overflow:hidden"), "a mobile hero with its size"),
            (.init(style: "display:none;width:100%;height:auto"), "a percentage width"),
            (.init(width: "100%", style: "max-height:0"), "a percentage in the attribute"),
            (.init(style: "max-width:0;width:320px"), "an inline size"),
            (.init(style: "display:none", styleable: true), "a class or id a stylesheet can reach"),
            (.init(width: "600", height: "300", hidden: true), "the hidden attribute on a sized picture"),
        ]
        for (hints, name) in cases {
            XCTAssertNil(TrackerRules.reason(forImageAt: image, hints: hints), name)
        }
        XCTAssertEqual(TrackerRules.reason(forImageAt: image, hints: .init(width: "1", height: "1", style: "display:none", styleable: true)),
                       .tiny, "a classed pixel is still a pixel")
        XCTAssertEqual(TrackerRules.reason(forImageAt: "https://us21.list-manage.com/track/open.php?u=1",
                                           hints: .init(width: "320", height: "200", style: "display:none", styleable: true)),
                       .known, "a known endpoint, whatever it declares")
    }

    /// Content keeps loading: a picture of any ordinary size, one with no size at all, a relative size, a thin rule or
    /// spacer taller or wider than a pixel, a faded but visible image.
    func testContentImagesAreNotTrackers() {
        let cases: [(TrackerRules.ImageHints, String)] = [
            (.init(), "no size given"),
            (.init(width: "600", height: "300"), "a hero"),
            (.init(width: "1"), "one side only"),
            (.init(width: "1", height: "20"), "a 1 px rule"),
            (.init(width: "100%", height: "2"), "a relative width"),
            (.init(width: "4", height: "4"), "4 × 4 is over the line"),
            (.init(style: "width:1em;height:1em"), "a relative unit"),
            (.init(style: "width:auto;height:auto"), "auto"),
            (.init(style: "opacity:0.5"), "faded, still seen"),
            (.init(style: "display:block;max-width:100%"), "the usual responsive image"),
            (.init(style: "width:-1px;height:-1px"), "an invalid negative size is ignored"),
        ]
        for (hints, name) in cases {
            XCTAssertNil(TrackerRules.reason(forImageAt: image, hints: hints), name)
        }
    }

    // MARK: Content blocker

    /// The WebKit expressions are the matcher's rules written another way: for every sample, and for each endpoint on its
    /// own, both say the same. ICU reads every construct WebKit's subset allows the same way.
    func testURLFiltersAgreeWithTheMatcher() throws {
        for endpoint in TrackerRules.endpoints {
            let filter = endpoint.urlFilter()
            let expression = try NSRegularExpression(pattern: filter, options: [.caseInsensitive])
            for address in pixels + content + [
                "https://US21.LIST-MANAGE.COM/TRACK/OPEN.PHP?u=1", "https://us21.list-manage.com:8443/track/open.php",
                "https://www.facebook.com/tr/extra", "https://www.facebook.com/tr#x",
            ] {
                let range = NSRange(address.startIndex..., in: address)
                let regex = expression.firstMatch(in: address, range: range) != nil
                XCTAssertEqual(regex, endpoint.matches(address), "\(endpoint.service) \(filter) on \(address)")
            }
        }
    }

    /// The shell reads the same expressions as JavaScript regular expressions (`SS_TRACKER_FILTERS`), to tell a known
    /// pixel in a body stored before the marks: each compiles in JavaScriptCore and says what the matcher says on every
    /// sample, with the case-insensitive flag the shell gives it.
    func testURLFiltersReadTheSameInJavaScript() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(ConversationShellAssets.trackerFiltersScript())
        XCTAssertNil(context.exception)
        XCTAssertTrue(ConversationShellAssets.js.contains(ConversationShellAssets.trackerFiltersScript()), "the shell carries them")
        let addresses = pixels + content + [
            "https://US21.LIST-MANAGE.COM/TRACK/OPEN.PHP?u=1", "https://us21.list-manage.com:8443/track/open.php",
            "https://www.facebook.com/tr/extra", "https://www.facebook.com/tr#x",
        ]
        let list = String(decoding: try JSONSerialization.data(withJSONObject: addresses), as: UTF8.self)
        let script = """
            JSON.stringify(SS_TRACKER_FILTERS.map(function (filter) {
              var pattern = new RegExp(filter, 'i');
              return \(list).map(function (address) { return pattern.test(address); });
            }))
            """
        let json = try XCTUnwrap(context.evaluateScript(script)?.toString())
        XCTAssertNil(context.exception, "\(String(describing: context.exception))")
        let matrix = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[Bool]])
        XCTAssertEqual(matrix.count, TrackerRules.endpoints.count)
        for (endpoint, row) in zip(TrackerRules.endpoints, matrix) {
            for (address, matched) in zip(addresses, row) {
                XCTAssertEqual(matched, endpoint.matches(address), "\(endpoint.service) \(endpoint.urlFilter()) on \(address)")
            }
        }
    }

    /// Only constructs WebKit's content blocker compiles: no alternation and no counted repetition.
    func testURLFiltersStayInWebKitsSubset() {
        for endpoint in TrackerRules.endpoints {
            let filter = endpoint.urlFilter()
            XCTAssertTrue(filter.hasPrefix("^https?://"), filter)
            XCTAssertFalse(filter.contains("|"), "alternation: \(filter)")
            XCTAssertFalse(filter.contains("{"), "counted repetition: \(filter)")
            XCTAssertTrue(filter.allSatisfy(\.isASCII), filter)
            if let dollar = filter.firstIndex(of: "$") { XCTAssertEqual(dollar, filter.index(before: filter.endIndex), "$ only at the end: \(filter)") }
        }
    }

    func testContentRuleListIsOneBlockRulePerEndpoint() throws {
        let data = Data(TrackerRules.contentRuleListJSON().utf8)
        let rules = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rules.count, TrackerRules.endpoints.count)
        for (rule, endpoint) in zip(rules, TrackerRules.endpoints) {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            XCTAssertEqual(trigger["url-filter"] as? String, endpoint.urlFilter())
            XCTAssertEqual(trigger["resource-type"] as? [String], ["image", "style-sheet", "font", "media", "raw"])
            XCTAssertNil(trigger["url-filter-is-case-sensitive"], "case-insensitive, as the matcher is")
            XCTAssertEqual((rule["action"] as? [String: Any])?["type"] as? String, "block")
        }
        let stand = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(TrackerRules.contentRuleListJSON(scheme: "ss-remote").utf8))
                                    as? [[String: Any]])
        XCTAssertTrue(((stand.first?["trigger"] as? [String: Any])?["url-filter"] as? String)?.hasPrefix("^ss-remote://") == true,
                      "the tests' stand-in scheme for the network")
    }

    func testContentRuleListIdentifierCarriesTheVersionAndTheRules() {
        let identifier = TrackerRules.contentRuleListIdentifier()
        XCTAssertEqual(identifier, TrackerRules.contentRuleListIdentifier(json: TrackerRules.contentRuleListJSON()),
                       "the same digest from JSON already written")
        XCTAssertTrue(identifier.hasPrefix(TrackerRules.contentRuleListPrefix + "\(TrackerRules.version)-"), identifier)
        XCTAssertEqual(identifier, TrackerRules.contentRuleListIdentifier(), "stable from run to run")
        XCTAssertNotEqual(identifier, TrackerRules.contentRuleListIdentifier(scheme: "ss-remote"), "other rules, another compilation")
    }
}
