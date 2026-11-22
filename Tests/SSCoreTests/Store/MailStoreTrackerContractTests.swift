import XCTest
import SSCore

/// The `MailStoring` contract for `bodies.tracker_images` (v24, spec §5.60): the count of images the sanitizer parked as
/// trackers is kept with the body, nil for a body stored without one (as every body from before v24 reads), and replaced
/// whole by the next save. Written as an extension so `SQLiteMailStoreContractTests` inherits every case and both stores
/// are held to the same semantics.
extension MailStoreContractTests {
    func testTrackerImageCountIsKeptWithTheBody() throws {
        try store.upsertMessages([message("m1", in: "c1"), message("m2", in: "c2")])
        let m1 = MessageID(accountID: accountA, providerID: "m1")
        let m2 = MessageID(accountID: accountA, providerID: "m2")
        var counted = body("Fall gear is here")
        counted.blockedRemoteImageCount = 4
        counted.trackerImageCount = 3
        try store.saveBody(counted, for: m1)
        try store.saveBody(body("No count"), for: m2)

        XCTAssertEqual(try store.body(for: m1)?.trackerImageCount, 3)
        XCTAssertEqual(try store.body(for: m1)?.blockedRemoteImageCount, 4)
        XCTAssertNil(try store.body(for: m2)?.trackerImageCount, "unknown, as a body stored before v24 reads")

        counted.trackerImageCount = 0
        try store.saveBody(counted, for: m1)
        XCTAssertEqual(try store.body(for: m1)?.trackerImageCount, 0, "a body fetched again replaces the count")
        counted.trackerImageCount = nil
        try store.saveBody(counted, for: m1)
        XCTAssertNil(try store.body(for: m1)?.trackerImageCount)
    }
}
