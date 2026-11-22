import Foundation
import XCTest
@testable import PaperCore

/// The sanitizer's part of Block trackers (spec §5.60): every remote image the rules call a tracker is parked and marked
/// whatever the remote-images setting, and counted; content images are left as the setting says; a mark in incoming mail
/// never survives.
final class SanitizerTrackerTests: XCTestCase {
    private let newsletter = """
        <p>Fall gear is here.</p>\
        <img src="https://images.shop.example/hero.jpg" width="600" height="240" alt="Hero">\
        <img src="https://us21.list-manage.com/track/open.php?u=1&amp;id=2" width="600" height="40" alt="">\
        <img src="https://px.shop.example/v/open.png" style="display:none" alt="">\
        <img src="https://track.shop.example/open.gif" width="1" height="1" alt="">\
        <img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" width="1" height="1" alt="inline">
        """

    private func trackers(in html: String) -> [String] {
        html.components(separatedBy: HTMLSanitizer.trackerAttribute + "=\"").dropFirst().map { String($0.prefix { $0 != "\"" }) }
    }

    func testTrackersAreParkedAndMarkedWithRemoteImagesAllowed() {
        let body = RenderTestSupport.sanitize(newsletter, allowRemoteImages: true)
        XCTAssertEqual(body.trackerImageCount, 3)
        XCTAssertEqual(body.blockedRemoteImageCount, 3, "each tracker is parked; the hero loads")
        XCTAssertEqual(trackers(in: body.html), ["known", "hidden", "tiny"])
        assertContains(body.html, "src=\"https://images.shop.example/hero.jpg\"")
        assertNotContains(body.html, " src=\"https://us21.list-manage.com")
        assertContains(body.html, "data-ss-src=\"https://us21.list-manage.com/track/open.php?u=1&amp;id=2\"")
        assertContains(body.html, "data-ss-src=\"https://px.shop.example/v/open.png\"")
        assertContains(body.html, "data-ss-src=\"https://track.shop.example/open.gif\"")
        XCTAssertEqual(RenderPayloadBuilder.blockedRemoteImageCount(in: body.html), 3, "the count the store keeps is the parked attributes")
        XCTAssertEqual(RenderPayloadBuilder.occurrences(of: "src=\"" + HTMLSanitizer.placeholderImage, in: body.html), 3,
                       "a parked tracker shows the transparent stand-in")
    }

    func testTrackersAreMarkedAmongTheParkedWithRemoteImagesBlocked() {
        let body = RenderTestSupport.sanitize(newsletter)
        XCTAssertEqual(body.trackerImageCount, 3)
        XCTAssertEqual(body.blockedRemoteImageCount, 4, "the hero is parked too, unmarked")
        XCTAssertEqual(trackers(in: body.html), ["known", "hidden", "tiny"])
        assertContains(body.html, "data-ss-src=\"https://images.shop.example/hero.jpg\"")
        XCTAssertEqual(RenderPayloadBuilder.blockedRemoteImageCount(in: body.html), 4)
    }

    /// Size and visibility come from the image's own attributes and style, whichever order they are written in.
    func testHintsAreReadWhateverTheAttributeOrder() {
        for html in [
            "<img width=\"1\" height=\"1\" src=\"https://cdn.example/p.gif\">",
            "<img src=\"https://cdn.example/p.gif\" width=\"1\" height=\"1\">",
            "<img style=\"display:none\" src=\"https://cdn.example/p.gif\">",
            "<img src=\"https://cdn.example/p.gif\" hidden>",
        ] {
            let body = RenderTestSupport.sanitize(html, allowRemoteImages: true)
            XCTAssertEqual(body.trackerImageCount, 1, html)
            XCTAssertEqual(trackers(in: body.html).count, 1, html)
        }
    }

    /// A responsive newsletter's mobile-only pictures are hidden inline and shown by its `@media` rules: left as the
    /// setting says, while a pixel hidden beside them is still marked.
    func testPicturesAStylesheetShowsAreLeftAlone() {
        let html = """
            <style>@media (max-width:600px){.m-show{display:block!important;max-height:none!important}#m-hero{display:block!important}}</style>\
            <img class="m-show" src="https://cdn.shop.example/hero-mobile.jpg" width="320" height="200" style="display:none;max-height:0;overflow:hidden">\
            <img id="m-hero" src="https://cdn.shop.example/hero-2.jpg" style="display:none">\
            <img src="https://cdn.shop.example/hero-3.jpg" style="display:none;width:100%">\
            <img src="https://px.shop.example/open.png" style="display:none">
            """
        let body = RenderTestSupport.sanitize(html, allowRemoteImages: true)
        XCTAssertEqual(body.trackerImageCount, 1, "only the pixel")
        XCTAssertEqual(trackers(in: body.html), ["hidden"])
        for picture in ["hero-mobile.jpg", "hero-2.jpg", "hero-3.jpg"] {
            assertContains(body.html, "src=\"https://cdn.shop.example/\(picture)\"")
        }
        assertContains(body.html, "data-ss-src=\"https://px.shop.example/open.png\"")
    }

    func testContentImagesAreNeverMarked() {
        let html = """
            <img src="https://images.shop.example/a.jpg" width="300" height="200">\
            <img src="https://images.shop.example/b.jpg">\
            <img src="cid:logo@shop.example" width="1" height="1">\
            <img src="data:image/png;base64,iVBORw0KGgo=" style="display:none">\
            <div style="background:url(https://us21.list-manage.com/track/open.php)">x</div>
            """
        for allow in [true, false] {
            let body = RenderTestSupport.sanitize(html, allowRemoteImages: allow)
            XCTAssertEqual(body.trackerImageCount, 0, "allow \(allow)")
            assertNotContains(body.html, HTMLSanitizer.trackerAttribute)
        }
    }

    /// A sender cannot pre-mark an image so the reader holds back content, nor smuggle a tracker past by marking it
    /// otherwise: an incoming `data-ss-tracker` is dropped like every `data-ss-` attribute, and the sanitizer's own
    /// verdict is the only mark.
    func testAnIncomingMarkIsDropped() {
        let html = """
            <img src="https://images.shop.example/a.jpg" width="300" height="200" data-ss-tracker="known">\
            <img src="https://track.shop.example/p.gif" width="1" height="1" DATA-SS-TRACKER="none">\
            <p data-ss-tracker="1">Hi</p>
            """
        let body = RenderTestSupport.sanitize(html, allowRemoteImages: true)
        XCTAssertEqual(body.trackerImageCount, 1)
        XCTAssertEqual(trackers(in: body.html), ["tiny"])
        assertContains(body.html, "src=\"https://images.shop.example/a.jpg\"")
        assertNotContains(body.html, "none")
    }

    func testPlainTextBodiesCarryNoTrackers() {
        XCTAssertEqual(RenderTestSupport.sanitizeText("See https://track.shop.example/open.gif").trackerImageCount, 0)
    }
}
