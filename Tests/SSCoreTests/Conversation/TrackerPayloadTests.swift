import Foundation
import XCTest
@testable import SSCore

/// Block trackers in the payload and the printout (spec §5.60): the stored count reaches the shell with the setting, a body
/// stored before the marks counts none, and a printout holds marked trackers back while the setting is on, leaving them
/// out of its count of held-back images.
final class TrackerPayloadTests: XCTestCase {
    private typealias F = ConversationFixtures
    private let now = F.utc(2025, 3, 7, 15, 0)
    private let printer = PrintDocumentBuilder(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!,
                                               calendar: Calendar(identifier: .gregorian), imageWait: 3)
    private let parked = "<img src=\"\(HTMLSanitizer.placeholderImage)\" data-ss-src=\"https://cdn.example/hero.jpg\">"
        + "<img src=\"\(HTMLSanitizer.placeholderImage)\" data-ss-src=\"https://track.example/p.gif\" data-ss-tracker=\"tiny\">"
        + "<img src=\"\(HTMLSanitizer.placeholderImage)\" data-ss-src=\"https://us1.list-manage.com/track/open.php\" data-ss-tracker=\"known\">"

    private func body(trackers: Int?) -> StoredBody {
        var body = F.body(html: "<div class=\"ss-body\"><p>News</p>" + parked + "</div>")
        body.blockedRemoteImageCount = 3
        body.trackerImageCount = trackers
        return body
    }

    private func payload(_ body: StoredBody, blocksTrackers: Bool, loadRemoteImages: Bool = false) -> RenderPayload {
        let message = F.message("m1")
        return F.builder.build(messages: [message], bodies: [message.id: body], accounts: F.accounts, loadRemoteImages: loadRemoteImages,
                               blocksTrackers: blocksTrackers, now: now)
    }

    func testThePayloadCarriesTheCountAndTheSetting() throws {
        let on = payload(body(trackers: 2), blocksTrackers: true)
        XCTAssertTrue(on.blocksTrackers)
        XCTAssertEqual(on.messages[0].trackerImageCount, 2)
        XCTAssertEqual(on.messages[0].blockedRemoteImageCount, 3, "the trackers stay in the parked count; the shell takes them out")
        let off = payload(body(trackers: 2), blocksTrackers: false)
        XCTAssertFalse(off.blocksTrackers)
        XCTAssertEqual(off.messages[0].trackerImageCount, 2, "the count travels either way; the setting decides what it does")

        let json = try on.jsonString()
        XCTAssertTrue(json.contains("\"blocksTrackers\":true"))
        XCTAssertTrue(json.contains("\"trackerImageCount\":2"))
    }

    func testABodyStoredBeforeTheMarksCountsNone() {
        XCTAssertEqual(payload(body(trackers: nil), blocksTrackers: true).messages[0].trackerImageCount, 0)
        let message = F.message("m1", snippet: "Fall gear")
        let pending = F.builder.build(messages: [message], bodies: [:], accounts: F.accounts, blocksTrackers: true, now: now)
        XCTAssertEqual(pending.messages[0].trackerImageCount, 0, "no body yet, nothing counted")
    }

    // MARK: Print

    private func sheets(of html: String) -> String {
        html.components(separatedBy: "<main class=\"ss-pdoc\">").last?.components(separatedBy: "</main>").first ?? ""
    }

    func testAPrintoutLeavesTrackersOutOfItsHeldBackCount() {
        let key = RenderPayload.messageKey(for: F.message("m1").id)
        let held = [key: PrintSheetState(imagesShown: false)]
        let on = printer.document(for: payload(body(trackers: 2), blocksTrackers: true), sheets: held)
        XCTAssertTrue(sheets(of: on).contains("<span>1 remote image hidden</span>"), "only the hero is the reader's to offer")
        let off = printer.document(for: payload(body(trackers: 2), blocksTrackers: false), sheets: held)
        XCTAssertTrue(sheets(of: off).contains("<span>3 remote images hidden</span>"))

        var trackersOnly = body(trackers: 2)
        trackersOnly.blockedRemoteImageCount = 2
        let quiet = printer.document(for: payload(trackersOnly, blocksTrackers: true), sheets: held)
        XCTAssertFalse(sheets(of: quiet).contains("remote image"), "nothing the reader offers is held back")
    }

    /// The document's script puts parked sources back for a body whose images print, but not the marked ones of a body
    /// the setting holds trackers back in.
    func testAPrintoutHoldsMarkedTrackersBackWhileTheSettingIsOn() {
        let key = RenderPayload.messageKey(for: F.message("m1").id)
        let shown = [key: PrintSheetState(imagesShown: true)]
        let on = printer.document(for: payload(body(trackers: 2), blocksTrackers: true), sheets: shown)
        XCTAssertTrue(sheets(of: on).contains("data-images=\"shown\" data-trackers=\"held\""))
        XCTAssertTrue(on.contains("img[data-ss-src]:not([data-ss-tracker])"))
        XCTAssertTrue(on.contains("restore(content, host.getAttribute('data-trackers') === 'held')"))
        let off = printer.document(for: payload(body(trackers: 2), blocksTrackers: false), sheets: shown)
        XCTAssertFalse(sheets(of: off).contains("data-trackers"), "with the setting off they load as Load images loads them")
        let none = printer.document(for: payload(body(trackers: 0), blocksTrackers: true), sheets: shown)
        XCTAssertFalse(sheets(of: none).contains("data-trackers"))
    }
}
