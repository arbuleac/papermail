import Foundation
import XCTest
@testable import SSCore

/// The demo's tracker sample (spec §5.60, `--snapshot-state=trackers`): one newsletter whose remote pictures are answered
/// on this Mac and whose trackers are the three kinds the rules know, so a render shows pictures loaded and trackers held
/// back with nothing reaching the network.
final class DemoTrackerSampleTests: XCTestCase {
    private let account = AccountID("demo-gmail")
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func sample() throws -> DemoRecord {
        var builder = DemoMailboxBuilder(profile: .gmail, accountID: account, reference: now)
        let samples = builder.build().filter { DemoTrackerSample.isSample($0.metadata) }
        XCTAssertEqual(samples.count, 1, "one issue is the sample")
        return try XCTUnwrap(samples.first)
    }

    func testTheSampleCarriesThreeTrackersAndPicturesMadeHere() throws {
        let record = try sample()
        XCTAssertTrue(record.metadata.isInInbox, "the inbox lists it, so the snapshot can open it")
        for allow in [false, true] {
            let sanitizer = DemoStandInSanitizer(base: HTMLSanitizer(allowRemoteImages: allow))
            let body = sanitizer.sanitize(record.body, messageID: record.metadata.id)
            XCTAssertEqual(body.trackerImageCount, 3, "a known endpoint, a hidden pixel and the 1 px pixel (allow \(allow))")
            for reason in TrackerRules.Reason.allCases {
                XCTAssertTrue(body.html.contains("\(HTMLSanitizer.trackerAttribute)=\"\(reason.rawValue)\""), "\(reason) (allow \(allow))")
            }
            XCTAssertFalse(body.html.contains(DemoStandInSanitizer.host), "every stand-in became a picture (allow \(allow))")
            XCTAssertEqual(RenderPayloadBuilder.occurrences(of: "data:image/svg+xml;base64,", in: body.html), 4, "the hero and three tiles")
            // What could still reach a server once images load: only the trackers, which stay parked while blocking is on.
            let live = body.html.components(separatedBy: " src=\"http").count - 1
            XCTAssertEqual(live, 0, "no live remote source (allow \(allow))")
        }
        let held = DemoStandInSanitizer(base: HTMLSanitizer()).sanitize(record.body, messageID: record.metadata.id)
        XCTAssertEqual(RenderPayloadBuilder.occurrences(of: "data-ss-src=\"data:image/svg+xml", in: held.html), 4,
                       "parked like any remote image, so Load images brings them in")
    }

    /// Every demo body, its images loaded and Block trackers on (`--snapshot-state=trackers` pre-renders the sample's
    /// neighbours that way), asks the network for nothing: each newsletter's hero is a picture made here, and all that is
    /// left remote is the trackers, parked and marked.
    func testNoDemoBodyReachesTheNetworkOnceImagesLoad() {
        let sanitizer = DemoStandInSanitizer(base: HTMLSanitizer(allowRemoteImages: true))
        var heroes = 0
        for profile in DemoProfile.all {
            var builder = DemoMailboxBuilder(profile: profile, accountID: AccountID("demo-\(profile.kind)"), reference: now)
            for record in builder.build() {
                let body = sanitizer.sanitize(record.body, messageID: record.metadata.id)
                XCTAssertEqual(body.html.components(separatedBy: " src=\"http").count - 1, 0, "no live remote source: \(record.metadata.subject)")
                XCTAssertEqual(RenderPayloadBuilder.occurrences(of: "data-ss-src=\"http", in: body.html), body.trackerImageCount,
                               "every remote source left is a tracker: \(record.metadata.subject)")
                XCTAssertFalse(body.html.contains("background=\"http"), record.metadata.subject)
                heroes += RenderPayloadBuilder.occurrences(of: "data:image/svg+xml;base64,", in: body.html)
            }
        }
        XCTAssertGreaterThan(heroes, 4, "the newsletters' heroes are pictures made here too")
    }

    func testOtherBodiesPassThroughUnchanged() {
        let body = MessageBody(html: "<p>Hi <img src=\"https://stand-in.demo.test/unknown.svg\"></p>", text: nil)
        let id = MessageID(accountID: account, providerID: "m1")
        let plain = HTMLSanitizer(allowRemoteImages: true).sanitize(body, messageID: id)
        XCTAssertEqual(DemoStandInSanitizer(base: HTMLSanitizer(allowRemoteImages: true)).sanitize(body, messageID: id), plain,
                       "an unknown name is left as written")
        XCTAssertEqual(DemoStandInSanitizer.pointingAtStandIns("<p>no images</p>"), "<p>no images</p>")
    }
}
